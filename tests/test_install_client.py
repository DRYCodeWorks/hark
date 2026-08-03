"""Guard install-client.sh and the agent bundle's metadata.

The agent's failure modes are almost all silent. A missing Info.plist key
kills the process the moment it opens the microphone; a wrong bundle
identifier orphans every TCC grant with the toggle still showing ON; a doctor
that reports a denied microphone as PASS sends the user looking somewhere
else entirely. None of those announce themselves, so they get asserted here.

The scripted checks are exercised by sourcing install-client.sh, which stops at
its source guard with every function defined and nothing installed.
"""

import plistlib
import re
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "install-client.sh"
INFO_PLIST = REPO / "client" / "agent" / "Info.plist"
AGENT_SWIFT = REPO / "client" / "agent" / "hark-agent.swift"
BUILD_SCRIPT = REPO / "client" / "agent" / "build-agent.sh"

BUNDLE_ID = "com.drycodeworks.hark-agent"

# doctor_pass/doctor_fail colour their markers unconditionally.
_ANSI = re.compile(r"\x1b\[[0-9;]*m")

macos_only = pytest.mark.skipif(
    sys.platform != "darwin", reason="uses BSD stat / macOS-only tooling"
)


def run_sourced(body: str, env_overrides: dict[str, str] | None = None) -> tuple[int, str]:
    """Source install-client.sh, then run `body` with its functions available."""
    script = f'set -uo pipefail\nsource "{SCRIPT}"\n{body}\n'
    proc = subprocess.run(
        ["bash", "-c", script],
        capture_output=True,
        text=True,
        env={**dict(__import__("os").environ), **(env_overrides or {})},
    )
    return proc.returncode, _ANSI.sub("", proc.stdout + proc.stderr)


# ---------------------------------------------------------------------------
# Sourcing must not install anything
# ---------------------------------------------------------------------------


def test_sourcing_the_script_installs_nothing(tmp_path):
    rc, out = run_sourced("echo SOURCED", {"HOME": str(tmp_path)})
    assert rc == 0, out
    assert "SOURCED" in out
    assert not (tmp_path / "Applications").exists()
    assert not (tmp_path / "Library" / "LaunchAgents").exists()
    assert not (tmp_path / ".config").exists()


# ---------------------------------------------------------------------------
# Info.plist — the keys whose absence is fatal and silent
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def plist():
    return plistlib.loads(INFO_PLIST.read_bytes())


@pytest.fixture(scope="module")
def source():
    return AGENT_SWIFT.read_text()


class TestInfoPlist:
    def test_declares_a_microphone_usage_description(self, plist):
        # Without this key macOS does not show an empty prompt - it kills the
        # process outright the moment it touches the device.
        assert plist["NSMicrophoneUsageDescription"].strip()

    def test_the_usage_description_explains_the_ask(self, plist):
        # This string IS the consent dialog. A placeholder here is a real
        # defect, not a cosmetic one.
        text = plist["NSMicrophoneUsageDescription"].lower()
        assert "hark" in text
        assert any(word in text for word in ("dictat", "voice", "transcri"))

    def test_is_a_background_agent(self, plist):
        # A Dock icon for a process with no clickable window is noise, and
        # .regular activation would let the overlay steal focus.
        assert plist["LSUIElement"] is True

    def test_bundle_identifier_is_the_one_tcc_will_key_grants_to(self, plist):
        assert plist["CFBundleIdentifier"] == BUNDLE_ID

    def test_bundle_id_does_not_collide_with_the_server_launchd_label(self, plist):
        # The server's label is com.drycodeworks.hark. Different namespaces, so
        # this is about keeping `launchctl list | grep` unambiguous.
        assert plist["CFBundleIdentifier"] != "com.drycodeworks.hark"

    def test_executable_name_matches_what_the_build_produces(self, plist):
        assert plist["CFBundleExecutable"] == "hark-agent"
        assert f'MacOS/{plist["CFBundleExecutable"]}' in BUILD_SCRIPT.read_text()


