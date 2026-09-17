#!/bin/bash
# 一键产出 GitHub 发布物：编译两个架构 + zip + dmg + SHA256 校验和
# 用法: ./package_release.sh
# 产物: dist/release/ 下
#   NetSpeed-arm64.zip  NetSpeed-x86_64.zip      （直接解压可用，分发首选）
#   NetSpeed-arm64.dmg  NetSpeed-x86_64.dmg      （安装镜像）
#   SHA256SUMS.txt
set -euo pipefail
cd "$(dirname "$0")"

./build.sh all

RELEASE="dist/release"
mkdir -p "$RELEASE"

for arch in arm64 x86_64; do
    echo "==> 打包 $arch zip"
    rm -f "$RELEASE/NetSpeed-$arch.zip"
    ditto -c -k --keepParent "dist/$arch/NetSpeed.app" "$RELEASE/NetSpeed-$arch.zip"
    echo "==> 生成 $arch dmg"
    ./make_dmg.sh "$arch"
done

echo "==> 生成 SHA256SUMS.txt"
cd "$RELEASE"
shasum -a 256 NetSpeed-*.zip NetSpeed-*.dmg > SHA256SUMS.txt
cat SHA256SUMS.txt
cd ..

echo "发布物就绪 ✓  $RELEASE/"
