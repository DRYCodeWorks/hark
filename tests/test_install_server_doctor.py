"""Guard install-server.sh's --doctor checks against false PASSes.

A doctor that reports a service as loaded when it isn't is worse than no
doctor at all: the whole point of `--doctor` is to name the failing boundary,
and a wrong PASS sends the user looking somewhere else entirely.

The scripted checks are exercised by sourcing install-server.sh, which stops
at its source guard with every check_* function defined and nothing
installed, then substituting `service_listing` with a fixture instead of a
real `launchctl list`.
"""

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
