#!/bin/bash
# 固定 amcl/qa 工具链镜像已有 17/21 JVM；真正运行同一 class52 的 /bin/sh builtin 路径。
# 源/二进制/流/异常/负控全部留在本次 /output，不修改宿主 JDK 或生产参数。
set -euo pipefail
root=/workspace/tests/runtime-childproc
out=/output/runtime-childproc-java
python3 "$root/run-java-host.py" \
    --javac /usr/lib/jvm/java-17-openjdk-amd64/bin/javac \
    --java /usr/lib/jvm/java-17-openjdk-amd64/bin/java \
    --java /usr/lib/jvm/temurin-21-jdk-amd64/bin/java \
    --output "$out"
python3 "$root/test-java-process-verifier.py" \
    --evidence "$out/run-17-0/java-process" --major 17 --platform unix-host \
    --expected-run-directory "$out/run-17-0" --output "$out/verifier-controls"
