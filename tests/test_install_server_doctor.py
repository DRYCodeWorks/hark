"""Guard install-server.sh's --doctor checks against false PASSes.

A doctor that reports a service as loaded when it isn't is worse than no
doctor at all: the whole point of `--doctor` is to name the failing boundary,
and a wrong PASS sends the user looking somewhere else entirely.

The scripted checks are exercised by sourcing install-server.sh, which stops
at its source guard with every check_* function defined and nothing
installed, then substituting `service_listing` with a fixture instead of a
real `launchctl list`.
"""

import hashlib
import re
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "install-server.sh"

HARK = "com.drycodeworks.hark"
WHISPER = "com.drycodeworks.hark-whisper"

HEADER = "PID\tStatus\tLabel"

# doctor_pass/doctor_fail colour their PASS/FAIL markers unconditionally.
_ANSI = re.compile(r"\x1b\[[0-9;]*m")


def listing(*labels: str) -> str:
    """A `launchctl list` capture with exactly the given labels loaded."""
    rows = [HEADER, "-\t0\tcom.apple.somethingelse"]
    rows += [f"1234\t0\t{label}" for label in labels]
    return "\n".join(rows)


def run_check(fixture: str) -> tuple[int, str]:
    """Run check_services_loaded against a fixture listing.

    Returns (exit status, plain-text stdout).
    """
    program = f"""
    source {SCRIPT}
    service_listing() {{ printf '%s\\n' "$FIXTURE_LISTING"; }}
    check_services_loaded
    """
    result = subprocess.run(
        ["bash", "-c", program],
        capture_output=True,
        text=True,
        env={
            "FIXTURE_LISTING": fixture,
            "PATH": "/usr/bin:/bin",
            "HOME": str(Path.home()),
        },
    )
    assert not result.stderr, result.stderr
    return result.returncode, _ANSI.sub("", result.stdout)


def run_verify_model(path: Path, expected_sha: str) -> tuple[int, str]:
    """Run verify_model against a file, with MODEL_SHA256 overridden.

    Returns (exit status, plain-text stdout+stderr).
    """
    program = f"""
    source {SCRIPT}
    MODEL_SHA256="{expected_sha}"
    verify_model "{path}"
    """
    result = subprocess.run(
        ["bash", "-c", program],
        capture_output=True,
        text=True,
        env={"PATH": "/usr/bin:/bin", "HOME": str(Path.home())},
    )
    return result.returncode, _ANSI.sub("", result.stdout + result.stderr)


class TestVerifyModel:
    """The model is the one thing hark downloads and then feeds to another
    program, so its checksum is a security control — and an untested one is
    how the wildcard-bind guard ended up asserted only in a suite that
    install-server.sh never ran.
    """

    def test_matching_checksum_passes(self, tmp_path):
        f = tmp_path / "model.bin"
        f.write_bytes(b"pretend model bytes")
        digest = hashlib.sha256(f.read_bytes()).hexdigest()
        status, out = run_verify_model(f, digest)
        assert status == 0, out
        assert "Checksum OK" in out

    def test_mismatched_checksum_fails_and_names_both_digests(self, tmp_path):
        f = tmp_path / "model.bin"
        f.write_bytes(b"tampered")
        wrong = "0" * 64
        status, out = run_verify_model(f, wrong)
        assert status != 0
        # Both values matter: "mismatch" alone leaves you unable to tell a
        # corrupt download from a model you deliberately changed.
        assert wrong in out
        assert hashlib.sha256(b"tampered").hexdigest() in out

    def test_pinned_url_uses_the_revision_not_a_mutable_ref(self):
        # Scoped to the assignment, not the whole file: the comment above it
        # explains why `resolve/main` is wrong, and a naive substring search
        # matches that explanation.
        line = next(
            ln for ln in SCRIPT.read_text().splitlines() if ln.startswith("MODEL_URL=")
        )
        assert "resolve/main" not in line, f"MODEL_URL tracks a mutable ref: {line}"
        assert "${MODEL_REVISION}" in line, line

    def test_the_pinned_revision_looks_like_a_commit_sha(self):
        line = next(
            ln for ln in SCRIPT.read_text().splitlines() if ln.startswith("MODEL_REVISION=")
        )
        assert re.search(r'"[0-9a-f]{40}"', line), f"not a full commit sha: {line}"


def run_check_server_installed(app_dst: Path) -> tuple[int, str]:
    """Run check_server_installed against a fabricated bundle."""
    program = f"""
    source {SCRIPT}
    APP_DST="{app_dst}"
    check_server_installed
    """
    result = subprocess.run(
        ["bash", "-c", program],
        capture_output=True,
        text=True,
        env={"PATH": "/usr/bin:/bin", "HOME": str(Path.home())},
    )
    return result.returncode, _ANSI.sub("", result.stdout + result.stderr)


