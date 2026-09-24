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

echo "==> 完成：$OUTPUT"
ls "$OUTPUT"
