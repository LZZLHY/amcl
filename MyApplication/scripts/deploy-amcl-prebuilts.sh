#!/bin/bash
# deploy-amcl-prebuilts.sh — 把 .github/workflows/templates/amcl-prebuilts-build-*.yml
# 部署到 LZZLHY/amcl-prebuilts 仓的 .github/workflows/。
#
# 详见 docs/guides/third-party-deps-restructure-plan.md §3.3
#
# 前提：
#   1. gh CLI 已认证（gh auth status）
#   2. LZZLHY/amcl-prebuilts 仓已创建（GitHub Settings → Empty public repo）
#   3. 仓 secrets 已设置 OHOS_SYSROOT_URL（指向你 host 的 sysroot tarball）
#
# 用法：
#   bash scripts/deploy-amcl-prebuilts.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TEMPLATES_DIR="${ROOT_DIR}/.github/workflows/templates"
DRY_RUN=false

[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

REPO="LZZLHY/amcl-prebuilts"

if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI not found. install from https://cli.github.com/" >&2
    exit 1
fi

if ! gh repo view "$REPO" >/dev/null 2>&1; then
    echo "ERROR: $REPO does not exist on GitHub" >&2
    echo "       run: gh repo create $REPO --public --description 'AMCL prebuilt artifacts (.so / native binaries)'" >&2
    exit 1
fi

# Templates we deploy: file pattern → target name
declare -a WORKFLOWS=(
    "amcl-prebuilts-build-curl.yml|build-curl.yml"
    "amcl-prebuilts-build-libopenal.yml|build-libopenal.yml"
    "amcl-prebuilts-build-libglfw.yml|build-libglfw.yml"
    "amcl-prebuilts-build-lwjgl-natives.yml|build-lwjgl-natives.yml"
)

run() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] $*"
    else
        "$@"
    fi
}

echo "=== AMCL amcl-prebuilts deploy ==="
echo "  templates: $TEMPLATES_DIR"
echo "  repo:      $REPO"
echo "  mode:      $([ "$DRY_RUN" = true ] && echo DRY-RUN || echo LIVE)"
echo ""

workdir=$(mktemp -d -t amcl-prebuilts-XXXXXX)
echo "  workdir: $workdir"
run git clone "https://github.com/${REPO}.git" "$workdir" 2>&1 | head -5

run mkdir -p "${workdir}/.github/workflows"

for entry in "${WORKFLOWS[@]}"; do
    IFS='|' read -r src dst <<< "$entry"
    src_path="${TEMPLATES_DIR}/${src}"
    dst_path="${workdir}/.github/workflows/${dst}"
    if [ ! -f "$src_path" ]; then
        echo "  ⚠️  template missing: $src"
        continue
    fi
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] cp $src_path → $dst_path"
    else
        cp "$src_path" "$dst_path"
        echo "  ✓ ${dst}"
    fi
done

# README
if [ "$DRY_RUN" = false ]; then
    cat > "${workdir}/README.md" <<'EOF'
# amcl-prebuilts

Prebuilt OHOS-targeted native artifacts consumed by [LZZLHY/amcl](https://github.com/LZZLHY/amcl).

## Available builds

| Workflow | Produces | Tag pattern |
|---|---|---|
| `build-curl.yml` | `libcurl.so` (curl + OpenSSL static-linked) | `curl-<version>-ohos-<rev>` |
| `build-libopenal.yml` | `libopenal.so` (OpenAL Soft + OHAudio backend) | `libopenal-<tag>-ohos-<rev>` |
| `build-libglfw.yml` | `libglfw.so` (GLFW compat + MobileGlues) | `libglfw-mg-<commit8>-<rev>` |
| `build-lwjgl-natives.yml` | `liblwjgl*.so` (4 modules) | `lwjgl-natives-<version>-ohos-<rev>` |

All workflows are `workflow_dispatch` — manually trigger from the Actions tab.

## Requirements

- Repo secret `OHOS_SYSROOT_URL` pointing to a hosted OHOS NDK sysroot tarball
- Each release contains: `<name>.tar.gz`, `SHA256SUMS`, `BUILD_INFO.txt`

## Consumer side

Main repo `setup_deps.sh` fetches releases via `deps.lock [amcl-prebuilts]` section.
SHA256 of each tarball must match `<name>_sha256` in `deps.lock`.

## License

Per-artifact licenses follow upstream sources:
- libcurl: curl license + OpenSSL Apache-2.0
- libopenal: LGPL-2.0-or-later
- libglfw: BSD-3 (GLFW) + LGPL-2.1 (MobileGlues, dynamically linked)
- lwjgl-natives: BSD-3 (LWJGL)

EOF
fi

pushd "$workdir" >/dev/null
    run git add -A
    if [ "$DRY_RUN" = false ]; then
        if git diff --cached --quiet; then
            echo "  no changes; skipping commit"
        else
            run git -c user.name=amcl-deploy-bot -c user.email=amcl-deploy@noreply.github.com \
                commit -m "deploy: amcl-prebuilts build workflows"
            run git push origin HEAD:main 2>&1 | head -5 || \
                run git push origin HEAD:master 2>&1 | head -5
        fi
    fi
popd >/dev/null

run rm -rf "$workdir"

echo ""
echo "=== Done ==="
if [ "$DRY_RUN" = false ]; then
    echo "Next steps:"
    echo "  1. Set repo secret OHOS_SYSROOT_URL at https://github.com/${REPO}/settings/secrets/actions"
    echo "  2. Trigger each workflow manually from https://github.com/${REPO}/actions"
    echo "  3. After first release, fill deps.lock [amcl-prebuilts] sha256 fields and"
    echo "     run 'bash setup_deps.sh' from main repo to verify download path."
fi
