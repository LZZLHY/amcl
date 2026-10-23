#!/bin/bash
# 一次请求只消费一次。Docker Desktop 再次启动已结束容器时仅提示，不覆盖原输出或隐式重编。
set -euo pipefail
mode=${1:?fresh or reuse}; recipe=${2:?recipe}; shift 2
[[ "$mode" == fresh || "$mode" == reuse ]] || exit 2
if ! (set -o noclobber; printf '%s\n' "${AMCL_RUN_ID:?}" > /output/.amcl-request-claimed) 2>/dev/null; then
    echo 'This AMCL request has already run; use launch-builder.ps1 for a new recorded request.'
    exit 0
fi
# 所有尝试都保存实际配方身份；持久源码/编译缓存位于 /build，日志与产物位于本次 /output。
find /recipes -path /recipes/output -prune -o -type f \( -name '*.sh' -o -name '*.py' -o -name '*.c' \) -print0 |
    sort -z | xargs -0 sha256sum > /output/recipe-files.sha256
if [[ "$mode" == fresh ]]; then
    exec bash /recipes/builder-entry.sh "$recipe" "$@"
fi
exec bash /recipes/resume-builder-entry.sh "$recipe" "$@"
