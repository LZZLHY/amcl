#!/bin/bash
# 复用固定amcl/qa工具链；只产生外置重放及GNU make参数证据，不执行目标ELF。
set -euo pipefail
python3 -B /workspace/tests/java-sound/prepare-sound-link-patch.py --output /output/source > /output/source-replay.log
python3 -B /workspace/tests/java-sound/test-sound-link-make.py --sources /output/source --output /output/make
python3 -B /workspace/scripts/test-runtime-packaging.py
