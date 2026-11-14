#!/bin/bash
# 由现有 amcl/qa 的 java-sound-17 明确模式调用；输入/输出固定，绝不修改原 JDK 卷。
set -euo pipefail
exec python3 -B /workspace/tests/java-sound/run-daudio-jni.py
