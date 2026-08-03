#!/usr/bin/env bash
#
# hark — native agent setup.
#
# Installs the Swift agent (client/agent/) as ~/Applications/hark.app and
# registers it as a LaunchAgent so it starts at login. This is the eventual
# replacement for install-client.sh's Hammerspoon path.
#
#   ./install-agent.sh            install or update the agent
#   ./install-agent.sh --doctor   read-only diagnosis, changes nothing
#   ./install-agent.sh --uninstall remove the agent and its LaunchAgent
#
# WHY THIS IS A SEPARATE SCRIPT
#
# The agent and the Hammerspoon client are designed to coexist while you
# migrate, so nothing here touches ~/.hammerspoon or install-client.sh. When
# the Lua client is deleted this script folds back into install-client.sh; see
# GitHub issue #2.
#
# THEY CANNOT BOTH HOLD THE HOTKEY.
#
# Ctrl+Alt+Space is a system-wide registration and exactly one process gets
# it. Whichever of the two starts first wins, and the loser reports that it
# could not register. Coexist means "both installed, one running" - not "both
# listening". This script quits Hammerspoon for you unless --keep-hammerspoon
# is given.
#
# CONFIG MIGRATION
#
# ~/.hammerspoon/hark-config.lua (Lua) becomes ~/.config/hark/client.json.
# The old file is read but never modified, so rolling back to the Hammerspoon
# client is just quitting the agent and relaunching Hammerspoon.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$REPO_DIR/build"
APP_SRC="$BUILD_DIR/hark.app"
APP_DIR="$HOME/Applications"
APP_DST="$APP_DIR/hark.app"

HARK_CONFIG_DIR="$HOME/.config/hark"
CLIENT_CONFIG="$HARK_CONFIG_DIR/client.json"
MIC_STATUS="$HARK_CONFIG_DIR/agent-mic-status"
ACCESSIBILITY_STATUS="$HARK_CONFIG_DIR/agent-accessibility-status"
# The code identity the last install was granted against. See
# reset_stale_grants_on_identity_change().
INSTALLED_CDHASH="$HARK_CONFIG_DIR/.agent-cdhash"
SERVER_KEY="$HARK_CONFIG_DIR/key"

LEGACY_CONFIG="$HOME/.hammerspoon/hark-config.lua"

LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
AGENT_LABEL="com.drycodeworks.hark-agent"
AGENT_PLIST="$LAUNCH_AGENTS/$AGENT_LABEL.plist"

DEFAULT_SERVER="http://127.0.0.1:8911/dictate"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; }

doctor_failures=0
doctor_pass() { printf '  \033[1;32mPASS\033[0m  %s\n' "$1"; }
doctor_fail() {
  printf '  \033[1;31mFAIL\033[0m  %s\n' "$1"
  printf '        \033[1;33mfix:\033[0m %s\n' "$2"
  doctor_failures=$((doctor_failures + 1))
}

# ==============================================================================
# Config
# ==============================================================================

# Extracts a quoted field from the legacy Lua config, e.g. for a line
# `  server = "http://...",` prints `http://...`.
legacy_field() {
  local field="$1"
  [[ -f "$LEGACY_CONFIG" ]] || return 1
  local value
  value="$(grep -E "^[[:space:]]*${field}[[:space:]]*=" "$LEGACY_CONFIG" 2>/dev/null \
    | sed -E 's/^[^"]*"([^"]*)".*/\1/' || true)"
  [[ -n "$value" ]] || return 1
  printf '%s' "$value"
}

# Reads a string field out of client.json without needing jq. Deliberately
# narrow: these two fields are written by this script, so the shape is known.
json_field() {
  local field="$1"
  [[ -f "$CLIENT_CONFIG" ]] || return 1
  local value
  value="$(grep -E "\"${field}\"[[:space:]]*:" "$CLIENT_CONFIG" 2>/dev/null \
    | sed -E 's/.*"'"${field}"'"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true)"
  [[ -n "$value" ]] || return 1
  printf '%s' "$value"
}

