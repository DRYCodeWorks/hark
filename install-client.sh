#!/usr/bin/env bash
#
# hark — client setup.
#
# Run this on the Mac you want to dictate FROM. On a single-machine setup
# that is the same Mac that runs the server; on a two-machine setup it is the
# laptop, not the transcribing desktop. It:
#
#   1. installs Hammerspoon via Homebrew and builds client/rec.swift
#   2. reads the shared secret from ~/.config/hark/key if the server runs on
#      this same Mac; otherwise fetches it from the server over SSH
#   3. (nothing to pick — rec uses the system default input device)
#   4. writes ~/.hammerspoon/hark-config.lua (chmod 600 — it holds a secret)
#   5. links client/init.lua -> ~/.hammerspoon/init.lua (refuses to clobber a
#      real file there — see the loud error if that happens)
#   6. actually starts Hammerspoon with the new config loaded (launches it if
#      it wasn't running; quits + relaunches it if it was, since Hammerspoon
#      does not auto-reload its config)
#   7. checks Accessibility permission for Hammerspoon and, if it's missing,
#      opens the exact System Settings pane and BLOCKS until you confirm
#      you've granted it. Microphone permission works differently and is NOT
#      blocked on the same way — see step 8b's comment for why — instead
#      this waits (up to 30s) for client/init.lua's own startup microphone
#      probe to report an outcome, which is what actually triggers the
#      consent dialog
#   8. runs the same live checks as `--doctor` (below) and refuses to print
#      "setup complete" if any of them fail
#
# `./install-client.sh --doctor` runs step 8's checks on their own, read-only,
# changing nothing — useful any time the hotkey isn't working and you want to
# know exactly which piece is broken, without re-running the whole install.
#
# Safe to re-run: every step checks current state before acting, and step 2
# always re-reads the key fresh (so it also doubles as "resync my key after
# the server rotated it"). Re-running with permissions already granted is
# fast — the Accessibility check in step 7 only opens System Settings and
# blocks when it can't confirm the permission is already there, and the
# microphone probe in step 8b reports "ok" almost immediately once it's
# already been granted.
#
# This has been run for real, end to end, on one pair of Macs. The paths
# least likely to have been exercised on yours are the TCC permission
# prompts, which behave differently depending on what macOS has already
# granted. `--doctor` is the tool for that: it names the failing boundary
# rather than leaving you to guess.

set -euo pipefail

CONFIG_DIR="$HOME/.hammerspoon"
CONFIG_FILE="$CONFIG_DIR/hark-config.lua"
# Must match init.lua's RECORDER_PATH.
RECORDER_BIN="$CONFIG_DIR/rec"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This script lives at the repo root; the client sources it installs live in
# client/. Keep these separate — conflating them silently symlinks
# ~/.hammerspoon/init.lua to a path that does not exist.
CLIENT_DIR="$REPO_DIR/client"
HARK_PORT=8911
HAMMERSPOON_APP="/Applications/Hammerspoon.app"
HAMMERSPOON_BUNDLE_ID="org.hammerspoon.Hammerspoon"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; }

# ==============================================================================
# Diagnostics — shared between `--doctor` and the end of a normal run.
#
# Every check_* function prints exactly one PASS/FAIL line (with a remedy on
# FAIL) and returns 0/1. They never exit the script themselves: callers must
# use them as an `if`/`!` condition or append `|| true` when calling them as
# a bare statement, since a bare failing call under `set -e` would otherwise
# abort the whole script — the same class of bug this script already hit
# once with ffmpeg's expected-nonzero device-listing exit.
# ==============================================================================

DOCTOR_FAILURES=0

doctor_pass() { printf '  \033[1;32mPASS\033[0m  %s\n' "$1"; }
doctor_fail() {
  printf '  \033[1;31mFAIL\033[0m  %s\n' "$1"
  printf '        fix: %s\n' "$2"
  DOCTOR_FAILURES=$((DOCTOR_FAILURES + 1))
}

check_hammerspoon_installed() {
  if [[ -d "$HAMMERSPOON_APP" ]]; then
    doctor_pass "Hammerspoon.app installed"
    return 0
  fi
  doctor_fail "Hammerspoon.app installed" "brew install --cask hammerspoon"
  return 1
}

