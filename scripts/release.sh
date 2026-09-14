#!/bin/zsh
# Cuts a release: universal build, Developer ID signature, notarization, a zip (for Homebrew) and a disk image (for
# people) on a GitHub release, and the Homebrew cask bumped to match.
#   scripts/release.sh                 → everything, for the version in Resources/Info.plist
#   scripts/release.sh --skip-notarize → sign and package without notarizing (Gatekeeper will complain; for testing)
#   scripts/release.sh --dry-run       → build, sign, notarize and package (build/Burn.zip, build/Burn.dmg), but no
#                                        GitHub release and no tap push — the way to make a build to hand to someone
# Needs once: `xcrun notarytool store-credentials burn-notary --apple-id <id> --team-id Y5V8Y3BH9A --password <app-specific>`
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARIZE=1
PUBLISH=1
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) NOTARIZE=0 ;;
    --dry-run) PUBLISH=0 ;;
  esac
done

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
TAG="v$VERSION"
ZIP="build/Burn.zip"   # constant names, so releases/latest/download/Burn.zip and Burn.dmg always work
DMG="build/Burn.dmg"
DEVELOPER_ID="${BURN_DEVELOPER_ID:-Developer ID Application: Thomas Massaro (Y5V8Y3BH9A)}"
NOTARY_PROFILE="${BURN_NOTARY_PROFILE:-burn-notary}"
TAP_REPO="${BURN_TAP_REPO:-tmass1/homebrew-tap}"
RELEASE_REPO="${BURN_RELEASE_REPO:-tmass1/burn}"

echo "→ Burn $VERSION"
if [[ $PUBLISH -eq 1 ]] && gh release view "$TAG" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
  echo "release $TAG already exists — bump CFBundleShortVersionString first"; exit 1
fi
# Fail before the build if the notarization credential isn't there.
if [[ $NOTARIZE -eq 1 ]] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "no notarization credential '$NOTARY_PROFILE' — run:"
  echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple id> --team-id Y5V8Y3BH9A"
  exit 1
fi

# 1. Build both architectures and sign with the Developer ID certificate (hardened runtime, secure timestamp).
BURN_SIGN_IDENTITY="$DEVELOPER_ID" scripts/bundle.sh --universal
codesign --verify --deep --strict build/Burn.app
lipo -archs build/Burn.app/Contents/MacOS/Burn
codesign -dv --verbose=2 build/Burn.app 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier" | head -2

# 2. Notarize the zipped app, staple the ticket to the app, then zip again for distribution.
rm -f "$ZIP"
ditto -c -k --keepParent build/Burn.app "$ZIP"
if [[ $NOTARIZE -eq 1 ]]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple build/Burn.app
  rm -f "$ZIP"
  ditto -c -k --keepParent build/Burn.app "$ZIP"
  spctl -a -vv -t exec build/Burn.app 2>&1 | tail -2
else
  echo "(not notarized)"
fi
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "→ $ZIP  sha256 $SHA"

# 3. The disk image: the (stapled) app beside an Applications link, signed and notarized in its own right so it
# opens cleanly offline too.
STAGE=$(mktemp -d)
cp -R build/Burn.app "$STAGE/Burn.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Burn" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov -quiet "$DMG"
rm -rf "$STAGE"
codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"
if [[ $NOTARIZE -eq 1 ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 | tail -1
fi
echo "→ $DMG  $(du -h "$DMG" | cut -f1)"

[[ $PUBLISH -eq 1 ]] || { echo "dry run — stopping before the GitHub release and the tap"; exit 0; }

# 4. The GitHub release: the zip and the disk image, with docs/releases/<version>.md as the notes when there is one,
# else the commit subjects since the previous tag.
NOTES_FILE="docs/releases/$VERSION.md"
if [[ -f "$NOTES_FILE" ]]; then
  gh release create "$TAG" "$ZIP" "$DMG" --repo "$RELEASE_REPO" --title "Burn $VERSION" --notes-file "$NOTES_FILE"
else
  PREV=$(git describe --tags --abbrev=0 2>/dev/null || true)
  NOTES=$(git log --pretty='- %s' ${PREV:+$PREV..}HEAD | grep -v "Co-Authored-By" | head -40)
  gh release create "$TAG" "$ZIP" "$DMG" --repo "$RELEASE_REPO" --title "Burn $VERSION" --notes "$NOTES"
fi

# 5. The cask: version and checksum, in the tap (Homebrew takes the zip).
TAP_DIR=$(mktemp -d)
gh repo clone "$TAP_REPO" "$TAP_DIR" -- --quiet
mkdir -p "$TAP_DIR/Casks"
cat > "$TAP_DIR/Casks/burn.rb" <<CASK
cask "burn" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$RELEASE_REPO/releases/download/v#{version}/Burn.zip"
  name "Burn"
  desc "Menu-bar meter for AI plan limits: Claude, ChatGPT, Grok, Gemini, Cursor and Copilot"
  homepage "https://github.com/$RELEASE_REPO"

  depends_on macos: ">= :sonoma"

  app "Burn.app"
  binary "#{appdir}/Burn.app/Contents/Resources/burn"

  zap trash: [
    "~/Library/Application Support/Burn",
    "~/Library/Preferences/com.tommymassaro.burn.plist",
  ]
end
CASK
git -C "$TAP_DIR" add Casks/burn.rb
git -C "$TAP_DIR" commit -q -m "burn $VERSION" || true
git -C "$TAP_DIR" push -q
rm -rf "$TAP_DIR"
echo "→ released $TAG; brew install --cask ${TAP_REPO/homebrew-/}/burn"
