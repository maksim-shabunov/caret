#!/bin/bash
#
# Builds Caret.app.
#
#   ./build.sh                 release, universal, signed, into build/
#   ./build.sh --fast          this Mac's architecture only
#   ./build.sh --debug         debug configuration
#   ./build.sh --install       also copy the result into /Applications
#   ./build.sh --run           launch it when finished
#   ./build.sh --adhoc         sign ad hoc, ignoring any local identity
#   ./build.sh --zip           also produce dist/Caret-<version>.zip
#   ./build.sh --version X.Y.Z stamp this version instead of asking git
#
# The signature matters more than it looks. macOS grants Accessibility access to
# a *signature*, not to a path, so signing every build with the same identity is
# what stops the permission being revoked on every rebuild — and being asked for
# it again is the single most irritating thing a utility like this can do.
#
# Which is also why a local build is the better one to run day to day. An Apple
# Development identity — free with any Apple ID — produces a stable signature, so
# permission survives rebuilds. The released download is signed ad hoc, and an
# ad-hoc signature is the build's own hash, so it changes with every version.

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Caret"
BUNDLE_ID="com.maksim.caret"
CONFIGURATION="release"
BUILD_DIR="build"
DIST_DIR="dist"
ARCH_FLAGS=(--arch arm64 --arch x86_64)
INSTALL=false
RUN=false
SIGN=true
ADHOC=false
ZIP=false
VERSION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --fast)      ARCH_FLAGS=() ;;
        --debug)     CONFIGURATION="debug" ;;
        --install)   INSTALL=true ;;
        --run)       RUN=true ;;
        --adhoc)     ADHOC=true ;;
        --zip)       ZIP=true ;;
        --no-sign)   SIGN=false ;;
        --version)   shift; VERSION="${1:-}" ;;
        --help|-h)   sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

# The version is the tag if there is one, so a release build needs no argument
# and a working copy cannot accidentally claim to be a release.
if [ -z "$VERSION" ]; then
    VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
    [ -n "$VERSION" ] || VERSION="0.0.0"
fi
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# The bundle is assembled somewhere else entirely and copied here at the end.
#
# This project may live on the Desktop, which macOS syncs through a file
# provider, and a file provider stamps `com.apple.FinderInfo` on every app bundle
# it sees — within a second or two of the bundle appearing, again after every
# attempt to remove it. `codesign` refuses outright to sign anything carrying
# that attribute, so assembling in place is a race that cannot be won. A
# temporary directory is outside the provider's world, and stays clean.
STAGE="$(mktemp -d)"
APP="$STAGE/$APP_NAME.app"
trap 'rm -rf "$STAGE"' EXIT

# ---------------------------------------------------------------- compile

echo "Building $APP_NAME $VERSION ($CONFIGURATION)…"
swift build -c "$CONFIGURATION" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BINARY="$(swift build -c "$CONFIGURATION" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/$APP_NAME"

# ---------------------------------------------------------------- assemble

echo "Assembling $APP_NAME.app…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Caret.icns "$APP/Contents/Resources/Caret.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"

# The word lists the character models are trained from. Copied straight into
# Resources rather than shipping SwiftPM's resource bundle, which expects to sit
# at the root of the app bundle — where it would count as unsealed content and
# invalidate the signature.
cp -R Sources/CaretCore/LanguageModels "$APP/Contents/Resources/LanguageModels"

# ---------------------------------------------------------------- sign

if $SIGN; then
    # The word lists arrive with a text-encoding attribute attached, which is
    # another thing codesign will not have.
    xattr -cr "$APP"

    IDENTITY=""
    if ! $ADHOC; then
        IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | grep "Apple Development" \
            | head -1 \
            | sed -E 's/.*"(.*)"/\1/' || true)"
    fi

    if [ -z "$IDENTITY" ]; then
        $ADHOC || echo "No Apple Development identity found — signing ad hoc instead." >&2
        codesign --force --sign - --timestamp=none \
            --identifier "$BUNDLE_ID" \
            --entitlements Resources/Caret.entitlements "$APP"
    else
        # Braced because the ellipsis is multibyte and macOS ships bash 3.2,
        # which is not: it takes the first byte of `…` for part of the name,
        # looks up a variable nobody set, and `set -u` ends the build there.
        echo "Signing as ${IDENTITY}…"
        codesign --force --options runtime --timestamp=none \
            --sign "$IDENTITY" \
            --identifier "$BUNDLE_ID" \
            --entitlements Resources/Caret.entitlements \
            "$APP"
    fi
    codesign --verify --strict --verbose=1 "$APP"
fi

# ---------------------------------------------------------------- place

# The running copy has to go first, or the replacement inherits a stale process
# and macOS keeps showing the old one.
if $INSTALL; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    sleep 1
fi

# `ditto` rather than `cp -R`, because it is the copy that understands bundles.
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_DIR/$APP_NAME.app"
ditto "$APP" "$BUILD_DIR/$APP_NAME.app"
FINAL="$BUILD_DIR/$APP_NAME.app"

if $INSTALL; then
    echo "Installing to /Applications…"
    rm -rf "/Applications/$APP_NAME.app"
    ditto "$APP" "/Applications/$APP_NAME.app"
    FINAL="/Applications/$APP_NAME.app"
fi

# Zipped from the staging copy for the same reason it was assembled there: the
# copy inside the project may already have been stamped again.
if $ZIP; then
    mkdir -p "$DIST_DIR"
    ARCHIVE="$DIST_DIR/$APP_NAME-$VERSION.zip"
    rm -f "$ARCHIVE"
    # `ditto -c -k --keepParent` is the only archiver that preserves a bundle's
    # signature intact; `zip` drops extended attributes and breaks it.
    ditto -c -k --keepParent "$APP" "$ARCHIVE"
    shasum -a 256 "$ARCHIVE" | tee "$ARCHIVE.sha256"
    echo "Packaged $ARCHIVE"
fi

# ---------------------------------------------------------------- finish

# Verified where it landed rather than where it was signed. The copy inside the
# project will fail this if a file provider has stamped it again by now, which is
# exactly why the bundle was assembled elsewhere — so only the installed copy is
# worth asking about.
if $SIGN && $INSTALL; then
    codesign --verify --strict --verbose=1 "$FINAL"
fi

echo "Built $FINAL"
APP="$FINAL"

if $RUN; then
    open "$APP"
fi