class TestEntitlements:
    """The hardened runtime turns a missing entitlement into a non-event.

    Observed 2026-08-03: with `--options runtime` but no
    com.apple.security.device.audio-input, tccd logs "Policy disallows prompt
    ... access to kTCCServiceMicrophone denied" and never shows a dialog. The
    app therefore never appears in the Microphone pane at all — that pane
    lists only apps that have successfully requested — and the code sees
    .denied instantly, indistinguishable from a real user refusal. Nothing
    short of the unified log names the cause.
    """

    ENTITLEMENTS = REPO / "client" / "agent" / "hark-agent.entitlements"

    def test_declares_audio_input(self):
        ents = plistlib.loads(self.ENTITLEMENTS.read_bytes())
        assert ents.get("com.apple.security.device.audio-input") is True

    def test_the_build_signs_both_binaries_with_it(self):
        # The app is the responsible process tccd checks the entitlement on;
        # rec is the process that actually opens the device. Signing only one
        # of them reintroduces the same silent denial.
        build = BUILD_SCRIPT.read_text()
        assert build.count("--entitlements") >= 2

    def test_the_build_fails_when_the_entitlement_is_missing(self):
        # A signature that merely *verifies* proves nothing here: the bundle
        # signs, launches and runs fine without the entitlement and only fails
        # at the microphone, where it looks like a permission problem rather
        # than a build problem. So the build asserts it explicitly.
        build = BUILD_SCRIPT.read_text()
        assert "com.apple.security.device.audio-input" in build
        assert "codesign -d --entitlements" in build

    def test_hardened_runtime_stays_on(self):
        # Dropping --options runtime would also fix the microphone, and would
        # break notarization later instead. The entitlement is the right fix.
        assert "--options runtime" in BUILD_SCRIPT.read_text()


def test_rec_permission_help_names_the_responsible_app():
    # TCC attributes the grant to the RESPONSIBLE process, not to rec, so the
    # row a user has to switch on is named after whatever spawned it. hark is
    # now the only thing that does, so naming it is finally correct — while
    # the Hammerspoon client still shipped, this string named neither, because
    # the right answer depended on which client you were running.
    rec = (REPO / "client" / "rec.swift").read_text()
    start = rec.index("let permissionHelp")
    help_text = rec[start : rec.index("\n\n", start)]
    assert "hark" in help_text
    assert "Hammerspoon" not in help_text


def test_launchagent_label_matches_the_bundle_id():
    # Not required by macOS, but a mismatch makes every diagnostic ambiguous -
    # and check_accessibility below looks the client up in TCC.db BY this
    # string, where the value that matters is the bundle id.
    assert f'AGENT_LABEL="{BUNDLE_ID}"' in SCRIPT.read_text()


# ---------------------------------------------------------------------------
# Config: JSON the Swift side can actually decode
# ---------------------------------------------------------------------------


class TestClientConfig:
    def test_written_config_is_valid_json_with_both_fields(self, tmp_path):
        import json

        rc, out = run_sourced(
            'write_client_config "http://example:8911/dictate" "s3cr3t"',
            {"HOME": str(tmp_path)},
        )
        assert rc == 0, out
        written = json.loads((tmp_path / ".config/hark/client.json").read_text())
        assert written == {"server": "http://example:8911/dictate", "key": "s3cr3t"}

    @macos_only
    def test_written_config_is_600_because_it_holds_a_secret(self, tmp_path):
        rc, out = run_sourced(
            'write_client_config "http://x/dictate" "k"', {"HOME": str(tmp_path)}
        )
        assert rc == 0, out
        mode = (tmp_path / ".config/hark/client.json").stat().st_mode & 0o777
        assert mode == 0o600

    def test_a_key_containing_quotes_does_not_produce_broken_json(self, tmp_path):
        # Keys are base64-ish today, so this is a guard rather than a fix for
        # something observed. Broken JSON here is silent: the agent alerts
        # "not valid JSON" and the hotkey does nothing.
        import json

        rc, out = run_sourced(
            r"""write_client_config 'http://x/dictate' 'a"b\c' """,
            {"HOME": str(tmp_path)},
        )
        assert rc == 0, out
        written = json.loads((tmp_path / ".config/hark/client.json").read_text())
        assert written["key"] == r'a"b\c'

    def test_json_field_round_trips_what_write_client_config_wrote(self, tmp_path):
        rc, out = run_sourced(
            'write_client_config "http://rt:8911/dictate" "rtkey"\n'
            "json_field server\necho\njson_field key",
            {"HOME": str(tmp_path)},
        )
        assert rc == 0, out
        assert "http://rt:8911/dictate" in out
        assert "rtkey" in out


