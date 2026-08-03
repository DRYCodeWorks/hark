"""Guard install-client.sh and the agent bundle's metadata.

The agent's failure modes are almost all silent. A missing Info.plist key
kills the process the moment it opens the microphone; a wrong bundle
identifier orphans every TCC grant with the toggle still showing ON; a doctor
that reports a denied microphone as PASS sends the user looking somewhere
else entirely. None of those announce themselves, so they get asserted here.

The scripted checks are exercised by sourcing install-client.sh, which stops at
its source guard with every function defined and nothing installed.
"""

import re
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "install-client.sh"
INFO_PLIST = REPO / "swift" / "Packaging" / "Info.plist"
AGENT_SWIFT = REPO / "swift" / "Sources" / "hark" / "AgentController.swift"
BUILD_SCRIPT = REPO / "swift" / "Packaging" / "build-app.sh"

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










# ---------------------------------------------------------------------------
# Config: JSON the Swift side can actually decode
# ---------------------------------------------------------------------------


class TestClientConfig:
    def test_written_config_is_valid_json_with_both_fields(self, tmp_path):
        import json

        rc, out = run_sourced(
            'write_client_config "http://10.1.2.3:8911/dictate" "s3cr3t"',
            {"HOME": str(tmp_path)},
        )
        assert rc == 0, out
        written = json.loads((tmp_path / ".config/hark/client.json").read_text())
        assert written["server"] == "http://10.1.2.3:8911/dictate"
        assert written["key"] == "s3cr3t"

    @macos_only
    def test_written_config_is_600_because_it_holds_a_secret(self, tmp_path):
        rc, out = run_sourced(
            'write_client_config "http://127.0.0.1:8911/dictate" "k"', {"HOME": str(tmp_path)}
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
            r"""write_client_config 'http://127.0.0.1:8911/dictate' 'a"b\c' """,
            {"HOME": str(tmp_path)},
        )
        assert rc == 0, out
        written = json.loads((tmp_path / ".config/hark/client.json").read_text())
        assert written["key"] == r'a"b\c'

    def test_json_field_round_trips_what_write_client_config_wrote(self, tmp_path):
        rc, out = run_sourced(
            'write_client_config "http://10.9.9.9:8911/dictate" "rtkey"\n'
            "json_field server\necho\njson_field key",
            {"HOME": str(tmp_path)},
        )
        assert rc == 0, out
        assert "http://10.9.9.9:8911/dictate" in out
        assert "rtkey" in out


