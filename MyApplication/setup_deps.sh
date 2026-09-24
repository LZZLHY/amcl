#!/bin/bash
# setup_deps.sh — 一键拉取所有外部依赖源码
#
# 用法: bash setup_deps.sh [--force] [--mobileglues-only]
#   --force: 删除所选依赖的已有目录后重新克隆
#   --mobileglues-only: 只处理 MobileGlues，不触碰 LWJGL/OpenAL Soft/SDL3
#
# MobileGlues 的来源与版本定义在 deps.lock 中；脚本对其强制读取
# repo + 40 位 commit + branch/base_commit，不允许默认分支或环境变量覆盖。
# LWJGL / OpenAL Soft 的当前锁定方式见下方「安全约定」。
#
# ============================================================
# 🔐 安全约定（commit pin）
# ============================================================
# 1. LWJGL 源码：由 git submodule 指针 + deps.lock commit 双重锁定；现代 Maven jar
#    由 download-lwjgl-modern-slot.mjs 在临时目录完成校验和后处理，再原位切换稳定槽位。
# 2. MobileGlues：fork submodule 模型。源码是 prebuilt/mobileglues/mg_src，
#    amcl/2.0-ohos 分支以官方 2.0.0 commit 为唯一功能基线；下游只保留可上游化的
#    embed/init API、构建契约和 OHOS 必需的 exact-self resolver。2.0 已包含 depth-format
#    正确修复，旧 texture 补丁不再重放。范围与依据见
#    docs/guides/mobileglues-2.0-ohos-governance.md 与 deps.lock [mobileglues]。
#    deps.lock [mobileglues].commit 是权威版本号，脚本据此 checkout 并校验 HEAD。
#    submodule 内有未提交改动且与锁不一致时脚本报错，不会覆盖尚未 push 的开发成果。
# 3. SDL3：源码克隆到 gitignored 的 prebuilt/sdl3/sdl3_src，严格 checkout
#    deps.lock [sdl3-native].commit；AMCL 专用 patch 只在构建 worktree 中应用。
# 4. OpenAL Soft：读取 deps.lock 的 upstream/tag/commit，验证精确提交后，
#    通过已纳入版本控制的 patches/series 接入 OHAudio；重复执行保持幂等。
#
# 升级 / 同步 MobileGlues：在 prebuilt/mobileglues/mg_src 里改 amcl/2.0-ohos 分支并 push，
# 把新 commit 写回 deps.lock 并 commit superproject 的 gitlink，然后执行
# bash setup_deps.sh --mobileglues-only；不得通过 MG_COMMIT 临时覆盖，
# 否则工作区内容将无法从仓库配置复现。
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CPP_DIR="${SCRIPT_DIR}/entry/src/main/cpp"
FORCE=false
MOBILEGLUES_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        --mobileglues-only) MOBILEGLUES_ONLY=true ;;
        *) echo "ERROR: unknown argument: $arg" >&2; exit 1 ;;
    esac
done

echo "=== MC-OHOS: Setting up dependencies ==="
echo ""
TOTAL=4

# ============================================================
# 关于 libcurl for OHOS (下载引擎 v3)
# ============================================================
# libcurl.so 不通过 git clone 拉取，而是由 docker/build_curl_ohos.sh
# 在 Docker 容器里交叉编译（OpenSSL 3.3.2 + curl 8.10.1 静态链）。
# 产物位置：entry/libs/arm64-v8a/libcurl.so (5.57 MB，含完整 TLS stack)
# 头文件：   entry/src/main/cpp/third_party/curl/include/curl/*.h
#
# 重新构建方式（需要 Docker 和 openjdk-ohos-builder 镜像）：
#   ./docker/build_curl_ohos.ps1    # Windows
#   bash docker/build_curl_ohos.sh  # 直接在容器内
#
# 设计稿：docs/guides/download-system-redesign-v3.md
# ============================================================