class TestLegacyMigration:
    def _legacy(self, home: Path, server: str, key: str) -> None:
        d = home / ".hammerspoon"
        d.mkdir(parents=True)
        (d / "hark-config.lua").write_text(
            f'return {{\n  server = "{server}",\n  key = "{key}",\n}}\n'
        )

    def test_reads_the_hammerspoon_config_shape(self, tmp_path):
        self._legacy(tmp_path, "http://old:8911/dictate", "oldkey")
        rc, out = run_sourced("legacy_field server\necho\nlegacy_field key", {"HOME": str(tmp_path)})
        assert rc == 0, out
        assert "http://old:8911/dictate" in out
        assert "oldkey" in out

    def test_migration_never_modifies_the_hammerspoon_config(self, tmp_path):
        # Rolling back must stay as cheap as relaunching Hammerspoon.
        self._legacy(tmp_path, "http://old:8911/dictate", "oldkey")
        legacy = tmp_path / ".hammerspoon" / "hark-config.lua"
        before = legacy.read_bytes()
        rc, out = run_sourced("resolve_config", {"HOME": str(tmp_path)})
        assert rc == 0, out
        assert legacy.read_bytes() == before

    def test_an_existing_client_json_wins_over_the_legacy_config(self, tmp_path):
        import json

        self._legacy(tmp_path, "http://old:8911/dictate", "oldkey")
        rc, _ = run_sourced(
            'write_client_config "http://new:8911/dictate" "newkey"', {"HOME": str(tmp_path)}
        )
        assert rc == 0
        rc, out = run_sourced("resolve_config", {"HOME": str(tmp_path)})
        assert rc == 0, out
        written = json.loads((tmp_path / ".config/hark/client.json").read_text())
        assert written["key"] == "newkey", "a re-run clobbered a hand-edited config"

    def test_falls_back_to_the_local_server_key(self, tmp_path):
        import json

        d = tmp_path / ".config/hark"
        d.mkdir(parents=True)
        (d / "key").write_text("localkey\n")
        rc, out = run_sourced("resolve_config", {"HOME": str(tmp_path)})
        assert rc == 0, out
        written = json.loads((d / "client.json").read_text())
        # Trailing newline stripped, or the header goes out with one in it.
        assert written["key"] == "localkey"

    def test_no_key_anywhere_fails_loudly_rather_than_writing_an_empty_key(self, tmp_path):
        rc, out = run_sourced("resolve_config", {"HOME": str(tmp_path)})
        assert rc != 0
        assert "no shared secret" in out
        assert not (tmp_path / ".config/hark/client.json").exists()


# ---------------------------------------------------------------------------
# Doctor: no false PASSes
# ---------------------------------------------------------------------------


class TestMicDoctor:
    def _status(self, home: Path, body: str) -> None:
        d = home / ".config/hark"
        d.mkdir(parents=True, exist_ok=True)
        (d / "agent-mic-status").write_text(body)

    def test_ok_passes(self, tmp_path):
        self._status(tmp_path, "ok\n2026-08-03 12:00:00\n")
        rc, out = run_sourced("check_mic", {"HOME": str(tmp_path)})
        assert rc == 0, out
        assert "PASS" in out

    def test_denied_is_not_a_pass(self, tmp_path):
        self._status(tmp_path, "denied\n2026-08-03 12:00:00\nrec exited 3.\n")
        rc, out = run_sourced("check_mic", {"HOME": str(tmp_path)})
        assert "FAIL" in out
        assert "Microphone" in out

    def test_error_is_not_a_pass_and_surfaces_the_detail(self, tmp_path):
        self._status(tmp_path, "error\n2026-08-03 12:00:00\nrec exited 5. no audio\n")
        rc, out = run_sourced("check_mic", {"HOME": str(tmp_path)})
        assert "FAIL" in out
        assert "no audio" in out

    def test_a_missing_status_file_is_not_a_pass(self, tmp_path):
        rc, out = run_sourced("check_mic", {"HOME": str(tmp_path)})
        assert "FAIL" in out
        assert "PASS" not in out