# Escapes the two characters that can appear in a key or URL and would break
# the JSON we emit. Keys are base64-ish and URLs are plain, so this is a
# guard rather than a general-purpose escaper.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

write_client_config() {
  local server="$1" key="$2"
  mkdir -p "$HARK_CONFIG_DIR"
  # Written 600 BEFORE the secret goes in, so there is no window where the
  # key exists in a world-readable file.
  : > "$CLIENT_CONFIG"
  chmod 600 "$CLIENT_CONFIG"
  cat > "$CLIENT_CONFIG" <<EOF
{
  "server": "$(json_escape "$server")",
  "key": "$(json_escape "$key")"
}
EOF
  chmod 600 "$CLIENT_CONFIG"
}

resolve_config() {
  local server="" key=""

  # 1. An existing client.json wins - re-running must not clobber hand edits.
  server="$(json_field server || true)"
  key="$(json_field key || true)"

  # 2. Otherwise migrate the Hammerspoon client's config.
  if [[ -z "$server" ]]; then server="$(legacy_field server || true)"; fi
  if [[ -z "$key" ]]; then key="$(legacy_field key || true)"; fi

  # 3. Otherwise, if the server runs on this Mac, its key is already local.
  if [[ -z "$key" && -r "$SERVER_KEY" ]]; then
    key="$(tr -d '[:space:]' < "$SERVER_KEY")"
  fi

  if [[ -z "$server" ]]; then server="$DEFAULT_SERVER"; fi

  if [[ -z "$key" ]]; then
    err "no shared secret found."
    printf '  Looked in, in order:\n'
    printf '    %s ("key" field)\n' "$CLIENT_CONFIG"
    printf '    %s (key = "...")\n' "$LEGACY_CONFIG"
    printf '    %s (the server'"'"'s own key, if it runs on this Mac)\n' "$SERVER_KEY"
    printf '  For a two-machine setup, copy the key from the server:\n'
    printf '    ssh <server> cat ~/.config/hark/key\n'
    exit 1
  fi

  write_client_config "$server" "$key"
  log "wrote $CLIENT_CONFIG (600) — server: $server"
}

# ==============================================================================
# Stale TCC grants
# ==============================================================================
#
# An ad-hoc signature's designated requirement is a bare content hash:
#
#   designated => cdhash H"6836bec46e8c7d394cf1ba94421ff18a31674867"
#
# so every rebuild is a new code identity and the Accessibility grant stops
# applying. What macOS does NOT do is tidy up: the old row survives with
# auth_value=2 and System Settings keeps drawing a switched-ON toggle for a
# binary nothing trusts. Observed twice on 2026-08-03, and it is genuinely
# misleading - you go to grant the permission, find it already granted, and
# conclude the problem is somewhere else.
#
# Toggling it off and on by hand works. So does this, without the detour.
#
# Only Accessibility is reset, for two reasons. It is the grant observed to
# break on rebuild, and the microphone path already tells the truth on its own:
# the agent's probe actually runs rec and reports what happened, so a stale
# microphone row cannot produce a false PASS the way a stale Accessibility row
# did. Resetting it anyway would cost a consent dialog for nothing.
#
# A Developer ID signature makes this whole function dead code, because the
# requirement becomes the certificate rather than the hash.
current_cdhash() {
  codesign -dvvv "$APP_DST" 2>&1 | sed -n 's/^CDHash=//p' | head -1
}

reset_stale_grants_on_identity_change() {
  local new_hash old_hash=""
  new_hash="$(current_cdhash)"
  [[ -n "$new_hash" ]] || return 0
  [[ -f "$INSTALLED_CDHASH" ]] && old_hash="$(cat "$INSTALLED_CDHASH")"

  mkdir -p "$HARK_CONFIG_DIR"
  printf '%s' "$new_hash" > "$INSTALLED_CDHASH"

  # First install, or the same binary reinstalled: nothing to invalidate.
  [[ -n "$old_hash" && "$old_hash" != "$new_hash" ]] || return 0

  warn "the agent binary changed (${old_hash:0:12}… -> ${new_hash:0:12}…)."
  warn "Ad-hoc signing ties TCC grants to that hash, so the Accessibility grant"
  warn "no longer applies — and macOS would still show its toggle switched ON."
  if tccutil reset Accessibility "$AGENT_LABEL" >/dev/null 2>&1; then
    warn "Cleared the stale entry. You will be asked to grant it again."
  else
    warn "Could not clear it automatically. Toggle hark OFF and back ON in"
    warn "System Settings -> Privacy & Security -> Accessibility."
  fi
}