check_hammerspoon_running() {
  if pgrep -x Hammerspoon >/dev/null 2>&1; then
    doctor_pass "Hammerspoon is running"
    return 0
  fi
  doctor_fail "Hammerspoon is running" "open -a Hammerspoon   (or re-run ./install-client.sh, which does this for you)"
  return 1
}

check_init_symlink() {
  if [[ -L "$CONFIG_DIR/init.lua" && "$CONFIG_DIR/init.lua" -ef "$CLIENT_DIR/init.lua" ]]; then
    doctor_pass "${CONFIG_DIR}/init.lua is a symlink to ${CLIENT_DIR}/init.lua"
    return 0
  fi
  doctor_fail "${CONFIG_DIR}/init.lua is a symlink to this repo's client/init.lua" \
    "ln -sf ${CLIENT_DIR}/init.lua ${CONFIG_DIR}/init.lua   (if it's a real file instead, move it aside first — see README)"
  return 1
}

check_config_file() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    doctor_fail "${CONFIG_FILE} exists" "run ./install-client.sh"
    return 1
  fi

  local mode
  mode="$(stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null || true)"
  if [[ "$mode" != "600" ]]; then
    doctor_fail "${CONFIG_FILE} is mode 600 (found: ${mode:-unreadable})" "chmod 600 ${CONFIG_FILE}"
    return 1
  fi

  if ! grep -qE '^[[:space:]]*key[[:space:]]*=[[:space:]]*"[^"]+"' "$CONFIG_FILE"; then
    doctor_fail "${CONFIG_FILE} has a non-empty key" "re-run ./install-client.sh"
    return 1
  fi

  doctor_pass "${CONFIG_FILE} exists, mode 600, has a key"
  return 0
}

# Extracts a quoted field's value from hark-config.lua, e.g. for a line
# `  server = "http://...",` prints `http://...`. Prints nothing (and
# returns 1) if the field isn't present.
config_field() {
  local field="$1"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    return 1
  fi
  local value
  value="$(grep -E "^[[:space:]]*${field}[[:space:]]*=" "$CONFIG_FILE" 2>/dev/null \
    | sed -E 's/^[^"]*"([^"]*)".*/\1/' || true)"
  if [[ -z "$value" ]]; then
    return 1
  fi
  printf '%s' "$value"
}

# Mirrors init.lua's resolveRecorder(): trust the configured path if it's a
# real executable, else the default build location.
resolve_recorder_for_doctor() {
  local configured
  configured="$(config_field recorder || true)"
  if [[ -n "$configured" && -x "$configured" ]]; then
    printf '%s' "$configured"
    return 0
  fi
  if [[ -x "$RECORDER_BIN" ]]; then
    printf '%s' "$RECORDER_BIN"
    return 0
  fi
  return 1
}

check_recorder() {
  local resolved
  resolved="$(resolve_recorder_for_doctor || true)"
  if [[ -z "$resolved" ]]; then
    doctor_fail "rec is built" "re-run ./install-client.sh (it compiles client/rec.swift)"
    return 1
  fi
  # Deliberately does NOT run it: rec opens the microphone, and a run from
  # this shell would test the terminal's TCC grant rather than Hammerspoon's
  # — the same trap check_mic_permission() below exists to avoid.
  doctor_pass "rec is built; init.lua would use: ${resolved}"
  return 0
}

# Reads the outcome client/init.lua's own startup microphone probe wrote to
# ~/.hammerspoon/.hark-mic-status. This is the ONLY reliable way to learn
# whether HAMMERSPOON can reach the microphone: TCC grants are attributed to
# whichever app is responsible for the process that opened the device, and
# rec runs as Hammerspoon's child — so a probe run from THIS shell script
# would test the terminal's own microphone grant, a different permission
# that would produce a confidently wrong PASS. Never run rec from here to
# "test" this; read the file init.lua already wrote.
#
# That is still true now that rec asks TCC directly instead of inferring the
# answer from a frame count: authorizationStatus resolves against the
# responsible process too. Run from a terminal it reports on the terminal.
check_mic_permission() {
  local status_file="$CONFIG_DIR/.hark-mic-status"
  if [[ ! -f "$status_file" ]]; then
    doctor_fail "Hammerspoon can reach the microphone" \
      "Hammerspoon hasn't probed the mic yet — is it running? (open -a Hammerspoon)"
    return 1
  fi

  local status
  status="$(head -n 1 "$status_file" 2>/dev/null || true)"
  case "$status" in
    ok)
      doctor_pass "Hammerspoon can reach the microphone"
      return 0
      ;;
    denied)
      doctor_fail "Hammerspoon can reach the microphone" \
        "System Settings -> Privacy & Security -> Microphone -> turn ON Hammerspoon (it will be listed now — it has finally asked)"
      return 1
      ;;
    error)
      # The probe failed for a reason that is not permission — a muted device,
      # a dead input, rec missing. Sending the user to the Microphone toggle
      # would be a wrong answer, so report what actually happened instead.
      local detail
      detail="$(sed -n '3p' "$status_file" 2>/dev/null || true)"
      doctor_fail "Hammerspoon can reach the microphone" \
        "the probe failed, but not on permission: ${detail:-see $status_file}"
      return 1
      ;;
    *)
      doctor_fail "Hammerspoon can reach the microphone (unrecognized status in ${status_file}: '${status:-empty}')" \
        "reload Hammerspoon's config (menu bar icon -> Reload Config) to re-run the probe"
      return 1
      ;;
  esac
}

