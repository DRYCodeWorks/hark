"""Render the launchd plist templates from config.

launchd does not read ``config.py`` — it reads its own XML. Anything that must
agree between the two (bind address, ports, model path, vocabulary prompt) can
therefore drift silently into production. The templates in ``launchd/`` carry
placeholders instead of values, this module fills them from config, and
``tests/test_launchd_config_sync.py`` renders them and asserts agreement. That
makes drift a test failure rather than a mystery.

Run it directly to install the services::

    uv run python -m dictated.plists            # render to ~/Library/LaunchAgents
    uv run python -m dictated.plists --print    # render to stdout, install nothing
"""

import argparse
import shutil
import sys
from pathlib import Path
from xml.sax.saxutils import escape

from dictated import config

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
TEMPLATE_DIR = REPO_ROOT / "launchd"
LAUNCH_AGENTS = Path.home() / "Library/LaunchAgents"

TEMPLATES = (
    "com.drycodeworks.dictated.plist",
    "com.drycodeworks.whisper-server.plist",
)


def _tool(name: str, fallback: str) -> str:
    """Absolute path to an installed CLI.

    launchd jobs get a bare PATH — nothing from a login shell, no Homebrew —
    so every executable in a plist must be an absolute path or the job dies at
    load with a spawn error and no useful message.
    """
    return shutil.which(name) or fallback


def substitutions() -> dict[str, str]:
    """The placeholder → value map, derived entirely from config."""
    return {
        "@UV@": _tool("uv", "/opt/homebrew/bin/uv"),
        "@WHISPER_SERVER@": _tool("whisper-server", "/opt/homebrew/bin/whisper-server"),
        "@WORKDIR@": str(REPO_ROOT),
        "@BIND@": config.DICTATED_HOST,
        "@PORT@": str(config.DICTATED_PORT),
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

    if args.print_only:
        for name in TEMPLATES:
            print(f"===== {name} =====")
            print(render(name))
        return 0

    LAUNCH_AGENTS.mkdir(parents=True, exist_ok=True)
    for name in TEMPLATES:
        target = LAUNCH_AGENTS / name
        target.write_text(render(name))
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
