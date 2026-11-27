#!/bin/bash
#
# Builds Mailer.app with nothing but Xcode's command-line tools — the same
# approach as Cued: SwiftPM compiles, this script wraps the binary in a real
# .app (so macOS grants it notifications and a stable Keychain identity) and
# signs it with your Apple Development certificate (or ad hoc, if you have none).
#
#   ./build.sh          release build into build/Mailer.app
#   ./build.sh run      build, then (re)launch it
#   ./build.sh demo     build, then launch with sample mail (POSTLINE_DEMO=1)
#   ./build.sh install  build, then copy to /Applications
#   ./build.sh release  notarized build/Mailer.dmg for sharing (needs a
#                       Developer ID certificate and a notarytool profile)
#
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
# The app is called Mailer; the Swift package, its sources and the data
# folders keep the name Postline it was forked from (2026-11-27).
APP="$ROOT/build/Mailer.app"
BUNDLE_ID="com.oiharshit.postline"

ACTION="${1:-}"
say() { printf '\033[2m›\033[0m %s\n' "$1"; }

say "Compiling (release)…"
xcrun metal --version >/dev/null 2>&1 || true   # mounts the Metal Toolchain
"$ROOT/tools/fix-metal-path.sh"
swift build -c release --arch arm64 --product Postline
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Postline"

say "Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Mailer"
cp -R "$ROOT/Resources/Icons" "$APP/Contents/Resources/Icons"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# MLX's GPU kernels for the writing model (Qwen). MLX finds them at
# Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib;
# a data file next to the executable would break the code signature (Cued
# learned this). Prefer the bundle this build compiled; else Cued's copy of
# the same MLX version.
BIN_DIR="$(dirname "$BIN")"
# Resource bundles SwiftPM built for the libraries (tokenizer data, MLX
# kernels…) go where Bundle.module looks inside an app: Contents/Resources.
for b in "$BIN_DIR"/*.bundle; do
    [ -d "$b" ] && ditto "$b" "$APP/Contents/Resources/$(basename "$b")"
done
METALLIB=""
# A plain `swift build` does not compile Metal, so the last resort is a copy
# kept at build/mlx/default.metallib (taken from an earlier app built with the
# same MLX version, 2026-11-27).
for candidate in "$BIN_DIR/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" \
                 "$BIN_DIR/mlx-swift_Cmlx.bundle/default.metallib" \
                 "$ROOT/build/mlx/default.metallib"; do
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
ICNS="$ROOT/build/Postline.icns"
if [ ! -f "$ICNS" ] || [ "$ROOT/Resources/Icons/mail.svg" -nt "$ICNS" ]; then
    say "Drawing the app icon…"
    rm -rf "$ROOT/build/Postline.iconset"
    swift "$ROOT/tools/make-icon.swift" "$ROOT/Resources/Icons/mail.svg" "$ROOT/build/Postline.iconset"
    iconutil -c icns "$ROOT/build/Postline.iconset" -o "$ICNS"
fi
cp "$ICNS" "$APP/Contents/Resources/Postline.icns"

# Your Google OAuth client ID (README → Google setup): from
# POSTLINE_GOOGLE_CLIENT_ID, else GoogleClientID.txt next to this script.
# It is kept out of the repository so every build signs in through its
# builder's own Google project. Google redirects sign-in back to the reversed
# client ID, so that is registered as a URL scheme too.
CLIENT_ID="${POSTLINE_GOOGLE_CLIENT_ID:-}"
if [ -z "$CLIENT_ID" ] && [ -f "$ROOT/GoogleClientID.txt" ]; then
    CLIENT_ID="$(tr -d '[:space:]' < "$ROOT/GoogleClientID.txt")"
fi
if [[ "$CLIENT_ID" == *.apps.googleusercontent.com ]]; then
    SCHEME="com.googleusercontent.apps.${CLIENT_ID%.apps.googleusercontent.com}"
    /usr/libexec/PlistBuddy -c "Add :PostlineGoogleClientID string $CLIENT_ID" \
        -c "Add :CFBundleURLTypes array" \
        -c "Add :CFBundleURLTypes:0 dict" \
        -c "Add :CFBundleURLTypes:0:CFBundleURLName string $BUNDLE_ID.oauth" \
        -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" \
        -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string $SCHEME" "$APP/Contents/Info.plist"
else
    say "No Google client ID yet — the app runs, but sign-in stays off until"
    say "you add one (README → Google setup). Try it now with: ./build.sh demo"
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
codesign --force --options runtime $TIMESTAMP --entitlements "$ROOT/Resources/Postline.entitlements" \
    --identifier "$BUNDLE_ID" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
say "Built $APP"

case "$ACTION" in
    run)
        pkill -x Mailer 2>/dev/null || true; pkill -x Postline 2>/dev/null || true; sleep 0.5
        open "$APP" ;;
    demo)
        pkill -x Mailer 2>/dev/null || true; pkill -x Postline 2>/dev/null || true; sleep 0.5
        POSTLINE_DEMO=1 "$APP/Contents/MacOS/Mailer" >/dev/null 2>&1 & ;;
    install)
        pkill -x Mailer 2>/dev/null || true; pkill -x Postline 2>/dev/null || true; sleep 0.5
        rm -rf /Applications/Postline.app /Applications/Mailer.app
        ditto "$APP" /Applications/Mailer.app
        open /Applications/Mailer.app
        say "Installed to /Applications" ;;
    release)
        # Store notarization credentials once with
        #   xcrun notarytool store-credentials postline --apple-id <you> \
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
        xcrun notarytool submit "$DMG" --keychain-profile "${NOTARY_PROFILE:-postline}" --wait
        xcrun stapler staple "$DMG"
        xcrun stapler validate "$DMG" && say "Notarized: $DMG" ;;
esac
