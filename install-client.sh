#!/usr/bin/env bash
#
# hark — client setup.
#
# Run this on the Mac you want to dictate FROM. On a single-machine setup that
# is the same Mac that runs the server; on a two-machine setup it is the
# laptop, not the transcribing desktop. It builds swift/ into
# ~/Applications/Hark.app and registers `hark agent` as a LaunchAgent so it
# starts at login.
#
#   ./install-client.sh                install or update
#   ./install-client.sh <ssh-host>     skip the "server SSH host" prompt
#   ./install-client.sh --doctor       read-only diagnosis, changes nothing
#   ./install-client.sh --uninstall    remove the agent and its LaunchAgent
#
# Safe to re-run: every step checks current state first, and the key is always
# re-read, so this doubles as "resync my key after the server rotated it".
#
# MIGRATING FROM THE HAMMERSPOON CLIENT
#
# Until 2026-08-03 the client was Hammerspoon plus 505 lines of Lua, which
# meant Accessibility was granted to a general-purpose scriptable runtime whose
# config was a symlink into this repo — so a `git pull` changed what that grant
# covered without re-prompting. The native agent asks for the same permission
# with far less behind it. See GitHub issue #2.
#
# Two things this still does for anyone crossing that bridge:
#
#   - ~/.hammerspoon/hark-config.lua is read into ~/.config/hark/client.json,
#     if the latter does not exist yet. The old file is never modified.
#   - Hammerspoon is quit if it is running, because Ctrl+Alt+Space is a
#     system-wide registration and exactly one process gets it — whichever
#     starts first wins and the loser reports it could not register. Pass
#     --keep-hammerspoon to leave it alone.
#
# Once you are on the agent: `brew uninstall --cask hammerspoon` and remove
# ~/.hammerspoon/init.lua. Revoking Hammerspoon's Accessibility and Microphone
# grants is the actual point of the exercise, and quitting the app does not do
# it for you.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_SRC="$REPO_DIR/swift/Packaging/Hark.app"
APP_DIR="$HOME/Applications"
APP_DST="$APP_DIR/Hark.app"

HARK_CONFIG_DIR="$HOME/.config/hark"
CLIENT_CONFIG="$HARK_CONFIG_DIR/client.json"
STATUS_JSON="$HARK_CONFIG_DIR/status.json"
# The code identity the last install was granted against. See
# reset_stale_grants_on_identity_change().
INSTALLED_CDHASH="$HARK_CONFIG_DIR/.agent-cdhash"
SERVER_KEY="$HARK_CONFIG_DIR/key"

LEGACY_CONFIG="$HOME/.hammerspoon/hark-config.lua"

LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
AGENT_LABEL="com.drycodeworks.hark-agent"
AGENT_PLIST="$LAUNCH_AGENTS/$AGENT_LABEL.plist"

DEFAULT_SERVER="http://127.0.0.1:8911/dictate"

# The server's SSH host, for a two-machine setup. Set by a bare argument or
# HARK_SERVER_HOST; otherwise prompted for, and only when no key is found
# locally. Deliberately separate from the server URL — see fetch_key_over_ssh.
SERVER_HOST="${HARK_SERVER_HOST:-}"

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

# Emits the client config the agent actually accepts.
#
# The agent enforces a transport policy: plain HTTP to loopback always; to a
# numeric IP only with an explicit allowPlaintext; to a HOSTNAME never, because
# a name resolves through something and a MagicDNS name is a hostname. Writing
# a config the agent will refuse just moves the failure to first launch, so the
# refusal happens here where it can be explained.
write_client_config() {
  local server="$1" key="$2" host scheme plaintext="false"
  scheme="${server%%://*}"
  host="${server#*://}"; host="${host%%/*}"; host="${host%%:*}"

  if [[ "$scheme" == "http" ]] && ! is_loopback_host "$host"; then
    if ! is_numeric_ip "$host"; then
      err "the agent will refuse plain HTTP to the hostname '${host}'."
      err "Use the numeric address instead — a Tailscale MagicDNS name is a"
      err "hostname, so use the tailnet IP — or serve it over https://."
      exit 1
    fi
    # A numeric IP on a tailnet is a defensible place for plaintext, but it
    # should be a stated decision rather than a silent default.
    plaintext="true"
    warn "no TLS to ${host} — recording it as allowPlaintext."
    warn "On a tailnet this is narrower than it sounds: WireGuard already"
    warn "encrypts the traffic between your machines, so this is 'no TLS"
    warn "inside an encrypted tunnel', not 'in the clear on the wire'. It"
    warn "still means the server is not authenticated to the client."
    warn "For real TLS: tailscale cert <magicdns-name>, serve it, and point"
    warn "\"server\" at https://<magicdns-name> — no opt-in needed then."
  fi

  mkdir -p "$HARK_CONFIG_DIR"
  # 600 BEFORE the secret goes in, so there is no world-readable window.
  : > "$CLIENT_CONFIG"
  chmod 600 "$CLIENT_CONFIG"
  cat > "$CLIENT_CONFIG" <<EOF
{
  "server": "$(json_escape "$server")",
  "key": "$(json_escape "$key")",
  "allowPlaintext": ${plaintext}
}
EOF
  chmod 600 "$CLIENT_CONFIG"
}

