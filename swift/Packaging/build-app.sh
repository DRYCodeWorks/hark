#!/bin/bash
# build-app.sh — build the release binary and assemble a signed Hark.app bundle.
#
#   ./Packaging/build-app.sh
#
# Signing identity comes from $HARK_SIGN_IDENTITY if set (e.g. a Developer ID),
# otherwise ad-hoc ("-") is used. Default is ad-hoc — fine for local dev.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${PKG_DIR}/.." && pwd)"
APP="${PKG_DIR}/Hark.app"

SIGN_IDENTITY="${HARK_SIGN_IDENTITY:-}"

echo "==> Building release binary"
cd "${ROOT_DIR}"
swift build -c release

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp ".build/release/hark" "${APP}/Contents/MacOS/hark"
cp "${PKG_DIR}/Info.plist" "${APP}/Contents/Info.plist"
cp "${PKG_DIR}/entitlements.plist" "${APP}/Contents/Resources/"
chmod +x "${APP}/Contents/MacOS/hark"

echo "==> Signing"
if [[ -n "${SIGN_IDENTITY}" ]]; then
    echo "   using identity: ${SIGN_IDENTITY}"
    codesign --force --deep --sign "${SIGN_IDENTITY}" \
        --options runtime \
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
