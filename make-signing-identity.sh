#!/bin/bash
# Creates a stable self-signed code-signing identity in your login keychain so
# that "Always Allow" on the keychain prompt persists across app rebuilds.
# Safe to run repeatedly — it no-ops if the identity already exists.
set -euo pipefail

CN="ClaudeUsageBar Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CN"; then
    echo "Signing identity '$CN' already exists. Nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = $CN
[v3]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
CFG

echo "Generating self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg" >/dev/null 2>&1
# macOS's importer needs the legacy PKCS12 MAC (SHA1). OpenSSL 3 defaults to a
# newer one; -legacy restores compatibility. Fall back if the flag is unsupported.
openssl pkcs12 -export -legacy -macalg sha1 -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -name "$CN" -passout pass:temp >/dev/null 2>&1 \
 || openssl pkcs12 -export -macalg sha1 -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -name "$CN" -passout pass:temp >/dev/null 2>&1

echo "Importing into login keychain (you may be asked for your login password)…"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P temp -T /usr/bin/codesign

echo "Done. Identity '$CN' is ready. Now run ./build-app.sh"
echo ""
echo "NOTE: The first time Xcode/codesign uses this key you may see a prompt"
echo "asking for access to the private key. Click 'Always Allow' so rebuilds"
echo "work without prompting."
