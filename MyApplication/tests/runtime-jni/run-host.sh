#!/bin/bash
# 固定 Compose 测试入口：所有产物写独占 /output，不覆盖宿主 JDK 或工作区源码。
set -euo pipefail
src=/workspace/tests/runtime-jni
out=/output/jni-invocation
mkdir -p "$out/classes"
# 私有native临时根与marker读取先跑同一生产helper；所有样本生成在独占/output。
python3 -B "$src/native_temp_cases.py" --output "$out/native-temp"
# 目录必须先于真实 VM 线程进入；核心负例同时核对现有 fork/创建认领和 FD 归还。
g++ -std=c++17 -O2 -g "$src/game_directory_test.cpp" -o "$out/game-directory-test"
mkdir "$out/game-directory"
"$out/game-directory-test" "$out/game-directory"
g++ -std=c++17 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$src/main_call_test.cpp" -o "$out/main-call-faults"
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 "$out/main-call-faults"
g++ -std=c++17 -O1 -g -pthread -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$src/watchdog_test.cpp" -o "$out/watchdog-faults"
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 "$out/watchdog-faults"
/usr/lib/jvm/java-8-openjdk-amd64/bin/javac -encoding UTF-8 -g:none -d "$out/classes" \
    /workspace/docker/tests/HelloWorld.java "$src/InvocationFixture.java" "$src/InvocationCompletionFixture.java" \
    "$src/MainThreadCompletionFixture.java"
python3 "$src/emit-header.py" /workspace/docker/tests/HelloWorld.java \
    "$out/classes/HelloWorld.class" "$out/hello_world_class.h"
g++ -std=c++17 -O2 -pthread "$src/real_vm_test.cpp" -ldl -o "$out/real-vm"
for major in 8 17 21 25; do
    case "$major" in
        8) jdk=/usr/lib/jvm/java-8-openjdk-amd64; vm="$jdk/jre/lib/amd64/server/libjvm.so" ;;
        17) jdk=/usr/lib/jvm/java-17-openjdk-amd64; vm="$jdk/lib/server/libjvm.so" ;;
        *) jdk="/usr/lib/jvm/temurin-$major-jdk-amd64"; vm="$jdk/lib/server/libjvm.so" ;;
    esac
    "$jdk/bin/java" -version 2>"$out/jdk-$major-version.txt"
    sha256sum "$vm" >"$out/jdk-$major-vm.sha256"
    for mode in legacy-attached-destroy launcher-completion; do
        prefix="$out/main-join-$major-$mode"
        set +e
        timeout -k 2s 5s "$out/real-vm" "$vm" "$major" "$out/classes" "$prefix" "$mode" >"$prefix.log" 2>&1
        status=$?
        set -e
        grep -F 'MAIN_RETURN_BEFORE_COMPLETION' "$prefix.log" >/dev/null
        if [ "$mode" = legacy-attached-destroy ]; then
            [ "$status" = 124 ] && [ ! -e "$prefix.worker" ] && [ ! -e "$prefix.hook" ] || exit 1
            echo "PASS attached-Destroy negative VM=$major: main returned but join/hook could not complete"
        else
            [ "$status" = 0 ] || { cat "$prefix.log"; exit 1; }
            cat "$prefix.log"
        fi
        if grep -E 'WARNING in native method|FATAL ERROR in native method' "$prefix.log"; then exit 1; fi
    done
    for mode in normal fallback watchdog; do
        "$out/real-vm" "$vm" "$major" "$out/classes" "$out/classes/HelloWorld.class" "$mode" \
            >"$out/jdk-$major-$mode.log" 2>&1
        cat "$out/jdk-$major-$mode.log"
        if grep -E 'WARNING in native method|FATAL ERROR in native method' "$out/jdk-$major-$mode.log"; then
            echo 'CheckJNI reported an invalid native call'; exit 1
        fi
    done
    for mode in completion completion-throws legacy-immediate-exit; do
        prefix="$out/completion-$major-$mode"
        set +e
        "$out/real-vm" "$vm" "$major" "$out/classes" "$prefix" "$mode" >"$prefix.log" 2>&1
        status=$?
        set -e
        expected=0
        if [ "$mode" = completion-throws ]; then expected=1; fi
        cat "$prefix.log"
        if [ "$status" != "$expected" ]; then echo "Unexpected completion status $status"; exit 1; fi
        if grep -E 'WARNING in native method|FATAL ERROR in native method' "$prefix.log"; then exit 1; fi
        if [ "$mode" = legacy-immediate-exit ]; then
            # worker 可能受调度影响先写出；未进入关闭协议时 hook 必然没有执行，不能假设 sleep 精确。
            if [ -e "$prefix.hook" ]; then echo 'Legacy negative control unexpectedly ran shutdown hook'; exit 1; fi
            echo "PASS legacy immediate-exit negative VM=$major: shutdown hook omitted"
        fi
    done
    # 使用同一已锁定宿主 JDK 执行正式生产参数/属性门，包含堆预检负例和长字符串所有权。
    # 该脚本直接抽取生产正文，不能让 Windows default 门与四代 Linux QA 各自持有算法副本。
    python3 -B /workspace/scripts/test-jvm-bootstrap-invocation.py --java-home "$jdk" \
        --build-dir "$out/bootstrap-$major/build" --out-dir "$out/bootstrap-$major/results"
done
