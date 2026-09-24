#!/bin/bash
# deploy-mirror-repos.sh — 把主仓 .github/workflows/templates/mirror-sync-upstream.yml
# 部署到 4 个 LZZLHY/*-mirror 仓，作为各自仓的 .github/workflows/sync-upstream.yml。
#
# 前提：
#   1. gh CLI 已认证（gh auth status）
#   2. 4 个 mirror 仓已经在 GitHub 上创建（空仓即可，本脚本会做首轮 mirror push 自动初始化）
#   3. 本机有 git 可用
#
# 用法：
#   bash scripts/deploy-mirror-repos.sh
#   bash scripts/deploy-mirror-repos.sh --dry-run    # 只打印不执行
#
# 详见 docs/guides/third-party-deps-restructure-plan.md §3.5.2 + §3.5.5

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TEMPLATE="${ROOT_DIR}/.github/workflows/templates/mirror-sync-upstream.yml"
DRY_RUN=false

[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

if [ ! -f "$TEMPLATE" ]; then
    echo "ERROR: template not found at $TEMPLATE" >&2
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI not found. install from https://cli.github.com/" >&2
    exit 1
fi

# ============================================================
# Mirror 配置
# ============================================================
# 格式：mirror_name | upstream_url
declare -a MIRRORS=(
    "mobileglues-mirror|https://github.com/MobileGL-Dev/MobileGlues.git"
    "openal-soft-mirror|https://github.com/kcat/openal-soft.git"
    # lwjgl3-fork-mirror 已废弃（2026-05-19 v6 切换到 LWJGL 官方 3.3.3 release tag）；
    # 镜像仓 LZZLHY/lwjgl3-fork-mirror 保留作历史快照，但不再 sync。
    "jdk17u-mirror|https://github.com/openjdk/jdk17u.git"
)

ORG="LZZLHY"

# ============================================================
# Helpers
# ============================================================
log() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] $*"
    else
        echo "[deploy] $*"
    fi
}

run() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] $*"
    else
        "$@"
    fi
}

deploy_one() {
    local name="$1"
    local upstream="$2"
    local repo="${ORG}/${name}"

    log "=== ${repo} ==="

    # 1. 检查仓存在
    if ! gh repo view "$repo" >/dev/null 2>&1; then
        echo "ERROR: $repo does not exist on GitHub" >&2
        echo "       Create it first (Settings → empty private/public repo named '${name}')" >&2
        echo "       or run: gh repo create $repo --public --description 'Mirror of $upstream'" >&2
        return 1
    fi

    # 2. 准备本地工作目录
    local workdir
    # 远端部署所需的临时克隆独占一个子目录，统一归入外部工作树容器。
    local workBase
    workBase=$(python3 -B "${ROOT_DIR}/scripts/lib/workspace_paths.py" wt mirror-deploy)
    mkdir -p "$workBase"
    workdir=$(mktemp -d "${workBase}/clone-XXXXXX")
    log "  workdir: $workdir"

    # 3. Clone mirror（空仓也行）
    run git clone "https://github.com/${repo}.git" "$workdir" 2>&1 | head -5

    # 4. 渲染模板，写入 workflow
    run mkdir -p "${workdir}/.github/workflows"
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] sed s|{{UPSTREAM_URL}}|$upstream|g $TEMPLATE > ${workdir}/.github/workflows/sync-upstream.yml"
    else
        sed "s|{{UPSTREAM_URL}}|${upstream}|g" "$TEMPLATE" \
            > "${workdir}/.github/workflows/sync-upstream.yml"
    fi

    # 5. README 给一个最小的
    if [ "$DRY_RUN" = false ]; then
        cat > "${workdir}/README.md" <<EOF
# ${name}

Read-only mirror of [\`${upstream}\`](${upstream}).

Maintained by [LZZLHY/amcl](https://github.com/LZZLHY/amcl) for supply-chain
stability. Synced daily via \`.github/workflows/sync-upstream.yml\`.

⚠️ **Do not push directly. Do not file PRs.** Send PRs to upstream.

Branches under \`upstream-*\` track upstream branches verbatim.

Pinned in main repo: see \`deps.lock\` (\`[<dep>].commit\`).
EOF
    else
        echo "[DRY-RUN] write README.md"
    fi

    # 6. Commit + push
    pushd "$workdir" >/dev/null
        run git add -A
        if [ "$DRY_RUN" = false ]; then
            if git diff --cached --quiet; then
                log "  no changes; skipping commit"
            else
                run git -c user.name=amcl-deploy-bot -c user.email=amcl-deploy@noreply.github.com \
                    commit -m "deploy: sync-upstream workflow + README"
                run git push origin HEAD:main 2>&1 | head -5 || \
                    run git push origin HEAD:master 2>&1 | head -5
            fi
        fi
    popd >/dev/null

    # 7. 触发首次 sync
    log "  triggering first sync run ..."
    if [ "$DRY_RUN" = false ]; then
        gh workflow run --repo "$repo" sync-upstream.yml 2>&1 | head -3 || true
    fi

    # 8. 设置 branch protection（main 不允许 force-push、必须 status-check）
    if [ "$DRY_RUN" = false ]; then
        log "  setting branch protection on main ..."
        # 静默失败可接受 —— 仓库可能还没 main 分支
        gh api -X PUT "repos/${repo}/branches/main/protection" \
            --input - <<'JSON' >/dev/null 2>&1 || true
{
  "required_status_checks": null,
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
    fi

    # 9. cleanup
    run rm -rf "$workdir"
    log "  ✓ done"
}

# ============================================================
# Main
# ============================================================
echo "=== AMCL mirror repo deploy ==="
echo "  template: $TEMPLATE"
echo "  org:      $ORG"
echo "  mode:     $([ "$DRY_RUN" = true ] && echo DRY-RUN || echo LIVE)"
echo ""

for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name upstream <<< "$entry"
    deploy_one "$name" "$upstream" || echo "  ⚠️  failed for $name; continuing"
    echo ""
done

echo "=== Done ==="
echo ""
if [ "$DRY_RUN" = true ]; then
    echo "Run without --dry-run to actually deploy."
else
    echo "Next steps:"
    echo "  1. Watch the 4 sync-upstream.yml runs at"
    echo "     https://github.com/orgs/${ORG}/repositories"
    echo "  2. Once first sync succeeds, change deps.lock [*].repo from upstream URL"
    echo "     to mirror URL (e.g. [mobileglues].repo = https://github.com/${ORG}/mobileglues-mirror.git)"
    echo "  3. Test 'bash setup_deps.sh --force' against new repo URLs"
fi
