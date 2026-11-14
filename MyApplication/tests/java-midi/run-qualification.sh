#!/bin/bash
# 固定amcl/qa工具链镜像中的四代boot JVM；输出独占且保留所有正/负例原件。
# 当前SDK声明快照明确来自宿主API26 SDK，不能由此推断镜像内安装了该SDK。
set -euo pipefail
root=/workspace/tests/java-midi
python3 -B "$root/run-host.py" --sdk-headers "$root/reference/sdk" --out /output/midi-primitives
python3 -B "$root/run-jni-host.py" --out /output/midi-jni
