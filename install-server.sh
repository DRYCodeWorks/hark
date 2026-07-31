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
#   3. installs the hark package into ~/.local/share/hark/venv, which is what
#      launchd actually runs — the clone is for editing, not for serving
#   4. generates the shared secret at ~/.config/hark/key (mode 600) so
#      install-client.sh has something to read
#   5. renders both launchd plists from ~/.config/hark/config.toml
#   6. boots the services out and back in
#   7. waits for /health and refuses to claim success if it never answers
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

# Where the running service lives, kept in step with hark.plists.VENV_DIR —
# tests/test_launchd_config_sync.py asserts the plists point here. The clone is
# a place to edit code; a daemon that runs out of it breaks when the checkout
# moves and silently changes behaviour on `git pull`.
INSTALL_DIR="$HOME/.local/share/hark"
VENV_DIR="$INSTALL_DIR/venv"
VENV_PYTHON="$VENV_DIR/bin/python"

MODEL_DIR="$HOME/.local/share/whisper-cpp"
MODEL_NAME="ggml-large-v3-turbo.bin"

# Changing the model is these three lines, together. The revision is pinned
# rather than tracking `main` because `resolve/main` is a mutable ref: what it
# serves today and what it served last month are not guaranteed to be the same
# bytes, and nothing downstream would notice. This is the only place hark
# fetches something it then executes against, so it is the one trust boundary
# that was implicit — every other one in this project is explicit.
#
# MODEL_SHA256 is the file's LFS oid as published by the Hugging Face API,
# confirmed against a downloaded copy.
MODEL_REVISION="5359861c739e955e79d9a303bcbc70fb988958b1"
MODEL_SHA256="1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/${MODEL_REVISION}/${MODEL_NAME}"

# Kept as a cheap pre-check before the expensive one. A truncated download is
# worse than a missing one: whisper-server starts, fails to load the model, and
# the failure surfaces as an unhelpful 503 from hark.
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
#
# Asked of the INSTALLED package, not the clone: the installed one is what
# launchd is running, and if the two have drifted then the clone's answer is
# the wrong one to probe with.
hark_url() {
  "$VENV_PYTHON" -c \
    'from hark import config; print(f"http://{config.HARK_HOST}:{config.HARK_PORT}")'
}

# ==============================================================================
# Checks
# ==============================================================================

# The plists name an absolute path inside VENV_DIR. If that venv is missing or
# broken, launchd's only account of it is a restart loop and a spawn error in
# /tmp/hark.err — so check it here, first, where the message can say what to do.
check_server_installed() {
  if [[ ! -x "$VENV_DIR/bin/uvicorn" ]]; then
    doctor_fail "the server is installed at ${VENV_DIR}" \
      "re-run ./install-server.sh (it installs the package there; launchd runs that copy, not this clone)"
    return 1
  fi
  if ! "$VENV_PYTHON" -c 'import hark' >/dev/null 2>&1; then
    doctor_fail "the server is installed at ${VENV_DIR}" \
      "the venv exists but cannot import hark — re-run ./install-server.sh"
    return 1
  fi
  doctor_pass "the server is installed at ${VENV_DIR}"
  return 0
}

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

# Wrapped in a function so tests can substitute a fixture listing without a
# real launchctl. See tests/test_install_server_doctor.py.
service_listing() { launchctl list; }