# ==============================================================================
# LaunchAgent
# ==============================================================================
#
# RunAtLoad only, no KeepAlive. A crashed agent should stay down and be
# noticed, not be silently resurrected into a crash loop that looks like
# "the hotkey is flaky".
#
# ProgramArguments points INSIDE the bundle. That is deliberate and is what
# keeps TCC attributing the microphone and Accessibility grants to
# com.drycodeworks.hark-agent: the executable is covered by the bundle's code
# signature, so its identity resolves to the bundle regardless of who exec'd
# it. `open -a` would work too but gives launchd nothing to supervise.

write_plist() {
  mkdir -p "$LAUNCH_AGENTS"
  cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${AGENT_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${APP_DST}/Contents/MacOS/hark-agent</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>/tmp/hark-agent.out</string>
	<key>StandardErrorPath</key>
	<string>/tmp/hark-agent.err</string>
</dict>
</plist>
EOF
  log "wrote $AGENT_PLIST"
}

agent_loaded() {
  # Captured into a variable first, NOT piped. `launchctl list | grep -q X`
  # under `set -o pipefail` reports every service as not-loaded: grep exits at
  # the first match, launchctl takes SIGPIPE, and pipefail propagates it.
  local listing
  listing="$(launchctl list 2>/dev/null || true)"
  printf '%s' "$listing" | grep -q "$AGENT_LABEL"
}

reload_agent() {
  local domain
  domain="gui/$(id -u)"
  if agent_loaded; then
    launchctl bootout "$domain/$AGENT_LABEL" 2>/dev/null || true
    # `Bootstrap failed: 5: Input/output error` right after a bootout is
    # usually the old instance still tearing down, not a bad plist.
    sleep 1
  fi
  if ! launchctl bootstrap "$domain" "$AGENT_PLIST" 2>/dev/null; then
    sleep 2
    launchctl bootstrap "$domain" "$AGENT_PLIST" 2>/dev/null || {
      err "launchctl bootstrap failed for $AGENT_LABEL"
      err "try: launchctl bootout $domain/$AGENT_LABEL && launchctl bootstrap $domain $AGENT_PLIST"
      return 1
    }
  fi
  log "loaded $AGENT_LABEL"
}

# ==============================================================================
# Doctor
# ==============================================================================

check_app_installed() {
  if [[ ! -d "$APP_DST" ]]; then
    doctor_fail "hark.app is installed" "run ./install-agent.sh"
    return 1
  fi
  doctor_pass "hark.app is installed at $APP_DST"
}

check_signature() {
  if [[ ! -d "$APP_DST" ]]; then
    doctor_fail "hark.app has a valid signature" "run ./install-agent.sh"
    return 1
  fi
  if ! codesign --verify --strict "$APP_DST" 2>/dev/null; then
    doctor_fail "hark.app has a valid signature" \
      "rebuild it: ./client/agent/build-agent.sh && ./install-agent.sh"
    return 1
  fi
  local identity
  identity="$(codesign -dvv "$APP_DST" 2>&1 | grep -E '^Signature=' | cut -d= -f2- || true)"
  doctor_pass "hark.app signature is valid (${identity:-unknown})"
}

check_config() {
  if [[ ! -f "$CLIENT_CONFIG" ]]; then
    doctor_fail "$CLIENT_CONFIG exists" "run ./install-agent.sh"
    return 1
  fi
  local perms
  perms="$(stat -f '%OLp' "$CLIENT_CONFIG")"
  if [[ "$perms" != "600" ]]; then
    doctor_fail "$CLIENT_CONFIG is 600 (it holds a secret)" "chmod 600 $CLIENT_CONFIG"
    return 1
  fi
  if ! json_field key >/dev/null; then
    doctor_fail "$CLIENT_CONFIG has a key" "run ./install-agent.sh"
    return 1
  fi
  doctor_pass "$CLIENT_CONFIG is present, 600, and has a key"
}

check_agent_running() {
  if ! agent_loaded; then
    doctor_fail "the agent is loaded in launchd" "run ./install-agent.sh"
    return 1
  fi
  if ! pgrep -f "$APP_DST/Contents/MacOS/hark-agent" >/dev/null 2>&1; then
    doctor_fail "the agent process is running" \
      "check /tmp/hark-agent.err and ~/Library/Logs/hark-agent.log"
    return 1
  fi
  doctor_pass "the agent is loaded and running"
}

# Reads the outcome the AGENT's own startup probe wrote. This is the only
# reliable way to learn whether the agent can reach the microphone: TCC
# attributes a request to the responsible process, and rec runs as the
# agent's child — so running rec from THIS shell would test the terminal's
# grant, a different permission that produces a confidently wrong PASS.
# Never run rec from here to "test" this; read what the agent wrote.
check_mic() {
  if [[ ! -f "$MIC_STATUS" ]]; then
    doctor_fail "the agent can reach the microphone" \
      "the agent hasn't probed yet — is it running? (./install-agent.sh)"
    return 1
  fi
  local status detail
  status="$(sed -n '1p' "$MIC_STATUS")"
  detail="$(sed -n '3p' "$MIC_STATUS" || true)"
  case "$status" in
    ok)
      doctor_pass "the agent can reach the microphone"
      ;;
    denied)
      doctor_fail "the agent can reach the microphone" \
        "System Settings -> Privacy & Security -> Microphone -> turn ON hark"
      ;;
    *)
      doctor_fail "the agent can reach the microphone (probe said: $status)" \
        "${detail:-see ~/Library/Logs/hark-agent.log}"
      ;;
  esac
}

