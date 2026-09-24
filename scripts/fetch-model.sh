#!/usr/bin/env bash
#
# 把模型权重下载到 Resources/Model/，供打包进 app bundle。
#
# 权重不进 git：507 MB 远超 GitHub 的单文件上限，用 LFS 也会很快吃光免费配额。
# 仓库里只留这个脚本，CI 构建时现拉一份（有缓存，平时不会真的下载）。
#
#   ./scripts/fetch-model.sh
#
set -euo pipefail

MODEL_REPO="unsloth/Qwen3.5-0.8B-GGUF"
MODEL_FILE="Qwen3.5-0.8B-Q4_K_M.gguf"
EXPECTED_BYTES=532517120

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="$ROOT/Resources/Model"
DEST="$DEST_DIR/$MODEL_FILE"
URL="https://huggingface.co/$MODEL_REPO/resolve/main/$MODEL_FILE?download=true"

file_size() {
    # macOS 和 Linux 的 stat 参数不一样。
    stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0
}

if [[ -f "$DEST" ]]; then
    actual=$(file_size "$DEST")
    if [[ "$actual" == "$EXPECTED_BYTES" ]]; then
        echo "==> 模型已就位：$DEST"
        exit 0
    fi
    echo "==> 已有文件大小不符（$actual ≠ $EXPECTED_BYTES），重新下载"
    rm -f "$DEST"
fi

mkdir -p "$DEST_DIR"
echo "==> 下载 $MODEL_FILE（约 507 MB）"
# -C - 断点续传，--retry 扛一下 HuggingFace 偶发的连接中断。
curl -fL --retry 3 --retry-delay 2 -C - -o "$DEST" "$URL"

actual=$(file_size "$DEST")
if [[ "$actual" != "$EXPECTED_BYTES" ]]; then
    echo "::error::下载的文件大小不对：$actual ≠ $EXPECTED_BYTES" >&2
    rm -f "$DEST"
    exit 1
fi

# GGUF 魔数。大小对得上但内容是错误页的情况见过不止一次。
magic=$(head -c 4 "$DEST")
if [[ "$magic" != "GGUF" ]]; then
    echo "::error::文件头不是 GGUF，拿到的可能是一个错误页" >&2
    rm -f "$DEST"
    exit 1
fi

echo "==> 完成：$DEST"