check_server_url() {
  local server
  if ! server="$(config_field server)"; then
    doctor_fail "server URL is well-formed" "no server URL in ${CONFIG_FILE} — run ./install-client.sh first"
    return 1
  fi

  # An SSH-style "user@host" leaking into the HTTP URL. curl tolerates it (so
  # a reachability check alone passes), but it is basic-auth userinfo, not an
  # SSH target, and Hammerspoon's hs.http (NSURL) is stricter than curl. This
  # is exactly how a config can look healthy while the client silently fails.
  if [[ "$server" =~ ^[a-z]+://[^/@]+@ ]]; then
    doctor_fail "server URL is well-formed (${server})" \
      "the URL contains SSH-style 'user@' userinfo. Re-run ./install-client.sh to rewrite it, or edit ${CONFIG_FILE} and delete the 'user@' from the server line."
    return 1
  fi

  doctor_pass "server URL is well-formed (${server})"
  return 0
}

check_health() {
  local server url
  if ! server="$(config_field server)"; then
    doctor_fail "server /health reachable" "no server URL in ${CONFIG_FILE} — run ./install-client.sh first"
    return 1
  fi
  url="${server%/dictate}/health"

  if curl -sf --max-time 5 "$url" >/dev/null 2>&1; then
    doctor_pass "server /health reachable (${url})"
    return 0
  fi
  doctor_fail "server /health reachable (${url})" "check the tailnet (tailscale status) and that hark is running on the server (ssh <server> launchctl list | grep hark)"
  return 1
}

# POSTs a tiny generated-on-the-fly silent WAV to /dictate and checks the key
# authenticates. A 200 or 400 both prove the key is good (the server checks
# X-Hark-Key before it looks at the audio at all, so either response means
# auth passed); a 401 proves it isn't.
check_key_auth() {
  local server key
  if ! server="$(config_field server)" || ! key="$(config_field key)"; then
    doctor_fail "key authenticates against /dictate" "hark-config.lua is missing server or key — run ./install-client.sh"
    return 1
  fi

  local tmp_dir tmp_wav
  tmp_dir="$(mktemp -d)"
  tmp_wav="$tmp_dir/probe.wav"

  # Half a second of silence, rather than recording anything: this check is
  # about whether the KEY is accepted, and opening the microphone here would
  # both prompt for a permission this script does not need and test the
  # terminal's TCC grant instead of Hammerspoon's. The server answers
  # 200-with-empty-transcript for silence, which is a pass — only a 401 fails.
  #
  # Written with printf and dd rather than a python3 one-liner. That one-liner
  # quietly made Python a requirement on the CLIENT Mac, which otherwise needs
  # only Homebrew, Hammerspoon and swiftc — and when it was missing, the check
  # failed in a way that read like a hark problem rather than a missing
  # interpreter.
  #
  # A 16 kHz mono 16-bit WAV of silence is a fixed 44-byte header followed by
  # zeros. Header fields below are little-endian: RIFF chunk size 16036
  # (36 + data), fmt chunk 16, PCM format 1, 1 channel, 16000 Hz, byte rate
  # 32000, block align 2, 16 bits per sample, data size 16000.
  if ! {
    printf 'RIFF\244\076\000\000WAVEfmt \020\000\000\000\001\000\001\000\200\076\000\000\000\175\000\000\002\000\020\000data\200\076\000\000' &&
      dd if=/dev/zero bs=16000 count=1 2>/dev/null
  } >"$tmp_wav"; then
    doctor_fail "key authenticates against /dictate" "could not write the test WAV to ${tmp_dir}"
    rm -rf "$tmp_dir"
    return 1
  fi

  local status
  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -X POST "$server" \
    -H "X-Hark-Key: ${key}" \
    -H "Content-Type: audio/wav" \
    --data-binary "@${tmp_wav}" 2>/dev/null || true)"
  rm -rf "$tmp_dir"

  case "$status" in
    200|400)
      doctor_pass "key authenticates against /dictate (HTTP ${status})"
      return 0
      ;;
    401)
      doctor_fail "key authenticates against /dictate (HTTP 401)" "the key in ${CONFIG_FILE} doesn't match the server's ~/.config/hark/key — re-run ./install-client.sh to refetch it"
      return 1
      ;;
    *)
      doctor_fail "key authenticates against /dictate (got: ${status:-no response})" "could not get a clean response from ${server} — check the tailnet and that hark is running"
      return 1
      ;;
  esac
}

