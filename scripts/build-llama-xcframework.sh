#!/usr/bin/env bash
#
# 构建 llama.xcframework 并放进 Vendor/。
#
# 为什么从源码编而不是下官方 release：
#   1. Qwen3.5 是 Gated DeltaNet 混合架构，只有较新的 llama.cpp 才有对应算子，老版本会直接
#      在加载 GGUF 时报 unknown architecture；
#   2. 官方 release 的资产里不含 iOS 的 xcframework。
#
# 只编 iOS 的两个 slice（真机 + 模拟器），跳过 macOS/visionOS/tvOS —— 能省一半以上时间。
# 产物按 LLAMA_REF 缓存，日常开发只会编一次。
#
#   ./scripts/build-llama-xcframework.sh
#
set -euo pipefail

# 固定版本，别用 master：上游 API 变动频繁，浮动引用会让构建随机挂掉。
# 升级步骤：改这里 → 跑一次本脚本 → 按 include/llama.h 的 diff 修 LlamaBridge.swift。
LLAMA_REF="${LLAMA_REF:-b11158}"

# 着色器在构建期编好，不要留到运行时。
#
# 上游默认 ON，而这个开关的名字有误导性：ON 是把 Metal **源码**嵌进二进制，
# 首次运行再调 newLibraryWithSource 现场编译几百个 kernel —— 在手机 GPU 上从头编
# 一遍，装完第一次要等好几分钟，界面就停在「Preparing the GPU」一动不动。
# 编完进系统着色器缓存，所以第二次开就是秒进。
#
# OFF 让 cmake 在构建期产出 default.metallib，上游脚本会把它拷进 framework，
# 运行时直接加载。前提是那个文件真的能跟着进 app 包 —— project.yml 里
# llama.xcframework 是 embed: true，所以能。下面会校验，拷丢了就当场失败，
# 而不是等到装到手机上才发现 Metal 起不来。
export GGML_METAL_EMBED_LIBRARY="${GGML_METAL_EMBED_LIBRARY:-OFF}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$ROOT/.build}"
SOURCE_DIR="$WORK_DIR/llama.cpp-$LLAMA_REF"
OUTPUT="$ROOT/Vendor/llama.xcframework"

if [[ -d "$OUTPUT" && -z "${FORCE_REBUILD:-}" ]]; then
    echo "==> Vendor/llama.xcframework 已存在，跳过构建（FORCE_REBUILD=1 可强制重建）"
    exit 0
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "==> 拉取 llama.cpp @ $LLAMA_REF"
    mkdir -p "$WORK_DIR"
    git clone --depth 1 --branch "$LLAMA_REF" https://github.com/ggml-org/llama.cpp "$SOURCE_DIR"
fi

echo "==> 构建 iOS xcframework（真机 + 模拟器）"
pushd "$SOURCE_DIR" >/dev/null
./build-xcframework.sh ios-sim ios-device
popd >/dev/null

echo "==> 安装到 Vendor/"
mkdir -p "$ROOT/Vendor"
rm -rf "$OUTPUT"
cp -R "$SOURCE_DIR/build-apple/llama.xcframework" "$OUTPUT"

if [[ "$GGML_METAL_EMBED_LIBRARY" == "OFF" ]]; then
    echo "==> 校验 default.metallib 是否在 framework 里"
    if ! find "$OUTPUT" -name '*.metallib' -print -quit | grep -q .; then
        echo "错误：EMBED_LIBRARY=OFF 但 framework 里没有 .metallib。" >&2
        echo "      运行时会找不到着色器，Metal 后端起不来 —— 这里就停，别让它上机器。" >&2
        exit 1
    fi
    find "$OUTPUT" -name '*.metallib'
fi

echo "==> 完成：$OUTPUT"
ls "$OUTPUT"
