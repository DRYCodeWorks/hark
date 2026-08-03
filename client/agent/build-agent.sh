#!/usr/bin/env bash
#
# Build client/agent/hark-agent.swift into hark.app.
#
#   ./client/agent/build-agent.sh [output-dir]
#
# Output defaults to build/ at the repo root. install-client.sh calls this and
# then copies the bundle into place; run it directly when iterating on the
# agent itself.
#
# The bundle is ad-hoc signed (`codesign -s -`). That is not decoration:
#
#   - An UNSIGNED bundle has no stable code identity at all, so TCC re-prompts
#     essentially at random and grants do not survive a rebuild.
#   - An AD-HOC signature gives it a cdhash identity. Grants survive until the
#     binary changes, which is the best available answer during development
#     and means one re-grant per rebuild rather than one per launch.
#   - A DEVELOPER ID signature makes grants survive rebuilds outright, because
#     the identity is then the certificate rather than the hash. That is what
#     a release build wants, and it is tracked separately - the certificate is
#     gated on Apple Developer enrollment paperwork, not on this script.
#
# When a Developer ID identity is available, pass it:
#
#   HARK_SIGN_IDENTITY="Developer ID Application: ... (TEAMID)" \
#     ./client/agent/build-agent.sh
#
# Notarization is a separate step against a release artifact; see DRY-723.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENT_DIR="$REPO_DIR/client/agent"
CLIENT_DIR="$REPO_DIR/client"
OUT_DIR="${1:-$REPO_DIR/build}"
APP="$OUT_DIR/hark.app"

# Ad-hoc unless the caller supplies a real identity.
SIGN_IDENTITY="${HARK_SIGN_IDENTITY:--}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; }

if ! command -v swiftc >/dev/null 2>&1; then
  err "swiftc not found. Install the Xcode command line tools: xcode-select --install"
  exit 1
fi

log "building into $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# The agent itself.
swiftc -O -o "$APP/Contents/MacOS/hark-agent" "$AGENT_DIR/hark-agent.swift"

# rec ships INSIDE the bundle. Two reasons: the app is self-contained, and a
# nested binary is covered by the bundle's own signature, so signing does not
# become a two-artifact problem later.
swiftc -O -o "$APP/Contents/MacOS/rec" "$CLIENT_DIR/rec.swift"

cp "$AGENT_DIR/Info.plist" "$APP/Contents/Info.plist"

# Marks the directory as a bundle for Launch Services. Without it the app can
# still be exec'd but `open` and login-item registration misbehave.
printf 'APPL????' > "$APP/Contents/PkgInfo"

log "signing with identity: $SIGN_IDENTITY"
# --options runtime enables the hardened runtime, which notarization requires
# and which is harmless ad-hoc. --force so a rebuild replaces the previous
# signature rather than failing on it. --deep is deliberately NOT used: it is
# deprecated and signs nested code with the wrong flags; the explicit rec sign
# below is the supported way to cover a nested binary.
codesign --force --options runtime --timestamp=none \
  --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/rec"
codesign --force --options runtime --timestamp=none \
  --sign "$SIGN_IDENTITY" "$APP"

log "verifying"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

log "built $APP"
