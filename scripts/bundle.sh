#!/bin/zsh
# Builds Burn.app from the SwiftPM product. No Xcode project needed.
#   scripts/bundle.sh            → build/Burn.app (release)
#   scripts/bundle.sh --debug    → faster incremental build for iterating
#   scripts/bundle.sh --install  → also copies to /Applications and relaunches
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
INSTALL=0
ARCHS=()
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --install) INSTALL=1 ;;
    --universal) ARCHS=(--arch arm64 --arch x86_64) ;;   # for releases: one binary for both Mac families
  esac
done

# Stable signing identity (certificate SHA-1; the name is ambiguous with two certs) so macOS treats every rebuild as the
# same app: keychain grants, the login item and the URL scheme all key off the signature.
SIGN_IDENTITY="${BURN_SIGN_IDENTITY:-D571DD22F1D1235F02C6F94AD31B5C3A7A1AF6FC}"  # Apple Development cert, valid to Sep 2027
if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
  echo "Signing identity not found, falling back to ad-hoc (keychain prompts may repeat between builds)"
  SIGN_IDENTITY="-"
fi

# The repo lives in Dropbox; the toolchain cache and app bundle must not sync (slow, and useless on another Mac).
mkdir -p .build build
xattr -w com.dropbox.ignored 1 .build build 2>/dev/null || true

if ! swift build -c "$CONFIG" "${ARCHS[@]}" 2>&1 | grep -vE '^\[|warning: .*unhandled files'; then :; fi
[[ ${pipestatus[1]} -eq 0 ]] || { echo "build failed"; exit 1; }
BIN="$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)/Burn"
[[ -x "$BIN" ]] || { echo "build failed: $BIN missing"; exit 1; }

APP=build/Burn.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Burn"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/burn-midnight.svg Resources/burn-porcelain.svg "$APP/Contents/Resources/"
# The command-line tool as a script inside the bundle, so Homebrew (and anyone) can put `burn` on PATH by symlink.
printf '#!/bin/sh\n# Burn'"'"'s command-line tool: the app binary in CLI mode.\nexec "$(cd "$(dirname "$0")/../MacOS" && pwd)/Burn" cli "$@"\n' > "$APP/Contents/Resources/burn"
chmod 755 "$APP/Contents/Resources/burn"
# SwiftPM resource bundles (KeyboardShortcuts localizations) live beside the binary; ship them.
for bundle in "$(dirname "$BIN")"/*.bundle; do
  [[ -d "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done
codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP" 2>&1 | grep -v "replacing existing signature" || true
echo "built $APP"

if [[ $INSTALL -eq 1 ]]; then
  pkill -x Burn 2>/dev/null || true
  # The app was called Headroom until 2.0; retire that copy so only one of them polls (Burn migrates its settings).
  pkill -x Headroom 2>/dev/null || true
  rm -rf /Applications/Headroom.app
  rm -rf /Applications/Burn.app
  cp -R "$APP" /Applications/Burn.app
  open /Applications/Burn.app
  echo "installed and launched /Applications/Burn.app"
  # The command-line tool: a wrapper that runs the installed binary in CLI mode (Settings → General does the same).
  mkdir -p ~/.local/bin
  printf '#!/bin/sh\n# Installed by Burn — the app'"'"'s command-line tool. Reinstall from Settings → General if the app moves.\nexec "/Applications/Burn.app/Contents/MacOS/Burn" cli "$@"\n' > ~/.local/bin/burn
  chmod 755 ~/.local/bin/burn
  grep -q "Installed by Headroom" ~/.local/bin/headroom 2>/dev/null && rm -f ~/.local/bin/headroom
  echo "installed ~/.local/bin/burn"
fi
