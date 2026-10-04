#!/bin/sh
# Builds Sheaf for release: archives it, signs it with a Developer ID, has Apple notarize
# it, and packs it in a disk image.
#
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   TEAM_ID=TEAMID NOTARY_PROFILE=sheaf-notary Scripts/release.sh
#
# NOTARY_PROFILE names credentials saved once with:
#   xcrun notarytool store-credentials sheaf-notary --apple-id you@example.com --team-id TEAMID
#
# Without DEVELOPER_ID the app is signed to run on this Mac only and nothing is sent to
# Apple, which is enough to try the disk image out. See RELEASING.md.
set -eu
cd "$(dirname "$0")/.."

case "$(xcode-select -p)" in *CommandLineTools*) export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ;; esac

version=$(sed -n 's/^ *MARKETING_VERSION: *//p' project.yml | head -1)
out=build/release
archive="$out/Sheaf.xcarchive"
app="$out/Sheaf.app"
dmg="$out/Sheaf-$version.dmg"
rm -rf "$out"
mkdir -p "$out"

xcodegen generate --quiet
Scripts/make-help.py > /dev/null

if [ -n "${DEVELOPER_ID:-}" ]; then
    : "${TEAM_ID:?Set TEAM_ID to your Apple developer team}"
    signing="CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=$TEAM_ID"
    identity="$DEVELOPER_ID"
else
    echo "No DEVELOPER_ID given: signing to run locally, and skipping notarization."
    signing="CODE_SIGN_STYLE=Automatic"
    identity="-"
fi

# shellcheck disable=SC2086
xcodebuild -project Sheaf.xcodeproj -scheme Sheaf -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$archive" -derivedDataPath build archive -quiet \
    CODE_SIGN_IDENTITY="$identity" $signing OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime"
cp -R "$archive/Products/Applications/Sheaf.app" "$app"
codesign --verify --deep --strict "$app"

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "${NOTARY_PROFILE:?Set NOTARY_PROFILE; see the top of this script}" --wait
}

if [ -n "${DEVELOPER_ID:-}" ]; then
    # The app first, so the ticket can be stapled to it before it goes into the image.
    ditto -c -k --keepParent "$app" "$out/Sheaf.zip"
    notarize "$out/Sheaf.zip"
    xcrun stapler staple "$app"
    rm "$out/Sheaf.zip"
fi

# A disk image with the app and a shortcut to Applications to drag it onto.
stage="$out/image"
mkdir -p "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Sheaf $version" -srcfolder "$stage" -ov -format UDZO -quiet "$dmg"
rm -rf "$stage"

if [ -n "${DEVELOPER_ID:-}" ]; then
    codesign --sign "$DEVELOPER_ID" --timestamp "$dmg"
    notarize "$dmg"
    xcrun stapler staple "$dmg"
    spctl --assess --type open --context context:primary-signature -v "$dmg"
fi

echo "Built $dmg"