run_diagnostics() {
  DOCTOR_FAILURES=0
  echo
  check_hammerspoon_installed || true
  check_hammerspoon_running || true
  check_init_symlink || true
  check_config_file || true
  check_recorder || true
  check_mic_permission || true
  check_server_url || true

  check_health || true
  check_key_auth || true
  echo
  if [[ "$DOCTOR_FAILURES" -eq 0 ]]; then
    log "All checks passed."
    return 0
  fi
  err "${DOCTOR_FAILURES} check(s) failed — see the FAIL lines above, each names its exact fix."
  return 1
}

# ==============================================================================
# Arg parsing
# ==============================================================================

DOCTOR_MODE=false
POSITIONAL_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --doctor)
      DOCTOR_MODE=true
      ;;
    -h|--help)
      echo "Usage: $0 [--doctor] [server-ssh-host]"
      echo "  (no args)         run the full interactive install"
      echo "  server-ssh-host   skip the 'server SSH host' prompt"
      echo "  --doctor          read-only: run the diagnostic checks and exit"
      exit 0
      ;;
    *)
      POSITIONAL_ARGS+=("$arg")
      ;;
  esac
done

# --- 0. sanity ---------------------------------------------------------------

if [[ "$(uname -s)" != "Darwin" ]]; then
  err "this installs macOS-only tools (Hammerspoon, avfoundation). Run it on the client Mac."
  exit 1
fi

if $DOCTOR_MODE; then
  log "hark --doctor: read-only checks, nothing will be changed."
  if run_diagnostics; then
    exit 0
  else
    exit 1
  fi
fi

if ! command -v brew >/dev/null 2>&1; then
  err "Homebrew is not installed. Install it first: https://brew.sh"
  exit 1
fi

# --- 1. Homebrew installs -----------------------------------------------------

log "Checking Hammerspoon..."
if brew list --cask hammerspoon >/dev/null 2>&1; then
  log "hammerspoon already installed."
else
  log "Installing hammerspoon..."
  brew install --cask hammerspoon
fi

# Recording is NOT done with ffmpeg. Its avfoundation input device accepts
# only packed sample layouts, and a 24-bit USB interface (a Focusrite
# Scarlett 2i2, for one) offers nothing but 24-bit UNPACKED — so ffmpeg dies
# with "audio format is not supported" whenever CoreAudio hands it the
# device's physical format rather than the converted Float32 virtual one.
# Which of the two you get varies per open, so it failed roughly half the
# time. client/rec.swift uses AVAudioEngine, whose input is Float32 by
# contract and never sees the physical format. See its header comment.
log "Building the recorder (client/rec.swift)..."
if ! command -v swiftc >/dev/null 2>&1; then
  err "swiftc not found. Install the Xcode command line tools: xcode-select --install"
  exit 1
fi

mkdir -p "$CONFIG_DIR"
if ! swiftc -O -o "$RECORDER_BIN" "$CLIENT_DIR/rec.swift"; then
  err "could not build $CLIENT_DIR/rec.swift"
  exit 1
fi
log "recorder: $RECORDER_BIN"