check_services_loaded() {
  local ok=0 label listing
  # Captured once rather than piped per-label on purpose: `launchctl list |
  # grep -q` makes grep exit at the first match, launchctl takes SIGPIPE, and
  # `set -o pipefail` reports the whole pipeline as failed — so every service
  # reads as "not loaded" no matter what is actually running.
  listing="$(service_listing)"
  for label in "${LABELS[@]}"; do
    # Match the LABEL FIELD exactly. `com.drycodeworks.hark` is a prefix of
    # `com.drycodeworks.hark-whisper`, so a substring grep reported the hark
    # service as loaded whenever only the ASR service was — a confident PASS
    # on precisely the run where the user needed to be told which of the two
    # is down. awk compares whole fields, so it also needs no regex escaping
    # for the dots in the label.
    if awk -v label="$label" '$NF == label { found = 1 } END { exit !found }' \
      <<<"$listing"; then
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

# Verifies an existing or freshly-downloaded model against MODEL_SHA256.
# Deliberately not silent about being skipped: a checksum you can't compute is
# not a checksum you passed, and saying so is the difference between a
# verified install and one that only looks like it.
verify_model() {
  local path="$1" actual
  if ! command -v shasum >/dev/null 2>&1; then
    warn "shasum not found — cannot verify the model checksum."
    return 0
  fi
  log "Verifying the model checksum (1.5 GB, a few seconds)..."
  actual="$(shasum -a 256 "$path" | awk '{print $1}')"
  if [[ "$actual" != "$MODEL_SHA256" ]]; then
    err "model checksum mismatch for ${path}"
    err "  expected ${MODEL_SHA256}"
    err "  got      ${actual}"
    err "Delete it and re-run, or update MODEL_REVISION/MODEL_SHA256 together"
    err "if you meant to change the model."
    return 1
  fi
  log "Checksum OK."
  return 0
}


run_doctor() {
  log "hark --doctor: read-only checks, nothing is modified."
  DOCTOR_FAILURES=0
  check_server_installed || true
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

# Sourcing this file defines the check_* functions and stops here, so the test
# suite can exercise them without running an install. Everything below this
# line only runs when the script is executed directly.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

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

if [[ -f "$MODEL_PATH" ]] && (( $(stat -f '%z' "$MODEL_PATH") >= MODEL_MIN_BYTES )) \
  && verify_model "$MODEL_PATH"; then
  log "Model already present and verified ($MODEL_PATH)."
else
  [[ -f "$MODEL_PATH" ]] && warn "existing model is missing, truncated or fails its checksum; re-downloading."
  log "Downloading ${MODEL_NAME} (~1.5 GB)..."
  # Download to a temp name and verify BEFORE moving into place, so neither an
  # interrupted transfer nor one that completed with the wrong bytes can be
  # mistaken for a usable model.
  curl -fL --progress-bar -o "${MODEL_PATH}.part" "$MODEL_URL"
  if ! verify_model "${MODEL_PATH}.part"; then
    rm -f "${MODEL_PATH}.part"
    err "Refusing to install an unverified model."
    exit 1
  fi
  mv "${MODEL_PATH}.part" "$MODEL_PATH"
  log "Model saved to ${MODEL_PATH}"
fi

# --- 3. Install the server -----------------------------------------------------

# launchd runs THIS copy, not the clone. Rebuilt from scratch on every run so a
# dependency dropped from pyproject.toml actually leaves, rather than lingering
# in the installed environment and hiding a missing declaration until someone
# installs fresh. It is a few seconds and a 26 MB directory.
log "Installing the server into ${VENV_DIR}..."
mkdir -p "$INSTALL_DIR"
rm -rf "$VENV_DIR"
uv venv --quiet "$VENV_DIR"
uv pip install --quiet --python "$VENV_PYTHON" "$REPO_DIR"

# Prove it before a plist points launchd at it: a venv that cannot import hark
# would otherwise surface as a restart loop with a traceback in /tmp/hark.err.
if ! "$VENV_PYTHON" -c 'import hark' >/dev/null 2>&1; then
  err "installed ${VENV_DIR} but it cannot import hark — aborting."
  exit 1
fi
log "Installed. The clone is now only needed to re-install."

# --- 4. Shared secret ---------------------------------------------------------

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
if [[ -s "$KEY_FILE" ]]; then
  log "Shared secret already exists (${KEY_FILE}) — leaving it alone."
else
  # Generated by config.hark_key() rather than here, so there is exactly one
  # implementation of how the key is created and persisted. Regenerating a
  # key that already exists would silently 401 every configured client.
  log "Generating the shared secret..."
  # Run from the INSTALLED package: the key the server will read must be
  # written by the same code that will read it.
  "$VENV_PYTHON" -c 'from hark import config; config.hark_key()'
  log "Wrote ${KEY_FILE}"
fi

# --- 5. Render the plists -----------------------------------------------------

log "Rendering launchd plists from config..."
mkdir -p "$LAUNCH_AGENTS"
# From the CLONE, not the installed venv: the templates live in launchd/ and
# are not shipped in the wheel. Rendering is an install-time task, and this
# script is part of the checkout that has them.
(cd "$REPO_DIR" && uv run --quiet python -m hark.plists >/dev/null)

# --- 6. Load the services -----------------------------------------------------

for label in "${LABELS[@]}"; do
  plist="$LAUNCH_AGENTS/${label}.plist"
  if [[ ! -f "$plist" ]]; then
    err "expected ${plist} to exist after rendering — aborting."
    exit 1
  fi
  # bootout first so a re-run picks up a changed plist. A service that isn't
  # loaded makes bootout exit non-zero, which is expected, not a failure.
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true

  # bootout returns before launchd has finished tearing the job down, and
  # bootstrapping into that window fails with "Input/output error: 5". Under
  # `set -e` that aborted the install with the service left UNLOADED — a
  # re-run, whose whole promise is that it is safe, taking dictation down.
  # Observed on a re-run, not theoretical. Wait for the label to actually
  # leave the listing, then still retry: the wait is a heuristic, the retry
  # is the guarantee.
  for _ in $(seq 1 50); do
    launchctl list | awk -v l="$label" '$NF == l { f = 1 } END { exit !f }' || break
    sleep 0.1
  done

  loaded=0
  for _ in $(seq 1 5); do
    if launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null; then
      loaded=1
      break
    fi
    sleep 1
  done
  if (( loaded == 0 )); then
    # Re-run without swallowing stderr, so the reason reaches the user.
    launchctl bootstrap "gui/$(id -u)" "$plist" || true
    err "could not bootstrap ${label} — it is NOT running."
    exit 1
  fi
  log "Loaded ${label}"
done

# --- 7. Verify ----------------------------------------------------------------

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
