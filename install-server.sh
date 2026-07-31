#!/usr/bin/env bash
#
# hark — server setup.
#
# Run this on the Mac that will do the transcribing. On a single-machine
# setup that is the same Mac you dictate from; on a two-machine setup it is
# the one that can afford to keep a model resident. It:
#
#   1. installs whisper-cpp and uv via Homebrew if missing
#   2. downloads a Whisper model (skipped if one is already there)
#   3. generates the shared secret at ~/.config/hark/key (mode 600) so
#      install-client.sh has something to read
#   4. renders both launchd plists from ~/.config/hark/config.toml
#   5. boots the services out and back in
#   6. waits for /health and refuses to claim success if it never answers
#
# `./install-server.sh --doctor` runs the checks alone, read-only, changing
# nothing.
#
# Safe to re-run: every step checks current state first. Re-running is also
# how you apply a config change — it re-renders the plists and reloads.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config/hark"
KEY_FILE="$CONFIG_DIR/key"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
LABELS=(com.drycodeworks.hark com.drycodeworks.hark-whisper)

MODEL_DIR="$HOME/.local/share/whisper-cpp"
MODEL_NAME="ggml-large-v3-turbo.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL_NAME}"
# A truncated download is worse than a missing one: whisper-server starts,
# fails to load the model, and the failure surfaces as an unhelpful 503 from
# hark. Anything this far below the real size is a partial file.
MODEL_MIN_BYTES=$((500 * 1024 * 1024))

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; }

DOCTOR_FAILURES=0
doctor_pass() { printf '  \033[1;32mPASS\033[0m  %s\n' "$1"; }
doctor_fail() {
  printf '  \033[1;31mFAIL\033[0m  %s\n' "$1"
  printf '        fix: %s\n' "$2"
  DOCTOR_FAILURES=$((DOCTOR_FAILURES + 1))
}

# Reads the effective bind address and port out of config rather than
# re-parsing the TOML here. config.py is the single source of truth for what
# the plists were rendered with, so asking it is the only way to be sure the
# health check probes the address the service actually bound.
hark_url() {
  (cd "$REPO_DIR" && uv run --quiet python -c \
    'from hark import config; print(f"http://{config.HARK_HOST}:{config.HARK_PORT}")')
}

# ==============================================================================
# Checks
# ==============================================================================

check_model() {
  local path="$MODEL_DIR/$MODEL_NAME" size
  if [[ ! -f "$path" ]]; then
    doctor_fail "Whisper model present" "re-run ./install-server.sh (it downloads one)"
    return 1
  fi
  size="$(stat -f '%z' "$path" 2>/dev/null || echo 0)"
  if (( size < MODEL_MIN_BYTES )); then
    doctor_fail "Whisper model looks complete (${size} bytes)" \
      "rm ${path} && ./install-server.sh   (the file is truncated)"
    return 1
  fi
  doctor_pass "Whisper model present (${path})"
  return 0
}

check_key() {
  if [[ ! -s "$KEY_FILE" ]]; then
    doctor_fail "${KEY_FILE} exists and is non-empty" "re-run ./install-server.sh"
    return 1
  fi
  local mode
  mode="$(stat -f '%Lp' "$KEY_FILE" 2>/dev/null || true)"
  if [[ "$mode" != "600" ]]; then
    doctor_fail "${KEY_FILE} is mode 600 (found: ${mode:-unreadable})" "chmod 600 ${KEY_FILE}"
    return 1
  fi
  doctor_pass "${KEY_FILE} exists, mode 600"
  return 0
}

check_services_loaded() {
  local ok=0 label listing
  # Captured once rather than piped per-label on purpose: `launchctl list |
  # grep -q` makes grep exit at the first match, launchctl takes SIGPIPE, and
  # `set -o pipefail` reports the whole pipeline as failed — so every service
  # reads as "not loaded" no matter what is actually running.
  listing="$(launchctl list)"
  for label in "${LABELS[@]}"; do
    if grep -q "$label" <<<"$listing"; then
      doctor_pass "${label} is loaded"
    else
      doctor_fail "${label} is loaded" "re-run ./install-server.sh"
      ok=1
    fi
  done
  return $ok
}

