"""Where the installers put the bundle, and when they refuse to touch it.

A Homebrew cask and these installers both want to own Tacet.app. Left alone,
each install would build over the other's copy: the cask's bundle is notarized,
and a rebuild here re-signs it with whatever identity is in the environment —
usually none. That silently invalidates the Accessibility and Microphone grants
keyed to its designated requirement, and leaves `brew uninstall` looking at
something it did not install.

So the installers detect a cask install and step aside. These tests pin the
resolution order and, more importantly, the refusals.
"""

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SERVER = ROOT / "install-server.sh"
CLIENT = ROOT / "install-client.sh"


@pytest.fixture
def resolve(tmp_path):
    """Source an installer and report the resolved APP_DIR / APP_MANAGED."""

    def run(script: Path, *, caskroom_has_tacet: bool | None, **env: str):
        bin_dir = tmp_path / "bin"
        bin_dir.mkdir(exist_ok=True)

        # caskroom_has_tacet=None means "no brew at all on this machine".
        if caskroom_has_tacet is not None:
            caskroom = tmp_path / "Caskroom"
            caskroom.mkdir(exist_ok=True)
            if caskroom_has_tacet:
                (caskroom / "tacet").mkdir(exist_ok=True)
            brew = bin_dir / "brew"
            brew.write_text(
                "#!/bin/bash\n"
                f"[[ \"$1\" == '--caskroom' ]] && echo '{caskroom}' && exit 0\n"
                "exit 1\n"
            )
            brew.chmod(0o755)

        program = f"source {script}\nprintf '%s\\n%s\\n' \"$APP_DIR\" \"$APP_MANAGED\"\n"
        r = subprocess.run(
            ["bash", "-c", program],
            capture_output=True,
            text=True,
            env={"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": str(tmp_path), **env},
        )
        assert r.returncode == 0, r.stderr
        app_dir, managed = r.stdout.strip().splitlines()[-2:]
        return app_dir, managed == "1"

    return run


@pytest.mark.parametrize("script", [SERVER, CLIENT], ids=lambda p: p.name)
class TestResolutionOrder:
    def test_without_brew_it_builds_into_home(self, resolve, script, tmp_path):
        app_dir, managed = resolve(script, caskroom_has_tacet=None)
        assert app_dir == f"{tmp_path}/Applications"
        assert not managed, "a from-source install owns its bundle"

    def test_brew_without_the_cask_is_not_a_cask_install(self, resolve, script, tmp_path):
        # Almost every Mac has brew. Its mere presence must not redirect the
        # install to /Applications.
        app_dir, managed = resolve(script, caskroom_has_tacet=False)
        assert app_dir == f"{tmp_path}/Applications"
        assert not managed

    def test_a_cask_install_is_detected_and_marked_managed(self, resolve, script):
        app_dir, managed = resolve(script, caskroom_has_tacet=True)
        assert app_dir == "/Applications"
        assert managed, "a brew-owned bundle must never be rebuilt over"

    def test_an_explicit_override_beats_a_cask_install(self, resolve, script):
        # Someone who names a directory means it, even with a cask present.
        app_dir, managed = resolve(script, caskroom_has_tacet=True,
                                   TACET_APP_DIR="/opt/custom")
        assert app_dir == "/opt/custom"
        assert not managed


class TestManagedBundleIsLeftAlone:
    """The refusals, checked at source level.

    Running the real install paths would need a signed bundle, a working swift
    toolchain and a live launchd — so these assert the guards exist and are
    attached to the managed case, which is what the whole mechanism is for.
    """

    @pytest.mark.parametrize("script", [SERVER, CLIENT], ids=lambda p: p.name)
    def test_the_build_is_skipped_when_homebrew_owns_the_bundle(self, script):
        code = script.read_text()
        assert 'if [[ "$APP_MANAGED" -eq 1 ]]; then' in code
        # The copy-over-the-bundle line must sit inside the else branch.
        build_idx = code.index('if [[ "$APP_MANAGED" -eq 1 ]]; then')
        assert code.index("swift build -c release", build_idx) > build_idx

    def test_uninstall_does_not_delete_a_brew_owned_bundle(self):
        # rm -rf on a cask's bundle leaves Homebrew believing tacet is still
        # installed: `brew uninstall` then fails and only `brew reinstall`
        # recovers. The client is the one with an uninstall path.
        code = CLIENT.read_text()
        uninstall = code[code.index("run_uninstall()"):]
        guard = uninstall.index('"$APP_MANAGED" -eq 1')
        removal = uninstall.index('rm -rf "$APP_DST"')
        assert guard < removal, "the removal must be guarded by the managed check"


class TestGrantResetIsSignatureAware:
    """A cdhash change only invalidates TCC when the cdhash IS the requirement.

    That is the ad-hoc case. A Developer ID signature's designated requirement
    is identifier + Team ID, stable across rebuilds, so the grant survives one.
    Resetting regardless made the user re-grant Accessibility after every
    install — exactly the cost that signing properly exists to remove, and it
    was observed doing so on 2026-08-05 immediately after the switch to a
    Developer ID build.
    """

    def test_the_reset_is_skipped_for_a_developer_id_signature(self):
        code = CLIENT.read_text()
        # Match the DEFINITION, not the earlier comment that names the
        # function — indexing on the bare name lands in a comment and slices
        # a completely different function's body.
        fn = code[code.index("reset_stale_grants_on_identity_change() {"):]
        fn = fn[:fn.index("\n}\n")]
        adhoc_check = fn.index("Signature=adhoc")
        reset_call = fn.index("tccutil reset Accessibility")
        assert adhoc_check < reset_call, (
            "the ad-hoc check must gate the reset, not follow it"
        )
        assert "return 0" in fn[adhoc_check:reset_call], (
            "a non-ad-hoc signature must return before resetting anything"
        )