class TestLegacyMigration:
    def _legacy(self, home: Path, server: str, key: str) -> None:
        d = home / ".hammerspoon"
        d.mkdir(parents=True)
        (d / "hark-config.lua").write_text(
            f'return {{\n  server = "{server}",\n  key = "{key}",\n}}\n'
        )

    def test_reads_the_hammerspoon_config_shape(self, tmp_path):
        self._legacy(tmp_path, "http://10.0.0.1:8911/dictate", "oldkey")
        rc, out = run_sourced("legacy_field server\necho\nlegacy_field key", {"HOME": str(tmp_path)})
        assert rc == 0, out
        assert "http://10.0.0.1:8911/dictate" in out
        assert "oldkey" in out

    def test_migration_never_modifies_the_hammerspoon_config(self, tmp_path):
        # Rolling back must stay as cheap as relaunching Hammerspoon.
        self._legacy(tmp_path, "http://10.0.0.1:8911/dictate", "oldkey")
        legacy = tmp_path / ".hammerspoon" / "hark-config.lua"
        before = legacy.read_bytes()
        rc, out = run_sourced("resolve_config", {"HOME": str(tmp_path)})
        assert rc == 0, out
        assert legacy.read_bytes() == before

    def test_an_existing_client_json_wins_over_the_legacy_config(self, tmp_path):
        import json

        self._legacy(tmp_path, "http://10.0.0.1:8911/dictate", "oldkey")
        rc, _ = run_sourced(
            'write_client_config "http://10.0.0.2:8911/dictate" "newkey"', {"HOME": str(tmp_path)}
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
        assert "install-client.sh" in ci
        assert "install-agent.sh" not in ci

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


class TestTransportPolicy:
    """The installer must not write a config the agent will refuse.

    The agent enforces: plain HTTP to loopback always; to a numeric IP only
    with an explicit allowPlaintext; to a hostname never. Writing a config that
    fails those checks just moves the failure to first launch, where it reads
    as "the agent is broken" rather than "your address is wrong".
    """

    def _write(self, home, server):
        return run_sourced(f'write_client_config "{server}" "k"', {"HOME": str(home)})

    def test_a_hostname_over_plain_http_is_refused(self, tmp_path):
        # A MagicDNS name is a hostname. It resolves through something, and
        # "the tailnet is trusted" stops being true when it resolves elsewhere.
        rc, out = self._write(tmp_path, "http://dans-mac-studio:8911/dictate")
        assert rc != 0
        assert "hostname" in out
        assert not (tmp_path / ".config/hark/client.json").exists()

    def test_a_numeric_ip_is_allowed_and_records_the_choice(self, tmp_path):
        import json

        rc, out = self._write(tmp_path, "http://100.64.66.46:8911/dictate")
        assert rc == 0, out
        written = json.loads((tmp_path / ".config/hark/client.json").read_text())
        assert written["allowPlaintext"] is True
        assert "allowPlaintext" in out, "the choice should be stated, not silent"
        # The warning must not overclaim: on a tailnet WireGuard already
        # encrypts the hop, so "in the clear on the wire" is wrong.
        assert "unencrypted" not in out

    def test_loopback_needs_no_opt_in(self, tmp_path):
        import json

        rc, out = self._write(tmp_path, "http://127.0.0.1:8911/dictate")
        assert rc == 0, out
        written = json.loads((tmp_path / ".config/hark/client.json").read_text())
        assert written["allowPlaintext"] is False

    def test_https_to_a_hostname_is_fine(self, tmp_path):
        import json

        rc, out = self._write(tmp_path, "https://dans-mac-studio:8911/dictate")
        assert rc == 0, out
        written = json.loads((tmp_path / ".config/hark/client.json").read_text())
        assert written["allowPlaintext"] is False


class TestStatusDoctor:
    """Every permission check reads the agent's own status.json.

    Measured from outside, both are wrong: a mic probe from this script tests
    the terminal's grant, and TCC.db reports what was true for an earlier
    build. Both produced confident false PASSes during bring-up.
    """

    def _status(self, home, **fields):
        import json, time

        d = {"pid": 123, "written_epoch": int(time.time()),
             "microphone": "authorized", "accessibility": "trusted",
             "hotkey": "registered"}
        d.update(fields)
        p = home / ".config/hark"
        p.mkdir(parents=True, exist_ok=True)
        (p / "status.json").write_text(json.dumps(d))

    def test_all_good_passes(self, tmp_path):
        self._status(tmp_path)
        for check in ("check_mic", "check_accessibility", "check_hotkey_bound"):
            rc, out = run_sourced(check, {"HOME": str(tmp_path)})
            assert "PASS" in out, f"{check}: {out}"

    def test_denied_microphone_is_not_a_pass(self, tmp_path):
        self._status(tmp_path, microphone="denied")
        rc, out = run_sourced("check_mic", {"HOME": str(tmp_path)})
        assert "FAIL" in out and "PASS" not in out

    def test_untrusted_accessibility_is_not_a_pass(self, tmp_path):
        self._status(tmp_path, accessibility="not_trusted")
        rc, out = run_sourced("check_accessibility", {"HOME": str(tmp_path)})
        assert "FAIL" in out and "PASS" not in out

    def test_an_unbound_hotkey_is_not_a_pass(self, tmp_path):
        # This field used to be a hardcoded "registered" literal, which is how
        # a dead CGEventTap looked healthy from the outside.
        self._status(tmp_path, hotkey="not_registered")
        rc, out = run_sourced("check_hotkey_bound", {"HOME": str(tmp_path)})
        assert "FAIL" in out and "PASS" not in out

    def test_a_stale_status_is_not_trusted(self, tmp_path):
        # The heartbeat rewrites every 30s, so a stale file means the agent
        # died without saying so and every field is a claim about a dead pid.
        self._status(tmp_path, written_epoch=1)
        rc, out = run_sourced("check_status_freshness", {"HOME": str(tmp_path)})
        assert "FAIL" in out
        assert "stale" in out

    def test_a_missing_status_is_not_a_pass(self, tmp_path):
        rc, out = run_sourced("check_status_freshness", {"HOME": str(tmp_path)})
        assert "FAIL" in out and "PASS" not in out
