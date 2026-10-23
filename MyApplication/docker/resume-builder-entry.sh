#!/bin/bash
# 仅续跑本轮 launch-builder 创建的、已停止的独占卷；绝不接受历史匿名构建树。
set -euo pipefail
recipe=${1:?missing recipe}; shift
[[ "${AMCL_BUILDER_MANAGED:-}" == 1 ]] || { echo 'ERROR: unmanaged resume'; exit 1; }
[[ -f /build/amcl-build-id && "$(cat /build/amcl-build-id)" == "$AMCL_BUILD_ID" ]] || {
    echo 'ERROR: build volume identity mismatch'; exit 1;
}
[[ "$recipe" =~ ^build_[a-z0-9_]+\.sh$ && -f "/recipes/$recipe" ]] || exit 1
# 新容器没有上一容器的根别名，只恢复指向当前只读输入和原独占卷的受控别名。
for version in 8 17 21 25; do
    target="/jdk${version}-spec"; [[ "$version" == 17 ]] && target=/jdk-spec
    [[ ! -e "$target" && ! -L "$target" ]] || { echo "ERROR: occupied alias $target"; exit 1; }
    ln -s "/prebuilt/jdk/$version" "$target"
done
for target in /stubs-src /host-docker /ohos-sysroot-rw /ohos-toolchain; do
    [[ ! -e "$target" && ! -L "$target" ]] || { echo "ERROR: occupied alias $target"; exit 1; }
done
ln -s /prebuilt/stubs/src /stubs-src
ln -s /recipes /host-docker
ln -s /build/sysroot /ohos-sysroot-rw
ln -s /build/toolchain /ohos-toolchain
export AMCL_SYSROOT_BASE=/ohos-sysroot
export OHOS_SYSROOT=/ohos-sysroot
export PATH="/ohos-toolchain:$PATH"
exec bash "/recipes/$recipe" "$@"
