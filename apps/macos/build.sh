#!/bin/sh
# ============================================================================
# iFolo macOS build script
#
# No Xcode project, no SwiftPM -- one script produces a runnable .app
#
# Usage:
#   ./build.sh             build
#   ./build.sh --run       build and launch
# ============================================================================
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../.." && pwd)"
APP="$ROOT/build/iFolo.app"
SWIFTC="$(command -v swiftc || echo /usr/bin/swiftc)"
ARCH="$(uname -m)"
TARGET_OS="macos14.0"
SHOULD_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --arch)
      ARCH="$2"
      shift 2
      ;;
    --out)
      APP="$2"
      shift 2
      ;;
    --run)
      SHOULD_RUN=1
      shift
      ;;
    *)
      shift
      ;;
  esac
done

echo "[1/5] compiling Swift ($ARCH $TARGET_OS)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# -parse-as-library: required by @main; entry file must not be named main.swift
#                    (it is App.swift)
# -disable-sandbox: SwiftUI macro plugin gets sandbox-exec'd and fails; we use
#                   plain AppKit today but keep it in case SwiftUI arrives later
"$SWIFTC" -O -swift-version 5 -parse-as-library -disable-sandbox \
  -target "$ARCH-apple-$TARGET_OS" \
  -F "$ROOT/Frameworks" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -framework AppKit -framework WebKit -framework Carbon -framework NaturalLanguage -framework LocalAuthentication -framework CryptoKit -framework Security \
  "$ROOT"/Sources/*.swift -o "$APP/Contents/MacOS/iFolo"
echo "[2/5] writing Info.plist"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
for lproj in "$ROOT"/Resources/*.lproj; do
  if [ -d "$lproj" ]; then
    cp -R "$lproj" "$APP/Contents/Resources/"
  fi
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "[3/5] embedding editor bundle"
EDITOR_DIST="$REPO/packages/editor/dist"
if [ ! -f "$EDITOR_DIST/index.html" ]; then
  echo "editor bundle missing -- run pnpm build first" >&2
  exit 1
fi
mkdir -p "$APP/Contents/Resources/editor"
# 注意 /. —— 否则 cp 会把 dist 目录本身塞进去，得到 editor/dist/index.html
cp -R "$EDITOR_DIST/." "$APP/Contents/Resources/editor/"

echo "[3.5/5] embedding frameworks"
mkdir -p "$APP/Contents/Frameworks"
cp -R "$ROOT/Frameworks/Sparkle.framework" "$APP/Contents/Frameworks/"

SIGN_IDENTITY=\"-\"
if security find-identity -v -p codesigning 2>/dev/null | grep -q 'Apple Development:'; then
  DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep 'Apple Development:' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
  if [ -n "$DEV_ID" ]; then
    SIGN_IDENTITY="$DEV_ID"
    echo "[4/5] signing with '$SIGN_IDENTITY'"
  else
    echo "[4/5] signing (ad-hoc fallback)"
  fi
else
  echo "[4/5] signing (ad-hoc fallback)"
fi

codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/org.sparkle-project.Downloader.xpc" 2>/dev/null || true
codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/org.sparkle-project.InstallerConnection.xpc" 2>/dev/null || true
codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/org.sparkle-project.InstallerStatus.xpc" 2>/dev/null || true
codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate.app" 2>/dev/null || true
codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework" 2>/dev/null || true
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" 2>&1 | head -3 || true
echo "[5/5] done"
SIZE=$(du -sh "$APP" | cut -f1)
echo "$APP ($SIZE)"

if [ "$SHOULD_RUN" = "1" ]; then
  echo "launching..."
  open "$APP"
fi