class TestAccessibilityDoctor:
    """This check produced a confident FALSE PASS on 2026-08-03.

    It queried TCC.db and reported "Accessibility is granted" while the agent
    was simultaneously alerting on screen that it could not paste. The row
    outlives the grant it describes: an ad-hoc signature's designated
    requirement is a bare cdhash, so every rebuild is a new identity, and the
    stale row keeps auth_value=2 while System Settings keeps drawing a
    switched-ON toggle for a binary nobody trusts.
    """

    def _status(self, home: Path, body: str) -> None:
        d = home / ".config/hark"
        d.mkdir(parents=True, exist_ok=True)
        (d / "agent-accessibility-status").write_text(body)

    def test_never_reads_tcc_db(self):
        # The bug was structural, not a typo. Reading that file at all is the
        # defect, so it is the file's presence that is asserted against.
        # The comment block still explains what TCC.db is and why it is wrong,
        # so the string itself must stay legal. What must not survive is the
        # mechanism: a query, and the service name it would query for.
        text = SCRIPT.read_text()
        assert "sqlite3" not in text
        assert "kTCCServiceAccessibility" not in text

    def test_ok_passes(self, tmp_path):
        self._status(tmp_path, "ok\n2026-08-03 15:32:00\n")
        rc, out = run_sourced("check_accessibility", {"HOME": str(tmp_path)})
        assert rc == 0, out
        assert "PASS" in out

    def test_denied_is_not_a_pass(self, tmp_path):
        self._status(tmp_path, "denied\n2026-08-03 15:28:00\n")
        rc, out = run_sourced("check_accessibility", {"HOME": str(tmp_path)})
        assert "FAIL" in out
        assert "PASS" not in out

    def test_a_missing_report_is_not_a_pass(self, tmp_path):
        # An agent that predates this check, or has not started. Reporting
        # PASS here is exactly the failure being fixed.
        rc, out = run_sourced("check_accessibility", {"HOME": str(tmp_path)})
        assert "PASS" not in out
        assert "SKIP" in out


class TestHammerspoonIsGone:
    """The Lua client is deleted, not merely unused.

    The point of issue #2 was never the 505 lines — it was that Accessibility
    was granted to a general-purpose scriptable runtime whose config was a
    symlink into this repo, so a `git pull` changed what that grant covered.
    Leaving the files behind would leave that path installable.
    """

    def test_the_lua_client_is_deleted(self):
        assert not (REPO / "client" / "init.lua").exists()
        assert not (REPO / "client" / "hark-config.example.lua").exists()
        assert not (REPO / "tests" / "test_client_record.lua").exists()

    def test_ci_no_longer_installs_lua(self):
        ci = (REPO / ".github" / "workflows" / "ci.yml").read_text()
        assert "lua" not in ci.lower()

    def test_ci_shellchecks_the_scripts_that_exist(self):
        ci = (REPO / ".github" / "workflows" / "ci.yml").read_text()
        assert "install-agent.sh" not in ci
        assert "install-client.sh" in ci
        assert "client/agent/build-agent.sh" in ci

    def test_the_installer_still_migrates_an_existing_lua_config(self):
        # Deleting the client must not strand anyone mid-upgrade: the old
        # config is still the only place their key lives.
        assert "hark-config.lua" in SCRIPT.read_text()


