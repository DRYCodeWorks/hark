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

# Accessibility is queried directly rather than through a status file: unlike
# the microphone, the answer does not depend on which process asks. The agent
# needs it to synthesize Cmd+V — without it, recording and transcription both
# work and nothing ever appears.
check_accessibility() {
  local db="/Library/Application Support/com.apple.TCC/TCC.db"
  if [[ ! -r "$db" ]]; then
    # Expected: the system TCC database is not world-readable, and reading it
    # needs Full Disk Access. Not a failure — say so rather than reporting a
    # permission we cannot see as missing.
    printf '  \033[1;33mSKIP\033[0m  Accessibility (cannot read TCC.db without Full Disk Access)\n'
    printf '        check by hand: System Settings -> Privacy & Security -> Accessibility -> hark\n'
    return 0
  fi
  if sqlite3 "$db" \
    "select 1 from access where service='kTCCServiceAccessibility' and client='$AGENT_LABEL' and auth_value>0" \
    2>/dev/null | grep -q 1; then
    doctor_pass "Accessibility is granted to hark"
  else
    doctor_fail "Accessibility is granted to hark" \
      "System Settings -> Privacy & Security -> Accessibility -> turn ON hark"
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

resolve_config

if [[ "$KEEP_HAMMERSPOON" -eq 0 ]] && pgrep -x Hammerspoon >/dev/null 2>&1; then
  warn "Hammerspoon is running and owns Ctrl+Alt+Space — quitting it so the agent can register."
  warn "Pass --keep-hammerspoon to leave it alone (the agent will then fail to bind the hotkey)."
  osascript -e 'quit app "Hammerspoon"' 2>/dev/null || true
  sleep 1
fi

write_plist
reload_agent

# The agent needs a moment to register the hotkey, run its microphone probe
# and write the status file the doctor reads.
sleep 3

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
