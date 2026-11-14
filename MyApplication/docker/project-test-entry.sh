#!/bin/bash
# 固定 qa 服务的受控测试入口；仅执行仓库内明确列出的套件，结果写外部独占输出。
set -euo pipefail
suite=${1:?suite}
shift
if ! (set -o noclobber; printf '%s\n' "${AMCL_RUN_ID:?}" > /output/.amcl-request-claimed) 2>/dev/null; then
    echo 'This AMCL test request has already run; submit a new request through project.py.'
    exit 0
fi
case "$suite" in
    elf) exec bash /workspace/tests/runtime-elf/run.sh ;;
    jdk-abi) exec bash /workspace/tests/runtime-abi/build-target.sh ;;
    jdk-abi-run) exec bash /workspace/tests/runtime-abi/run-target.sh "$@" ;;
    runtime-io) exec bash /workspace/tests/runtime-io/run-host.sh ;;
    runtime-install) exec bash /workspace/tests/runtime-install/run-host.sh ;;
    runtime-java) exec bash /workspace/tests/runtime-java/run-host.sh ;;
    runtime-process) exec bash /workspace/tests/runtime-process/run-ncp.sh ;;
    runtime-childproc) exec bash /workspace/tests/runtime-childproc/run-qualification-host.sh ;;
    java-ports) exec bash /workspace/tests/java-sound-ports/run-host.sh ;;
    sound-links) exec bash /workspace/tests/java-sound/run-sound-links.sh ;;
    runtime-midi) exec bash /workspace/tests/java-midi/run-qualification.sh ;;
    tls-storage) exec bash /workspace/tests/runtime-tls-storage/run.sh ;;
    tls-crt-reference) exec bash /workspace/tests/runtime-abi/tls-crt/run-glibc-reference.sh ;;
    fontconfig-freetype) exec bash /workspace/tests/runtime-fontconfig/run-freetype.sh ;;
    fontconfig-fallback) exec bash /workspace/tests/runtime-fontconfig/run-fallback.sh ;;
    fontconfig-defaults) exec python3 -B /workspace/tests/runtime-fontconfig/run-defaults.py --sources "${AMCL_FONTCONFIG_DEFAULT_SOURCES_MANIFEST:?}" --output /output/fontconfig-defaults ;;
    jdk-probe-owner) exec bash /workspace/tests/jdk-probe/run-host.sh ;;
    jni-invocation) exec bash /workspace/tests/runtime-jni/run-host.sh ;;
    processor-setup) exec bash /workspace/tests/runtime-process/run-host.sh ;;
    unwind-cache) exec bash /workspace/tests/runtime-abi/run-unwind-cache.sh ;;
    application-abi) exec bash /workspace/tests/runtime-abi/build-application-provider.sh ;;
    mobilegl-replay-host) exec bash /workspace/tests/mobilegl-replay-host/run-host.sh "$@" ;;
    mobilegl-cpu-proof)
        # 仅收取完整实际Linux链接输入；不执行CPU/GPU，也不授予正确性资格。
        # source/tree/clean/image由宿主原生Git与固定QA引擎核实后注入。
        exec python3 /workspace/tests/mobilegl-cpu-host/capture-host-proof.py \
            --source /mobilegl-source --cache /native-cache \
            --expected-source "${AMCL_MOBILEGL_SOURCE_COMMIT:?}" \
            --expected-tree "${AMCL_MOBILEGL_SOURCE_TREE:?}" \
            --expected-image "${AMCL_MOBILEGL_HOST_IMAGE:?}" \
            --producer-manifest "/mobilegl-producer/${AMCL_MOBILEGL_PRODUCER_FILE:?}" \
            --expected-producer-sha "${AMCL_MOBILEGL_PRODUCER_SHA:?}" \
            --expected-producer-compose-sha "${AMCL_MOBILEGL_PRODUCER_COMPOSE_SHA:?}" \
            --expected-producer-log-sha "${AMCL_MOBILEGL_PRODUCER_LOG_SHA:?}" \
            --expected-host-source "${AMCL_MOBILEGL_HOST_SOURCE:?}" \
            --expected-host-cache "${AMCL_MOBILEGL_HOST_CACHE:?}" \
            --expected-host-producer-dir "${AMCL_MOBILEGL_HOST_PRODUCER_DIR:?}" \
            --output /output/host-cache-proof.json "$@" ;;
    mobilegl-cpu-host)
        # 固定QA内只薄调用所属fork CPU合同；所有身份来自host实际选定参数，输出独占。
        exec python3 /workspace/tests/mobilegl-cpu-host/run-host.py \
            --source /mobilegl-source --cache /native-cache \
            --proof "/mobilegl-host-proof/${AMCL_MOBILEGL_HOST_PROOF_FILE:?}" \
            --expected-proof-sha "${AMCL_MOBILEGL_HOST_PROOF_SHA:?}" \
            --expected-source "${AMCL_MOBILEGL_SOURCE_COMMIT:?}" \
            --expected-image "${AMCL_MOBILEGL_HOST_IMAGE:?}" --output /output/mobilegl-cpu "$@" ;;
    gl4es-draw) exec bash /workspace/tests/gl4es-draw/run-host.sh "$@" ;;
    java-sound-8) exec bash /workspace/tests/java-sound/run-host8.sh ;;
    java-sound-17)
        # 该模式只有 project.py 的固定闭包/SHA 校验能建立，默认软件资格保持原入口。
        if [ -n "${AMCL_DAUDIO_INPUT_SHA:-}" ]; then
            exec bash /workspace/tests/java-sound/run-daudio-jni-host.sh
        fi
        exec bash /workspace/tests/java-sound/run-host.sh 17 ;;
    java-sound-21|java-sound-25)
        exec bash /workspace/tests/java-sound/run-host.sh "${suite##*-}" ;;
    *) echo 'Unknown AMCL test suite'; exit 2 ;;
esac
