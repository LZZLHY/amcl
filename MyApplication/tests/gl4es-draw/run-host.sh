#!/bin/bash
# 固定 qa 服务以只读源码种子启动；源码与编译树均落到本轮外置 /output。
set -euo pipefail
exec python3 -B /workspace/tests/gl4es-draw/run-host.py \
    --source /gl4es-source --output /output/gl4es-draw "${@}"
