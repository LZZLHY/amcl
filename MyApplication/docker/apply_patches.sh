#!/bin/bash
# apply_patches.sh — 通用 patch series 应用器
#
# 两种调用形式（向后兼容）：
#
#   旧形式（docker/build_jdk17_ohos.sh 仍在用）：
#     apply_patches.sh <jdk-version> <jdk-source-dir>
#     # 例: apply_patches.sh jdk17u /build/jdk17u
#     # 从 docker/patches/<jdk-version>/series 读 patch list
#
#   新形式（推荐，可对任意依赖使用）：
#     apply_patches.sh --patch-dir <patch-dir> --target <source-dir>
#     # 例: apply_patches.sh --patch-dir prebuilt/openal-soft/patches \
#     #                      --target entry/src/main/cpp/openal/openal-soft
#     # 从 <patch-dir>/series 读 patch list
#
# series 文件格式：
#   - 每行一个 .patch 文件名（相对 <patch-dir>）
#   - 以 # 开头为注释；空行跳过
#
# 应用方式：cd <target> && git apply [--3way] <patch>

set -euo pipefail

PATCH_DIR=""
TARGET=""
JDK_VERSION=""

# 解析参数
while [ $# -gt 0 ]; do
    case "$1" in
        --patch-dir)
            PATCH_DIR="$2"; shift 2 ;;
        --target)
            TARGET="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,21p' "$0"; exit 0 ;;
        *)
            # 旧形式：positional <jdk-version> <jdk-source-dir>
            if [ -z "$JDK_VERSION" ]; then
                JDK_VERSION="$1"
            elif [ -z "$TARGET" ]; then
                TARGET="$1"
            else
                echo "Unknown argument: $1" >&2; exit 1
            fi
            shift ;;
    esac
done

# 旧形式 → 推导 PATCH_DIR
if [ -z "$PATCH_DIR" ] && [ -n "$JDK_VERSION" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    PATCH_DIR="${SCRIPT_DIR}/patches/${JDK_VERSION}"
fi

# 校验
if [ -z "$PATCH_DIR" ] || [ -z "$TARGET" ]; then
    echo "Usage:" >&2
    echo "  apply_patches.sh <jdk-version> <source-dir>            (legacy)" >&2
    echo "  apply_patches.sh --patch-dir <dir> --target <src-dir>  (preferred)" >&2
    exit 1
fi

# 转为绝对路径，cd 到 target 后仍然能找到 patches
PATCH_DIR=$(cd "$PATCH_DIR" 2>/dev/null && pwd) || {
    echo "ERROR: patch dir not found: $PATCH_DIR" >&2; exit 1; }
TARGET=$(cd "$TARGET" 2>/dev/null && pwd) || {
    echo "ERROR: target source dir not found: $TARGET" >&2; exit 1; }

if [ ! -f "${PATCH_DIR}/series" ]; then
    echo "ERROR: ${PATCH_DIR}/series not found" >&2
    exit 1
fi

echo "=== Applying patches ==="
echo "  patch-dir: $PATCH_DIR"
echo "  target:    $TARGET"
echo ""

# Prevent git from discovering a parent repository when TARGET is a vendored
# source tree without its own .git directory. Otherwise `git apply` resolves
# patch paths from the parent repository root and can silently ignore every
# hunk while returning success. A real repository rooted at TARGET is still
# discovered because Git checks the current directory before the ceiling.
TARGET_PARENT="$(dirname "$TARGET")"
export GIT_CEILING_DIRECTORIES="${GIT_CEILING_DIRECTORIES:+${GIT_CEILING_DIRECTORIES}:}${TARGET_PARENT}"

# 切到 target 目录后应用补丁；路径始终相对 target 解析。
cd "$TARGET"

APPLIED=0
FAILED=0
TOTAL=0

while IFS= read -r line; do
    # strip CRLF (Windows-edited series files)
    line="${line%$'\r'}"
    # 跳过注释和空行
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    TOTAL=$((TOTAL + 1))

    PATCH_FILE="${PATCH_DIR}/${line}"
    printf "  [%d] %-50s ... " "$TOTAL" "$line"

    if [ ! -f "$PATCH_FILE" ]; then
        echo "NOT FOUND"
        FAILED=$((FAILED + 1))
        continue
    fi

    # CRLF tolerance: if patch file is CRLF, normalise into a tmp copy.
    # git apply doesn't tolerate CR in context lines when source is LF.
    APPLY_PATCH="$PATCH_FILE"
    if head -1 "$PATCH_FILE" | grep -q $'\r$'; then
        TMP_PATCH=$(mktemp)
        sed 's/\r$//' "$PATCH_FILE" > "$TMP_PATCH"
        APPLY_PATCH="$TMP_PATCH"
    fi

    # 已经应用过的 patch 不重复应用（reverse-check）
    if git apply --reverse --check "$APPLY_PATCH" >/dev/null 2>&1 || \
       git apply --reverse --ignore-whitespace --check "$APPLY_PATCH" >/dev/null 2>&1; then
        echo "ALREADY APPLIED"
        APPLIED=$((APPLIED + 1))
        [ -n "${TMP_PATCH:-}" ] && rm -f "$TMP_PATCH" && unset TMP_PATCH
        continue
    fi

    if git apply --check "$APPLY_PATCH" >/dev/null 2>&1; then
        git apply "$APPLY_PATCH"
        echo "OK"
        APPLIED=$((APPLIED + 1))
    elif git apply --3way --check "$APPLY_PATCH" >/dev/null 2>&1; then
        git apply --3way "$APPLY_PATCH"
        echo "OK (3way)"
        APPLIED=$((APPLIED + 1))
    elif git apply --ignore-whitespace --check "$APPLY_PATCH" >/dev/null 2>&1; then
        git apply --ignore-whitespace "$APPLY_PATCH"
        echo "OK (ignore-whitespace)"
        APPLIED=$((APPLIED + 1))
    else
        echo "FAILED"
        echo "    Patch does not apply cleanly. Source has likely diverged from upstream."
        echo "    Tried: git apply --check / git apply --3way --check"
        FAILED=$((FAILED + 1))
    fi
    [ -n "${TMP_PATCH:-}" ] && rm -f "$TMP_PATCH" && unset TMP_PATCH
done < "${PATCH_DIR}/series"

echo ""
if [ "$FAILED" -gt 0 ]; then
    echo "=== FAIL: $APPLIED/$TOTAL applied, $FAILED FAILED ==="
    exit 1
fi
echo "=== OK: $APPLIED/$TOTAL applied ==="
