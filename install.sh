#!/bin/bash
# Todo Maxxing Downloader installer for Mac (Apple Silicon).
#
#   curl -fsSL https://todomaxxing.com/install.sh | bash
#
# Why this exists: a DMG downloaded in a browser is quarantined, and macOS then
# refuses to open an app that isn't notarized ("Todo Maxxing Downloader Not Opened").
# Files fetched by curl are not quarantined, so the app installed here opens
# normally. The app updates itself afterwards the same way.
#
# What it does: looks up the latest release, downloads the DMG, checks its size and
# SHA-256 against the release's manifest, copies the app to /Applications (or
# ~/Applications when that isn't writable), ejects the DMG and opens the app.
# It needs nothing but the tools every Mac has.
#
# Test overrides: TM_INSTALL_DIR (default /Applications), TM_NO_LAUNCH=1.
set -euo pipefail

REPO="Garvvaiahnav/todomaxxing-downloader"
FEED="https://github.com/$REPO/releases/latest/download"
APP="Todo Maxxing Downloader.app"
NAME="Todo Maxxing Downloader"

say() { printf '\033[1m%s\033[0m\n' "$*"; }

# One line, redrawn in place: [#########---------]  45%   52 / 128 MB   8.4 MB/s
progress() {  # bytes_done bytes_total seconds
  local done=$1 total=$2 secs=$3 pct=0 bar
  [ "$total" -gt 0 ] && pct=$(( done * 100 / total ))
  [ "$pct" -gt 100 ] && pct=100
  bar=$(printf '%*s' $(( pct / 4 )) '' | tr ' ' '#')
  bar=$(printf '%-25s' "$bar" | tr ' ' '-')
  printf '\r  [%s] %3d%%  %4d / %d MB  %5s MB/s ' "$bar" "$pct" $(( done / 1048576 )) $(( total / 1048576 )) \
    "$( [ "$secs" -gt 0 ] && echo "scale=1; $done / 1048576 / $secs" | bc || echo " ")"
}
die() { printf 'Install stopped: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "this installer is for Mac. On Windows use: irm https://todomaxxing.com/install.ps1 | iex"
[ "$(uname -m)" = "arm64" ] || die "$NAME needs an Apple Silicon Mac (M1 or newer)."

DEST="${TM_INSTALL_DIR:-/Applications}"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

WORK="$(mktemp -d)"
MNT="$WORK/mnt"
cleanup() {
  [ -n "${CURL:-}" ] && kill "$CURL" 2>/dev/null || true
  hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

say "Looking up the latest version..."
curl -fsSL "$FEED/manifest.json" -o "$WORK/manifest.json" || die "could not reach the download server. Check your connection and run the command again."
VERSION="$(plutil -extract version raw -o - "$WORK/manifest.json")"
URL="$(plutil -extract assets.darwin-arm64.url raw -o - "$WORK/manifest.json")"
SHA="$(plutil -extract assets.darwin-arm64.sha256 raw -o - "$WORK/manifest.json")"
SIZE="$(plutil -extract assets.darwin-arm64.size raw -o - "$WORK/manifest.json")"
case "$URL" in
  "https://github.com/$REPO/releases/download/"*) ;;
  *) die "the release points somewhere unexpected." ;;
esac
case "$SIZE" in
  ''|*[!0-9]*) die "the release has no valid file size." ;;
esac

say "Downloading $NAME $VERSION..."
curl -fsSL "$URL" -o "$WORK/app.dmg" </dev/null &
CURL=$!
START=$(date +%s)
while kill -0 "$CURL" 2>/dev/null; do
  progress "$(stat -f%z "$WORK/app.dmg" 2>/dev/null || echo 0)" "$SIZE" $(( $(date +%s) - START ))
  sleep 0.5
done
wait "$CURL" || { printf '\n'; die "download failed. Run the command again."; }
progress "$(stat -f%z "$WORK/app.dmg")" "$SIZE" $(( $(date +%s) - START ))
printf '\n'
[ "$(stat -f%z "$WORK/app.dmg")" = "$SIZE" ] || die "the download is incomplete (size mismatch). Run the command again."
[ "$(shasum -a 256 "$WORK/app.dmg" | cut -d' ' -f1)" = "$SHA" ] || die "the download is corrupted (checksum mismatch). Run the command again."

say "Installing to $DEST..."
mkdir -p "$MNT"
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$WORK/app.dmg" >/dev/null
[ -d "$MNT/$APP" ] || die "the installer file has no $APP inside."

# Quit a running copy so it can be replaced.
if pgrep -f "$APP/Contents/MacOS" >/dev/null 2>&1; then
  osascript -e "tell application \"$NAME\" to quit" >/dev/null 2>&1 || true
  sleep 2
fi
rm -rf "$DEST/$APP"
ditto "$MNT/$APP" "$DEST/$APP"
xattr -cr "$DEST/$APP" 2>/dev/null || true
hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true   # eject; the cleanup trap tries again if it was busy

say "Done. $NAME $VERSION is in $DEST."
if [ -z "${TM_NO_LAUNCH:-}" ]; then
  open "$DEST/$APP"
fi
