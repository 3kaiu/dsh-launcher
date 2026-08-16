#!/usr/bin/env bash
set -euo pipefail
# 构建 DeepSeek Harness Launcher.app(macOS 菜单栏 App)+ 发布包
# 用法: bash scripts/build-app.sh [版本]   (默认 0.1.0,CI 传 tag 版本)
# 产物: dist/dsh-launcher-macos-<版本>.zip + SHA256SUMS.txt
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-${VERSION:-0.1.0}}"
APP_NAME="DShLauncher"
APP_BUNDLE_NAME="DeepSeek Harness Launcher.app"
DIST="$ROOT/dist"
STAGE="$DIST/dsh-launcher-macos-$VERSION"

rm -rf "$DIST"
mkdir -p "$STAGE/$APP_BUNDLE_NAME/Contents/MacOS" \
         "$STAGE/$APP_BUNDLE_NAME/Contents/Resources" \
         "$DIST/icon.iconset"

echo "== swift build (release) =="
(cd "$ROOT/app" && swift build -c release)

echo "== 组装 .app =="
cp "$ROOT/app/.build/release/$APP_NAME" "$STAGE/$APP_BUNDLE_NAME/Contents/MacOS/"
cp "$ROOT/dshctl" "$STAGE/$APP_BUNDLE_NAME/Contents/Resources/dshctl"
chmod +x "$STAGE/$APP_BUNDLE_NAME/Contents/Resources/dshctl"

echo "== 生成图标 =="
node "$ROOT/tools/gen-icon.mjs" "$DIST/icon-1024.png"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$DIST/icon-1024.png" --out "$DIST/icon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" "$DIST/icon-1024.png" --out "$DIST/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$DIST/icon.iconset" -o "$STAGE/$APP_BUNDLE_NAME/Contents/Resources/AppIcon.icns"

echo "== Info.plist =="
cat > "$STAGE/$APP_BUNDLE_NAME/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DeepSeek Harness Launcher</string>
  <key>CFBundleDisplayName</key><string>DeepSeek Harness</string>
  <key>CFBundleIdentifier</key><string>dev.dsh.launcher</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "== 签名 (ad-hoc) =="
codesign --force --deep -s - "$STAGE/$APP_BUNDLE_NAME"

echo "== 打包发布目录 =="
cp "$ROOT/dshctl" "$STAGE/dshctl"
cp "$ROOT/scripts/install.sh" "$STAGE/install.sh"
cp "$ROOT/README.md" "$STAGE/README.md"
cp -R "$ROOT/docs" "$STAGE/docs"
chmod +x "$STAGE/dshctl" "$STAGE/install.sh"
(cd "$DIST" && zip -qry "dsh-launcher-macos-$VERSION.zip" "dsh-launcher-macos-$VERSION")
(cd "$DIST" && shasum -a 256 "dsh-launcher-macos-$VERSION.zip" > SHA256SUMS.txt)

echo "== 完成 =="
ls -lh "$DIST"
echo "发布包: $DIST/dsh-launcher-macos-$VERSION.zip"