is_loopback_host() {
  [[ "$1" == "127.0.0.1" || "$1" == "localhost" || "$1" == "::1" ]]
}

# Dotted quad, or anything with a colon (IPv6). The only question is whether
# the user gave an address or a name.
is_numeric_ip() {
  local h="$1"
  [[ "$h" == *:* ]] && return 0
  [[ "$h" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
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

  # 4. Otherwise the server is another Mac, so fetch its key over SSH.
  if [[ -z "$key" ]]; then
    key="$(fetch_key_over_ssh)" || true
  fi

  if [[ -z "$server" ]]; then server="$DEFAULT_SERVER"; fi

  if [[ -z "$key" ]]; then
    err "no shared secret found."
    printf '  Looked in, in order:\n' >&2
    printf '    %s ("key" field)\n' "$CLIENT_CONFIG" >&2
    printf '    %s (key = "...")\n' "$LEGACY_CONFIG" >&2
    printf '    %s (the server'"'"'s own key, if it runs on this Mac)\n' "$SERVER_KEY" >&2
    printf '  For a two-machine setup, pass the server'"'"'s SSH host:\n' >&2
    printf '    ./install-client.sh <ssh-host>\n' >&2
    exit 1
  fi

  write_client_config "$server" "$key"
  log "wrote $CLIENT_CONFIG (600) — server: $server"

  # The key came from another Mac but the URL is still loopback, which would
  # POST every recording into the void on this one. Cheap to say, and the
  # alternative — deriving the URL from the SSH host — is exactly the guess
  # that makes a config look healthy while the client silently fails.
  if [[ "$server" == "$DEFAULT_SERVER" && -n "$SERVER_HOST" ]]; then
    warn "the server URL is still the loopback default, but the key came from"
    warn "'$SERVER_HOST'. Set the real address in $CLIENT_CONFIG."
  fi
}

# Fetches the shared secret from the Mac running the server. Prints it on
# stdout; prints nothing and returns non-zero on any failure.
#
# The SSH host is NOT derived from the server URL, nor the URL from the host.
# An alias that works for `ssh <host>` — a ~/.ssh/config entry, a MagicDNS
# name — is not necessarily an address curl can reach.
fetch_key_over_ssh() {
  if [[ -z "$SERVER_HOST" ]]; then
    # Non-interactive (CI, a piped install): fail to the caller's message
    # rather than blocking forever on a read that can never be answered.
    [[ -t 0 ]] || return 1
    {
      echo
      echo "No key found on this Mac, so hark's server is presumably another one."
      echo
      echo "If it should be THIS Mac, quit (Ctrl-C) and run ./install-server.sh first."
      echo
      echo "Otherwise give the server's SSH host — exactly what you would type for"
      echo "'ssh <host>' today (a ~/.ssh/config alias, a Tailscale name, or an IP)."
    } >&2
    read -rp "server SSH host: " SERVER_HOST
  fi
  [[ -n "$SERVER_HOST" ]] || return 1

  log "fetching the shared secret from ${SERVER_HOST} over SSH..." >&2
  local err_file fetched rc=0
  err_file="$(mktemp)"

  fetched="$(ssh -o ConnectTimeout=10 "$SERVER_HOST" 'cat ~/.config/hark/key' 2>"$err_file")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    err "could not fetch the key from '${SERVER_HOST}'. Likely causes:"
    err "  - you are not on the same network/tailnet right now"
    err "  - '${SERVER_HOST}' is not the right SSH host/alias for the server"
    err "  - SSH key auth to that host is not set up (if it hung, that is probably it)"
    err "  - ~/.config/hark/key does not exist there — run ./install-server.sh on it"
    err "ssh said:"
    sed 's/^/    /' "$err_file" >&2 || true
    rm -f "$err_file"
    return 1
  fi
  rm -f "$err_file"

  fetched="$(printf '%s' "$fetched" | tr -d '[:space:]')"
  if [[ -z "$fetched" ]]; then
    err "fetched an EMPTY key from ${SERVER_HOST} — check ~/.config/hark/key there."
    return 1
  fi
  printf '%s' "$fetched"
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
		<string>${APP_DST}/Contents/MacOS/hark</string>
		<string>agent</string>
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
    doctor_fail "Hark.app is installed" "run ./install-client.sh"
    return 1
  fi
  doctor_pass "Hark.app is installed at $APP_DST"
}

check_signature() {
  if [[ ! -d "$APP_DST" ]]; then
    doctor_fail "Hark.app has a valid signature" "run ./install-client.sh"
    return 1
  fi
  if ! codesign --verify --strict "$APP_DST" 2>/dev/null; then
    doctor_fail "Hark.app has a valid signature" \
      "rebuild it: ./install-client.sh"
    return 1
  fi
  local identity
  identity="$(codesign -dvv "$APP_DST" 2>&1 | grep -E '^Signature=' | cut -d= -f2- || true)"
  doctor_pass "Hark.app signature is valid (${identity:-unknown})"
}

check_config() {
  if [[ ! -f "$CLIENT_CONFIG" ]]; then
    doctor_fail "$CLIENT_CONFIG exists" "run ./install-client.sh"
    return 1
  fi
  local perms
  perms="$(stat -f '%OLp' "$CLIENT_CONFIG")"
  if [[ "$perms" != "600" ]]; then
    doctor_fail "$CLIENT_CONFIG is 600 (it holds a secret)" "chmod 600 $CLIENT_CONFIG"
    return 1
  fi
  if ! json_field key >/dev/null; then
    doctor_fail "$CLIENT_CONFIG has a key" "run ./install-client.sh"
    return 1
  fi
  doctor_pass "$CLIENT_CONFIG is present, 600, and has a key"
}

check_agent_running() {
  if ! agent_loaded; then
    doctor_fail "the agent is loaded in launchd" "run ./install-client.sh"
    return 1
  fi
  if ! pgrep -f "$APP_DST/Contents/MacOS/hark" >/dev/null 2>&1; then
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
# Reads one field out of the agent's status.json without needing jq.
#
# THE AGENT REPORTS ON ITSELF, and nothing here measures it from outside.
# That is not a style choice — both permissions were got wrong the other way
# during bring-up:
#
#   - a microphone probe run from this script tests the TERMINAL's grant, not
#     the agent's, because TCC attributes to the responsible process. A
#     confidently wrong PASS.
#   - querying TCC.db for Accessibility reports what was true for some EARLIER
#     build. An ad-hoc signature's designated requirement is a bare cdhash, so
#     every rebuild is a new identity while the old row survives reading
#     granted — and System Settings keeps drawing a switched-ON toggle for a
#     binary nothing trusts. This check printed PASS while the agent was
#     alerting on screen that it could not paste.
status_field() {
  local field="$1"
  [[ -f "$STATUS_JSON" ]] || return 1
  local value
  value="$(sed -E 's/.*"'"${field}"'"[[:space:]]*:[[:space:]]*"?([^",}]*)"?.*/\1/' "$STATUS_JSON" 2>/dev/null)"
  [[ -n "$value" ]] || return 1
  printf '%s' "$value"
}

# The heartbeat rewrites status.json every 30s, so a stale file means the agent
# died without saying so and every field in it is a claim about a process that
# no longer exists.
status_is_fresh() {
  local written now
  written="$(status_field written_epoch)" || return 1
  now="$(date +%s)"
  [[ $((now - written)) -lt 120 ]]
}

check_status_freshness() {
  if [[ ! -f "$STATUS_JSON" ]]; then
    doctor_fail "the agent has reported its status" \
      "the agent has not started yet — run ./install-client.sh"
    return 1
  fi
  if ! status_is_fresh; then
    doctor_fail "the agent's status is current" \
      "status.json is stale (>120s) — the agent is not running; check /tmp/hark-agent.err"
    return 1
  fi
  doctor_pass "the agent is reporting (pid $(status_field pid))"
}

check_mic() {
  local v
  v="$(status_field microphone || true)"
  case "$v" in
    authorized) doctor_pass "the agent can reach the microphone" ;;
    "")         doctor_fail "the agent can reach the microphone" "no status yet — is the agent running?" ;;
    *)          doctor_fail "the agent can reach the microphone (reported: $v)" \
                  "System Settings -> Privacy & Security -> Microphone -> turn ON hark" ;;
  esac
}


# The hotkey field used to be a hardcoded "registered" literal, so it reported
# success whether or not anything was bound — which is exactly how a dead
# CGEventTap looked healthy from outside. It now reflects the real binding.
check_hotkey_bound() {
  local v
  v="$(status_field hotkey || true)"
  case "$v" in
    registered) doctor_pass "Ctrl+Alt+Space is bound" ;;
    "")         doctor_fail "Ctrl+Alt+Space is bound" "no status yet — is the agent running?" ;;
    *)          doctor_fail "Ctrl+Alt+Space is bound (reported: $v)" \
                  "something else is holding the chord — quit it and re-run ./install-client.sh" ;;
  esac
}

