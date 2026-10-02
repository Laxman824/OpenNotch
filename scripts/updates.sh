#!/bin/bash
# Auto-update plumbing (Sparkle).
#   scripts/updates.sh keys      once: create the EdDSA update key (private half stays in your login
#                                Keychain) and print the public key for build.sh
#   scripts/updates.sh backup F  export the private key to file F (keep it off the repo, next to the .p12)
#   scripts/updates.sh appcast   after `scripts/build.sh --dmg`: sign build/OpenNotch.dmg and write
#                                build/appcast.xml — attach BOTH to the GitHub release
#
# The feed is releases/latest/download/appcast.xml, so it always comes from the newest release, and its
# download link points at that release's own OpenNotch.dmg. Lose the private key and existing installs
# can't verify new updates — back it up.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPARKLE_VERSION="2.10.0"
TOOLS="$ROOT/build/sparkle"
REPO="Laxman824/OpenNotch"

tools() {
  if [ ! -x "$TOOLS/bin/sign_update" ]; then
    mkdir -p "$TOOLS"
    curl -sSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
      | tar -xJ -C "$TOOLS" bin
  fi
}

case "${1:-}" in
  keys)
    tools
    "$TOOLS/bin/generate_keys" | tail -n +1
    echo
    echo "Public key: $("$TOOLS/bin/generate_keys" -p)  (build.sh reads it with generate_keys -p)"
    ;;
  backup)
    tools
    [ -n "${2:-}" ] || { echo "usage: scripts/updates.sh backup <file>"; exit 2; }
    "$TOOLS/bin/generate_keys" -x "$2"
    echo "Exported to $2 — keep it somewhere safe, never in the repo."
    ;;
  appcast)
    tools
    VERSION="$(cat "$ROOT/VERSION")"
    DMG="$ROOT/build/OpenNotch.dmg"
    [ -f "$ROOT/build/OpenNotch-$VERSION.dmg" ] && cp "$ROOT/build/OpenNotch-$VERSION.dmg" "$DMG"
    [ -f "$DMG" ] || { echo "No $DMG — run scripts/build.sh --dmg first."; exit 1; }
    SIG="$("$TOOLS/bin/sign_update" "$DMG")"          # sparkle:edSignature="…" length="…"
    DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
    cat > "$ROOT/build/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>OpenNotch</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>OpenNotch $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/OpenNotch.dmg" type="application/octet-stream" $SIG />
    </item>
  </channel>
</rss>
XML
    echo "Wrote build/appcast.xml for $VERSION. Attach build/OpenNotch.dmg and build/appcast.xml to release v$VERSION."
    ;;
  *)
    sed -n '2,12p' "$0"; exit 2 ;;
esac
