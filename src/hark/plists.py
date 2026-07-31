"""Render the launchd plist templates from config.

launchd does not read ``config.py`` — it reads its own XML. Anything that must
agree between the two (bind address, ports, model path, vocabulary prompt) can
therefore drift silently into production. The templates in ``launchd/`` carry
placeholders instead of values, this module fills them from config, and
``tests/test_launchd_config_sync.py`` renders them and asserts agreement. That
makes drift a test failure rather than a mystery.

Run it directly to install the services::

    uv run python -m hark.plists            # render to ~/Library/LaunchAgents
    uv run python -m hark.plists --print    # render to stdout, install nothing
"""

import argparse
import shutil
import sys
from pathlib import Path
from xml.sax.saxutils import escape

from hark import config

# Rendering is an INSTALL-time task, run from a checkout: the templates live in
# the repo and are not shipped in the wheel, so these resolve only when this
# module is imported from the source tree. Running `python -m hark.plists` out
# of the installed venv is a mistake with a specific message - see main().
REPO_ROOT = Path(__file__).resolve().parent.parent.parent
TEMPLATE_DIR = REPO_ROOT / "launchd"
LAUNCH_AGENTS = Path.home() / "Library/LaunchAgents"

# Where install-server.sh installs the package for the running service.
#
# The clone is a place you edit code, not a place a daemon lives. Pointing
# launchd at the checkout made moving or deleting it break the service - with
# KeepAlive true, that shows up only as a restart loop and a nonzero exit in
# /tmp/hark.err - and made `git pull` live-patch a running daemon, so the next
# utterance ran whatever had just landed. Installing into a stable prefix makes
# the clone disposable and upgrades explicit: re-run install-server.sh.
INSTALL_DIR = Path.home() / ".local/share/hark"
VENV_DIR = INSTALL_DIR / "venv"

TEMPLATES = (
    "com.drycodeworks.hark.plist",
    "com.drycodeworks.hark-whisper.plist",
)


def _tool(name: str, fallback: str) -> str:
    """Absolute path to an installed CLI.

    launchd jobs get a bare PATH — nothing from a login shell, no Homebrew —
    so every executable in a plist must be an absolute path or the job dies at
    load with a spawn error and no useful message.
    """
    return shutil.which(name) or fallback


class UnsafeBindError(ValueError):
    """Raised when the configured bind address would expose the service."""


# 0.0.0.0 and :: are every interface; "" is how most socket APIs spell the
# same thing. Everything else is allowed on purpose — the two-machine setup
# binds to a private address, so this cannot be a whitelist of loopback.
WILDCARD_BINDS = frozenset({"0.0.0.0", "::", ""})


def _check_bind(host: str) -> str:
    """Refuse a wildcard bind before it can reach a plist.

    `hark` returns text that goes onto the clipboard and is then pasted into
    whatever has focus, so an endpoint reachable from every attached network
    lets anyone who can route to this machine choose what gets typed into the
    user's terminal. The drift guard in the test suite asserted this, but
    `install-server.sh` renders and bootstraps without ever running pytest —
    so for an actual user the check did not exist. Enforcing it here is what
    makes the promise in README.md and config.example.toml true.
    """
    if host.strip() in WILDCARD_BINDS:
        raise UnsafeBindError(
            f"server.bind is {host!r}, which listens on every network interface.\n"
            "hark's response is pasted into whatever has focus, so this lets "
            "anyone who can reach this machine choose what gets typed.\n"
            "Use 127.0.0.1 for a single machine, or the private address of "
            "this machine (a tailnet/VPN/LAN IP) for the two-machine setup.\n"
            "Set it in ~/.config/hark/config.toml."
        )
    return host


def substitutions() -> dict[str, str]:
    """The placeholder → value map, derived entirely from config."""
    return {
        # The installed venv's uvicorn, by absolute path - not `uv run` from
        # the clone. uv is needed to install the service, not to run it.
        "@UVICORN@": str(VENV_DIR / "bin" / "uvicorn"),
        "@WHISPER_SERVER@": _tool("whisper-server", "/opt/homebrew/bin/whisper-server"),
        "@BIND@": _check_bind(config.HARK_HOST),
        "@PORT@": str(config.HARK_PORT),
        "@WHISPER_HOST@": config.WHISPER_HOST,
        "@WHISPER_PORT@": str(config.WHISPER_PORT),
        "@MODEL@": str(config.MODEL_PATH),
        "@PROMPT@": config.VOCAB_PROMPT,
    }


def render(name: str) -> str:
    """Return the rendered plist XML for one template."""
    text = (TEMPLATE_DIR / f"{name}.template").read_text()
    for token, value in substitutions().items():
        # The values land inside XML text nodes, and a vocabulary prompt is
        # free text a user wrote — an unescaped & or < would produce a plist
        # that launchd rejects as malformed.
        text = text.replace(token, escape(value))
    leftover = [t for t in substitutions() if t in text]
    if leftover:
        raise AssertionError(f"unsubstituted placeholder in {name}: {leftover}")
    return text


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--print",
        action="store_true",
        dest="print_only",
        help="write the rendered plists to stdout instead of installing them",
    )
    args = parser.parse_args(argv)

    # Same reasoning as the bind check below: this is reachable by running the
    # installed copy instead of the checkout, and a FileNotFoundError naming a
    # path inside site-packages/ does not tell anyone what to do about it.
    if not TEMPLATE_DIR.is_dir():
        print(
            f"error: no plist templates at {TEMPLATE_DIR}.\n"
            "The templates live in the repo and are not shipped in the wheel, "
            "so rendering has to run from a checkout:\n"
            "  cd /path/to/hark && uv run python -m hark.plists",
            file=sys.stderr,
        )
        return 1

    # A misconfigured bind is a user error in a TOML file, not a bug — it
    # deserves the message, not a traceback. install-server.sh calls this, so
    # this is what the user sees mid-install.
    try:
        rendered = {name: render(name) for name in TEMPLATES}
    except UnsafeBindError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if args.print_only:
        for name, text in rendered.items():
            print(f"===== {name} =====")
            print(text)
        return 0

    LAUNCH_AGENTS.mkdir(parents=True, exist_ok=True)
    for name, text in rendered.items():
        target = LAUNCH_AGENTS / name
        target.write_text(text)
        print(f"wrote {target}")

    label_args = " ".join(f"gui/$(id -u)/{n.removesuffix('.plist')}" for n in TEMPLATES)
    print(
        "\nNot loaded yet. To (re)load:\n"
        f"  for l in {label_args}; do launchctl bootout $l 2>/dev/null; done\n"
        f"  for n in {' '.join(TEMPLATES)}; do "
        'launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/$n"; done'
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
