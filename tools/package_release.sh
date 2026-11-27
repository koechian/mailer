#!/bin/bash
#
# Packages a built Mailer.app as an update: a zip, its EdDSA signature, the
# release notes and the appcast.xml feed Sparkle reads (Core/Updates.swift).
# GitHub's release job runs it after the tests; it also runs locally.
#
#   tools/package_release.sh [build/Mailer.app] [build/release]
#
# The update key comes from SPARKLE_KEY_FILE when set (GitHub, from the
# SPARKLE_PRIVATE_KEY secret), otherwise from the login keychain (account
# "mailer", made by Sparkle's generate_keys). Prints the version on its last
# line.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="${1:-$ROOT/build/Mailer.app}"
OUT="${2:-$ROOT/build/release}"
REPOSITORY="${GITHUB_REPOSITORY:-koechian/mailer}"
SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"

[ -d "$APP" ] || { echo "No app at $APP: run ./build.sh first." >&2; exit 1; }
[ -x "$SIGN_UPDATE" ] || swift package resolve >/dev/null

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")"
MINIMUM="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")"
ZIP_NAME="Mailer-$VERSION.zip"

rm -rf "$OUT"
mkdir -p "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP_NAME"

if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
    SIGNATURE="$("$SIGN_UPDATE" --ed-key-file "$SPARKLE_KEY_FILE" "$OUT/$ZIP_NAME")"
else
    SIGNATURE="$("$SIGN_UPDATE" --account mailer "$OUT/$ZIP_NAME")"
fi

# Release notes: the commit subjects since the last release, newest first.
PREVIOUS="$(git describe --tags --abbrev=0 --match 'v*' HEAD^ 2>/dev/null || true)"
if [ -n "$PREVIOUS" ]; then RANGE="$PREVIOUS..HEAD"; else RANGE="-10"; fi
git log --no-merges --format='%s' $RANGE > "$OUT/subjects.txt"
{ echo "Changes in this build:"; echo; sed 's/^/- /' "$OUT/subjects.txt"; } > "$OUT/notes.md"
NOTES_HTML="<ul>$(sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's|.*|<li>&</li>|' "$OUT/subjects.txt" | tr -d '\n')</ul>"
rm "$OUT/subjects.txt"

cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Mailer</title>
    <item>
      <title>Mailer $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES_HTML]]></description>
      <enclosure url="https://github.com/$REPOSITORY/releases/download/v$VERSION/$ZIP_NAME"
                 type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
XML

echo "$VERSION"
