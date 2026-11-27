#!/bin/bash
#
# Builds Mailer.app with nothing but Xcode's command-line tools — the same
# approach as Cued: SwiftPM compiles, this script wraps the binary in a real
# .app (so macOS grants it notifications and a stable Keychain identity) and
# signs it with your Apple Development certificate (or ad hoc, if you have none).
#
#   ./build.sh          release build into build/Mailer.app
#   ./build.sh run      build, then (re)launch it
#   ./build.sh demo     build, then launch with sample mail (MAILER_DEMO=1)
#   ./build.sh install  build, then copy to /Applications
#   ./build.sh release  notarized build/Mailer.dmg for sharing (needs a
#                       Developer ID certificate and a notarytool profile)
#
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
# Mailer is a fork of Postline. The app ID below, the Keychain entry and the
# data folders (~/Library/Application Support/Postline, ~/Library/Logs/
# Postline*.log) keep Postline's name: renaming them would sign every account
# out and leave the mail behind (2026-11-27).
APP="$ROOT/build/Mailer.app"
BUNDLE_ID="com.oiharshit.postline"

ACTION="${1:-}"
say() { printf '\033[2m›\033[0m %s\n' "$1"; }

say "Compiling (release)…"
xcrun metal --version >/dev/null 2>&1 || true   # mounts the Metal Toolchain
"$ROOT/tools/fix-metal-path.sh"
swift build -c release --arch arm64 --product Mailer
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Mailer"

# Debug symbols, so GlitchTip can turn a crash's addresses into function
# names and lines. Kept next to the app (build/Mailer.app.dSYM).
DSYM="$ROOT/build/Mailer.app.dSYM"
rm -rf "$DSYM"
mkdir -p "$ROOT/build"
dsymutil "$BIN" -o "$DSYM"

say "Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Mailer"
cp -R "$ROOT/Resources/Icons" "$APP/Contents/Resources/Icons"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# The version: Info.plist's base (1.2) and the number of commits on this
# branch, so the same commit always builds the same version, here or on
# GitHub, and each merge to main is newer than the last. Updates compare the
# build number (Core/Updates.swift).
COMMITS="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
BASE_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Resources/Info.plist")"
VERSION="$BASE_VERSION.$COMMITS"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $COMMITS" "$APP/Contents/Info.plist"
say "Version $VERSION"

# MLX's GPU kernels for the writing model (Qwen). MLX finds them at
# Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib;
# a data file next to the executable would break the code signature (Cued
# learned this). Prefer the bundle this build compiled; else Cued's copy of
# the same MLX version.
BIN_DIR="$(dirname "$BIN")"