# --- 2. Shared secret ---------------------------------------------------------
#
# Two cases, and the local one is the default because it is the one that
# needs no explanation: if hark's server runs on THIS Mac, the key is simply
# sitting in ~/.config/hark/key and there is no network involved at all.
#
# Only when it isn't there do we ask for an SSH host — that means the server
# is another machine. The host is deliberately NOT guessed: an alias that
# works for `ssh <host>` (e.g. via ~/.ssh/config) is not necessarily a
# hostname curl can reach, so it is asked for separately from the HTTP URL in
# step 4 below.

LOCAL_KEY_FILE="$HOME/.config/hark/key"
SERVER_HOST="${POSITIONAL_ARGS[0]:-${HARK_SERVER_HOST:-}}"

if [[ -z "$SERVER_HOST" && -s "$LOCAL_KEY_FILE" ]]; then
  log "Found a local shared secret (${LOCAL_KEY_FILE}) — single-machine setup, no SSH needed."
  HARK_KEY="$(tr -d '\n' < "$LOCAL_KEY_FILE")"
else
  if [[ -z "$SERVER_HOST" ]]; then
    echo
    echo "No local key at ${LOCAL_KEY_FILE}, so hark's server is presumably"
    echo "another machine."
    echo
    echo "If it should be THIS Mac, quit (Ctrl-C) and run ./install-server.sh first."
    echo
    echo "Otherwise give the server's SSH host — exactly what you'd type for"
    # shellcheck disable=SC2088  # literal text for the user to read, not a path to expand
    echo "'ssh <host>' today (a ~/.ssh/config alias, a Tailscale MagicDNS name,"
    echo "or a private IP). Not guessed automatically."
    read -rp "server SSH host: " SERVER_HOST
  fi
  if [[ -z "$SERVER_HOST" ]]; then
    err "no server SSH host given, aborting."
    exit 1
  fi

  log "Fetching the shared secret from ${SERVER_HOST}:~/.config/hark/key over SSH..."
  SSH_ERR_FILE="$(mktemp)"
  trap 'rm -f "$SSH_ERR_FILE"' EXIT

  if ! HARK_KEY="$(ssh -o ConnectTimeout=10 "$SERVER_HOST" cat ~/.config/hark/key 2>"$SSH_ERR_FILE")"; then
    err "could not fetch the key from '${SERVER_HOST}'. Likely causes:"
    err "  - you're not on the same network/tailnet right now"
    err "  - '${SERVER_HOST}' isn't the right SSH host/alias for the server"
    err "  - SSH key auth to that host isn't set up (if it hung, that's probably it)"
    err "  - ~/.config/hark/key doesn't exist on the server — run"
    err "    ./install-server.sh there first"
    err "ssh said:"
    sed 's/^/    /' "$SSH_ERR_FILE" >&2 || true
    exit 1
  fi

  if [[ -z "$HARK_KEY" ]]; then
    err "fetched an EMPTY key from ${SERVER_HOST}. Check ~/.config/hark/key on the server isn't a zero-byte file."
    exit 1
  fi
fi
if [[ "$HARK_KEY" == *'"'* || "$HARK_KEY" == *$'\n'* ]]; then
  err "the fetched key contains a quote or newline, which would break the generated Lua config. This is unexpected — check ~/.config/hark/key on the server by hand."
  exit 1
fi
log "Got the shared secret (${#HARK_KEY} characters)."

# --- 3. Microphone selection --------------------------------------------------
#
# There is nothing to ask. rec records the SYSTEM DEFAULT input, so the mic is
# chosen in System Settings -> Sound -> Input like every other app on the
# machine. Earlier versions asked for an avfoundation device INDEX, which was
# both an extra thing to get wrong and genuinely unstable: those indices are
# positional, so a virtual device appearing or disappearing (Loom installs
# one) silently renumbers every device after it.

log "Microphone: whatever is selected in System Settings -> Sound -> Input."

# --- 4. server HTTP URL + reachability ----------------------------------------

if [[ -z "$SERVER_HOST" ]]; then
  # Single machine: the server is right here, so there is nothing to ask and
  # nothing to resolve. Loopback is not a guess, it is the only correct answer.
  DEFAULT_URL="http://127.0.0.1:${HARK_PORT}/dictate"
  HARK_URL="$DEFAULT_URL"
  log "Server URL: ${HARK_URL} (this Mac)"
