#!/usr/bin/env bash
# Fork-only: build the Intel (x86_64) DMG of agterm <version> for maxshevelev/agterm.
#
# Usage: scripts/fork-dmg.sh <x.y.z> [suffix]   # writes build/agterm-<x.y.z>[-suffix]-x86_64.dmg
#
# Not scripts/release.sh: that one notarizes, builds the Linux server in Docker and publishes umputun's release.
# Here the app carries the checksums of umputun's official agterm-server tarballs, which `agtermctl server install`
# downloads, and the Sparkle feed stays empty (release.sh's `ARCHS=x86_64 build` keeps it so too).
#
# Signing: AGTERM_FORK_SIGN_IDENTITY (a name or SHA-1 from `security find-identity -v -p codesigning`), else the
# self-signed "agterm fork signing" code-signing certificate when the keychain trusts it, else ad-hoc.
# A certificate gives a designated requirement of identifier + certificate, the same for every build, so macOS
# privacy grants (Desktop, Downloads, …) survive an update and panes still running under the previous session
# host keep them. An ad-hoc requirement is the binary's cdhash, which every build changes, so those panes would
# ask again on the origin's screen. No hardened runtime: its library validation needs an Apple team id, which a
# self-signed certificate has none of, and the fork is not notarized anyway.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD_DIR="$ROOT/build"

VERSION="${1:-}"
SUFFIX="${2:+-$2}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: scripts/fork-dmg.sh <x.y.z> [suffix]" >&2; exit 1; }
APP="$BUILD_DIR/DerivedData/Build/Products/Release/agterm.app"
DMG="$BUILD_DIR/agterm-$VERSION$SUFFIX-x86_64.dmg"

SIGN_ID="${AGTERM_FORK_SIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning | awk '/"agterm fork signing"/ {print $2; exit}')"
fi
if [ -n "$SIGN_ID" ]; then
  echo "==> signing identity: $SIGN_ID"
else
  echo "==> WARNING: no \"agterm fork signing\" identity, building AD-HOC: privacy grants will not survive updates"
fi

# ── build ────────────────────────────────────────────────────────────────────
"$ROOT/scripts/setup.sh"
xcodegen generate >/dev/null
GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
xcodebuild -project agterm.xcodeproj -scheme agterm -configuration Release \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" GIT_COMMIT="$GIT_COMMIT" \
  ARCHS=x86_64 build
[ -d "$APP" ] || { echo "expected app not found: $APP" >&2; exit 1; }
FEED="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[ -z "$FEED" ] || { echo "SUFeedURL is set ($FEED): the fork must not offer umputun's arm64 updates" >&2; exit 1; }

# ── checksums of umputun's agterm-server tarballs ────────────────────────────
SERVER_DIR="$(mktemp -d)"
trap 'rm -rf "$SERVER_DIR"' EXIT
gh release download "v$VERSION" --repo umputun/agterm --dir "$SERVER_DIR" \
  --pattern "agterm-server-$VERSION-linux-aarch64.tar.gz" --pattern "agterm-server-$VERSION-linux-x86_64.tar.gz"
(cd "$SERVER_DIR" && shasum -a 256 "agterm-server-$VERSION-linux-aarch64.tar.gz" \
  "agterm-server-$VERSION-linux-x86_64.tar.gz") >"$APP/Contents/Resources/agterm-server.sha256"

# ── sign ─────────────────────────────────────────────────────────────────────
# Inside-out, as release.sh does: helpers without entitlements, never --deep on the app, which would stamp its
# TCC entitlements onto standalone executables.
if [ -n "$SIGN_ID" ]; then
  for helper in agtermctl zmx agterm-session-host; do
    codesign --force --sign "$SIGN_ID" "$APP/Contents/MacOS/$helper"
  done
  sparkle="$APP/Contents/Frameworks/Sparkle.framework"
  for nested in "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle/Versions/B/XPCServices/Downloader.xpc" \
    "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
    codesign --force --sign "$SIGN_ID" "$nested"
  done
  codesign --force --entitlements "$ROOT/agterm/agterm.entitlements" --sign "$SIGN_ID" "$APP"
else
  codesign --force --entitlements "$ROOT/agterm/agterm.entitlements" --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
if [ -n "$SIGN_ID" ]; then
  for bin in "$APP" "$APP/Contents/MacOS/agterm-session-host" "$APP/Contents/MacOS/zmx"; do
    if codesign -dr - "$bin" 2>&1 | grep -q 'designated => cdhash'; then
      echo "$bin still has a cdhash requirement" >&2; exit 1
    fi
  done
fi

# ── DMG ──────────────────────────────────────────────────────────────────────
STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname agterm -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"
echo "==> $DMG"
shasum -a 256 "$DMG"
