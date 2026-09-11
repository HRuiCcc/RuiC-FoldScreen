#!/usr/bin/env bash
#
# Builds RuiC-FoldScreen.app using only the Xcode command line tools.
#
# There is no Xcode project here on purpose. The original approach needs Xcode
# for three things this app does not: the Metal compiler, a SwiftPM dependency,
# and the project file itself. The shader is compiled by the GPU at runtime, the
# single external dependency was dropped, and the bundle is assembled by hand —
# so `swiftc` plus the macOS SDK is the whole toolchain.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="RuiC-FoldScreen"
BUNDLE_ID="app.ruic.foldscreen"
BUILD_DIR="$ROOT/build"
APP="$ROOT/dist/$APP_NAME.app"
DEPLOYMENT_TARGET="14.0"
ARCH="$(uname -m)"

say() { printf '\033[1;36m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# --- Checks -------------------------------------------------------------------

command -v swiftc >/dev/null 2>&1 || fail "swiftc not found. Install the Xcode command line tools: xcode-select --install"
SDK_PATH="$(xcrun --show-sdk-path 2>/dev/null)" || fail "cannot locate the macOS SDK"
[ -d "$SDK_PATH" ] || fail "macOS SDK missing at $SDK_PATH"

# Metal shaders are compiled at runtime, so the offline compiler is not needed.
# Warn only, because the app genuinely builds without Xcode.
if ! xcrun -f metal >/dev/null 2>&1; then
  say "offline Metal compiler not present — fine, the shader is compiled at runtime"
fi

# --- Shader -------------------------------------------------------------------

say "embedding Shaders/Fold.metal"
python3 "$ROOT/Tools/embed_shader.py" || fail "shader embedding failed"

# --- Icon ---------------------------------------------------------------------

mkdir -p "$BUILD_DIR"
if [ ! -f "$BUILD_DIR/AppIcon.icns" ] || [ "$ROOT/Tools/MakeIcon.swift" -nt "$BUILD_DIR/AppIcon.icns" ]; then
  say "drawing the app icon"
  swift "$ROOT/Tools/MakeIcon.swift" "$BUILD_DIR" >/dev/null || fail "icon generation failed"
else
  say "reusing the cached app icon"
fi

# --- Compile ------------------------------------------------------------------

say "compiling Swift sources"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(
  find "$ROOT/Sources" "$ROOT/Generated" -name '*.swift' -print | sort
)
[ "${#SOURCES[@]}" -gt 0 ] || fail "no Swift sources found"

swiftc \
  -swift-version 5 \
  -O \
  -target "${ARCH}-apple-macos${DEPLOYMENT_TARGET}" \
  -sdk "$SDK_PATH" \
  -framework AppKit \
  -framework SwiftUI \
  -framework Combine \
  -framework Metal \
  -framework MetalKit \
  -framework MetalPerformanceShaders \
  -framework ScreenCaptureKit \
  -framework CoreVideo \
  -framework CoreMedia \
  -framework CoreGraphics \
  -framework ImageIO \
  -framework IOKit \
  -framework Carbon \
  -framework ServiceManagement \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  "${SOURCES[@]}"

# --- Assemble the bundle ------------------------------------------------------

say "assembling $APP_NAME.app"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail "Info.plist is malformed"

# Ad-hoc signing keeps the bundle loadable, but it keys the app's identity to a
# hash of the binary. TCC stores that hash as the app's code requirement, so every
# rebuild looks like a brand new app and the screen recording grant stops
# matching it. Prefer the stable local identity so a grant survives rebuilding;
# fall back to ad-hoc only if the keychain refuses.
SIGNING_IDENTITY="RuiC-FoldScreen Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGNING_IDENTITY"; then
  say "signing with the stable local identity"
elif "$ROOT/Tools/make-signing-identity.sh" >/dev/null 2>&1 &&
     security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGNING_IDENTITY"; then
  say "created and using the stable local identity"
else
  SIGNING_IDENTITY="-"
  say "WARNING: falling back to ad-hoc signing."
  say "         The screen recording grant will be forgotten on every rebuild."
fi

codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$APP" 2>&1 | sed 's/^/    /' ||
  fail "codesign failed"

say "built $APP"
echo
echo "  run:      open \"$APP\""
echo "  selftest: \"$APP/Contents/MacOS/$APP_NAME\" --selftest"
echo "  frames:   \"$APP/Contents/MacOS/$APP_NAME\" --render-frames ./frames --hold 0.85"