class TestSshKeyFetch:
    """Two-machine setups need the key from the other Mac.

    The old Hammerspoon installer did this and the agent installer did not, so
    it had to come across before the old one could be deleted — otherwise a
    laptop install regresses to "copy this file by hand".
    """

    def test_a_bare_argument_is_taken_as_the_ssh_host(self):
        body = SCRIPT.read_text()
        assert 'SERVER_HOST="$arg"' in body

    def test_the_url_is_not_derived_from_the_ssh_host(self, tmp_path):
        # An alias that works for `ssh <host>` is not necessarily an address
        # curl can reach. Guessing is how a config looks healthy while the
        # client silently fails, so a mismatch is warned about, not "fixed".
        body = SCRIPT.read_text()
        fn = body[body.index("fetch_key_over_ssh() {") :]
        fn = fn[: fn.index("\n}\n")]
        assert "DEFAULT_SERVER" not in fn

    def test_non_interactive_does_not_block_on_a_prompt(self, tmp_path):
        # A piped or CI install must fail with a message, not hang forever on
        # a `read` nobody can answer.
        rc, out = run_sourced(
            "fetch_key_over_ssh </dev/null && echo GOT || echo FAILED",
            {"HOME": str(tmp_path)},
        )
        assert "FAILED" in out, out

    def test_no_key_anywhere_still_fails_loudly(self, tmp_path):
        rc, out = run_sourced("resolve_config </dev/null", {"HOME": str(tmp_path)})
        assert rc != 0
        assert "no shared secret" in out
        assert not (tmp_path / ".config/hark/client.json").exists()


class TestHealthDoctor:
    """Everything local can be healthy while the server is simply unreachable.

    From the user's chair that is indistinguishable from a microphone fault:
    hold the key, speak, nothing appears.
    """

    def test_missing_server_url_is_not_a_pass(self, tmp_path):
        rc, out = run_sourced("check_health", {"HOME": str(tmp_path)})
        assert "PASS" not in out
        assert "FAIL" in out

    def test_an_unreachable_server_fails(self, tmp_path):
        rc, _ = run_sourced(
            'write_client_config "http://127.0.0.1:9/dictate" "k"', {"HOME": str(tmp_path)}
        )
        assert rc == 0
        # Port 9 (discard) refuses fast, so this does not hang on the timeout.
        rc, out = run_sourced("check_health", {"HOME": str(tmp_path)})
        assert "FAIL" in out
        assert "/health" in out


class TestStaleGrantReset:
    """A rebuild invalidates the Accessibility grant but not its TCC row.

    Observed twice on 2026-08-03: cdhash 6836bec4… -> be5a5c92… left the row
    reading auth_value=2 with System Settings still drawing a switched-ON
    toggle, while the agent reported `denied`. The installer clears it so the
    user is asked again instead of finding a permission already "granted".
    """

    def _stub_codesign(self, tmp_path: Path, cdhash: str) -> str:
        import os

        stub = tmp_path / "bin"
        stub.mkdir(exist_ok=True)
        (stub / "codesign").write_text(f"#!/bin/sh\necho 'CDHash={cdhash}' >&2\n")
        (stub / "codesign").chmod(0o755)
        # Never actually reset a real grant from the suite.
        (stub / "tccutil").write_text("#!/bin/sh\nexit 0\n")
        (stub / "tccutil").chmod(0o755)
        return f"{stub}:{os.environ['PATH']}"

    def test_first_install_records_the_hash_and_resets_nothing(self, tmp_path):
        path = self._stub_codesign(tmp_path, "aaaa1111")
        rc, out = run_sourced(
            "reset_stale_grants_on_identity_change",
            {"HOME": str(tmp_path), "PATH": path},
        )
        assert rc == 0, out
        assert "binary changed" not in out
        assert (tmp_path / ".config/hark/.agent-cdhash").read_text() == "aaaa1111"

    def test_reinstalling_the_same_binary_does_not_reset(self, tmp_path):
        # Re-running the installer on an unchanged build must not cost the
        # user a consent dialog.
        path = self._stub_codesign(tmp_path, "aaaa1111")
        env = {"HOME": str(tmp_path), "PATH": path}
        run_sourced("reset_stale_grants_on_identity_change", env)
        rc, out = run_sourced("reset_stale_grants_on_identity_change", env)
        assert rc == 0, out
        assert "binary changed" not in out

    def test_a_changed_binary_clears_the_stale_grant(self, tmp_path):
        env_a = {"HOME": str(tmp_path), "PATH": self._stub_codesign(tmp_path, "aaaa1111")}
        run_sourced("reset_stale_grants_on_identity_change", env_a)
        env_b = {"HOME": str(tmp_path), "PATH": self._stub_codesign(tmp_path, "bbbb2222")}
        rc, out = run_sourced("reset_stale_grants_on_identity_change", env_b)
        assert rc == 0, out
        assert "binary changed" in out
        assert (tmp_path / ".config/hark/.agent-cdhash").read_text() == "bbbb2222"

    def test_only_accessibility_is_reset(self):
        # The microphone path already tells the truth: the agent's probe runs
        # rec and reports the outcome, so a stale mic row cannot produce a
        # false PASS. Resetting it would cost a dialog for nothing.
        body = SCRIPT.read_text()
        body = body[body.index("reset_stale_grants_on_identity_change() {") :]
        body = body[: body.index("\n}\n")]
        assert "tccutil reset Accessibility" in body
        assert "tccutil reset Microphone" not in body