# Reads what the agent's own AXIsProcessTrusted() call recorded — NOT TCC.db.
#
# This check used to query TCC.db directly and it produced a confident FALSE
# PASS on 2026-08-03: it reported "Accessibility is granted" while the agent
# was simultaneously alerting on screen that it could not paste. The row in
# TCC.db outlives the grant it describes. An ad-hoc signature's designated
# requirement is a bare `cdhash`, so every rebuild is a new identity — the old
# row survives with auth_value=2, System Settings keeps drawing a switched-ON
# toggle, and the running binary is trusted by nobody.
#
# So the same rule as the microphone applies for the same underlying reason:
# only the process can answer for the process. Reading TCC.db also required
# Full Disk Access, which this script does not necessarily have.
check_accessibility() {
  local status_file="$ACCESSIBILITY_STATUS"
  if [[ ! -f "$status_file" ]]; then
    # An agent older than this check, or one that has not started yet. Not a
    # failure, and deliberately not a PASS either.
    printf '  \033[1;33mSKIP\033[0m  Accessibility (the agent has not reported yet)\n'
    printf '        if dictation records but nothing pastes, that is this permission:\n'
    printf '        System Settings -> Privacy & Security -> Accessibility -> hark\n'
    return 0
  fi
  if [[ "$(sed -n '1p' "$status_file")" == "ok" ]]; then
    doctor_pass "Accessibility is granted (agent reported at $(sed -n '2p' "$status_file"))"
  else
    doctor_fail "Accessibility is granted to hark" \
      "System Settings -> Privacy & Security -> Accessibility -> turn ON hark, then restart the agent"
  fi
}

check_hotkey_conflict() {
  if pgrep -x Hammerspoon >/dev/null 2>&1; then
    doctor_fail "nothing else holds Ctrl+Alt+Space" \
      "Hammerspoon is running and owns the hotkey — quit it (osascript -e 'quit app \"Hammerspoon\"')"
    return 1
  fi
  doctor_pass "nothing else is holding Ctrl+Alt+Space"
}