else
  # SERVER_HOST is an SSH target, so it may carry a "user@" prefix and/or a
  # ":port" suffix. Neither belongs in an HTTP URL: "user@" is basic-auth
  # userinfo, which hark ignores, and an SSH port is not the HTTP port.
  # curl tolerates the userinfo form, so this drifted through --doctor as a
  # PASS while writing http://user@some-host:8911/dictate into the config.
  # Hammerspoon's hs.http (NSURL) is stricter than curl, so strip both.
  HTTP_HOST="${SERVER_HOST##*@}"   # drop "user@"
  HTTP_HOST="${HTTP_HOST%%:*}"     # drop any ":port"

  DEFAULT_URL="http://${HTTP_HOST}:${HARK_PORT}/dictate"
  echo
  echo "server /dictate URL. This must be directly reachable by curl/HTTP — an"
  echo "SSH config alias may not be (SSH config aliases aren't read by curl)."
  echo "If '${HTTP_HOST}' isn't itself a resolvable hostname, use the server's"
  echo "private IP with port ${HARK_PORT}."
  read -rp "server /dictate URL [${DEFAULT_URL}]: " HARK_URL
  HARK_URL="${HARK_URL:-$DEFAULT_URL}"
fi

# Guard the hand-typed case too: a pasted "http://user@host:8911/dictate" is
# just as wrong as a derived one.
if [[ "$HARK_URL" =~ ^([a-z]+://)([^/@]+@)(.*)$ ]]; then
  HARK_URL="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
  warn "Stripped the 'user@' from the URL — that's SSH syntax, not HTTP."
  warn "Using: ${HARK_URL}"
fi

HEALTH_URL="${HARK_URL%/dictate}/health"
log "Checking ${HEALTH_URL} ..."
if curl -sf --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
  log "hark is reachable."
else
  warn "could not reach ${HEALTH_URL}."
  if [[ -z "$SERVER_HOST" ]]; then
    warn "  - the server doesn't appear to be running on this Mac: ./install-server.sh"
    warn "  - check its state: launchctl list | grep hark, and /tmp/hark.err"
  else
    warn "  - check the network/tailnet path to ${SERVER_HOST}"
    warn "  - check hark is running there: ssh ${SERVER_HOST} launchctl list | grep hark"
  fi
  warn "  - the client will still be configured below; fix reachability before using it."
fi

# --- 5. Write the client config ------------------------------------------------

mkdir -p "$CONFIG_DIR"
umask 077
cat > "$CONFIG_FILE" <<LUACONFIG
-- Generated by install-client.sh on $(date '+%Y-%m-%d %H:%M:%S %Z').
-- Re-run ./install-client.sh any time to regenerate (e.g. after the server rotates the
-- key, or to change the server). Contains a real secret — never commit this
-- file, never share it.
--
-- No mic setting: rec records the system default input, chosen in
-- System Settings -> Sound -> Input.
return {
  server = "${HARK_URL}",
  key = "${HARK_KEY}",
  recorder = "${RECORDER_BIN}",
}
LUACONFIG
chmod 600 "$CONFIG_FILE"
log "Wrote ${CONFIG_FILE} (chmod 600)."

# --- 6. Install init.lua -------------------------------------------------------
#
# A pre-existing REAL file here (not a symlink) means Hammerspoon would load
# THAT file instead of this repo's client/init.lua and hark would never
# fire — silently, with no error anywhere. That is exactly the failure mode
# this whole fix is about, so this is a hard stop, not a warning to scroll past.

if [[ -e "$CONFIG_DIR/init.lua" && ! -L "$CONFIG_DIR/init.lua" ]]; then
  err "${CONFIG_DIR}/init.lua already exists as a REAL file (not a symlink) — refusing to overwrite it."
  err "Hammerspoon would load THAT file instead of this repo's client/init.lua, and the hotkey would never be bound."
  err "Fix it, then re-run this script:"
  err "  mv ${CONFIG_DIR}/init.lua ${CONFIG_DIR}/init.lua.bak"
  err "(merge anything you need from init.lua.bak into ${CLIENT_DIR}/init.lua by hand afterward, if you had custom config there)"
  exit 1
fi
ln -sf "${CLIENT_DIR}/init.lua" "$CONFIG_DIR/init.lua"
log "Linked ${CONFIG_DIR}/init.lua -> ${CLIENT_DIR}/init.lua"

# --- 7. Actually start Hammerspoon with the new config -------------------------
#
# THE BUG THIS SCRIPT USED TO HAVE: `brew install --cask hammerspoon` installs
# the app bundle but never runs it. Every previous version of this script just
# told the user to "open Hammerspoon (menu bar icon) -> Reload Config" — but on
# a fresh install there IS no menu bar icon, because the app has never been
# opened. init.lua never loads, the hotkey never binds, and holding the key
# does literally nothing: no alert, no beep, no error, no HTTP request. That
# exactly matches the symptom this fix exists to close.
#
# Hammerspoon does not auto-reload its config, and the `hs` CLI (`hs -c`,
# which could trigger a reload remotely) is not installed unless the user has
# already run hs.ipc.cliInstall() — so if Hammerspoon is already running, the
# only reliable way to make it pick up a new config is to quit and relaunch it.

log "Starting Hammerspoon with the new config..."
if pgrep -x Hammerspoon >/dev/null 2>&1; then
  log "Hammerspoon is already running — quitting it so it reloads the new config (it does not auto-reload)."
  osascript -e 'quit app "Hammerspoon"' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    if ! pgrep -x Hammerspoon >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done
  if pgrep -x Hammerspoon >/dev/null 2>&1; then
    warn "Hammerspoon didn't quit within 10s — forcing it closed."
    pkill -x Hammerspoon >/dev/null 2>&1 || true
    sleep 1
  fi
fi

if ! open -a Hammerspoon; then
  err "could not launch Hammerspoon via 'open -a Hammerspoon'. Is it installed at ${HAMMERSPOON_APP}?"
  exit 1
fi

HAMMERSPOON_STARTED=false
for _ in $(seq 1 20); do
  if pgrep -x Hammerspoon >/dev/null 2>&1; then
    HAMMERSPOON_STARTED=true
    break
  fi
  sleep 0.5
done
if ! $HAMMERSPOON_STARTED; then
  err "Hammerspoon did not start within 10s of 'open -a Hammerspoon'."
  err "Try opening it by hand from /Applications, then re-run: ./install-client.sh --doctor"
  exit 1
fi
log "Hammerspoon is running with the new config loaded."

# --- 8. Accessibility permission ------------------------------------------------
#
# Cannot be granted from a script — macOS requires a human click in System
# Settings. What CAN be scripted: detecting whether it's already granted
# (best-effort — see tcc_allowed below), opening the exact pane instead of
# making the user hunt for it, and blocking here instead of printing advice
# into a wall of text at the very end that's easy to miss.
#
# This works as a pre-grantable, block-and-confirm step because the
# Accessibility pane has a "+" button and lists every installed app whether
# or not it has ever run — Hammerspoon requesting it is not a precondition
# for it appearing in the list. Microphone is fundamentally different (see
# step 8b below): it has no "+" button and only lists apps that have
# ALREADY asked, so the same blocking pattern is impossible to satisfy
# there and must not be used.

# Best-effort read of the per-user TCC database. This can fail to see
# anything useful if the terminal running this script itself lacks Full Disk
# Access (macOS locks TCC.db down) — that failure mode is handled safely:
# `tcc_allowed` returns false, and the caller treats "unconfirmed" the same
# as "not granted" and blocks. It never trusts a read failure as a pass.
tcc_allowed() {
  local service="$1"
  if ! command -v sqlite3 >/dev/null 2>&1; then
    return 1
  fi
  local db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
  local value
  value="$(sqlite3 -readonly "$db" \
    "SELECT auth_value FROM access WHERE service='${service}' AND client='${HAMMERSPOON_BUNDLE_ID}' ORDER BY auth_value DESC LIMIT 1;" \
    2>/dev/null || true)"
  [[ "$value" == "2" ]]
}

require_permission() {
  local name="$1" service="$2" pane_url="$3"
  log "Checking ${name} permission for Hammerspoon..."
  if tcc_allowed "$service"; then
    log "${name}: already granted."
    return 0
  fi
  warn "${name} is not confirmed granted to Hammerspoon."
  warn "Opening System Settings -> Privacy & Security -> ${name}..."
  open "$pane_url"
  echo
  read -rp "Toggle Hammerspoon ON for ${name}, then press Enter to continue: " _
  if tcc_allowed "$service"; then
    log "${name}: confirmed granted."
  else
    warn "${name}: still not confirmed granted."
    warn "  If you definitely toggled it on, this may just be a detection limitation (this check needs Full"
    warn "  Disk Access for your terminal to read TCC.db reliably) rather than a real problem — the final"
    warn "  checks below will tell you for sure whether things actually work."
  fi
}

require_permission "Accessibility" "kTCCServiceAccessibility" \
  "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

# --- 8b. Microphone permission ---------------------------------------------------
#
# THE BUG THIS REPLACES: this step used to open the Microphone pane and
# block on "Toggle Hammerspoon ON for Microphone, then press Enter" — which
# is impossible to satisfy. Unlike Accessibility, the Microphone pane has no
# "+" button; it only lists apps that have ALREADY REQUESTED access. Before
# Hammerspoon's config has ever tried to open the mic, it cannot appear in
# that list, so there is nothing there to toggle. A user following the old
# instructions correctly has no choice but to Ctrl-C out.
#
# The fix lives in client/init.lua: it now probes the microphone itself at
# config load (which already happened when Hammerspoon (re)started in step
# 7, above) — that's what actually raises the consent dialog, attributed to
# Hammerspoon, because rec runs as its child process. All this step can
# do is wait for init.lua to report the outcome, and it deliberately does
# NOT run its own rec probe to check: a shell-side probe would test THIS
# TERMINAL's microphone grant, a different permission that would produce a
# confidently wrong answer either way. See check_mic_permission() above for
# why reading MIC_STATUS_FILE is the only trustworthy option.

MIC_STATUS_FILE="$CONFIG_DIR/.hark-mic-status"
MIC_STATUS_TIMEOUT_S=30

log "Waiting for Hammerspoon's microphone probe (up to ${MIC_STATUS_TIMEOUT_S}s)..."
echo "A Microphone permission dialog should appear on its own in a moment —"
echo "click Allow. This is triggered by init.lua actually trying to open the"
echo "mic; it's also the only way to make Hammerspoon show up in System"
echo "Settings -> Privacy & Security -> Microphone in the first place."
echo

MIC_STATUS=""
for _ in $(seq 1 "$MIC_STATUS_TIMEOUT_S"); do
  if [[ -f "$MIC_STATUS_FILE" ]]; then
    MIC_STATUS="$(head -n 1 "$MIC_STATUS_FILE" 2>/dev/null || true)"
    if [[ -n "$MIC_STATUS" ]]; then
      break
    fi
  fi
  sleep 1
done

case "$MIC_STATUS" in
  ok)
    log "Microphone: confirmed working — Hammerspoon's probe captured real audio."
    ;;
  denied)
    warn "Microphone: Hammerspoon's probe got no audio (permission denied, or the dialog was dismissed/missed)."
    warn "Fix: System Settings -> Privacy & Security -> Microphone -> turn ON Hammerspoon."
    warn "  (Hammerspoon WILL be listed there now — it has finally asked.)"
    warn "Then re-run: ./install-client.sh --doctor"
    ;;
  *)
    warn "Microphone: no result from Hammerspoon within ${MIC_STATUS_TIMEOUT_S}s (expected at ${MIC_STATUS_FILE})."
    warn "  Open the Hammerspoon console (menu bar icon -> Console) and check for errors."
    warn "  Then run: ./install-client.sh --doctor"
    ;;
esac

# --- 9. Final diagnostics -------------------------------------------------------
#
# Same checks `--doctor` runs. This is the whole point of the fix: the installer
# must never again print "done" while the hotkey is actually dead.

echo
log "Running final checks (same as ./install-client.sh --doctor)..."
if run_diagnostics; then
  cat <<'EOF'

==============================================================================
SETUP COMPLETE.

HOTKEY: hold Ctrl + Alt + Space — ALL THREE KEYS TOGETHER, not the spacebar
alone. Release when you're done speaking.

Test it for real: mosh into the server, put your cursor at a shell prompt,
hold Ctrl+Alt+Space, say a short sentence, release. Expected: the sentence
appears at the prompt within a couple of seconds — NOT executed.

If anything ever stops working, run this first:  ./install-client.sh --doctor
==============================================================================
EOF
else
  echo
  err "Setup wrote all the files, but the checks above found real problems —"
  err "the hotkey will NOT work yet. Fix the FAILs above (each names its exact"
  err "fix), then re-run:  ./install-client.sh --doctor"
  exit 1
fi
