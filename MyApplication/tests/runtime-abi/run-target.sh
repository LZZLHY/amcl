#!/bin/bash
# 在 QEMU 运行 AArch64 ABI 原件和实际设备 libc；不宣称此环境具有设备 namespace、
# 代码签名、沙箱 exec 或自定义装载器资格。所有输入摘要和运行结果独立保留。
set -euo pipefail
# 负控制故意终止独立进程；保留完整诊断而不额外生成大体积 core 文件。
ulimit -c 0
cd /abi
mode=${1:-abi}
qemu-aarch64 --version | tee /output/qemu-version.txt
if [ "$mode" = jdk-load ]; then
    [ -n "${AMCL_ELF_FIXTURES:-}" ] || { echo 'Actual JDK fixtures are required'; exit 2; }
    sha256sum /abi/elf_unwind_runner /abi/libc++_shared.so "/device-libc/${AMCL_ABI_LIBC_FILE:?}" > /output/runtime-inputs.sha256
    for major in 8 17 21 25; do
        timeout 40s qemu-aarch64 "/device-libc/$AMCL_ABI_LIBC_FILE" \
            --library-path /abi /abi/elf_unwind_runner /abi --jdk-load "$major" \
            2>&1 | tee "/output/jdk-$major-load.log"
    done
    exit 0
fi
if [ "$mode" = elf-unwind ]; then
    sha256sum /abi/elf_unwind_runner /abi/*.so "/device-libc/${AMCL_ABI_LIBC_FILE:?}" > /output/runtime-inputs.sha256
    timeout 40s qemu-aarch64 "/device-libc/$AMCL_ABI_LIBC_FILE" \
        --library-path /abi /abi/elf_unwind_runner /abi 2>&1 | tee /output/elf-unwind.log
    set +e
    timeout 10s qemu-aarch64 "/device-libc/$AMCL_ABI_LIBC_FILE" \
        --library-path /abi /abi/elf_unwind_runner /abi --no-register > /output/elf-unwind-negative.log 2>&1
    status=$?
    set -e
    [ "$status" = 134 ] && grep -q 'NEGATIVE crossing an unregistered custom frame' /output/elf-unwind-negative.log && \
        grep -q 'unwind-image-ok' /output/elf-unwind-negative.log || {
        cat /output/elf-unwind-negative.log; echo "FAIL custom FDE negative control status=$status"; exit 1;
    }
    echo 'PASS custom/system unwind and missing-registration negative control (QEMU only)'
    exit 0
fi
sha256sum /abi/abi_runner /abi/*.so "/device-libc/${AMCL_ABI_LIBC_FILE:?}" \
    | tee /output/runtime-inputs.sha256
if [ "$mode" = cpu-timer ]; then
    sha256sum /abi/cpu_timer_probe | tee -a /output/runtime-inputs.sha256
    timeout 20s qemu-aarch64 "/device-libc/$AMCL_ABI_LIBC_FILE" \
        --library-path /abi /abi/cpu_timer_probe 2>&1 | tee /output/cpu-timer.log
    exit 0
fi
[ "$mode" = abi ] || { echo 'Unknown ABI test mode'; exit 2; }
timeout 40s qemu-aarch64 "/device-libc/$AMCL_ABI_LIBC_FILE" \
    --library-path /abi /abi/abi_runner 2>&1 | tee /output/abi-behavior.log
# 旧 guard 只能以检测到语义错误的退出 1 通过负控制。超时、崩溃或加载失败都
# 属于测试设施失败，不能算成“成功检出”。stdout 也必须包含具体错误计数。
set +e
timeout 40s qemu-aarch64 -E LD_PRELOAD=/abi/liboldguard_negative.so \
    "/device-libc/$AMCL_ABI_LIBC_FILE" --library-path /abi /abi/abi_runner --guard-only \
    > /output/old-guard-negative.log 2>&1
negative_status=$?
set -e
cat /output/old-guard-negative.log
[ "$negative_status" = 1 ] && grep -Eq '^ABI guardFailures=[1-9][0-9]*$' /output/old-guard-negative.log || {
    echo "FAIL old guard negative control: status=$negative_status"; exit 1;
}
echo 'PASS real ABI behavior and old guard negative control (QEMU, not device qualification)'
