#!/bin/bash
#
# Installs the latest release of Caret into /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/maksim-shabunov/caret/main/install.sh | bash
#
# What it does that dragging the app out of the zip does not: removes the
# quarantine flag macOS puts on anything downloaded from the internet.
#
# That flag is why an unsigned download normally greets you with "Apple could
# not verify this app is free of malware". Caret is signed, but ad hoc — signing
# in a way Gatekeeper will accept without complaint needs a paid Apple Developer
# account, which this project does not have. Removing the flag is exactly what
# Homebrew's --no-quarantine does, and what you would otherwise do by hand in
# System Settings › Privacy & Security.
#
# You are piping a script from the internet into a shell, so read it first. It
# is short on purpose.

set -euo pipefail

REPO="maksim-shabunov/caret"
APP="Caret.app"
DESTINATION="/Applications"

fail() { echo "error: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Caret is a macOS app."

MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 15 ] || fail "Caret needs macOS 15 or later (this is $(sw_vers -productVersion))."

echo "Finding the latest release…"
ASSET="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*\.zip"' \
    | head -1 \
    | cut -d'"' -f4)"
[ -n "$ASSET" ] || fail "No release found. Build from source instead: https://github.com/$REPO#building"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading $(basename "$ASSET")…"
curl -fsSL "$ASSET" -o "$WORK/Caret.zip"

# Verified when the release publishes a checksum, skipped without complaint when
# it does not — a missing checksum is not a reason to refuse to install.
if CHECKSUM="$(curl -fsSL "$ASSET.sha256" 2>/dev/null)"; then
    EXPECTED="$(echo "$CHECKSUM" | cut -d' ' -f1)"
    ACTUAL="$(shasum -a 256 "$WORK/Caret.zip" | cut -d' ' -f1)"
    [ "$EXPECTED" = "$ACTUAL" ] || fail "Checksum mismatch. Expected $EXPECTED, got $ACTUAL."
    echo "Checksum verified."
fi

echo "Unpacking…"
ditto -x -k "$WORK/Caret.zip" "$WORK/unpacked"
[ -d "$WORK/unpacked/$APP" ] || fail "The archive did not contain $APP."

# A running copy has to go first, or the replacement inherits a stale process.
osascript -e 'tell application id "com.maksim.caret" to quit' >/dev/null 2>&1 || true
sleep 1

# Braced because the ellipsis is multibyte and macOS ships bash 3.2, which is
# not: it takes the first byte of `…` for part of the variable name, looks up a
# name nobody set, and `set -u` ends the install right there.
echo "Installing to ${DESTINATION}…"
rm -rf "${DESTINATION:?}/$APP"
ditto "$WORK/unpacked/$APP" "$DESTINATION/$APP"
xattr -dr com.apple.quarantine "$DESTINATION/$APP" 2>/dev/null || true

echo
echo "Installed $DESTINATION/$APP"
echo "Caret needs Accessibility permission to see what you type — it will ask on first launch."
open "$DESTINATION/$APP"
