#!/bin/bash
# 独立资格使用工具链镜像已有四代boot工具，仍复用固定amcl/qa服务。
set -euo pipefail
bash /workspace/tests/runtime-childproc/run-source-host.sh
bash /workspace/tests/runtime-childproc/run-selection-host.sh
bash /workspace/tests/runtime-childproc/run-java-host.sh
