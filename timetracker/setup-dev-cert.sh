#!/bin/bash
# One-time setup. Run once:
#   cd timetracker && ./setup-dev-cert.sh
#
# Why this exists: build-app.sh used to sign the app "ad-hoc" (codesign
# --sign -). Ad-hoc signatures are NOT stable across rebuilds — every time
# you rebuild, the app gets a different identity in macOS's eyes. macOS
# ties privacy permissions (Screen Recording, Automation/Apple Events) to
# that identity, so every rebuild silently revoked the Screen Recording
# permission you'd granted — no re-prompt, it just quietly stopped taking
# screenshots (and stopped reading window titles) after the first run.
#
# This script creates a self-signed local code-signing certificate whose
# identity stays the same across every rebuild, so a permission you grant
# once keeps working. It only touches your local login keychain — nothing
# is uploaded or shared.
set -euo pipefail

CERT_NAME="TaskTimeTracker Local Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "Certificate '$CERT_NAME' already exists in your login keychain — nothing to do."
    echo "If screenshots/window titles still misbehave, the issue is elsewhere; re-run build-app.sh and check its output."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "Generating a self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -config "$TMP/cert.conf"
openssl pkcs12 -export -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout pass:tttdev -legacy 2>/dev/null || \
openssl pkcs12 -export -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout pass:tttdev

echo "Importing it into your login keychain — macOS may ask for your Mac password…"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P tttdev -T /usr/bin/codesign -T /usr/bin/security

echo "Marking it trusted for code signing…"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
echo "Done. From now on, run ./build-app.sh as usual — it will detect this"
echo "certificate and use it automatically. Since your existing"
echo "TaskTimeTracker.app was signed differently before, do this once more:"
echo "  1. System Settings -> Privacy & Security -> Screen Recording"
echo "     -> remove any existing TaskTimeTracker entries (- button)"
echo "  2. Also check Automation there, remove any TaskTimeTracker entry"
echo "  3. Rebuild: ./build-app.sh"
echo "  4. Relaunch the app and re-grant Screen Recording / Automation when asked"
echo "This permission should then survive all future rebuilds."