class TestServerInstalled:
    """The plist names an absolute path inside the bundle, and launchd reports a
    bad one only as a restart loop plus a spawn error in a log file nobody is
    watching. This check is the thing that says so out loud, so it must not PASS
    on an install that cannot actually run.
    """

    def _bundle(self, tmp_path: Path, *, executable: bool = True) -> Path:
        app = tmp_path / "Hark.app"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        binary = app / "Contents" / "MacOS" / "hark"
        binary.write_text("#!/bin/sh\necho 'usage: hark <serve|agent>' >&2\nexit 2\n")
        binary.chmod(0o755 if executable else 0o644)
        return app

    def test_a_missing_install_fails(self, tmp_path):
        status, out = run_check_server_installed(tmp_path / "not-installed")
        assert status != 0
        assert "FAIL" in out
        assert "install-server.sh" in out

    def test_a_non_executable_binary_is_not_a_pass(self, tmp_path):
        # The trap: the bundle exists, so a directory check alone would PASS
        # while launchd cannot spawn it at all.
        status, out = run_check_server_installed(self._bundle(tmp_path, executable=False))
        assert status != 0, out
        assert "FAIL" in out

    def test_an_unsigned_bundle_is_not_a_pass(self, tmp_path):
        # A fabricated bundle has no signature. Signature verification is what
        # catches a partially-replaced bundle, whose only other symptom is an
        # unexplained TCC re-prompt much later.
        status, out = run_check_server_installed(self._bundle(tmp_path))
        assert status != 0, out
        assert "signature" in out


