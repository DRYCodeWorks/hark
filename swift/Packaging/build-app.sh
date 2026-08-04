#!/bin/bash
# build-app.sh — build the release binary and assemble a signed Tacet.app bundle.
#
#   ./Packaging/build-app.sh
#
# Signing identity comes from $TACET_SIGN_IDENTITY if set (e.g. a Developer ID),
# otherwise ad-hoc ("-") is used. Default is ad-hoc — fine for local dev.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${PKG_DIR}/.." && pwd)"
APP="${PKG_DIR}/Tacet.app"

SIGN_IDENTITY="${TACET_SIGN_IDENTITY:-}"

echo "==> Building release binary"
cd "${ROOT_DIR}"
swift build -c release

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp ".build/release/tacet" "${APP}/Contents/MacOS/tacet"
cp "${PKG_DIR}/Info.plist" "${APP}/Contents/Info.plist"
cp "${PKG_DIR}/entitlements.plist" "${APP}/Contents/Resources/"
chmod +x "${APP}/Contents/MacOS/tacet"

echo "==> Signing"
if [[ -n "${SIGN_IDENTITY}" ]]; then
    echo "   using identity: ${SIGN_IDENTITY}"
    # --timestamp is REQUIRED for notarization and is not the default. Without
    # it Apple rejects the submission with "The signature does not include a
    # secure timestamp" — after the upload, so the failure costs a round trip.
    # It contacts Apple's timestamp server, so this step needs network.
    codesign --force --deep --sign "${SIGN_IDENTITY}" \
        --options runtime \
        --timestamp \
        --entitlements "${PKG_DIR}/entitlements.plist" \
        "${APP}"
else
    echo "   using ad-hoc signature (-)"
    codesign --force --deep --sign - \
        --options runtime \
        --entitlements "${PKG_DIR}/entitlements.plist" \
        "${APP}"
fi

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "${APP}"
echo "==> Entitlements embedded in binary:"
codesign -d --entitlements :- "${APP}" 2>/dev/null || true
echo "==> done. Bundle at: ${APP}"
