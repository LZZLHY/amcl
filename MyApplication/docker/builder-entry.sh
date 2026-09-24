#!/bin/bash
# 仅用于 launch-builder.ps1 创建的新现场：配方只读、/build 为新 Linux 卷。
# 历史配方仍引用 /build/*.sh，因此显式链接当前 /recipes，绝不复用镜像里的旧脚本。
set -euo pipefail
[[ "${AMCL_BUILDER_MANAGED:-}" == 1 ]] || { echo 'ERROR: use launch-builder.ps1'; exit 1; }
recipe=${1:?missing recipe}; shift
[[ "$recipe" =~ ^build_[a-z0-9_]+\.sh$ && -f "/recipes/$recipe" ]] || { echo 'ERROR: invalid recipe'; exit 1; }
[[ -d /prebuilt && -f /ohos-sysroot/usr/include/stdio.h ]] || { echo 'ERROR: missing readonly inputs'; exit 1; }
[[ -z "$(find /build -mindepth 1 -maxdepth 1 -print -quit)" ]] || { echo 'ERROR: /build must be a fresh work volume'; exit 1; }
# 镜像内若已有未知的同名可写层，不覆盖、不向其中链接，要求选用干净工具链镜像。
for alias_path in /jdk8-spec /jdk-spec /jdk21-spec /jdk25-spec /stubs-src /host-docker /ohos-sysroot-rw /ohos-toolchain; do
    [[ ! -e "$alias_path" && ! -L "$alias_path" ]] || { echo "ERROR: image has unmanaged state at $alias_path"; exit 1; }
done
# 保存实际配方文件身份；后续源码继续修改时仍可追溯本次输入。
find /recipes -path /recipes/output -prune -o -type f \( -name '*.sh' -o -name '*.py' -o -name '*.c' \) -print0 | sort -z | xargs -0 sha256sum > /output/recipe-files.sha256
for input in /recipes/*.sh /recipes/*.py /recipes/*.c /recipes/scripts /recipes/stubs; do
    [[ -e "$input" ]] || continue
    ln -s "$input" "/build/$(basename "$input")"
done
# 所有规格/补丁别名都指向只读 prebuilt，不将补丁写入主工程消费副本。
for version in 8 17 21 25; do
    target="/jdk${version}-spec"; [[ "$version" == 17 ]] && target=/jdk-spec
    ln -s "/prebuilt/jdk/$version" "$target"
done
ln -s /prebuilt/stubs/src /stubs-src
ln -s /recipes /host-docker
ln -s /prebuilt/gl4es/patches /build/gl4es-patches
ln -s /build/sysroot /ohos-sysroot-rw
mkdir -p /build/toolchain
ln -s /build/toolchain /ohos-toolchain
export AMCL_SYSROOT_BASE=/ohos-sysroot
export OHOS_SYSROOT=/ohos-sysroot
export PATH="/ohos-toolchain:$PATH"
bash /recipes/setup_toolchain.sh
printf '%s\n' "$AMCL_BUILD_ID" > /build/amcl-build-id
printf 'Executing current recipe: /recipes/%s\n' "$recipe"
exec bash "/recipes/$recipe" "$@"