check_accessibility() {
  local v
  v="$(status_field accessibility || true)"
  case "$v" in
    trusted) doctor_pass "Accessibility is granted" ;;
    "")      doctor_fail "Accessibility is granted" "no status yet — is the agent running?" ;;
    *)       doctor_fail "Accessibility is granted (reported: $v)" \
               "System Settings -> Privacy & Security -> Accessibility -> turn ON hark, then re-run this" ;;
  esac
}

check_hotkey_conflict() {
  if pgrep -x Hammerspoon >/dev/null 2>&1; then
    doctor_fail "nothing else holds Ctrl+Alt+Space" \
      "Hammerspoon is running and owns the hotkey — quit it (osascript -e 'quit app \"Hammerspoon\"')"
    return 1
  fi
  doctor_pass "nothing else is holding Ctrl+Alt+Space"
}

# The permissions and the process can all be healthy while the server is
# simply unreachable — a downed tailnet, a stopped service — and the symptom
# of that is identical to a microphone fault from the user's chair: you hold
# the key, speak, and nothing appears.
check_health() {
  local server url
  if ! server="$(json_field server)"; then
    doctor_fail "server /health reachable" "no server URL in $CLIENT_CONFIG — run ./install-client.sh"
    return 1
  fi
  url="${server%/dictate}/health"
  if curl -sf --max-time 5 "$url" >/dev/null 2>&1; then
    doctor_pass "server /health reachable ($url)"
    return 0
  fi
  doctor_fail "server /health reachable ($url)" \
    "check the tailnet (tailscale status) and that hark is running on the server (ssh <server> launchctl list | grep hark)"
  return 1
}