def test_sourcing_the_script_installs_nothing():
    # The source guard is what makes every other test here safe to run.
    result = subprocess.run(
        ["bash", "-c", f"source {SCRIPT}; declare -F check_services_loaded"],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    assert "check_services_loaded" in result.stdout


def test_both_services_loaded_passes():
    status, out = run_check(listing(HARK, WHISPER))
    assert status == 0, out
    assert "FAIL" not in out


def test_neither_service_loaded_fails():
    status, out = run_check(listing())
    assert status != 0
    assert out.count("FAIL") == 2


@pytest.mark.parametrize("loaded,missing", [(WHISPER, HARK), (HARK, WHISPER)])
def test_one_service_loaded_does_not_pass_the_other(loaded, missing):
    """The label-prefix trap.

    `com.drycodeworks.hark` is a prefix of `com.drycodeworks.hark-whisper`, so
    a substring match reports the hark service as loaded whenever only the ASR
    service is running. That is exactly the case where the user needs the
    truth: /health is unreachable, and a PASS here sends them looking at the
    network instead of at the service that is actually down.
    """
    status, out = run_check(listing(loaded))
    assert status != 0, out
    assert f"PASS  {loaded} is loaded" in out
    assert f"FAIL  {missing} is loaded" in out


def test_a_label_that_merely_contains_ours_is_not_a_match():
    # Nothing ships such a label today; this pins the matcher to whole fields
    # so a future rename cannot silently reintroduce prefix matching.
    status, out = run_check(listing("com.example.com.drycodeworks.hark.backup"))
    assert status != 0
    assert out.count("FAIL") == 2


class TestPlistRendering:
    """The launchd drift guard, ported from test_launchd_config_sync.py.

    The plists are now rendered by install-server.sh rather than by a Python
    module, but what they must satisfy is unchanged: they are what launchd
    actually runs, and a wrong one surfaces only as a restart loop and a spawn
    error in a log nobody is watching.
    """

    def _render(self, tmp_path: Path, config: str) -> tuple[int, dict[str, str]]:
        cfg_dir = tmp_path / ".config" / "hark"
        cfg_dir.mkdir(parents=True)
        (cfg_dir / "config.toml").write_text(config)
        agents = tmp_path / "Library" / "LaunchAgents"
        agents.mkdir(parents=True)
        program = f"""
        source {SCRIPT}
        CONFIG_FILE="{cfg_dir}/config.toml"
        LAUNCH_AGENTS="{agents}"
        APP_DST="{tmp_path}/Hark.app"
        MODEL_PATH="{tmp_path}/model.bin"
        render_plists
        """
        r = subprocess.run(["bash", "-c", program], capture_output=True, text=True,
                           env={"PATH": "/usr/bin:/bin", "HOME": str(tmp_path)})
        rendered = {p.name: p.read_text() for p in agents.glob("*.plist")}
        return r.returncode, rendered

    ONE_MACHINE = '[server]\nbind = "127.0.0.1"\nport = 8911\n\n[whisper]\nport = 8910\n'

    def test_both_plists_are_rendered(self, tmp_path):
        rc, plists = self._render(tmp_path, self.ONE_MACHINE)
        assert rc == 0
        assert set(plists) == {"com.drycodeworks.hark.plist",
                               "com.drycodeworks.hark-whisper.plist"}

    def test_no_placeholder_survives(self, tmp_path):
        _, plists = self._render(tmp_path, self.ONE_MACHINE)
        for name, text in plists.items():
            assert "@" not in text, f"{name} still has an unsubstituted placeholder"
            assert "${" not in text, f"{name} has an unexpanded shell variable"

    def test_the_port_matches_config(self, tmp_path):
        cfg = '[server]\nbind = "127.0.0.1"\nport = 9111\n\n[whisper]\nport = 9110\n'
        _, plists = self._render(tmp_path, cfg)
        assert "9110" in plists["com.drycodeworks.hark-whisper.plist"]

    def test_whisper_stays_on_loopback(self, tmp_path):
        # whisper handles raw audio. It must never be reachable off-box, and
        # its host is deliberately not configurable.
        cfg = '[server]\nbind = "100.64.66.46"\nport = 8911\n\n[whisper]\nport = 8910\n'
        _, plists = self._render(tmp_path, cfg)
        w = plists["com.drycodeworks.hark-whisper.plist"]
        assert "127.0.0.1" in w
        assert "100.64.66.46" not in w, "the tailnet address leaked into whisper's plist"

    def test_the_plist_points_at_the_installed_bundle_not_the_clone(self, tmp_path):
        _, plists = self._render(tmp_path, self.ONE_MACHINE)
        hark = plists["com.drycodeworks.hark.plist"]
        assert str(tmp_path / "Hark.app") in hark
        assert "/swift/Packaging/" not in hark, "points into the build tree, not the install"

    def test_it_runs_the_serve_role(self, tmp_path):
        _, plists = self._render(tmp_path, self.ONE_MACHINE)
        assert "<string>serve</string>" in plists["com.drycodeworks.hark.plist"]

    def test_the_server_plist_carries_no_address(self, tmp_path):
        """`hark serve` reads config.toml itself, so the plist encodes nothing.

        uvicorn needed --host and --port baked into the plist, which is exactly
        what the old drift guard existed to police: two copies of the same fact
        that could disagree. There is now one copy.
        """
        cfg = '[server]\nbind = "100.64.66.46"\nport = 9911\n\n[whisper]\nport = 8910\n'
        _, plists = self._render(tmp_path, cfg)
        hark = plists["com.drycodeworks.hark.plist"]
        assert "100.64.66.46" not in hark
        assert "9911" not in hark

    def test_no_working_directory_is_set(self, tmp_path):
        # A WorkingDirectory would make the service depend on a path that can
        # move, which is the failure the install prefix exists to avoid.
        _, plists = self._render(tmp_path, self.ONE_MACHINE)
        for text in plists.values():
            assert "WorkingDirectory" not in text

    @pytest.mark.parametrize("host", ["0.0.0.0", "::"])
    def test_a_wildcard_bind_is_refused_at_render(self, tmp_path, host):
        # `hark serve` also refuses this, but launchd answers that with a crash
        # loop — catching it here is the difference between a message and a
        # restart storm.
        cfg = f'[server]\nbind = "{host}"\nport = 8911\n\n[whisper]\nport = 8910\n'
        rc, plists = self._render(tmp_path, cfg)
        assert rc != 0, f"bind {host!r} must be refused"
        assert plists == {}, "nothing should be written when the bind is refused"

    def test_an_empty_bind_falls_back_to_loopback(self, tmp_path):
        """`bind = ""` means unset, not "every interface".

        The Python guard refused it, because there the value went straight to a
        socket API where empty spells the wildcard. Here it never reaches one:
        an absent or empty value takes the default, and the default is
        loopback. Defaulting to the safe end is better than refusing, but it is
        a deliberate difference rather than an oversight.
        """
        cfg = '[server]\nbind = ""\nport = 8911\n\n[whisper]\nport = 8910\n'
        rc, plists = self._render(tmp_path, cfg)
        assert rc == 0
        assert plists != {}

    @pytest.mark.parametrize("host", ["127.0.0.1", "100.64.66.46", "192.168.1.10"])
    def test_private_binds_are_allowed(self, tmp_path, host):
        cfg = f'[server]\nbind = "{host}"\nport = 8911\n\n[whisper]\nport = 8910\n'
        rc, _ = self._render(tmp_path, cfg)
        assert rc == 0
