#!/bin/bash
# build-app.sh — build the release binary and assemble a signed Tacet.app bundle.
#
#   ./Packaging/build-app.sh
#
# Signing identity comes from $TACET_SIGN_IDENTITY if set. When it is unset the
# script resolves a Developer ID Application identity from the keychain, and
# refuses to build rather than quietly downgrading to an ad-hoc signature.
# Ad-hoc is opt-in: TACET_ALLOW_ADHOC=1.
#
# The refusal is the point. TCC grants key on the designated requirement, and an
# ad-hoc DR is a bare cdhash — so an ad-hoc rebuild silently invalidates
# Accessibility and Microphone, and an ad-hoc bundle is rejected by notarization
# only after the upload. Both failures land far from the install that caused
# them, which is what makes the default worth spending an error on.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${PKG_DIR}/.." && pwd)"
APP="${PKG_DIR}/Tacet.app"

# Print the one Developer ID Application identity in the keychain, or nothing.
#
# Deduplication is on the SHA-1, not the line: `security find-identity` lists an
# identity once per keychain that holds it, so the same certificate routinely
# appears two or four times. Counting lines reports "ambiguous" for a machine
# with exactly one usable certificate installed twice.
resolve_developer_id() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' \
        | sed -n 's/^[[:space:]]*[0-9]*)[[:space:]]*\([0-9A-F]*\).*/\1/p' \
        | sort -u
}

SIGN_IDENTITY="${TACET_SIGN_IDENTITY:-}"
ALLOW_ADHOC="${TACET_ALLOW_ADHOC:-}"

if [[ -z "${SIGN_IDENTITY}" ]]; then
    # A while-read loop rather than `mapfile`: the shebang is /bin/bash, which
    # on macOS is 3.2, where mapfile does not exist. Under `set -e` that is an
    # immediate 127 with a one-line error and no signing context at all.
    FOUND=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && FOUND+=("$line")
    done < <(resolve_developer_id)

    if [[ "${#FOUND[@]}" -eq 1 ]]; then
        SIGN_IDENTITY="${FOUND[0]}"
        echo "==> Resolved Developer ID from the keychain: ${SIGN_IDENTITY}"
    elif [[ "${#FOUND[@]}" -gt 1 && -z "${ALLOW_ADHOC}" ]]; then
        echo "ERROR: ${#FOUND[@]} Developer ID Application identities are in the keychain." >&2
        echo "       Pick one and re-run with it:" >&2
        printf '         TACET_SIGN_IDENTITY=%s ./Packaging/build-app.sh\n' "${FOUND[@]}" >&2
        exit 1
    elif [[ -z "${ALLOW_ADHOC}" ]]; then
        echo "ERROR: no Developer ID Application identity found in the keychain," >&2
        echo "       and TACET_SIGN_IDENTITY is unset." >&2
        echo >&2
        echo "       An ad-hoc signature would build and install without complaint," >&2
        echo "       then invalidate this machine's Accessibility and Microphone" >&2
        echo "       grants on the next rebuild, and be rejected by notarization" >&2
        echo "       only after upload. So this is an error, not a fallback." >&2
        echo >&2
        echo "       To sign properly:  TACET_SIGN_IDENTITY=\"Developer ID Application: ...\"" >&2
        echo "       For local dev:     TACET_ALLOW_ADHOC=1 ./Packaging/build-app.sh" >&2
        exit 1
    fi
fi

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
    # Only reachable with TACET_ALLOW_ADHOC=1 — the unset case exits above.
    echo "   WARNING: signing ad-hoc because TACET_ALLOW_ADHOC is set."
    echo "   WARNING: this bundle cannot be notarized, and installing it will"
    echo "   WARNING: invalidate this machine's Accessibility and Microphone grants."
    codesign --force --deep --sign - \
        --options runtime \
        --entitlements "${PKG_DIR}/entitlements.plist" \
        "${APP}"
fi

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "${APP}"
# --verify is satisfied by an ad-hoc signature, so it cannot answer "is this
# notarizable / will it keep its TCC grants". Report the type separately.
if codesign -dvvv "${APP}" 2>&1 | grep -q '^Signature=adhoc'; then
    echo "==> Signature type: AD-HOC (not notarizable; TCC grants will not survive a rebuild)"
else
    echo "==> Signature type: $(codesign -dvvv "${APP}" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
fi
echo "==> Entitlements embedded in binary:"
codesign -d --entitlements :- "${APP}" 2>/dev/null || true
echo "==> done. Bundle at: ${APP}"
