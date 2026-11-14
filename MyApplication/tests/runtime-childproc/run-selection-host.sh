#!/bin/bash
# 完整候选Java类+实际JVMTI/JNI注册，运行在固定工具链镜像已有17/21/25 boot JVM中。
# 用模拟uname观察默认分支；显式机制的读取/验证仍由完整ProcessImpl原源码执行。
set -euo pipefail
root=/workspace/tests/runtime-childproc
out=/output/runtime-childproc-source
for major in 17 21 25; do
    if [ "$major" = 17 ]; then jdk=/usr/lib/jvm/java-17-openjdk-amd64
    else jdk="/usr/lib/jvm/temurin-$major-jdk-amd64"; fi
    test -x "$jdk/bin/javac"
    candidate="$out/candidates/$major"
    mkdir -p "$candidate/java-src/java/lang" "$candidate/patch-classes" "$candidate/test-classes"
    cp "$candidate/ProcessImpl.java" "$candidate/java-src/java/lang/ProcessImpl.java"
    "$jdk/bin/javac" -encoding UTF-8 --patch-module java.base="$candidate/java-src" \
        -d "$candidate/patch-classes" "$candidate/java-src/java/lang/ProcessImpl.java"
    "$jdk/bin/javac" -encoding UTF-8 -d "$candidate/test-classes" "$root/PlatformSelection.java"
    gcc -std=c11 -O2 -fPIC -shared -D_GNU_SOURCE -D__OHOS__ -I"$jdk/include" -I"$jdk/include/linux" \
        -I"$candidate" "$root/platform_selection_agent.c" -o "$candidate/platform-ohos-agent.so"
    gcc -std=c11 -O2 -fPIC -shared -D_GNU_SOURCE -I"$jdk/include" -I"$jdk/include/linux" \
        -I"$candidate" "$root/platform_selection_agent.c" -o "$candidate/platform-linux-agent.so"
    "$jdk/bin/java" -version >"$candidate/selection-vm-version.log" 2>&1
    sha256sum "$jdk/lib/server/libjvm.so" >"$candidate/selection-vm.sha256"
    for row in \
        'HarmonyOS:1 Linux default FORK ohos' \
        'OpenHarmony:1 Linux default FORK ohos' \
        'OHOS:1 Linux default FORK ohos' \
        'Linux:1 HarmonyOS default POSIX_SPAWN ohos' \
        'error:1 Linux default POSIX_SPAWN ohos' \
        'HarmonyOS:0 Linux POSIX_SPAWN POSIX_SPAWN ohos' \
        'HarmonyOS:0 Linux VFORK VFORK ohos' \
        'Linux:0 Linux FORK FORK ohos' \
        'HarmonyOS:0 Linux invalid INVALID ohos' \
        'HarmonyOS:1 Linux default POSIX_SPAWN linux'; do
        read -r native os requested expected build <<<"$row"
        options=()
        if [ "$requested" != default ]; then options+=("-Djdk.lang.Process.launchMechanism=$requested"); fi
        log="$candidate/selection-${native/:/-}-$requested-$build.log"
        timeout --signal=KILL 15s "$jdk/bin/java" -Xcheck:jni --add-opens=java.base/java.lang=ALL-UNNAMED \
            --patch-module java.base="$candidate/patch-classes" \
            "-agentpath:$candidate/platform-$build-agent.so=$native" "-Dos.name=$os" "${options[@]}" \
            -cp "$candidate/test-classes" PlatformSelection "$expected" >"$log" 2>&1
        cat "$log"
        if grep -E 'WARNING in native method|FATAL ERROR in native method' "$log"; then exit 1; fi
    done
done
