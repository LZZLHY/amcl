#!/bin/bash
# 仅由固定 amcl QA 调用；源码清单所在目录只读挂载，全部中间/结果写独占 output。
set -euo pipefail
exec python3 -B /workspace/tests/runtime-fontconfig/run-freetype.py \
    --sources "${AMCL_FONTCONFIG_SOURCES_MANIFEST:-/fontconfig-sources/sources.json}" \
    --output /output/freetype-behavior --jobs "${AMCL_FONTCONFIG_TEST_JOBS:-4}"
