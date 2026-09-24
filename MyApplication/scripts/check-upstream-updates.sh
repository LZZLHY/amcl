#!/bin/bash
# check-upstream-updates.sh — 监听 deps.lock 中各上游 commit / tag 是否有新版本
#
# 用法：
#   bash scripts/check-upstream-updates.sh           # 仅打印
#   GITHUB_TOKEN=xxx bash scripts/check-upstream-updates.sh --open-issues
#                                                    # 不一致时调 gh CLI 开 issue（CI 用）
#
# 监控对象：
#   • [mobileglues] official source main / Android renderer / plugin / release-index
#   • [openal-soft].upstream  最新 release tag vs deps.lock tag
#   • [lwjgl-natives].upstream  最新 release tag vs deps.lock tag
#   • [openjdk].upstream  最新 jdk-17.x.x+y tag vs deps.lock tag
#
# 不监控：JNA / Cacio / objc-bridge / forge-bootstrapper（死冻类）
#
# 详见 docs/guides/third-party-deps-restructure-plan.md §4.3

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DEPS_LOCK="${ROOT_DIR}/deps.lock"
OPEN_ISSUES=false
[ "${1:-}" = "--open-issues" ] && OPEN_ISSUES=true

read_lock() {
    local section="$1" key="$2"
    awk -v section="$section" -v key="$key" '
        { sub(/\r$/, "") }
        BEGIN { in_section = 0 }
        /^\[/ { in_section = ($0 == "[" section "]") ? 1 : 0; next }
        in_section && $1 == key && $2 == "=" {
            $1=""; $2=""
            sub(/^[ \t]+/, "")
            sub(/[ \t]*#.*$/, "")
            sub(/[ \t]+$/, "")
            print
            exit
        }
    ' "$DEPS_LOCK"
}

DRIFT_REPORT=""
DRIFT_COUNT=0

report() {
    local label="$1"
    local pinned="$2"
    local upstream="$3"
    local note="$4"
    if [ "$pinned" = "$upstream" ]; then
        echo "  ✓  $label  $pinned  (in sync)"
    else
        echo "  ⚠  $label"
        echo "       deps.lock pin:  $pinned"
        echo "       observed remote: $upstream"
        echo "       $note"
        DRIFT_REPORT="${DRIFT_REPORT}\n* **${label}**: pinned \`${pinned}\` upstream \`${upstream}\`"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
    fi
}

echo "=== AMCL upstream-watch ==="
echo "    deps.lock: $DEPS_LOCK"
echo ""

# 1. MobileGlues has four distinct upstream surfaces. The source repository has
# no V2.0.0 tag, so source-main drift is a commit review signal, not a claim that
# a new release exists. Android plugin/renderer and the separate release-index
# are reported independently; check-mg-pin verifies their locked object relation.
MG_UPSTREAM=$(read_lock mobileglues upstream)
MG_SOURCE_BRANCH=$(read_lock mobileglues source_branch)
MG_SOURCE_PIN=$(read_lock mobileglues source_main_commit)
if [ -n "$MG_UPSTREAM" ] && [ -n "$MG_SOURCE_PIN" ]; then
    [ -z "$MG_SOURCE_BRANCH" ] && MG_SOURCE_BRANCH=main
    MG_HEAD=$(git ls-remote --heads "$MG_UPSTREAM" "refs/heads/$MG_SOURCE_BRANCH" 2>/dev/null | awk '{print $1}')
    [ -z "$MG_HEAD" ] && MG_HEAD="UNKNOWN"
    report "MobileGlues source/$MG_SOURCE_BRANCH (source repo has no release tag)" "$MG_SOURCE_PIN" "$MG_HEAD" \
        "source main 有新 commit；先审阅，不要把它自动等同于新 release，再决定是否重放 OHOS commit 栈"
fi

MG_RENDERER_PIN=$(read_lock mobileglues android_renderer_commit)
if [ -n "$MG_UPSTREAM" ] && [ -n "$MG_RENDERER_PIN" ]; then
    MG_RENDERER_HEAD=$(git ls-remote --heads "$MG_UPSTREAM" refs/heads/dev 2>/dev/null | awk '{print $1}')
    [ -z "$MG_RENDERER_HEAD" ] && MG_RENDERER_HEAD="UNKNOWN"
    report "MobileGlues Android renderer/dev" "$MG_RENDERER_PIN" "$MG_RENDERER_HEAD" \
        "Android renderer moved；审阅 source tree、plugin gitlink 与构建契约后再升级"
fi

MG_PLUGIN_REPO=$(read_lock mobileglues android_plugin_repo)
MG_PLUGIN_BRANCH=$(read_lock mobileglues android_plugin_branch)
MG_PLUGIN_PIN=$(read_lock mobileglues android_plugin_commit)
MG_PLUGIN_MAIN_PIN=$(read_lock mobileglues android_plugin_main_commit)
if [ -n "$MG_PLUGIN_REPO" ] && [ -n "$MG_PLUGIN_PIN" ]; then
    [ -z "$MG_PLUGIN_BRANCH" ] && MG_PLUGIN_BRANCH=dev
    MG_PLUGIN_HEAD=$(git ls-remote --heads "$MG_PLUGIN_REPO" "refs/heads/$MG_PLUGIN_BRANCH" 2>/dev/null | awk '{print $1}')
    [ -z "$MG_PLUGIN_HEAD" ] && MG_PLUGIN_HEAD="UNKNOWN"
    report "MobileGlues Android plugin/$MG_PLUGIN_BRANCH" "$MG_PLUGIN_PIN" "$MG_PLUGIN_HEAD" \
        "plugin release branch moved；验证其 MobileGlues gitlink 后更新精确 plugin commit"
    MG_PLUGIN_MAIN=$(git ls-remote --heads "$MG_PLUGIN_REPO" refs/heads/main 2>/dev/null | awk '{print $1}')
    [ -z "$MG_PLUGIN_MAIN" ] && MG_PLUGIN_MAIN="UNKNOWN"
    report "MobileGlues Android plugin/main" "$MG_PLUGIN_MAIN_PIN" "$MG_PLUGIN_MAIN" \
        "plugin main moved；这是 drift，不改变已锁 2.0 plugin release commit"
fi

MG_RELEASE_REPO=$(read_lock mobileglues release_repo)
MG_RELEASE_TAG=$(read_lock mobileglues release_tag)
MG_RELEASE_PIN=$(read_lock mobileglues release_commit)
if [ -n "$MG_RELEASE_REPO" ] && [ -n "$MG_RELEASE_TAG" ] && [ -n "$MG_RELEASE_PIN" ]; then
    MG_RELEASE_REMOTE=$(git ls-remote --tags "$MG_RELEASE_REPO" \
        "refs/tags/$MG_RELEASE_TAG" "refs/tags/$MG_RELEASE_TAG^{}" 2>/dev/null | tail -1 | awk '{print $1}')
    [ -z "$MG_RELEASE_REMOTE" ] && MG_RELEASE_REMOTE="UNKNOWN"
    report "MobileGlues release-index tag $MG_RELEASE_TAG" "$MG_RELEASE_PIN" "$MG_RELEASE_REMOTE" \
        "官方 release-index tag 缺失或被移动；停止发布并人工核查（它不是 source 仓 tag）"
fi

# 2. OpenAL Soft (latest release tag)
OAL_UPSTREAM=$(read_lock openal-soft upstream)
OAL_PIN=$(read_lock openal-soft tag)
if [ -n "$OAL_UPSTREAM" ] && [ -n "$OAL_PIN" ]; then
    # 取最新 release tag（按 vX.Y.Z 排序）
    OAL_LATEST=$(git ls-remote --tags --refs "$OAL_UPSTREAM" 2>/dev/null \
        | awk -F'/' '{print $NF}' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -V | tail -1)
    [ -z "$OAL_LATEST" ] && OAL_LATEST="UNKNOWN"
    report "OpenAL Soft" "$OAL_PIN" "$OAL_LATEST" "上游发了新 release；评估是否升级"
fi

# 3. LWJGL natives (LWJGL 官方 release tag)
LWJGL_UPSTREAM=$(read_lock lwjgl-natives upstream)
LWJGL_PIN=$(read_lock lwjgl-natives tag)
if [ -n "$LWJGL_UPSTREAM" ] && [ -n "$LWJGL_PIN" ]; then
    # 取最新 LWJGL 3.3.x release tag
    LWJGL_LATEST=$(git ls-remote --tags --refs "$LWJGL_UPSTREAM" 2>/dev/null \
        | awk -F'/' '{print $NF}' \
        | grep -E '^3\.[0-9]+\.[0-9]+$' \
        | sort -V | tail -1)
    [ -z "$LWJGL_LATEST" ] && LWJGL_LATEST="UNKNOWN"
    report "LWJGL (${LWJGL_PIN})" "$LWJGL_PIN" "$LWJGL_LATEST" \
        "上游发了新 release；评估是否升级（详见 prebuilt/lwjgl3/README.md 升级流程）"
fi

# 4. OpenJDK 17u
JDK_UPSTREAM=$(read_lock openjdk upstream)
JDK_PIN=$(read_lock openjdk tag)
if [ -n "$JDK_UPSTREAM" ] && [ -n "$JDK_PIN" ]; then
    # 取最新 jdk-17.x.x+y tag
    JDK_LATEST=$(git ls-remote --tags --refs "$JDK_UPSTREAM" 2>/dev/null \
        | awk -F'/' '{print $NF}' \
        | grep -E '^jdk-17\.[0-9]+\.[0-9]+\+[0-9]+$' \
        | sort -V | tail -1)
    [ -z "$JDK_LATEST" ] && JDK_LATEST="UNKNOWN"
    report "OpenJDK 17u" "$JDK_PIN" "$JDK_LATEST" "上游 17 LTS 发了新 patch release"
fi

echo ""
if [ "$DRIFT_COUNT" = 0 ]; then
    echo "=== All deps in sync with upstream ==="
    exit 0
fi

echo "=== $DRIFT_COUNT dep(s) have upstream updates ==="
echo ""
echo "Note: 这只是提醒，不会自动 PR。是否升级由维护者按 §4.2 决定。"

# 在 GH Action 上把 drift 写到 GITHUB_STEP_SUMMARY，方便看
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "## AMCL upstream-watch — drift detected"
        echo ""
        echo "$DRIFT_COUNT dependency/dependencies have upstream updates:"
        echo ""
        printf "%b\n" "$DRIFT_REPORT"
    } >> "$GITHUB_STEP_SUMMARY"
fi

# 可选：开 issue
if [ "$OPEN_ISSUES" = true ] && command -v gh >/dev/null 2>&1; then
    echo ""
    echo "Opening GitHub issue ..."
    body="AMCL upstream-watch detected upstream updates:

$(printf '%b' "$DRIFT_REPORT")

Action items (per docs/guides/third-party-deps-restructure-plan.md §4):
- Decide whether to upgrade per the cadence table in §4.1
- If yes, follow the per-dep upgrade flow in §3.1
- If no, close this issue and re-run watch later"
    gh issue create \
        --title "[upstream-watch] $DRIFT_COUNT dep(s) have new versions" \
        --body "$body" \
        --label "deps,upstream-watch" || true
fi

# 退出码 0 即可（不阻塞 PR；watch 是提示性质）
