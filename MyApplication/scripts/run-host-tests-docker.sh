#!/usr/bin/env bash
# run-host-tests-docker.sh — 在 Linux 容器里编译并**执行** C++ host 测试的断言
#
# 与 `run-host-tests-msvc.ps1` 的关系：**同一批断言、不同的宿主语义**。
#   · MSVC 那条：LLP64 + MSVC 语义。
#   · 本条：**LP64** + GCC + glibc，`std::mutex` 落在真 pthread 上，且可加 ASan/UBSan、
#     可进 GitHub Actions（同级仓库 amcl-qa 的 qa-native job 已证明这条路可行）。
# 两条都不能替代 `check-host-tests-crosscompile.ps1`（aarch64 编译面）与真机回归。
#
# 用法（从 Windows 宿主，工作区根 = MyApplication 的父目录）：
#   docker run --rm -v "<workspace-root>:/work" -w /work/MyApplication \
#       amcl-qa-native bash scripts/run-host-tests-docker.sh
#
# 可选环境变量：
#   AMCL_HOST_TEST_SANITIZE=1   加 -fsanitize=address,undefined（会显著变慢）
#   AMCL_HOST_TEST_FILTER=<正则> 只跑匹配的用例（传给 ctest -R）
#
# ⚠️ 镜像里已有 build-essential / cmake / ninja-build，**不需要额外装包**。
set -euo pipefail

hostDir="entry/src/main/cpp/tests/host"
buildDir="${hostDir}/build-linux-host"

if [ ! -f "${hostDir}/CMakeLists.txt" ]; then
    echo "找不到 ${hostDir}/CMakeLists.txt —— 请把 -w 指到 MyApplication 目录" >&2
    exit 2
fi

echo "=== host tests (GCC / Linux x86-64) ==="
for t in c++ cmake ninja; do
    printf '  %s: ' "$t"
    command -v "$t" >/dev/null 2>&1 && "$t" --version | head -1 || { echo MISSING; exit 2; }
done

# ⚠️ `-Wno-error=missing-field-initializers`：与 check-host-tests-crosscompile.ps1 同一条原则 ——
# **只在调用层抑制，绝不改源码去迁就验证手段**。这里它是相对意图的**纯误报**：
# `GlfwInputAdapter::Impl::InFlight` 有 19 个成员且**几乎每个都带类内默认初始化器**，所以
# `{true, ticket, incarnation, event}` 里没写的成员拿到的是它们**声明处的默认值**（空 map /
# false / `{}`），而"一条新的 in-flight 记录没有回滚快照"正是设计意图。GCC 与 clang 对这个
# 模式过度告警，MSVC 不报 —— 所以 MSVC 那条路线 29/29 全绿而这里会红。
# 用 `-Wno-error=` 而不是 `-Wno-`：告警仍然打印，只是不再致命，不会顺手掩掉将来的新告警。
extraFlags='-Wno-error=missing-field-initializers'
if [ "${AMCL_HOST_TEST_SANITIZE:-0}" = "1" ]; then
    # 刻意只在这里注入，不写进 CMakeLists：sanitizer 是验证手段，不是项目的构建契约。
    extraFlags="${extraFlags} -fsanitize=address,undefined -fno-omit-frame-pointer -g"
    echo "  sanitizers: ON"
fi

rm -rf "${buildDir}"
# ⚠️ CMake 的 flag 顺序坑（交叉脚本文件头已记）：`CMAKE_CXX_FLAGS` 排在 `target_compile_options`
# **之前**，所以在这里写 `-Wno-missing-field-initializers` 会被随后的 `-Wextra` 重新打开。
# `-Wno-error=<name>` 不受这个影响：它改的是"该诊断是否致命"，与 `-W`/`-Wno-` 的开关是两回事。
cmake -S "${hostDir}" -B "${buildDir}" -G Ninja \
      -DCMAKE_CXX_FLAGS="${extraFlags}" \
      -DCMAKE_EXE_LINKER_FLAGS="${extraFlags}" \
      >/dev/null
cmake --build "${buildDir}"
echo

ctestArgs=(--output-on-failure)
if [ -n "${AMCL_HOST_TEST_FILTER:-}" ]; then
    ctestArgs+=(-R "${AMCL_HOST_TEST_FILTER}")
fi
rc=0
ctest --test-dir "${buildDir}" "${ctestArgs[@]}" || rc=$?

echo
if [ "${rc}" -eq 0 ]; then
    echo 'HOST TEST ASSERTIONS PASS (GCC / Linux x86-64)'
    echo '  ⚠️ 只证明 LP64 + GCC 语义下断言成立；aarch64 行为仍需交叉脚本 + 真机。'
else
    echo "HOST TEST RUN FAILED (exit ${rc})"
fi
exit "${rc}"
