#!/bin/bash
# 打包 NetSpeed 菜单栏应用成 .dmg 安装包（含 "拖到 Applications" 布局）
# 用法: ./make_dmg.sh
# 依赖: 已安装 Xcode Command Line Tools（swiftc、codesign、iconutil、hdiutil）
set -euo pipefail
cd "$(dirname "$0")"

APP="NetSpeed.app"
DMG="NetSpeed.dmg"
STAGE=".dmg_staging"

# 1. 若尚未构建出 .app，先从源码构建
if [ ! -d "$APP" ]; then
    echo "==> 未找到 $APP，先执行 build.sh 构建"
    ./build.sh
fi

# 2. 准备 DMG 暂存目录：放入 .app + 指向 /Applications 的"Applications"链接
echo "==> 准备 DMG 内容"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 3. 用 hdiutil 生成压缩 DMG（UDZO）
echo "==> 生成压缩 DMG（hdiutil UDZO）"
rm -f "$DMG"
hdiutil create -volname "NetSpeed" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

# 4. 清理暂存目录
rm -rf "$STAGE"

echo "=== 打包完成: $(pwd)/$DMG ==="
echo "打开方式示例:"
echo "  hdiutil attach $DMG   # 挂载"
echo "  open $DMG            # 打开并挂载（Finder 里拖 NetSpeed.app 到 Applications）"