# Sparkle, for updates. Its XPC services are only for sandboxed apps;
# Mailer isn't one, so they are left out.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
# Resource bundles SwiftPM built for the libraries (tokenizer data, MLX
# kernels…) go where Bundle.module looks inside an app: Contents/Resources.
for b in "$BIN_DIR"/*.bundle; do
    [ -d "$b" ] && ditto "$b" "$APP/Contents/Resources/$(basename "$b")"
done
METALLIB=""
# A plain `swift build` does not compile Metal, so the last resort is the copy
# in Resources/MLX, compiled for mlx-swift 0.32.3 (the version in
# Package.resolved; replace it when MLX is updated). It is in the repository
# so GitHub's builds have it too: without it, published updates had no
# writing help (2026-11-27).
for candidate in "$BIN_DIR/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" \
                 "$BIN_DIR/mlx-swift_Cmlx.bundle/default.metallib" \
                 "$ROOT/Resources/MLX/default.metallib"; do
    [ -f "$candidate" ] && { METALLIB="$candidate"; break; }
done
if [ -n "$METALLIB" ]; then
    NESTED="$APP/Contents/Resources/mlx-swift_Cmlx.bundle/Contents"
    mkdir -p "$NESTED/Resources"
    cp "$METALLIB" "$NESTED/Resources/default.metallib"
    cat > "$NESTED/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>com.oiharshit.postline.mlx-swift-Cmlx</string>
    <key>CFBundleName</key><string>mlx-swift_Cmlx</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
    say "MLX kernels: $(basename "$(dirname "$METALLIB")")/$(basename "$METALLIB")"
else
    say "WARNING: no MLX kernels found — writing help will use Apple's model"
fi

# App icon, regenerated only when the glyph changes.
ICNS="$ROOT/build/Mailer.icns"
if [ ! -f "$ICNS" ] || [ "$ROOT/Resources/Icons/mail.svg" -nt "$ICNS" ]; then
    say "Drawing the app icon…"
    rm -rf "$ROOT/build/Mailer.iconset"
    swift "$ROOT/tools/make-icon.swift" "$ROOT/Resources/Icons/mail.svg" "$ROOT/build/Mailer.iconset"
    iconutil -c icns "$ROOT/build/Mailer.iconset" -o "$ICNS"
fi
cp "$ICNS" "$APP/Contents/Resources/Mailer.icns"

# Your Google OAuth client ID (README → Google setup): from
# MAILER_GOOGLE_CLIENT_ID, else GoogleClientID.txt next to this script.
# It is kept out of the repository so every build signs in through its
# builder's own Google project. Google redirects sign-in back to the reversed
# client ID, so that is registered as a URL scheme too.
CLIENT_ID="${MAILER_GOOGLE_CLIENT_ID:-}"
if [ -z "$CLIENT_ID" ] && [ -f "$ROOT/GoogleClientID.txt" ]; then
    CLIENT_ID="$(tr -d '[:space:]' < "$ROOT/GoogleClientID.txt")"
fi
if [[ "$CLIENT_ID" == *.apps.googleusercontent.com ]]; then
    SCHEME="com.googleusercontent.apps.${CLIENT_ID%.apps.googleusercontent.com}"
    /usr/libexec/PlistBuddy -c "Add :MailerGoogleClientID string $CLIENT_ID" \
        -c "Add :CFBundleURLTypes array" \
        -c "Add :CFBundleURLTypes:0 dict" \
        -c "Add :CFBundleURLTypes:0:CFBundleURLName string $BUNDLE_ID.oauth" \
        -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" \
        -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string $SCHEME" "$APP/Contents/Info.plist"
else
    say "No Google client ID yet — the app runs, but sign-in stays off until"
    say "you add one (README → Google setup). Try it now with: ./build.sh demo"
fi

# GlitchTip, for errors, crashes and timings (Telemetry.swift): its DSN from
# MAILER_GLITCHTIP_DSN, else GlitchTipDSN.txt next to this script. Kept out
# of the repository like the client ID. Without one, Settings has no
# Diagnostics switch and nothing is ever sent. The commit names the build in
# GlitchTip's releases.
DSN="${MAILER_GLITCHTIP_DSN:-}"
if [ -z "$DSN" ] && [ -f "$ROOT/GlitchTipDSN.txt" ]; then
    DSN="$(tr -d '[:space:]' < "$ROOT/GlitchTipDSN.txt")"
fi
if [[ "$DSN" == https://*@*/* ]]; then
    /usr/libexec/PlistBuddy -c "Add :MailerGlitchTipDSN string $DSN" "$APP/Contents/Info.plist"
    say "Diagnostics: GlitchTip at $(sed -E 's#https://[^@]*@([^/]*)/.*#\1#' <<<"$DSN") (off until turned on in Settings)"
fi
COMMIT="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || true)"
[ -n "$COMMIT" ] && /usr/libexec/PlistBuddy -c "Add :MailerGitCommit string $COMMIT" "$APP/Contents/Info.plist"

