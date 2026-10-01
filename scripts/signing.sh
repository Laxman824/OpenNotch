#!/bin/bash
# Creates (once) a local self-signed code-signing identity for OpenNotch.
#
# Why: an ad-hoc signature's designated requirement is the binary's cdhash,
# which changes on every rebuild — macOS then treats the app as new and
# forgets Microphone, Speech, Calendars, Reminders, Screen Recording,
# Accessibility and Automation grants. Signed with a fixed certificate the
# requirement becomes "identifier + this certificate", so grants survive rebuilds.
#
# Private to this Mac: the key lives only in the login keychain. Remove with
#   security delete-identity -c "OpenNotch Local Signing"
set -euo pipefail
NAME="OpenNotch Local Signing"
KC="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1; then
  exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$TMP/cfg" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS=$(openssl rand -hex 16)
# -legacy: the macOS keychain can't read OpenSSL 3's default PKCS#12 ciphers.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
       -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PASS"
# -T: let codesign use the key without a keychain prompt on every build.
security import "$TMP/id.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Created code-signing identity \"$NAME\" in the login keychain."
