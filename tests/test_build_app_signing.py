"""Guard build-app.sh's signing policy.

An ad-hoc signature is not a degraded build, it is a different build: TCC
grants key on the designated requirement, and an ad-hoc DR is a bare cdhash,
so an ad-hoc rebuild silently invalidates Accessibility and Microphone.
Notarization rejects the same bundle, but only after the upload. Both
failures land far from the install that caused them, which is why the
default has to be a refusal rather than a fallback (issue #21).

These tests stub `security` (and `swift`, so nothing is actually compiled)
onto PATH, which keeps them hermetic and fast — the refusal happens before
the build starts, so the stub is never reached on the failure paths.
"""

import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "swift" / "Packaging" / "build-app.sh"

DEV_ID = "Developer ID Application: Dan Young Enterprises LLC (Q6G8B5282N)"
HASH_A = "6FD803AC935B0A64E2E5CF83C8FD1850F2A50160"
HASH_B = "1111111111111111111111111111111111111111"


def _find_identity_output(entries: list[tuple[str, str]]) -> str:
    """Render `security find-identity -v -p codesigning` output."""
    lines = [
        f"  {i}) {sha} \"{name}\"" for i, (sha, name) in enumerate(entries, start=1)
    ]
    lines.append(f"     {len(entries)} valid identities found")
    return "\n".join(lines) + "\n"


@pytest.fixture
def stub_bin(tmp_path):
    """A PATH directory whose `security` and `swift` are scripted stubs."""

    def make(identities_output: str) -> dict[str, str]:
        bin_dir = tmp_path / "bin"
        bin_dir.mkdir(exist_ok=True)

        security = bin_dir / "security"
        security.write_text(
            "#!/bin/bash\n"
            "if [[ \"$1\" == 'find-identity' ]]; then\n"
            f"  cat <<'IDENT'\n{identities_output}IDENT\n"
            "  exit 0\n"
            "fi\n"
            "exit 1\n"
        )
        security.chmod(0o755)

        # Reached only when resolution succeeds. Failing here keeps a passing
        # resolution from running a real `swift build` inside a unit test,
        # and its exit code is distinguishable from the policy refusal's 1.
        swift = bin_dir / "swift"
        swift.write_text("#!/bin/bash\necho 'STUB SWIFT REACHED' >&2\nexit 42\n")
        swift.chmod(0o755)

        return {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": str(tmp_path)}

    return make


def _run(env: dict[str, str], **extra: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(SCRIPT)],
        capture_output=True,
        text=True,
        env={**env, **extra},
    )


class TestSigningPolicy:
    def test_no_identity_refuses_rather_than_going_ad_hoc(self, stub_bin):
        # The regression this whole issue is about: an unset variable used to
        # produce a successful, installable, un-notarizable bundle.
        env = stub_bin("     0 valid identities found\n")
        r = _run(env)
        assert r.returncode == 1
        assert "STUB SWIFT REACHED" not in r.stderr, "refusal must precede the build"
        assert "TACET_ALLOW_ADHOC" in r.stderr, "the escape hatch must be named"

    def test_ad_hoc_is_available_but_only_on_purpose(self, stub_bin):
        env = stub_bin("     0 valid identities found\n")
        r = _run(env, TACET_ALLOW_ADHOC="1")
        # Gets past the policy gate and dies in the stubbed build instead.
        assert r.returncode == 42

    def test_one_certificate_in_several_keychains_is_not_ambiguous(self, stub_bin):
        # `security find-identity` lists an identity once per keychain holding
        # it, so the same certificate routinely appears two or four times.
        # Counting lines instead of unique hashes reports "ambiguous" for a
        # machine with exactly one usable certificate — the common case.
        env = stub_bin(_find_identity_output([(HASH_A, DEV_ID)] * 4))
        r = _run(env)
        assert r.returncode == 42, f"expected auto-resolve, got: {r.stderr}"
        assert HASH_A in r.stdout

    def test_genuinely_different_identities_are_refused_with_both_listed(self, stub_bin):
        env = stub_bin(
            _find_identity_output([(HASH_A, DEV_ID), (HASH_B, "Developer ID Application: Other (X)")])
        )
        r = _run(env)
        assert r.returncode == 1
        assert HASH_A in r.stderr and HASH_B in r.stderr, "both choices must be shown"

    def test_an_explicit_identity_skips_resolution_entirely(self, stub_bin):
        # Nothing in the keychain, but the caller named one: that is not the
        # ambiguous case and must not be second-guessed.
        env = stub_bin("     0 valid identities found\n")
        r = _run(env, TACET_SIGN_IDENTITY=DEV_ID)
        assert r.returncode == 42

    def test_non_developer_id_certificates_are_not_offered(self, stub_bin):
        # An Apple Development certificate is a codesigning identity but not a
        # distributable one; treating it as the default would produce a bundle
        # that notarization rejects.
        env = stub_bin(
            _find_identity_output([(HASH_B, "Apple Development: dan@drycodeworks.com (ABC123)")])
        )
        r = _run(env)
        assert r.returncode == 1
        assert "TACET_ALLOW_ADHOC" in r.stderr


class TestBash32Compatibility:
    def test_the_script_runs_under_the_bash_macos_actually_ships(self):
        # The shebang is /bin/bash, which on macOS is 3.2.57 — no mapfile, no
        # associative arrays. A bash-4 builtin here is a 127 at the very first
        # step of every install, on every Mac.
        # Comments are stripped first: the script explains *why* it avoids
        # mapfile, and naming the trap is worth more than a grep-clean file.
        code = "\n".join(
            line for line in SCRIPT.read_text().splitlines()
            if not line.lstrip().startswith("#")
        )
        for builtin in ("mapfile", "readarray", "declare -A"):
            assert builtin not in code, f"{builtin} is not available in bash 3.2"
