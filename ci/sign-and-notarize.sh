#!/bin/bash
# sign-and-notarize.sh — build, Developer ID sign, notarize and staple Tacet.app
# on a machine with no GUI session and no pre-installed certificate.
#
#   ci/sign-and-notarize.sh
#
# Reads everything from the environment so the same script runs on a GitHub
# runner and on a developer machine:
#
#   DEVELOPER_ID_KEY    PEM private key for the Developer ID Application cert
#   DEVELOPER_ID_CERT   base64 of the DER .cer Apple issued from the CSR
#   NOTARY_KEY_P8       App Store Connect API key (.p8) for notarytool
#   NOTARY_KEY_ID       e.g. 7PK968C347   (rotates)
#   NOTARY_ISSUER_ID    e.g. 1fd19a95-…   (survives rotation)
#
# Writes swift/Packaging/Tacet.zip, stapled and verified, and prints its sha256
# to stdout as `sha256=<hex>` for the caller to pin a cask with.
set -euo pipefail

# A CI runner is a Background launchd session, exactly like SSH or tmux. There,
# codesign against the *login* keychain returns errSecInternalComponent, because
# Security.framework cannot get an authorization context without a GUI. It reads
# as a permissions problem and is not one — do not chase it with
# set-key-partition-list. A dedicated keychain placed in the user search list is
# the documented way through, and is what this script does.

for var in DEVELOPER_ID_KEY DEVELOPER_ID_CERT NOTARY_KEY_P8 NOTARY_KEY_ID NOTARY_ISSUER_ID; do
    if [[ -z "${!var:-}" ]]; then
        echo "error: $var is not set" >&2
        exit 1
    fi
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
KC="$WORK/tacet-signing.keychain-db"
PW="$(openssl rand -hex 24)"
ORIG=""

cleanup() {
    # Restore the search list before deleting, or a failure mid-run leaves the
    # runner (or a developer machine) pointed at a keychain that is about to
    # stop existing.
    # shellcheck disable=SC2086  # ORIG is a LIST of keychain paths; it must split.
    [[ -n "$ORIG" ]] && security list-keychains -d user -s $ORIG >/dev/null 2>&1 || true
    security delete-keychain "$KC" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

umask 077

printf '%s' "$DEVELOPER_ID_KEY" > "$WORK/devid.key"
printf '%s' "$DEVELOPER_ID_CERT" | base64 --decode > "$WORK/devid.cer"
printf '%s' "$NOTARY_KEY_P8" > "$WORK/notary.p8"

echo "==> Converting the issued certificate to PEM"
openssl x509 -in "$WORK/devid.cer" -inform DER -out "$WORK/leaf.pem"

# Fail loudly if the .cer is the G2 intermediate rather than the leaf. The
# portal hands you two downloads with near-identical names, and importing the
# intermediate leaves find-identity at 0 forever with no error that names the
# cause.
subject="$(openssl x509 -in "$WORK/leaf.pem" -noout -subject)"
case "$subject" in
    *"Developer ID Application"*) ;;
    *)
        echo "error: DEVELOPER_ID_CERT is not a Developer ID Application leaf." >&2
        echo "       subject: $subject" >&2
        echo "       This is the G2 intermediate download, not your certificate." >&2
        exit 1
        ;;
esac

# The G2 intermediate must be in the SAME keychain or the leaf cannot chain and
# find-identity reports zero valid identities. A runner's keychain may not carry
# it, so fall back to Apple's public copy rather than assuming.
echo "==> Resolving the G2 intermediate"
if ! security find-certificate -c "Developer ID Certification Authority" -p > "$WORK/g2.pem" 2>/dev/null \
   || ! [[ -s "$WORK/g2.pem" ]]; then
    echo "    not in the keychain; fetching Apple's public copy"
    curl -fsSL https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer -o "$WORK/g2.cer"
    openssl x509 -in "$WORK/g2.cer" -inform DER -out "$WORK/g2.pem"
fi

# -legacy is REQUIRED: OpenSSL 3 writes a PKCS#12 MAC that macOS `security`
# cannot read, and reports it as "MAC verification failed ... (wrong password?)".
# The password is fine; the format is not.
echo "==> Assembling PKCS#12"
openssl pkcs12 -export -legacy -inkey "$WORK/devid.key" \
    -in "$WORK/leaf.pem" -certfile "$WORK/g2.pem" \
    -name devid -out "$WORK/signing.p12" -passout pass:"$PW"

echo "==> Creating a dedicated keychain"
security create-keychain -p "$PW" "$KC"
security unlock-keychain -p "$PW" "$KC"
security import "$WORK/signing.p12" -k "$KC" -P "$PW" -A -T /usr/bin/codesign
security import "$WORK/g2.pem" -k "$KC" -A >/dev/null 2>&1 || true
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null

# REQUIRED: `codesign --keychain <kc>` alone is NOT enough — you get
# errSecInternalComponent even though find-identity lists the identity as valid.
ORIG=$(security list-keychains -d user | tr -d ' "')
# shellcheck disable=SC2086  # ORIG is a LIST of keychain paths; it must split.
security list-keychains -d user -s "$KC" $ORIG

IDENT=$(security find-identity -v -p codesigning "$KC" \
    | grep 'Developer ID Application' \
    | sed -n 's/^[[:space:]]*[0-9]*)[[:space:]]*\([0-9A-F]*\).*/\1/p' \
    | sort -u | head -1)
if [[ -z "$IDENT" ]]; then
    echo "error: no Developer ID Application identity after import." >&2
    echo "       Usually the G2 intermediate failed to chain." >&2
    exit 1
fi
echo "==> Signing identity: $IDENT"

# build-app.sh owns the signing flags, including --timestamp, which is required
# for notarization and is not codesign's default. Apple only reports its absence
# after the upload, so a missing timestamp costs a full round trip.
cd "$REPO_DIR/swift"
TACET_SIGN_IDENTITY="$IDENT" ./Packaging/build-app.sh

cd "$REPO_DIR/swift/Packaging"

echo "==> Notarizing"
rm -f Tacet.zip
ditto -c -k --keepParent Tacet.app Tacet.zip
# --key/--key-id/--issuer, never --keychain-profile: store-credentials cannot
# write from a non-interactive session and a runner has no profile anyway.
xcrun notarytool submit Tacet.zip \
    --key "$WORK/notary.p8" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" \
    --wait

echo "==> Stapling"
xcrun stapler staple Tacet.app
xcrun stapler validate Tacet.app

# spctl on the build machine cannot tell notarization from a local signature the
# way a machine that has never seen the artifact can, so this is the weak check.
# It still catches a bundle that was rebuilt after notarization, which is the
# common way a release goes out unstapled.
spctl -a -vv Tacet.app

echo "==> Re-zipping the STAPLED bundle"
rm -f Tacet.zip
ditto -c -k --keepParent Tacet.app Tacet.zip

# The bundle must reach its own main(). A quarantine wedge blocks in dyld and
# never gets there — see tacet#25. --help is the only invocation guaranteed to
# print and exit; a bare call now starts the agent and would block forever.
echo "==> Smoke-testing the signed bundle"
./Tacet.app/Contents/MacOS/tacet --help >/dev/null

SHA="$(shasum -a 256 Tacet.zip | cut -d' ' -f1)"
echo "sha256=$SHA"