# The symbols go to GlitchTip when a token is at hand (GlitchTip → Profile →
# Auth Tokens, with project:write), through sentry-cli, which GlitchTip
# accepts. The server is the DSN's (or GLITCHTIP_URL); GLITCHTIP_ORG and
# GLITCHTIP_PROJECT name the project.
GLITCHTIP_URL="${GLITCHTIP_URL:-$(sed -nE 's#(https://)[^@]*@([^/]*)/.*#\1\2#p' <<<"$DSN")}"
if [ -n "$GLITCHTIP_URL" ] && [ -n "${GLITCHTIP_AUTH_TOKEN:-}" ] && command -v sentry-cli >/dev/null; then
    say "Uploading debug symbols to GlitchTip…"
    SENTRY_URL="$GLITCHTIP_URL" SENTRY_AUTH_TOKEN="$GLITCHTIP_AUTH_TOKEN" \
        sentry-cli debug-files upload --org "${GLITCHTIP_ORG:-personal}" --project "${GLITCHTIP_PROJECT:-mailer}" "$DSYM" \
        || say "WARNING: the debug symbols did not upload; crashes from this build will show addresses only"
fi

# A stable identity keeps the Keychain from re-asking after every build.
# A release for other Macs must be Developer ID signed (and notarized below).
IDENTITIES="$(security find-identity -v -p codesigning)"
DEVELOPER_ID="$(sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' <<<"$IDENTITIES" | head -1)"
if [ "$ACTION" = "release" ]; then
    [ -n "$DEVELOPER_ID" ] || { echo "✗ 'release' needs a Developer ID Application certificate (Apple Developer Program)."; exit 1; }
    IDENTITY="$DEVELOPER_ID"; TIMESTAMP="--timestamp"
else
    IDENTITY="$(sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' <<<"$IDENTITIES" | head -1)"
    [ -n "$IDENTITY" ] || IDENTITY="$DEVELOPER_ID"
    TIMESTAMP=""
fi
if [ -n "$IDENTITY" ]; then
    say "Signing as $IDENTITY"
else
    # Ad hoc: runs on this Mac. macOS may ask again for Keychain access after
    # each rebuild; a free Apple ID in Xcode → Settings → Accounts avoids that.
    IDENTITY="-"
    say "No signing certificate found — signing ad hoc (fine for your own Mac)"
fi
# Inside out: Sparkle's helpers, then Sparkle, then the app. One identity
# for all, so the updater may replace the app and macOS lets it load.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for part in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
    codesign --force --options runtime $TIMESTAMP --sign "$IDENTITY" "$part"
done
codesign --force --options runtime $TIMESTAMP --entitlements "$ROOT/Resources/Mailer.entitlements" \
    --identifier "$BUNDLE_ID" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
say "Built $APP"

case "$ACTION" in
    run)
        pkill -x Mailer 2>/dev/null || true; pkill -x Postline 2>/dev/null || true; sleep 0.5
        open "$APP" ;;
    demo)
        pkill -x Mailer 2>/dev/null || true; pkill -x Postline 2>/dev/null || true; sleep 0.5
        MAILER_DEMO=1 "$APP/Contents/MacOS/Mailer" >/dev/null 2>&1 & ;;
    install)
        pkill -x Mailer 2>/dev/null || true; pkill -x Postline 2>/dev/null || true; sleep 0.5
        rm -rf /Applications/Postline.app /Applications/Mailer.app
        ditto "$APP" /Applications/Mailer.app
        open /Applications/Mailer.app
        say "Installed to /Applications" ;;
    release)
        # Store notarization credentials once with
        #   xcrun notarytool store-credentials mailer --apple-id <you> \
        #         --team-id <TEAMID> --password <app-specific-password>
        # (or point NOTARY_PROFILE at an existing profile).
        DMG="$ROOT/build/Mailer.dmg"
        STAGE="$ROOT/build/dmg"
        rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
        ditto "$APP" "$STAGE/Mailer.app"
        ln -s /Applications "$STAGE/Applications"
        hdiutil create -volname Mailer -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
        rm -rf "$STAGE"
        codesign --force --timestamp --sign "$IDENTITY" "$DMG"
        say "Notarizing (a few minutes)…"
        xcrun notarytool submit "$DMG" --keychain-profile "${NOTARY_PROFILE:-mailer}" --wait
        xcrun stapler staple "$DMG"
        xcrun stapler validate "$DMG" && say "Notarized: $DMG" ;;
esac
