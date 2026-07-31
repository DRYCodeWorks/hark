"""Guard against launchd plist drift from src/hark/config.py.

The launchd plists carry values (host, port, model path, vocab prompt) that
MUST match config.py — launchd doesn't read config.py, it reads its own XML.
Nothing enforces agreement except a human reading both files side by side.

The plists are now rendered from templates by ``hark.plists``, so these
tests render them and parse the result with plistlib. That closes a loop the
old version could not: a template that loses a placeholder, or a substitution
that stops reaching config, now fails here instead of silently drifting into
production.
"""

import ipaddress
import plistlib
from pathlib import Path

import pytest

from hark import config, plists

TEMPLATE_DIR = Path(plists.TEMPLATE_DIR)
WHISPER_PLIST = "com.drycodeworks.hark-whisper.plist"
DICTATED_PLIST = "com.drycodeworks.hark.plist"


def render_plist(name: str) -> dict:
    return plistlib.loads(plists.render(name).encode())


def arg_after(args: list[str], flag: str) -> str:
    """Return the ProgramArguments value immediately following `flag`.

    Fails with a clear message (not an IndexError) if the flag is absent or
    is the last element with nothing after it.
    """
    if flag not in args:
        raise AssertionError(f"{flag!r} not found in ProgramArguments: {args!r}")
    idx = args.index(flag)
    if idx + 1 >= len(args):
        raise AssertionError(f"{flag!r} has no value after it in: {args!r}")
    return args[idx + 1]


def is_loopback(host: str) -> bool:
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return host == "localhost"


class TestTemplatesRender:
    def test_every_template_exists(self):
        for name in plists.TEMPLATES:
            assert (TEMPLATE_DIR / f"{name}.template").is_file()

    def test_no_placeholder_survives_rendering(self):
        # render() raises on a leftover placeholder; this also asserts the
        # result is valid plist XML, which a half-substituted file is not.
        for name in plists.TEMPLATES:
            assert render_plist(name)["Label"].startswith("com.drycodeworks.")

    def test_no_personal_path_is_baked_into_a_template(self):
        # The templates are published. A rendered plist may contain the
        # invoking user's home directory; a template never may.
        for name in plists.TEMPLATES:
            text = (TEMPLATE_DIR / f"{name}.template").read_text()
            assert "/Users/" not in text
            assert str(Path.home()) not in text


class TestWhisperServerPlist:
    def setup_method(self):
        self.plist = render_plist(WHISPER_PLIST)
        self.args = self.plist["ProgramArguments"]

    def test_prompt_matches_vocab_prompt(self):
        plist_prompt = arg_after(self.args, "--prompt")
        assert plist_prompt == config.VOCAB_PROMPT

    def test_host_matches_config_and_is_loopback(self):
        plist_host = arg_after(self.args, "--host")
        assert plist_host == config.WHISPER_HOST
        # This is the constraint that keeps the ASR server off the network:
        # audio must never leave the user's own hardware, so whisper-server
        # may only ever bind to loopback.
        assert is_loopback(plist_host), (
            f"whisper-server plist host {plist_host!r} is not loopback — "
            "this would expose raw audio transcription beyond localhost."
        )

    def test_port_matches_config(self):
        plist_port = arg_after(self.args, "--port")
        assert plist_port == str(config.WHISPER_PORT)

    def test_model_path_matches_config(self):
        plist_model = arg_after(self.args, "--model")
        assert plist_model == str(config.MODEL_PATH)


class TestDictatedPlist:
    def setup_method(self):
        self.plist = render_plist(DICTATED_PLIST)
        self.args = self.plist["ProgramArguments"]

    def test_host_matches_config(self):
        plist_host = arg_after(self.args, "--host")
        assert plist_host == config.HARK_HOST

    def test_port_matches_config(self):
        plist_port = arg_after(self.args, "--port")
        assert plist_port == str(config.HARK_PORT)

    def test_host_is_not_wildcard_bind(self):
        # Asserted against the rendered plist's literal value, not just against
        # config.HARK_HOST, so this still catches the failure mode even if
        # someone writes 0.0.0.0 into their own config.toml: binding hark
        # to all interfaces would expose the injection service to every
        # attached network, violating the "audio/text never leaves this
        # hardware" privacy premise.
        plist_host = arg_after(self.args, "--host")
        assert plist_host != "0.0.0.0"
        assert plist_host != ""

    @pytest.mark.parametrize("host", ["0.0.0.0", "::", "", "  "])
    def test_wildcard_bind_is_refused_at_render(self, monkeypatch, host):
        # This used to assert the opposite — that the dangerous value reached
        # the plist — because the guard was test-only and install-server.sh
        # never ran pytest. It is enforced in render() now, so the same
        # scenario must raise instead of producing a plist.
        monkeypatch.setattr(config, "HARK_HOST", host)
        with pytest.raises(plists.UnsafeBindError):
            plists.render(DICTATED_PLIST)

    @pytest.mark.parametrize("host", ["127.0.0.1", "10.0.0.2", "192.168.1.9", "100.64.0.1"])
    def test_private_binds_are_still_allowed(self, monkeypatch, host):
        # The guard must refuse wildcards ONLY. The two-machine setup binds to
        # a private address on purpose, so a whitelist of loopback would break
        # a supported configuration.
        monkeypatch.setattr(config, "HARK_HOST", host)
        assert arg_after(render_plist(DICTATED_PLIST)["ProgramArguments"], "--host") == host

    def test_workdir_is_the_repo_root(self):
        # A wrong WorkingDirectory makes `uv run` resolve a different project
        # (or none), which launchd surfaces only as a nonzero exit in the log.
        assert Path(self.plist["WorkingDirectory"], "pyproject.toml").is_file()
