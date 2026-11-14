#!/bin/bash
# 固定 amcl QA 的短回归；只读锁定原/候选源，所有输出写外置独占目录。
set -euo pipefail
python3 -B /workspace/tests/runtime-fontconfig/run-fallback.py \
    --sources "${AMCL_FONTCONFIG_FALLBACK_SOURCES_MANIFEST:?}" --output /output/fontconfig-fallback
if python3 -c 'import json,sys;sys.exit(json.load(open(sys.argv[1]))["schemaVersion"] != 2)' "$AMCL_FONTCONFIG_FALLBACK_SOURCES_MANIFEST"; then
    python3 -B /workspace/tests/runtime-fontconfig/run-stream.py \
        --sources "$AMCL_FONTCONFIG_FALLBACK_SOURCES_MANIFEST" --output /output/font-stream-jni
else
    printf '%s\n' 'Font stream JNI NOT RUN: historical v1 input manifest has no stream source.'
fi
exec bash /workspace/tests/runtime-fontconfig/run-font-context.sh
