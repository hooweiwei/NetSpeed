#!/bin/bash
# 编译 NetSpeed 菜单栏网速小应用（Swift，无 Xcode）
# 用法: ./build.sh
# 依赖: macOS + Xcode Command Line Tools（swiftc、codesign、iconutil）
set -euo pipefail
cd "$(dirname "$0")"

echo "==> 编译 main.swift (swiftc -O)"
swiftc -O -o NetSpeed main.swift

APP="NetSpeed.app"
echo "==> 组装应用包 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp NetSpeed "$APP/Contents/MacOS/NetSpeed"
cp Info.plist "$APP/Contents/Info.plist"

# 图标：从仓库内的 iconset 源生成 icns（保证与素材一致，产物不提交）
if [ ! -f AppIcon.icns ]; then
    echo "==> 由 Assets/AppIcon.iconset 生成 AppIcon.icns"
    iconutil -c icns Assets/AppIcon.iconset -o AppIcon.icns
fi
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> ad-hoc 签名"
codesign --force -s - "$APP"

echo "构建完成: $(pwd)/$APP"
