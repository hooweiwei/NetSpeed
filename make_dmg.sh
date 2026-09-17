#!/bin/bash
# 打包 NetSpeed 为 .dmg 安装镜像（含"拖到 Applications"布局）
# 用法: ./make_dmg.sh [arm64|x86_64|universal]   （默认 arm64）
# 产物: dist/release/NetSpeed-<版本>-<arch>.dmg（版本号取自构建产物 Info.plist）
# 依赖: 已用 ./build.sh <arch> 构建出对应 .app
set -euo pipefail
cd "$(dirname "$0")"

ARCH="${1:-arm64}"
APP="dist/$ARCH/NetSpeed.app"
[ -d "$APP" ] || { echo "未找到 ${APP}，请先执行 ./build.sh $ARCH"; exit 1; }

RELEASE="dist/release"
mkdir -p "$RELEASE"
# 版本号以构建产物内的 Info.plist 为准（由 build.sh 从 git tag 写入），避免两处各算一套
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0)"
DMG="$RELEASE/NetSpeed-$VERSION-$ARCH.dmg"
STAGE=".dmg_staging"

echo "==> 准备 DMG 内容（${APP}）"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> 生成压缩 DMG（hdiutil UDZO）"
rm -f "$DMG"
hdiutil create -volname "NetSpeed" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

rm -rf "$STAGE"
echo "完成 ✓  $DMG"
