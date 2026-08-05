"""install-server.sh's argument handling, and the bounded verification step.

Both of these were found the same way on 2026-08-05: by typing
`./install-server.sh --help` at a machine with a working install, which
performed a real installation, rebuilt the bundle, and then wedged for ten
minutes on a binary that never finished starting.

Neither failure was visible. The install printed progress and blocked; the
flag printed nothing to say it had been misread.
"""

import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "install-server.sh"


def run(*args: str, home: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(SCRIPT), *args],
        capture_output=True,
        text=True,
        env={"PATH": "/usr/bin:/bin", "HOME": str(home)},
    )


class TestArgumentHandling:
    def test_help_prints_usage_and_installs_nothing(self, tmp_path):
        # The original bug: no argument parsing at all, so every unrecognised
        # flag fell through to the install path.
        r = run("--help", home=tmp_path)
        assert r.returncode == 0
        assert "install or update" in r.stdout
        assert not any(tmp_path.iterdir()), \
            f"--help touched the filesystem: {list(tmp_path.iterdir())}"

    def test_short_help_works_too(self, tmp_path):
        r = run("-h", home=tmp_path)
        assert r.returncode == 0
        assert "--doctor" in r.stdout

    def test_an_unknown_flag_is_an_error_not_an_install(self, tmp_path):
        r = run("--bogus", home=tmp_path)
        assert r.returncode == 2, "a typo must not be interpreted as consent"
        assert "unknown option" in r.stderr
        assert not any(tmp_path.iterdir()), \
            f"an unknown flag touched the filesystem: {list(tmp_path.iterdir())}"

    def test_the_usage_text_documents_the_env_overrides(self, tmp_path):
        # TACET_APP_DIR is the documented escape hatch when a cask install is
        # not the bundle you want (issue #25), so it has to be discoverable.
        r = run("--help", home=tmp_path)
        assert "TACET_APP_DIR" in r.stdout
        assert "TACET_ALLOW_ADHOC" in r.stdout


class TestVerificationIsBounded:
    """The installed binary is executed to prove it works. That must not hang.

    A bundle can block in dyld before reaching main — Gatekeeper assessment on
    a bundle in /Applications does exactly that (#25). Unbounded, the installer
    waits forever: no output, no error, no service, nothing in any log.
    """

    def test_the_binary_check_goes_through_the_bounded_helper(self):
        code = SCRIPT.read_text()
        # The bare form is the bug. Anything invoking the installed binary for
        # verification has to go through run_bounded.
        assert 'run_bounded 20 "$APP_DST/Contents/MacOS/tacet"' in code
        assert 'usage_out="$("$APP_DST/Contents/MacOS/tacet"' not in code, \
            "the unbounded form is back"

    def test_a_timeout_is_reported_differently_from_a_broken_binary(self):
        # "did not run" and "did not finish" need different messages: the
        # second one has no output to show, and the fix is different.
        code = SCRIPT.read_text()
        assert 'verify_rc" -eq 124' in code, "the timeout status must be handled"

    def test_the_fallback_exists_because_macos_ships_no_timeout(self):
        # A stock macOS has neither timeout(1) nor gtimeout. Relying on
        # coreutils would leave the check silently unbounded on exactly the
        # machines it protects.
        code = SCRIPT.read_text()
        bounded = code[code.index("run_bounded() {"):]
        for tool in ("timeout", "gtimeout"):
            assert f'command -v {tool}' in bounded
        assert "kill -9" in bounded, "the fallback must actually enforce the bound"
        assert "return 124" in bounded, "the fallback must report a timeout as 124"


class TestRunBoundedBehaviour:
    """Exercise run_bounded itself, both with and without coreutils."""

    def _call(self, tmp_path, command: str, *, with_timeout: bool):
        # PATH without /opt/homebrew means no timeout(1) — the fallback path.
        path = "/opt/homebrew/bin:/usr/bin:/bin" if with_timeout else "/usr/bin:/bin"
        # `set +e` after sourcing: install-server.sh sets errexit, so a 124
        # return would kill this shell before it could report the status. The
        # real call site wraps the invocation the same way, for the same reason.
        program = f'source {SCRIPT}\nset +e\nrun_bounded 3 {command}\necho "rc=$?"\n'
        return subprocess.run(
            ["bash", "-c", program], capture_output=True, text=True,
            env={"PATH": path, "HOME": str(tmp_path)},
        ).stdout

    @pytest.mark.parametrize("with_timeout", [True, False], ids=["coreutils", "fallback"])
    def test_a_hanging_command_is_killed_and_reported_as_124(self, tmp_path, with_timeout):
        out = self._call(tmp_path, "/bin/sleep 30", with_timeout=with_timeout)
        assert "rc=124" in out, out

    @pytest.mark.parametrize("with_timeout", [True, False], ids=["coreutils", "fallback"])
    def test_a_fast_command_returns_its_own_output_and_status(self, tmp_path, with_timeout):
        out = self._call(tmp_path, "/bin/echo hello", with_timeout=with_timeout)
        assert "hello" in out
        assert "rc=0" in out, out