run_doctor() {
  printf '\nhark client diagnostics\n\n'
  check_app_installed || true
  check_signature || true
  check_config || true
  check_agent_running || true
  check_status_freshness || true
  check_hotkey_conflict || true
  check_hotkey_bound || true
  check_mic || true
  check_accessibility || true
  check_health || true
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
      sed -n '2,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      err "unknown option: $arg (try --help)"
      exit 2
      ;;
    *)
      # A bare argument is the server's SSH host, so a two-machine install can
      # skip the prompt. Not merged with the server URL: an alias that works
      # for `ssh <host>` is not necessarily something curl can reach.
      if [[ -n "$SERVER_HOST" ]]; then
        err "more than one SSH host given: '$SERVER_HOST' and '$arg'"
        exit 2
      fi
      SERVER_HOST="$arg"
      ;;
  esac
done

case "$MODE" in
  doctor)    run_doctor; exit $? ;;
  uninstall) run_uninstall; exit 0 ;;
esac

log "building the agent"
(cd "$REPO_DIR/swift" && swift build -c release && bash Packaging/build-app.sh)

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
rm -f "$STATUS_JSON"

write_plist
reload_agent

# Wait for the agent's microphone probe to report, rather than sleeping a
# fixed interval. The probe cannot finish until the user has answered the
# consent dialog, so any fixed wait either races a human or pads every
# already-granted re-run. A 3s sleep here reported a spurious FAIL on the
# first install, with the prompt still on screen.
printf '==> waiting for the microphone probe (answer the prompt if one appears)'
probe_started_at="$(date +%s)"
while [[ ! -f "$STATUS_JSON" ]]; do
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
  warn "./install-client.sh --doctor after granting them."
  exit 1
fi
