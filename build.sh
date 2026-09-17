#!/bin/bash
# 编译 NetSpeed 菜单栏网速小应用（Swift，无 Xcode）
# 用法: ./build.sh [arm64|x86_64|universal|all]   （默认 arm64）
# 产物: dist/<arch>/NetSpeed.app
# 依赖: macOS + Xcode Command Line Tools（swiftc、lipo、codesign、iconutil）
set -euo pipefail
cd "$(dirname "$0")"

ARCH="${1:-arm64}"
ICON="AppIcon.icns"

# 图标：仓库内 icns 为准（与 Assets/AppIcon.iconset 同源）。
# 更新图标流程：替换 AppIcon.icns 后执行
#   iconutil -c iconset AppIcon.icns -o Assets/AppIcon.iconset
if [ ! -f "$ICON" ]; then
    echo "==> 缺少 $ICON，由 Assets/AppIcon.iconset 生成"
    iconutil -c icns Assets/AppIcon.iconset -o "$ICON"
fi

assemble_app() {  # $1=二进制路径  $2=输出 .app 目录
    local bin="$1" out="$2"
    rm -rf "$out"
    mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
    cp "$bin" "$out/Contents/MacOS/NetSpeed"
    cp Info.plist "$out/Contents/Info.plist"
    cp "$ICON" "$out/Contents/Resources/AppIcon.icns"
    codesign --force -s - "$out"
}

build_one() {  # $1=arm64|x86_64
    local arch="$1"
    local target="${arch}-apple-macos12.0"
    mkdir -p .build
    echo "==> 编译 $arch (swiftc -O -target $target)"
    swiftc -O -target "$target" -o ".build/NetSpeed-$arch" main.swift
    assemble_app ".build/NetSpeed-$arch" "dist/$arch/NetSpeed.app"
    echo "    产物: dist/$arch/NetSpeed.app"
}

build_universal() {
    echo "==> 合并 universal (lipo)"
    lipo -create ".build/NetSpeed-arm64" ".build/NetSpeed-x86_64" -output ".build/NetSpeed-universal"
    assemble_app ".build/NetSpeed-universal" "dist/universal/NetSpeed.app"
    echo "    产物: dist/universal/NetSpeed.app"
}

mkdir -p .build dist
case "$ARCH" in
    arm64|x86_64)      build_one "$ARCH" ;;
    universal|all)     build_one arm64; build_one x86_64; build_universal ;;
    *) echo "未知架构: $ARCH（支持 arm64 | x86_64 | universal | all）"; exit 1 ;;
esac

echo "构建完成 ✓"
