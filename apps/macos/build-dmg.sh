#!/bin/sh
# ============================================================================
# iFolo macOS DMG Packager
#
# Creates high-end Apple-style drag-to-Applications DMGs with Liquid Glass
# Retina background and precise icon positioning.
#
# Supports dual-architecture builds:
#   ./build-dmg.sh                build both Apple Silicon (arm64) & Intel (x86_64)
#   ./build-dmg.sh --arch arm64   build Apple Silicon DMG only
#   ./build-dmg.sh --arch x86_64  build Intel DMG only
# ============================================================================
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../.." && pwd)"
DIST="$REPO/dist"
RESOURCES="$ROOT/Resources"
BACKGROUND="$RESOURCES/dmg/background.png"
VOLUME_NAME="iFolo"

mkdir -p "$DIST"

# 1. 确保背景图已生成
if [ ! -f "$BACKGROUND" ]; then
  echo "==> 生成 Retina DMG 背景图..."
  swift "$ROOT/scripts/generate_dmg_background.swift"
fi

# 2. 确保前端 Web 产物最新
if [ ! -f "$REPO/packages/editor/dist/index.html" ]; then
  echo "==> 编译前端编辑器 bundle..."
  (cd "$REPO" && pnpm build)
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$RESOURCES/Info.plist" 2>/dev/null || echo "0.1.1")"

build_dmg_for_arch() {
  TARGET_ARCH="$1"
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "  打包 DMG [$TARGET_ARCH] - iFolo v$VERSION"
  echo "════════════════════════════════════════════════════════════════"

  TEMP_APP="$ROOT/build/iFolo-$TARGET_ARCH.app"
  DMG_OUT="$DIST/iFolo-$VERSION-$TARGET_ARCH.dmg"
  DMG_TEMP="$(mktemp -t ifolo-dmg-tmp).dmg"
  STAGING="$(mktemp -d -t ifolo-stage)"
  MOUNT_DIR="/Volumes/$VOLUME_NAME"

  # 编译指定架构的 .app
  echo "==> [1/4] 编译 iFolo.app ($TARGET_ARCH)..."
  "$ROOT/build.sh" --arch "$TARGET_ARCH" --out "$TEMP_APP"

  # 准备临时暂存目录
  echo "==> [2/4] 配置暂存区与 Applications 软链接..."
  rm -rf "$STAGING"
  mkdir -p "$STAGING/.background"
  cp -R "$TEMP_APP" "$STAGING/iFolo.app"
  ln -s /Applications "$STAGING/Applications"
  cp "$BACKGROUND" "$STAGING/.background/background.png"

  # 创建读写 DMG
  echo "==> [3/4] 挂载并注入 Finder 布局视图..."
  rm -f "$DMG_TEMP" "$DMG_OUT"
  hdiutil create \
    -srcfolder "$STAGING" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -format UDRW \
    -ov \
    "$DMG_TEMP" >/dev/null

  # 卸载可能存在的同名卷并挂载读写镜像
  hdiutil detach "$MOUNT_DIR" -force -quiet 2>/dev/null || true
  ATTACH_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_TEMP")"
  DEVICE="$(echo "$ATTACH_OUT" | awk 'NR==1{print $1}')"

  # 通过 AppleScript 设置 Finder 窗口大小、背景图与图标座坐标
  osascript <<APPLESCRIPT || true
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        set the bounds of container window to {160, 110, 800, 560} -- 640 x 450 (content 640 x 420)
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "iFolo.app" of container window to {160, 180}
        set position of item "Applications" of container window to {480, 180}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

  sync
  sleep 1

  # 卸载挂载卷
  hdiutil detach "$DEVICE" -quiet 2>/dev/null || hdiutil detach "$MOUNT_DIR" -force -quiet 2>/dev/null || true

  # 压缩为只读 UDZO 镜像
  echo "==> [4/4] 最终压缩与固化 DMG..."
  hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_OUT" >/dev/null
  rm -f "$DMG_TEMP"
  rm -rf "$STAGING" "$TEMP_APP"

  # 计算校验码与大小
  SIZE=$(du -sh "$DMG_OUT" | cut -f1)
  SHA=$(shasum -a 256 "$DMG_OUT" | cut -d' ' -f1)
  # 同步创建无版本号固定名称副本，供 GitHub Releases /latest/download 使用
  FIXED_DMG="$DIST/iFolo-$TARGET_ARCH.dmg"
  cp -f "$DMG_OUT" "$FIXED_DMG"
  echo "✓ 完成: $DMG_OUT ($SIZE)"
  echo "  固定别名: $FIXED_DMG"
  echo "  SHA256: $SHA"
}

# 模式解析
TARGET="all"
while [ $# -gt 0 ]; do
  case "$1" in
    --arch)
      TARGET="$2"
      shift 2
      ;;
    arm64|x86_64)
      TARGET="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [ "$TARGET" = "arm64" ]; then
  build_dmg_for_arch "arm64"
elif [ "$TARGET" = "x86_64" ]; then
  build_dmg_for_arch "x86_64"
else
  build_dmg_for_arch "arm64"
  build_dmg_for_arch "x86_64"
fi

echo ""
echo "🎉 所有 DMG 打包任务已完成，产物位于: $DIST"
ls -lh "$DIST"/*.dmg