run_doctor() {
  printf '\nhark agent diagnostics\n\n'
  check_app_installed || true
  check_signature || true
  check_config || true
  check_agent_running || true
  check_hotkey_conflict || true
  check_mic || true
  check_accessibility || true
  printf '\n'
  if [[ "$doctor_failures" -gt 0 ]]; then
    err "$doctor_failures check(s) failed"
    return 1
  fi
  log "all checks passed"
}

# ==============================================================================
# Uninstall
# ==============================================================================

run_uninstall() {
  if agent_loaded; then
    launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
    log "unloaded $AGENT_LABEL"
  fi
  rm -f "$AGENT_PLIST"
  rm -rf "$APP_DST"
  log "removed $APP_DST and $AGENT_PLIST"
  # client.json is deliberately left in place: it holds the shared secret and
  # is what a reinstall (or the Hammerspoon client) would want back.
  log "left $CLIENT_CONFIG alone — delete it by hand if you meant to."
}

# ==============================================================================
# Main
# ==============================================================================

# Sourcing this file defines the helpers and check_* functions and stops here,
# so the test suite can exercise them without running an install. Everything
# below this line only runs when the script is executed directly.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

KEEP_HAMMERSPOON=0
MODE="install"
for arg in "$@"; do
  case "$arg" in
    --doctor)           MODE="doctor" ;;
    --uninstall)        MODE="uninstall" ;;
    --keep-hammerspoon) KEEP_HAMMERSPOON=1 ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      err "unknown argument: $arg (try --help)"
      exit 2
      ;;
  esac
done

case "$MODE" in
  doctor)    run_doctor; exit $? ;;
  uninstall) run_uninstall; exit 0 ;;
esac

log "building the agent"
"$REPO_DIR/client/agent/build-agent.sh" "$BUILD_DIR"

log "installing to $APP_DST"
mkdir -p "$APP_DIR"
# Replaced wholesale rather than copied over: a stale file left inside the
# bundle invalidates the signature, and the failure surfaces much later as an
# unexplained TCC re-prompt.
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

# Must run AFTER the copy (it hashes the installed bundle) and BEFORE the agent
# restarts, so the agent's prompt lands on a cleared entry rather than a stale
# one that claims to be granted already.
reset_stale_grants_on_identity_change

resolve_config

if [[ "$KEEP_HAMMERSPOON" -eq 0 ]] && pgrep -x Hammerspoon >/dev/null 2>&1; then
  warn "Hammerspoon is running and owns Ctrl+Alt+Space — quitting it so the agent can register."
  warn "Pass --keep-hammerspoon to leave it alone (the agent will then fail to bind the hotkey)."
  osascript -e 'quit app "Hammerspoon"' 2>/dev/null || true
  sleep 1
fi

# Cleared BEFORE the agent restarts, so the wait below observes THIS run's
# probe rather than instantly succeeding on the previous run's file.
rm -f "$MIC_STATUS"

write_plist
reload_agent

# Wait for the agent's microphone probe to report, rather than sleeping a
# fixed interval. The probe cannot finish until the user has answered the
# consent dialog, so any fixed wait either races a human or pads every
# already-granted re-run. A 3s sleep here reported a spurious FAIL on the
# first install, with the prompt still on screen.
printf '==> waiting for the microphone probe (answer the prompt if one appears)'
probe_started_at="$(date +%s)"
while [[ ! -f "$MIC_STATUS" ]]; do
  if [[ $(($(date +%s) - probe_started_at)) -ge 45 ]]; then
    printf '\n'
    warn "the probe did not report within 45s — the doctor below may be stale"
    break
  fi
  printf '.'
  sleep 1
done
printf '\n'

printf '\n'
if run_doctor; then
  printf '\n'
  log "setup complete — hold Ctrl+Alt+Space and speak."
else
  printf '\n'
  warn "setup finished with failing checks — see the fixes above."
  warn "Both permission prompts only appear once the agent asks, so re-run"
  warn "./install-agent.sh --doctor after granting them."
  exit 1
fi