def test_the_agent_reports_its_own_trust_state(source):
    # Only the process can answer for the process — the same rule the
    # microphone probe already followed, arrived at the expensive way.
    assert "writeAccessibilityStatus" in source
    assert "agent-accessibility-status" in source


def test_trust_is_rechecked_at_paste_time_not_only_at_launch(source):
    # A grant can be revoked, or silently invalidated by a rebuild, while the
    # process keeps running. Paste is the moment it matters.
    paste_body = source[source.index("func paste(") : source.index("// HTTP")]
    assert "AXIsProcessTrusted()" in paste_body


def test_agent_loaded_survives_the_pipefail_sigpipe_trap(tmp_path):
    """`launchctl list | grep -q X` under pipefail reports everything unloaded.

    grep exits at the first match, launchctl takes SIGPIPE, and pipefail
    propagates it - so the check reports every service as not-loaded while
    they are all running. This bit install-server.sh once already (156bb69).
    The fix is to capture into a variable first, which is what is asserted
    here: a stub launchctl emitting many lines must still be detected.
    """
    stub = tmp_path / "bin"
    stub.mkdir()
    (stub / "launchctl").write_text(
        "#!/bin/sh\n"
        "echo 'PID\tStatus\tLabel'\n"
        f"echo '1\t0\t{BUNDLE_ID}'\n"
        + "".join(f"echo '{n}\t0\tcom.example.filler{n}'\n" for n in range(2, 400))
    )
    (stub / "launchctl").chmod(0o755)

    import os

    rc, out = run_sourced(
        "agent_loaded && echo DETECTED || echo MISSED",
        {"HOME": str(tmp_path), "PATH": f"{stub}:{os.environ['PATH']}"},
    )
    assert "DETECTED" in out, out


# ---------------------------------------------------------------------------
# The agent's own invariants, asserted against its source
# ---------------------------------------------------------------------------


class TestAgentSource:
    def test_never_presses_return_after_pasting(self, source):
        # Auto-submit is a hard non-goal: the user reviews the transcript
        # before sending it. kVK_Return appearing here at all is the defect.
        assert "kVK_Return" not in source
        assert "kVK_ANSI_KeypadEnter" not in source

    def test_does_not_save_and_restore_the_clipboard(self, source):
        # Leaving the transcript on the clipboard makes a misfired paste
        # recoverable with a manual Cmd+V. See the comment in paste().
        assert "pasteboardItems" not in source
        assert "restoreClipboard" not in source

    def test_uses_a_wav_path_the_hammerspoon_client_cannot_collide_with(self, source):
        # Both clients are installed at once during a migration. Sharing
        # /tmp/hark.wav would let one read the other's recording.
        assert '"/tmp/hark-agent.wav"' in source
        assert '"/tmp/hark.wav"' not in source

    def test_logs_transcript_length_but_never_content(self, source):
        assert "text.count) chars" in source

    def test_sends_the_key_as_the_hark_header(self, source):
        assert '"X-Hark-Key"' in source
        assert '"audio/wav"' in source

    def test_registers_both_press_and_release(self, source):
        # A hold-to-talk hotkey that only handles kEventHotKeyPressed records
        # forever. Both kinds must be in the event spec AND handled.
        assert "kEventHotKeyPressed" in source
        assert "kEventHotKeyReleased" in source

    def test_treats_rec_exit_3_as_a_permission_denial(self, source):
        # rec reserves exit 3 for "TCC said no". Inferring denial from an
        # empty capture cannot work - an ungranted process still receives
        # full-length buffers of zeros (issue #9).
        assert "terminationStatus == 3" in source
