#!/usr/bin/env bash
#
# Creates a stable, self-signed code signing identity for local builds.
#
# Why this exists: an ad-hoc signature (`codesign -s -`) is keyed to a hash of
# the binary. TCC stores that hash as the app's code requirement, so every
# rebuild produces a "different" app and the screen recording grant silently
# stops matching it. The symptom is a permission that can never be made to
# stick: you tick the box, and the app still reports it has no access.
#
# Signing with a certificate instead moves the requirement onto the certificate,
# which does not change between builds, so a grant survives rebuilding.
#
# This is a local-only identity. It is not issued by Apple, it is not trusted for
# distribution, and it is not a substitute for a Developer ID.

set -euo pipefail

IDENTITY_NAME="RuiC-FoldScreen Local Signing"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
WORK_DIR="$(mktemp -d)"
# Throwaway password for the temporary bundle below. It is never stored, and
# the bundle is deleted before this script exits.
P12_PASS="$(openssl rand -hex 16)"
trap 'rm -rf "$WORK_DIR"' EXIT

say() { printf '\033[1;36m==>\033[0m %s\n' "$1"; }

# Already present? Nothing to do. This is the common path after the first run.
if security find-certificate -c "$IDENTITY_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  say "signing identity already present: $IDENTITY_NAME"
  exit 0
fi

say "creating signing identity: $IDENTITY_NAME"
say "  (this happens once, and only touches your login keychain)"

# A self-signed certificate carrying the code signing extended key usage, which
# is what makes it usable with codesign.
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK_DIR/key.pem" \
  -out "$WORK_DIR/cert.pem" \
  -days 3650 \
  -subj "/CN=${IDENTITY_NAME}/O=RuiC-FoldScreen/C=CN" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" \
  >/dev/null 2>&1

openssl pkcs12 -export \
  -out "$WORK_DIR/identity.p12" \
  -inkey "$WORK_DIR/key.pem" \
  -in "$WORK_DIR/cert.pem" \
  -name "$IDENTITY_NAME" \
  -passout "pass:${P12_PASS}" \
  >/dev/null 2>&1

# -A lets codesign use the key without an interactive prompt on every build.
security import "$WORK_DIR/identity.p12" \
  -k "$KEYCHAIN" \
  -P "$P12_PASS" \
  -T /usr/bin/codesign \
  -A \
  >/dev/null

# Trust the certificate for code signing so the signature validates locally.
# This is what allows the requirement to be checked against the certificate
# rather than falling back to a binary hash.
security add-trusted-cert -d -r trustRoot -p codeSign \
  -k "$KEYCHAIN" "$WORK_DIR/cert.pem" >/dev/null 2>&1 || \
  say "  note: could not set trust automatically; signing will still work"

if security find-certificate -c "$IDENTITY_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  say "identity ready: $IDENTITY_NAME"
else
  say "failed to create the signing identity" >&2
  exit 1
fi
