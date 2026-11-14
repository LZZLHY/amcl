#!/bin/bash
# 兼容旧调用位置；实际供应者、审核和输出统一使用现行入口。
set -euo pipefail
exec bash /recipes/scripts/prepare_jdk_abi.sh 8 /build/jdk8-libs
