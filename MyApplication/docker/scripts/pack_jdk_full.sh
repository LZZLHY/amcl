#!/bin/bash
# JDK 完整包入口：身份、关键内容、原生依赖和 ZIP 读回任一失败均非零退出。
# 调用者可显式指定 image/output；默认值仅针对本次独立 Docker /build 与 /output。
set -euo pipefail
JDK_VERSION=${JDK_VERSION:-17}
JDK_IMAGE=${JDK_IMAGE:-/build/jdk${JDK_VERSION}u/build/linux-aarch64-server-release/images/jdk}
JDK_OUTPUT=${JDK_OUTPUT:-/output/jdk${JDK_VERSION}-ohos-${AMCL_RUN_ID:-candidate}.zip}
[ -d "$JDK_IMAGE" ] || { echo "ERROR: missing exact image $JDK_IMAGE"; exit 1; }
# 独立 CLI 也需要真实 provider。嵌入宿主时由加载器复用应用已加载的同 ABI 实例，
# 不能再次自定义映射另一套 libc++。经典版目录与现代布局分别处理。
abi_source=/output/jdk-libs
abi_target="$JDK_IMAGE/lib"
if [ "$JDK_VERSION" = 8 ]; then
  abi_source=/build/jdk8-libs
  abi_target="$JDK_IMAGE/jre/lib/aarch64"
fi
for name in libcxxabi_shim.so libc++_shared.so; do
  [ -f "$abi_source/$name" ] || { echo "ERROR: missing ABI input: $name"; exit 1; }
  cp "$abi_source/$name" "$abi_target/$name"
done
mkdir -p "$JDK_IMAGE/legal/amcl-native"
cp "${AMCL_JDK_NATIVE_ROOT:?}/NOTICE.txt" "$JDK_IMAGE/legal/amcl-native/NOTICE.txt"
# make images 先于 JLI 重链和 ABI 复制；同步最终模块输入，避免 jlink 派生旧实现/缺依赖。
if [ "$JDK_VERSION" != 8 ]; then
  python3 /build/scripts/sync_jdk_jmods.py --image "$JDK_IMAGE"
fi
python3 /build/scripts/jdk_build_identity.py "$JDK_VERSION" --image "$JDK_IMAGE"
python3 /build/scripts/package_runtime.py --source "$JDK_IMAGE" --major "$JDK_VERSION" \
  --system-library-dir /ohos-sysroot/usr/lib/aarch64-linux-ohos \
  --identity "/build/jdk${JDK_VERSION}-build-identity.json" --output "$JDK_OUTPUT"
if [ "${AMCL_JDK_TEST_IMAGE:-0}" = 1 ]; then
  python3 /build/scripts/package_jdk_test_image.py --major "$JDK_VERSION" \
    --jdk-image "$JDK_IMAGE" --output /output
fi