# ============================================================
# 1. MobileGlues — OpenGL → GLES 翻译层
# ============================================================
# 2026-07-31：MG 从「clone 官方仓 + 剥 .git + 搬进 cpp 目录」改为 fork submodule，
# 位置与 prebuilt/lwjgl3/lwjgl3_src 同构。源码树自带 .git，改完可直接 commit/push 回 fork。
MG_SUBMODULE_PATH="prebuilt/mobileglues/mg_src"
MG_REPO_DIR="${SCRIPT_DIR}/${MG_SUBMODULE_PATH}"
MG_DIR="${MG_REPO_DIR}/MobileGlues-cpp"
MG_LOCK_FILE="${SCRIPT_DIR}/deps.lock"
# MG 2.0 的常规构建依赖。刻意不用 --recursive 全量：perfetto 只在
# MOBILEGLUES_ENABLE_PROFILING=ON 时编译，默认发布链不需要它。
MG_NESTED_SUBMODULES="
MobileGlues-cpp/3rdparty/glslang
MobileGlues-cpp/3rdparty/SPIRV-Cross
MobileGlues-cpp/3rdparty/xxhash
MobileGlues-cpp/include/ska
"

read_lock_value() {
    local section="$1"
    local key="$2"
    awk -v target_section="[$section]" -v target_key="$key" '
        { sub(/\r$/, "") }
        $0 == target_section { in_section = 1; next }
        /^\[/ { in_section = 0 }
        in_section && $1 == target_key && $2 == "=" { print $3; exit }
    ' "$MG_LOCK_FILE"
}

if [ -n "${MG_COMMIT:-}" ] || [ -n "${MG_COMMIT_OVERRIDE:-}" ] || [ -n "${MG_COMMIT_ENV:-}" ]; then
    echo "ERROR: MobileGlues commit overrides are not supported; update deps.lock instead" >&2
    exit 1
fi

MG_UPSTREAM="$(read_lock_value mobileglues upstream)"
MG_REPO="$(read_lock_value mobileglues repo)"
MG_COMMIT="$(read_lock_value mobileglues commit)"
MG_BRANCH="$(read_lock_value mobileglues branch)"
MG_BASE_COMMIT="$(read_lock_value mobileglues base_commit)"
MG_SOURCE_MAIN_COMMIT="$(read_lock_value mobileglues source_main_commit)"
MG_RENDERER_COMMIT="$(read_lock_value mobileglues android_renderer_commit)"
MG_UPSTREAM_NO_PUSH="https://invalid.invalid/AMCL-DO-NOT-PUSH-OFFICIAL-MobileGlues.git"

if [ -z "$MG_UPSTREAM" ] || [ -z "$MG_REPO" ] || [ -z "$MG_COMMIT" ]; then
    echo "ERROR: deps.lock [mobileglues] requires non-empty upstream, repo and commit" >&2
    exit 1
fi
if [[ ! "$MG_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "ERROR: deps.lock [mobileglues].commit must be a 40-character SHA-1: $MG_COMMIT" >&2
    exit 1
fi
# fork 模型：OHOS 改动是 fork 分支上的 commit，不是本地 patch。branch/base_commit 用于
# 记录「这串提交基于哪个上游 commit」，并让 upstream-watch 拿 base_commit 去比上游 HEAD。
if [ -z "$MG_BRANCH" ] || [ -z "$MG_BASE_COMMIT" ] ||
   [ -z "$MG_SOURCE_MAIN_COMMIT" ] || [ -z "$MG_RENDERER_COMMIT" ]; then
    echo "ERROR: deps.lock [mobileglues] requires branch/base/source-main/renderer commits" >&2
    exit 1
fi
for MG_LOCKED_OBJECT in "$MG_BASE_COMMIT" "$MG_SOURCE_MAIN_COMMIT" "$MG_RENDERER_COMMIT"; do
    if [[ ! "$MG_LOCKED_OBJECT" =~ ^[0-9a-fA-F]{40}$ ]]; then
        echo "ERROR: deps.lock [mobileglues] contains a non-40-character source object: $MG_LOCKED_OBJECT" >&2
        exit 1
    fi
done
if [ "$MG_BASE_COMMIT" != "$MG_SOURCE_MAIN_COMMIT" ]; then
    echo "ERROR: MobileGlues base_commit must equal the locked source_main_commit" >&2
    exit 1
fi
if [ "$MG_REPO" = "$MG_UPSTREAM" ]; then
    echo "WARNING: deps.lock [mobileglues].repo points at official upstream; the OHOS branch" >&2
    echo "         and its HarmonyOS fixes are NOT part of that source tree." >&2
fi
echo "[1/$TOTAL] MobileGlues: fork model — branch '$MG_BRANCH' based on upstream $MG_BASE_COMMIT"

# submodule 未初始化（新克隆的仓库）时先拉起来；URL 以 deps.lock 的 repo 为准。
if [ ! -f "$MG_REPO_DIR/.git" ] && [ ! -d "$MG_REPO_DIR/.git" ]; then
    echo "[1/$TOTAL] MobileGlues: initializing submodule $MG_SUBMODULE_PATH ..."
    git -C "$SCRIPT_DIR" submodule sync -- "$MG_SUBMODULE_PATH"
    git -C "$SCRIPT_DIR" -c core.longpaths=true submodule update --init -- "$MG_SUBMODULE_PATH"
fi

# Make remote roles explicit. origin is the writable AMCL fork. upstream is
# fetch-only official provenance; its push URL is a reserved, non-resolving
# sentinel so an accidental `git push upstream` cannot target the official repo.
git -C "$MG_REPO_DIR" remote set-url origin "$MG_REPO"
if git -C "$MG_REPO_DIR" remote get-url upstream >/dev/null 2>&1; then
    git -C "$MG_REPO_DIR" remote set-url upstream "$MG_UPSTREAM"
else
    git -C "$MG_REPO_DIR" remote add upstream "$MG_UPSTREAM"
fi
git -C "$MG_REPO_DIR" remote set-url --push upstream "$MG_UPSTREAM_NO_PUSH"

MG_CURRENT_COMMIT="$(git -C "$MG_REPO_DIR" rev-parse HEAD 2>/dev/null || echo '')"
if [ "$MG_CURRENT_COMMIT" != "$MG_COMMIT" ]; then
    # 有未提交改动时绝不覆盖：那通常是还没 push 回 fork 的 OHOS 开发成果。
    if [ -n "$(git -C "$MG_REPO_DIR" status --porcelain --untracked-files=no)" ]; then
        echo "ERROR: $MG_SUBMODULE_PATH has uncommitted changes but is at ${MG_CURRENT_COMMIT:-<unknown>}," >&2
        echo "       while deps.lock requires $MG_COMMIT." >&2
        echo "       Commit and push them to the fork branch '$MG_BRANCH' first, then update deps.lock." >&2
        exit 1
    fi
    echo "[1/$TOTAL] MobileGlues: checking out locked commit $MG_COMMIT ..."
    if ! git -C "$MG_REPO_DIR" cat-file -e "${MG_COMMIT}^{commit}" 2>/dev/null; then
        git -C "$MG_REPO_DIR" -c core.longpaths=true fetch --quiet --no-tags --depth=8 origin "$MG_BRANCH"
    fi
    git -C "$MG_REPO_DIR" -c core.longpaths=true checkout --quiet --detach "$MG_COMMIT"
else
    echo "[1/$TOTAL] MobileGlues: already at locked commit $MG_COMMIT"
fi

# A depth-1 submodule can have the correct HEAD but still lack the six-commit
# integration ancestry and the official source/renderer objects needed to prove
# provenance. Hydrate the fork stack and exact official objects before gating.
if [ "$(git -C "$MG_REPO_DIR" rev-parse --is-shallow-repository 2>/dev/null || echo false)" = "true" ] ||
   ! git -C "$MG_REPO_DIR" cat-file -e "${MG_BASE_COMMIT}^{commit}" 2>/dev/null; then
    git -C "$MG_REPO_DIR" -c core.longpaths=true fetch --quiet --no-tags --depth=8 origin "$MG_BRANCH"
fi
if ! git -C "$MG_REPO_DIR" cat-file -e "${MG_SOURCE_MAIN_COMMIT}^{commit}" 2>/dev/null ||
   ! git -C "$MG_REPO_DIR" cat-file -e "${MG_RENDERER_COMMIT}^{commit}" 2>/dev/null; then
    git -C "$MG_REPO_DIR" -c core.longpaths=true fetch --quiet --no-tags --depth=2 upstream \
        "$MG_SOURCE_MAIN_COMMIT" "$MG_RENDERER_COMMIT"
fi
for MG_LOCKED_OBJECT in "$MG_SOURCE_MAIN_COMMIT" "$MG_RENDERER_COMMIT"; do
    if ! git -C "$MG_REPO_DIR" cat-file -e "${MG_LOCKED_OBJECT}^{commit}" 2>/dev/null; then
        echo "ERROR: MobileGlues locked provenance object is unavailable after fetch: $MG_LOCKED_OBJECT" >&2
        exit 1
    fi
done

MG_ACTUAL_COMMIT="$(git -C "$MG_REPO_DIR" rev-parse HEAD)"
if [ "$MG_ACTUAL_COMMIT" != "$MG_COMMIT" ]; then
    echo "ERROR: MobileGlues checkout mismatch: expected $MG_COMMIT, got $MG_ACTUAL_COMMIT" >&2
    exit 1
fi

# 嵌套依赖由 MG 自己的 CMake target 管理；逐个 --depth 1 初始化，避开可选 perfetto。
for MG_NESTED in $MG_NESTED_SUBMODULES; do
    if ! git -C "$MG_REPO_DIR" config --file .gitmodules --get-regexp path |
        grep -qx "submodule\..*\.path $MG_NESTED"; then
        echo "ERROR: expected submodule '$MG_NESTED' is not registered in MobileGlues .gitmodules" >&2
        echo "       MobileGlues layout changed; update setup_deps.sh before pinning this commit." >&2
        exit 1
    fi
    if [ ! -e "$MG_REPO_DIR/$MG_NESTED/.git" ] || [ "$FORCE" = true ]; then
        git -C "$MG_REPO_DIR" -c core.longpaths=true submodule update --init --depth 1 -- "$MG_NESTED"
    fi
done

echo "  pinned commit verification: $(git -C "$MG_REPO_DIR" log -1 --format='%H %s')"
echo "  OK"

# MobileGlues patch series is intentionally empty under the fork model: every
# OHOS change must be a reviewable commit on the pinned fork branch. Local patch
# replay would make the build differ from the locked gitlink and is rejected.
MG_PATCH_DIR="${SCRIPT_DIR}/prebuilt/mobileglues/patches"
MG_PATCH_SERIES="${MG_PATCH_DIR}/series"
if [ ! -f "$MG_PATCH_SERIES" ]; then
    echo "ERROR: MobileGlues patch series marker is missing: $MG_PATCH_SERIES" >&2
    exit 1
fi
if grep -Ev '^[[:space:]]*(#.*)?$' "$MG_PATCH_SERIES" | grep -q .; then
    echo "ERROR: MobileGlues patches/series must be empty/comment-only under the fork model" >&2
    exit 1
fi
if find "$MG_PATCH_DIR" -maxdepth 1 -type f -name '*.patch' -print -quit | grep -q .; then
    echo "ERROR: local MobileGlues .patch files are forbidden; commit the change to $MG_BRANCH" >&2
    exit 1
fi

if [ "$MOBILEGLUES_ONLY" = true ]; then
    echo "=== MobileGlues setup complete (other dependencies untouched) ==="
    exit 0
fi

# ============================================================
# 2. LWJGL — Lightweight Java Game Library (Native 层)
# ============================================================
# 2026-05-18：从 git clone 切换到 git submodule。主仓 .gitmodules 锁了精确 SHA，
# 所有人 setup 出来字节级一致；想升级时主仓里 cd 进 submodule git checkout <sha>
# 然后回主仓 commit 就行。LWJGL_COMMIT 环境变量不再支持（用 submodule 钉版即可）。
LWJGL_DIR="${SCRIPT_DIR}/prebuilt/lwjgl3/lwjgl3_src"

# Submodule 已在 .gitmodules 注册，url=https://github.com/LWJGL/lwjgl3.git。
# natives（.so）的 build 走 docker/build_lwjgl_ohos.sh，当前基于官方 3.4.2。
# Maven 原包下载、原始 SHA 校验、AMCL 后处理与稳定槽位切换由下方 Node 脚本完成。
if [ -d "$LWJGL_DIR" ] && [ -e "$LWJGL_DIR/.git" ] && [ "$FORCE" = false ]; then
    LWJGL_HEAD=$(cd "$LWJGL_DIR" && git rev-parse HEAD 2>/dev/null || echo '?')
    echo "[2/$TOTAL] LWJGL: submodule already initialized at $LWJGL_DIR (HEAD=$LWJGL_HEAD)"
else
    if [ "$FORCE" = true ] && [ -d "$LWJGL_DIR" ]; then
        echo "[2/$TOTAL] LWJGL: --force, deinit + re-init submodule ..."
        git -C "$SCRIPT_DIR" submodule deinit -f prebuilt/lwjgl3/lwjgl3_src
    fi
    echo "[2/$TOTAL] LWJGL: initializing submodule from .gitmodules ..."
    git -C "$SCRIPT_DIR" submodule update --init --recursive prebuilt/lwjgl3/lwjgl3_src
    echo "  HEAD: $(cd "$LWJGL_DIR" && git log -1 --format='%H %s')"
    echo "  OK"
fi

LWJGL_LOCKED_COMMIT="$(read_lock_value lwjgl-natives commit)"
LWJGL_ACTUAL_COMMIT="$(git -C "$LWJGL_DIR" rev-parse HEAD 2>/dev/null || echo '')"
if [[ ! "$LWJGL_LOCKED_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "ERROR: deps.lock [lwjgl-natives].commit must be a 40-character SHA-1" >&2
    exit 1
fi
if [ "$LWJGL_ACTUAL_COMMIT" != "$LWJGL_LOCKED_COMMIT" ]; then
    if [ -n "$(git -C "$LWJGL_DIR" status --porcelain --untracked-files=no)" ]; then
        echo "ERROR: LWJGL source has uncommitted changes at $LWJGL_ACTUAL_COMMIT; expected $LWJGL_LOCKED_COMMIT" >&2
        exit 1
    fi
    git -C "$LWJGL_DIR" checkout --quiet --detach "$LWJGL_LOCKED_COMMIT"
fi

echo "[2/$TOTAL] LWJGL: materializing locked modern slot (3.4.2 replaces the existing modern slot) ..."
if [ "$FORCE" = true ]; then
    node "$SCRIPT_DIR/scripts/download-lwjgl-modern-slot.mjs" --force
else
    node "$SCRIPT_DIR/scripts/download-lwjgl-modern-slot.mjs"
fi

# ============================================================
# 3. OpenAL Soft — 3D 音频库
# ============================================================
OAL_DIR="${CPP_DIR}/openal/openal-soft"
OAL_REPO="$(read_lock_value openal-soft upstream)"
OAL_TAG="$(read_lock_value openal-soft tag)"
OAL_COMMIT="$(read_lock_value openal-soft commit)"
if [ -z "$OAL_REPO" ] || [ -z "$OAL_TAG" ] || [[ ! "$OAL_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "ERROR: deps.lock [openal-soft] requires upstream, tag and a 40-character commit" >&2
    exit 1
fi

if [ -d "$OAL_DIR" ] && [ "$FORCE" = false ]; then
    echo "[3/$TOTAL] OpenAL Soft: already exists at $OAL_DIR (use --force to re-clone)"
else
    if [ -d "$OAL_DIR" ]; then
        echo "[3/$TOTAL] OpenAL Soft: removing existing directory..."
        rm -rf "$OAL_DIR"
    fi
    echo "[3/$TOTAL] OpenAL Soft: cloning $OAL_REPO (tag $OAL_TAG) ..."
    git clone --depth 1 --branch "$OAL_TAG" "$OAL_REPO" "$OAL_DIR"

fi

# tag 只是下载入口；必须以锁中的提交身份确认内容，再应用可审阅的标准补丁。
# 旧 sed 锚点带有本版本不存在的字符串字面量后缀 sv，会静默漏掉后端注册。
OAL_ACTUAL_COMMIT="$(git -C "$OAL_DIR" rev-parse HEAD)"
if [ "$OAL_ACTUAL_COMMIT" != "$OAL_COMMIT" ]; then
    echo "ERROR: OpenAL Soft HEAD=$OAL_ACTUAL_COMMIT, expected $OAL_COMMIT; preserve local changes before replacing it" >&2
    exit 1
fi
bash "$SCRIPT_DIR/docker/apply_patches.sh" \
    --patch-dir "$SCRIPT_DIR/prebuilt/openal-soft/patches" --target "$OAL_DIR"

# ============================================================
# 4. SDL3 — MC 26.3+ 窗口/输入层
# ============================================================
# 源码目录只保存干净的 pinned repository。构建脚本会另建 detached worktree，
# 再应用 prebuilt/sdl3/patches；因此 setup 不会污染源码基线，也不会覆盖开发仓改动。
SDL3_DIR="${SCRIPT_DIR}/prebuilt/sdl3/sdl3_src"
SDL3_REPO="$(read_lock_value sdl3-native repo)"
SDL3_COMMIT="$(read_lock_value sdl3-native commit)"
SDL3_ABI_BASE="$(read_lock_value sdl3-native abi_base)"

if [ -z "$SDL3_REPO" ] || [[ ! "$SDL3_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] ||
   [[ ! "$SDL3_ABI_BASE" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "ERROR: deps.lock [sdl3-native] requires repo, 40-char commit and abi_base" >&2
    exit 1
fi

if [ -e "$SDL3_DIR" ] && [ ! -e "$SDL3_DIR/.git" ]; then
    echo "ERROR: $SDL3_DIR exists but is not a git repository; refusing to replace it" >&2
    exit 1
fi
if [ ! -e "$SDL3_DIR/.git" ]; then
    echo "[4/$TOTAL] SDL3: cloning pinned source repository ..."
    # 新克隆必须生成与 HEAD 一致的初始索引和工作树。--no-checkout 会让
    # 下方的保护检查把全部源码识别为待删除修改，导致第一次准备依赖必然失败。
    # 完成初始 checkout 后仍按 deps.lock fetch/切换精确提交，不采用默认分支构建。
    git clone --filter=blob:none "$SDL3_REPO" "$SDL3_DIR"
fi

SDL3_ACTUAL_COMMIT="$(git -C "$SDL3_DIR" rev-parse HEAD 2>/dev/null || echo '')"
if [ "$SDL3_ACTUAL_COMMIT" != "$SDL3_COMMIT" ] &&
   [ -n "$(git -C "$SDL3_DIR" status --porcelain --untracked-files=no 2>/dev/null || true)" ]; then
    echo "ERROR: SDL3 source has uncommitted changes at ${SDL3_ACTUAL_COMMIT:-<unknown>};" >&2
    echo "       expected $SDL3_COMMIT. Commit/move those changes before setup." >&2
    exit 1
fi
git -C "$SDL3_DIR" remote set-url origin "$SDL3_REPO"
if [ "$FORCE" = true ] || ! git -C "$SDL3_DIR" cat-file -e "${SDL3_COMMIT}^{commit}" 2>/dev/null; then
    git -C "$SDL3_DIR" fetch --quiet --no-tags origin "$SDL3_COMMIT"
fi
if [ "$FORCE" = true ] || ! git -C "$SDL3_DIR" cat-file -e "${SDL3_ABI_BASE}^{commit}" 2>/dev/null; then
    git -C "$SDL3_DIR" fetch --quiet --no-tags origin "$SDL3_ABI_BASE"
fi
git -C "$SDL3_DIR" checkout --quiet --detach "$SDL3_COMMIT"
SDL3_ACTUAL_COMMIT="$(git -C "$SDL3_DIR" rev-parse HEAD)"
if [ "$SDL3_ACTUAL_COMMIT" != "$SDL3_COMMIT" ]; then
    echo "ERROR: SDL3 checkout mismatch: expected $SDL3_COMMIT, got $SDL3_ACTUAL_COMMIT" >&2
    exit 1
fi
echo "[4/$TOTAL] SDL3: pinned source ready at $SDL3_ACTUAL_COMMIT"

echo ""
echo "=== All dependencies ready ==="
echo ""
echo "Note: OpenJDK is cloned inside Docker during build, not locally."
echo "  See docker/build_jdk17_ohos.sh for details."
echo "SDL3 reproducible build: powershell -File scripts/build-sdl3-ohos.ps1"
