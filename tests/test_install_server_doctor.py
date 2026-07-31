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


def run_check_server_installed(venv_dir: Path) -> tuple[int, str]:
    """Run check_server_installed against a fabricated install prefix."""
    program = f"""
    source {SCRIPT}
    VENV_DIR="{venv_dir}"
    VENV_PYTHON="$VENV_DIR/bin/python"
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
    """The plists name an absolute path inside the install prefix, and launchd
    reports a bad one only as a restart loop plus a spawn error in a log file
    nobody is watching. This check is the thing that says so out loud, so it
    must not PASS on an install that cannot actually run.
    """

    def _venv(self, tmp_path: Path, *, importable: bool) -> Path:
        venv = tmp_path / "venv"
        (venv / "bin").mkdir(parents=True)
        (venv / "bin" / "uvicorn").write_text("#!/bin/sh\n")
        (venv / "bin" / "uvicorn").chmod(0o755)
        python = venv / "bin" / "python"
        python.write_text("#!/bin/sh\nexit %d\n" % (0 if importable else 1))
        python.chmod(0o755)
        return venv

    def test_a_working_install_passes(self, tmp_path):
        status, out = run_check_server_installed(self._venv(tmp_path, importable=True))
        assert status == 0, out
        assert "FAIL" not in out

    def test_a_missing_install_fails(self, tmp_path):
        status, out = run_check_server_installed(tmp_path / "not-installed")
        assert status != 0
        assert "FAIL" in out
        assert "install-server.sh" in out

    def test_a_venv_that_cannot_import_hark_is_not_a_pass(self, tmp_path):
        # The trap this exists for: uvicorn is on disk, so an existence check
        # alone would PASS, while launchd cannot start the app at all.
        status, out = run_check_server_installed(self._venv(tmp_path, importable=False))
        assert status != 0, out
        assert "cannot import hark" in out


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