check_health() {
  local url status
  url="$(hark_url)/health"
  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || true)"
  if [[ "$status" == "200" ]]; then
    doctor_pass "${url} answers 200"
    return 0
  fi
  doctor_fail "${url} answers 200 (got: ${status:-no response})" \
    "check /tmp/hark.err and /tmp/hark-whisper.err"
  return 1
}

run_doctor() {
  log "hark --doctor: read-only checks, nothing is modified."
  DOCTOR_FAILURES=0
  check_model      || true
  check_key        || true
  check_services_loaded || true
  check_health     || true
  echo
  if (( DOCTOR_FAILURES > 0 )); then
    err "${DOCTOR_FAILURES} check(s) failed."
    return 1
  fi
  log "All checks passed."
  return 0
}

if [[ "${1:-}" == "--doctor" ]]; then
  run_doctor
  exit $?
fi

# ==============================================================================
# Install
# ==============================================================================

if [[ "$(uname -s)" != "Darwin" ]]; then
  err "hark is macOS-only (launchd, AVAudioEngine, Hammerspoon, TCC)."
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  err "Homebrew not found. Install it from https://brew.sh, then re-run."
  exit 1
fi

# --- 1. Dependencies ----------------------------------------------------------

for pkg in whisper-cpp uv; do
  if brew list --formula "$pkg" >/dev/null 2>&1; then
    log "${pkg} already installed."
  else
    log "Installing ${pkg}..."
    brew install "$pkg"
  fi
done

# --- 2. Model -----------------------------------------------------------------

mkdir -p "$MODEL_DIR"
MODEL_PATH="$MODEL_DIR/$MODEL_NAME"
if [[ -f "$MODEL_PATH" ]] && (( $(stat -f '%z' "$MODEL_PATH") >= MODEL_MIN_BYTES )); then
  log "Model already present ($MODEL_PATH)."
else
  [[ -f "$MODEL_PATH" ]] && warn "existing model looks truncated; re-downloading."
  log "Downloading ${MODEL_NAME} (~1.5 GB)..."
  # Download to a temp name and move into place only on success, so an
  # interrupted download can never be mistaken for a usable model.
  curl -fL --progress-bar -o "${MODEL_PATH}.part" "$MODEL_URL"
  mv "${MODEL_PATH}.part" "$MODEL_PATH"
  log "Model saved to ${MODEL_PATH}"
fi

# --- 3. Shared secret ---------------------------------------------------------

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
if [[ -s "$KEY_FILE" ]]; then
  log "Shared secret already exists (${KEY_FILE}) — leaving it alone."
else
  # Generated by config.hark_key() rather than here, so there is exactly one
  # implementation of how the key is created and persisted. Regenerating a
  # key that already exists would silently 401 every configured client.
  log "Generating the shared secret..."
  (cd "$REPO_DIR" && uv run --quiet python -c \
    'from hark import config; config.hark_key()')
  log "Wrote ${KEY_FILE}"
fi

# --- 4. Render the plists -----------------------------------------------------

log "Rendering launchd plists from config..."
mkdir -p "$LAUNCH_AGENTS"
(cd "$REPO_DIR" && uv run --quiet python -m hark.plists >/dev/null)

# --- 5. Load the services -----------------------------------------------------

for label in "${LABELS[@]}"; do
  plist="$LAUNCH_AGENTS/${label}.plist"
  if [[ ! -f "$plist" ]]; then
    err "expected ${plist} to exist after rendering — aborting."
    exit 1
  fi
  # bootout first so a re-run picks up a changed plist. A service that isn't
  # loaded makes bootout exit non-zero, which is expected, not a failure.
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  log "Loaded ${label}"
done

# --- 6. Verify ----------------------------------------------------------------

URL="$(hark_url)/health"
log "Waiting for ${URL}..."
for _ in $(seq 1 30); do
  if [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$URL" 2>/dev/null || true)" == "200" ]]; then
    break
  fi
  sleep 1
done

echo
if ! run_doctor; then
  echo
  err "Server setup did NOT complete cleanly. Work through the FAIL lines above."
  err "Logs: /tmp/hark.err (service) and /tmp/hark-whisper.err (ASR engine)."
  exit 1
fi

echo
log "Server setup complete."
echo
echo "Next: run ./install-client.sh on the Mac you want to dictate FROM."
echo "(On a single-machine setup, that is this Mac.)"
