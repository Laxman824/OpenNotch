#!/bin/bash
# Build OpenNotch.app.   scripts/build.sh [--install] [--open] [--dmg]
#   --install  replace the installed copy — the one the LaunchAgent runs, else
#              /Applications/OpenNotch.app if present (a DMG install), else
#              ~/Applications (stopping the supervised copy first)
#   --open     launch it afterwards
#   --dmg      also make build/OpenNotch-<version>.dmg
#
# Signing, best available first:
#   1. "Developer ID Application: …" in your keychain (or SIGN_ID=…) → hardened
#      runtime + entitlements, ready for notarisation (scripts/notarize.sh)
#   2. "OpenNotch Local Signing" (free; scripts/signing.sh creates it) → macOS
#      keeps permissions across updates, users click "Open Anyway" once
#   3. ad-hoc → works, but permissions reset on every build
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
BUILD="$ROOT/build"
APP="$BUILD/OpenNotch.app"

cd "$ROOT/App"
# Don't ship the builder's folder layout (home path, username) inside the binary.
swift build -c release -Xswiftc -file-prefix-map -Xswiftc "$ROOT=/opennotch"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/OpenNotch "$APP/Contents/MacOS/OpenNotch"
strip -S -x "$APP/Contents/MacOS/OpenNotch"
# Sparkle (auto-updates). Not sandboxed, so its XPC services aren't needed.
ditto .build/release/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/OpenNotch"
# The desktop companion (three.js page), without its test harness.
rsync -a --delete --exclude test "$ROOT/Desktop/" "$APP/Contents/Resources/desktop/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>OpenNotch</string>
  <key>CFBundleDisplayName</key><string>OpenNotch</string>
  <key>CFBundleIdentifier</key><string>dev.opennotch.OpenNotch</string>
  <key>CFBundleExecutable</key><string>OpenNotch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT licensed · github.com/Laxman824/OpenNotch</string>
  <key>NSCameraUsageDescription</key><string>OpenNotch shows a camera mirror in the notch so you can check yourself before a call. Nothing is recorded.</string>
  <key>NSMicrophoneUsageDescription</key><string>OpenNotch listens only while you dictate or use hands-free mode.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>OpenNotch turns what you say into a prompt, on device.</string>
  <key>NSContactsUsageDescription</key><string>OpenNotch looks up a contact's email or phone when you ask about someone.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>OpenNotch shows your upcoming events in the notch. Nothing leaves your Mac.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>OpenNotch lists, adds and completes your reminders from the notch.</string>
  <key>SUFeedURL</key><string>https://github.com/Laxman824/OpenNotch/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>njaNWsZCnTk9DlbCaSxvoqDzSOq0NJ5+/4nf/hEMu/4=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>OpenNotch controls music, reads your browser tab, Mail and Notes when you ask — and only then.</string>
</dict></plist>
PLIST

DEV_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
LOCAL_ID="OpenNotch Local Signing"
# Sparkle's helpers are signed inside-out with the app's identity (updates must match it).
sign_sparkle() {
  local F="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  codesign --force "$@" "$F/Autoupdate"
  codesign --force "$@" "$F/Updater.app"
  codesign --force "$@" "$APP/Contents/Frameworks/Sparkle.framework"
}
if [ -n "$DEV_ID" ]; then
  sign_sparkle --options runtime --timestamp --sign "$DEV_ID"
  codesign --force --options runtime --timestamp \
    --entitlements "$ROOT/scripts/OpenNotch.entitlements" --sign "$DEV_ID" "$APP"
  echo "signed: $DEV_ID (hardened runtime — notarise with scripts/notarize.sh)"
elif security find-certificate -c "$LOCAL_ID" >/dev/null 2>&1 && sign_sparkle --sign "$LOCAL_ID" 2>/dev/null \
     && codesign --force --sign "$LOCAL_ID" "$APP" 2>/dev/null; then
  echo "signed: $LOCAL_ID (free local certificate — permissions survive updates)"
else
  sign_sparkle --sign - >/dev/null 2>&1 || true
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  echo "note: ad-hoc signed — permissions reset each build. Run scripts/signing.sh once to fix." >&2
fi
echo "Built $APP ($VERSION)"

AGENT="$HOME/Library/LaunchAgents/dev.opennotch.app.plist"
for arg in "$@"; do
  case "$arg" in
    --install) # Stop the supervised app first: launchd relaunching it while the
               # bundle is half-copied is refused by macOS and reads as a crash.
               if [ -f "$AGENT" ]; then
                 launchctl bootout "gui/$(id -u)/dev.opennotch.app" 2>/dev/null || true
                 while pgrep -x OpenNotch >/dev/null; do sleep 0.2; done
                 REBOOTSTRAP=1
               fi
               DEST="$HOME/Applications/OpenNotch.app"
               if [ -f "$AGENT" ]; then
                 RUNS="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$AGENT" 2>/dev/null || true)"
                 case "$RUNS" in */OpenNotch.app/Contents/MacOS/OpenNotch) DEST="${RUNS%/Contents/MacOS/OpenNotch}" ;; esac
               elif [ -d /Applications/OpenNotch.app ]; then
                 DEST=/Applications/OpenNotch.app
               fi
               rm -rf "$DEST"; mkdir -p "$(dirname "$DEST")"
               cp -R "$APP" "$DEST"; APP="$DEST"
               echo "Installed to $APP" ;;
    --open)    if [ -f "$AGENT" ]; then
                 if [ -n "${REBOOTSTRAP:-}" ]; then launchctl bootstrap "gui/$(id -u)" "$AGENT"; REBOOTSTRAP=
                 else launchctl kickstart -k "gui/$(id -u)/dev.opennotch.app"; fi
               else
                 pkill -x OpenNotch 2>/dev/null || true
                 while pgrep -x OpenNotch >/dev/null; do sleep 0.2; done
                 open "$APP"          # first launch hands itself over to launchd
               fi ;;
    --dmg)     "$ROOT/scripts/make-dmg.sh" "$BUILD/OpenNotch.app" "$BUILD/OpenNotch-$VERSION.dmg" ;;
  esac
done
if [ -n "${REBOOTSTRAP:-}" ]; then launchctl bootstrap "gui/$(id -u)" "$AGENT"; fi
