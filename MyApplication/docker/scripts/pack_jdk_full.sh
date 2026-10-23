#!/bin/bash
# JDK 完整包入口：身份、关键内容、原生依赖和 ZIP 读回任一失败均非零退出。
# 调用者可显式指定 image/output；默认值仅针对本次独立 Docker /build 与 /output。
set -euo pipefail
JDK_VERSION=${JDK_VERSION:-17}
JDK_IMAGE=${JDK_IMAGE:-/build/jdk${JDK_VERSION}u/build/linux-aarch64-server-release/images/jdk}
JDK_OUTPUT=${JDK_OUTPUT:-/output/jdk${JDK_VERSION}-ohos-runtime-audio-rc2.zip}
[ -d "$JDK_IMAGE" ] || { echo "ERROR: missing exact image $JDK_IMAGE"; exit 1; }
if [ "$JDK_VERSION" != 8 ]; then
  [ -f /output/jdk-libs/libcxxabi_shim.so ] || { echo 'ERROR: missing real ABI shim'; exit 1; }
  cp /output/jdk-libs/libcxxabi_shim.so "$JDK_IMAGE/lib/libcxxabi_shim.so"
fi
python3 /build/scripts/jdk_build_identity.py "$JDK_VERSION" --image "$JDK_IMAGE"
python3 /build/scripts/package_runtime.py --source "$JDK_IMAGE" --major "$JDK_VERSION" \
  --system-library-dir /ohos-sysroot/usr/lib/aarch64-linux-ohos \
  --identity "/build/jdk${JDK_VERSION}-build-identity.json" --output "$JDK_OUTPUT"
