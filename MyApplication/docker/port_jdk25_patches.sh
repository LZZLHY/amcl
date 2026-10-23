#!/bin/bash
# port_jdk25_patches.sh — 维护JDK25受审基础补丁，保留上游安全点协议
#
# MC 26.1+（YY.D.H 版本号格式）首个要求 Java 25 的版本。本脚本与
# port_jdk21_patches.sh的历史移植背景见适配评估；0006/0007已退役，不能再生成。
# 锚点存在和patch可应用不代表语义正确，真实源码还要通过25专项安全点守卫。
#
# 在 ohos-debug 容器内运行：
#   docker exec ohos-debug bash /build/port_jdk25_patches.sh
#
# 输出：只生成下方明确列出的基础补丁，写到本次外部/output子目录；后续独立补丁
# 仍由活动series管理。输出目录必须为空，不能把上次残留的历史补丁再次通配复制。
#
# 策略：
#   1. 重置 jdk25u 工作树
#   2. 对每个 patch 应用对应修改
#   3. git diff > patch 文件
#   4. 重置工作树，再 apply --check 验证
set -euo pipefail

JDK=/build/jdk25u
PATCH_OUT=${AMCL_JDK25_PATCH_OUTPUT:-/output/jdk25-patches-new}
mkdir -p "$PATCH_OUT"
if [[ -n "$(find "$PATCH_OUT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "ERROR: patch output must be empty; preserve the previous output and choose a new directory" >&2
    exit 1
fi

cd "$JDK"
git config user.email "build@amcl.local" 2>/dev/null || true
git config user.name "AMCL Build" 2>/dev/null || true
git reset --hard HEAD
git clean -fdx -- src/

echo "=== Generating JDK 25 OHOS patches ==="

# ============================================================
# 0001: musl dlvsym + dlinfo
# Strategy:
#   - jdk25u still ships a fallback `static dlvsym` shim guarded by `#ifdef MUSL_LIBC`,
#     for the case where musl libc doesn't provide dlvsym. But:
#       * Modern OHOS musl headers DO declare dlvsym (in dlfcn.h);
#       * The buildjdk image (host glibc) ALSO inherits -DMUSL_LIBC, where
#         glibc obviously declares dlvsym;
#     → On both target and buildjdk, the shim conflicts with the real declaration.
#   - Fix: simply drop the static shim entirely. musl/glibc both provide dlvsym.
#   - For the dlinfo() call: musl on OHOS truly doesn't have dlinfo, so guard
#     with `#if defined(MUSL_LIBC) && !defined(__GLIBC__)`.
# ============================================================
echo "[0001] musl-dlvsym-dlinfo..."
python3 << 'PYEOF'
import re
fp = '/build/jdk25u/src/hotspot/os/linux/os_linux.cpp'
with open(fp) as f: s = f.read()

# Patch 1: drop the static dlvsym shim. Modern OHOS musl provides dlvsym natively.
old = '''#ifdef MUSL_LIBC
// dlvsym is not a part of POSIX
// and musl libc doesn't implement it.
static void *dlvsym(void *handle,
                    const char *symbol,
                    const char *version) {
   // load the latest version of symbol
   return dlsym(handle, symbol);
}
#endif'''
new = '''// OHOS PATCH: dropped the jdk25u shim `static dlvsym` for MUSL_LIBC.
// Modern OHOS musl declares dlvsym in <dlfcn.h>, so the shim conflicts;
// glibc obviously declares dlvsym too — buildjdk on host glibc inherits
// -DMUSL_LIBC from the target spec and would also conflict.
// Both libcs provide a real dlvsym now, no shim needed.'''
assert old in s, "dlvsym block not found"
s = s.replace(old, new, 1)

# Patch 2: dlinfo guard inside dll_path — gate so host build (glibc) keeps real dlinfo,
# OHOS musl target falls back to the no-op path.
old2 = '''  assert(lib != nullptr, "dll_path parameter must not be null");

  int res_dli = ::dlinfo(lib, RTLD_DI_LINKMAP, &lmap);'''
new2 = '''  assert(lib != nullptr, "dll_path parameter must not be null");

#if defined(MUSL_LIBC) && !defined(__GLIBC__)
  // OHOS PATCH: musl does not have dlinfo(); host glibc does.
  int res_dli = -1;
  (void)lmap;
#else
  int res_dli = ::dlinfo(lib, RTLD_DI_LINKMAP, &lmap);
#endif'''
assert old2 in s, "dlinfo block not found"
s = s.replace(old2, new2, 1)

with open(fp, 'w') as f: f.write(s)
print("OK 0001")
PYEOF

git diff > "$PATCH_OUT/0001-musl-dlvsym-dlinfo.patch"
echo "  generated $(wc -l < $PATCH_OUT/0001-musl-dlvsym-dlinfo.patch) lines"
git reset --hard HEAD
git clean -fdx -- src/

# ============================================================
# 0002: java-home env var
# ============================================================
echo "[0002] java-home-env..."
python3 << 'PYEOF'
fp = '/build/jdk25u/src/hotspot/os/linux/os_linux.cpp'
with open(fp) as f: s = f.read()

# Gate with __MUSL__: host buildjdk must NOT use JAVA_HOME env var
# (that points to boot JDK and would break buildjdk runtime).
# jdk25u dropped the `// Get rid of /lib.` trailing comment; anchor on the
# whole pslash block ending at set_java_home (unique because set_java_home
# appears once). Indentation verified against jdk-25.0.4+3.
old = '''    if (pslash != nullptr) {
      pslash = strrchr(buf, '/');
      if (pslash != nullptr) {
        *pslash = '\\0';
      }
    }
    Arguments::set_java_home(buf);'''
new = '''    if (pslash != nullptr) {
      pslash = strrchr(buf, '/');
      if (pslash != nullptr) {
        *pslash = '\\0';
      }
    }
#ifdef __MUSL__
    // OHOS PATCH: prefer JAVA_HOME env var (sandbox path inference fails)
    {
      const char* java_home_env = ::getenv("JAVA_HOME");
      if (java_home_env != nullptr && java_home_env[0] != '\\0') {
        Arguments::set_java_home(java_home_env);
      } else {
        Arguments::set_java_home(buf);
      }
    }
#else
    Arguments::set_java_home(buf);
#endif'''
assert old in s, "set_java_home block not found"
s = s.replace(old, new, 1)
with open(fp, 'w') as f: f.write(s)
print("OK 0002")
PYEOF

git diff > "$PATCH_OUT/0002-java-home-env.patch"
echo "  generated $(wc -l < $PATCH_OUT/0002-java-home-env.patch) lines"
git reset --hard HEAD
git clean -fdx -- src/

# ============================================================
# 0003: dll-dir env var
# ============================================================
echo "[0003] dll-dir-env..."
python3 << 'PYEOF'
fp = '/build/jdk25u/src/hotspot/os/linux/os_linux.cpp'
with open(fp) as f: s = f.read()

# Gate with __MUSL__: host buildjdk must NOT use SUN_BOOT_LIBRARY_PATH env var.
# jdk25u dropped the trailing `// Get rid of /{client|server|hotspot}.` comment;
# anchor on the pslash block ending at set_dll_dir (unique). Verified jdk-25.0.4+3.
old = '''      pslash = strrchr(buf, '/');
      if (pslash != nullptr) {
        *pslash = '\\0';
      }
    }
    Arguments::set_dll_dir(buf);'''
new = '''      pslash = strrchr(buf, '/');
      if (pslash != nullptr) {
        *pslash = '\\0';
      }
    }
#ifdef __MUSL__
    // OHOS PATCH: prefer SUN_BOOT_LIBRARY_PATH env var
    {
      const char* dll_dir_env = ::getenv("SUN_BOOT_LIBRARY_PATH");
      if (dll_dir_env != nullptr && dll_dir_env[0] != '\\0') {
        Arguments::set_dll_dir(dll_dir_env);
      } else {
        Arguments::set_dll_dir(buf);
      }
    }
#else
    Arguments::set_dll_dir(buf);
#endif'''
assert old in s, "set_dll_dir block not found"
s = s.replace(old, new, 1)
with open(fp, 'w') as f: f.write(s)
print("OK 0003")
PYEOF

git diff > "$PATCH_OUT/0003-dll-dir-env.patch"
echo "  generated $(wc -l < $PATCH_OUT/0003-dll-dir-env.patch) lines"
git reset --hard HEAD
git clean -fdx -- src/

# ============================================================
# 0004: musl utmpx
# ============================================================
echo "[0004] musl-utmpx..."
python3 << 'PYEOF'
fp = '/build/jdk25u/src/hotspot/os/posix/os_posix.cpp'
with open(fp) as f: s = f.read()

# print_uptime_info: setutxent loop without endutxent() trailer.
# Wrap setutxent..break;}\n  } block with #ifndef __MUSL__ ... #else (void)ent; #endif.
# Anchor: the unique '  setutxent();\n' line. Capture from that line through the closing '  }\n'
# of the while loop. Insert wrap markers on their own lines so we don't merge with the line above.
import re
m = re.search(
    r'(  setutxent\(\);\n  while \(\(ent = getutxent\(\)\)\) \{\n    if \(!strcmp\("system boot", ent->ut_line\)\) \{\n      bootsec = \(int\)ent->ut_tv\.tv_sec;\n      break;\n    \}\n  \}\n)(  endutxent\(\);\n)?',
    s)
assert m is not None, "utmpx setutxent block not found"
start = m.start()
end = m.end()
inner = s[start:end]
wrapped = "#ifndef __MUSL__\n" + inner + "#else\n  (void)ent;\n#endif\n"
s = s[:start] + wrapped + s[end:]
with open(fp, 'w') as f: f.write(s)
print("OK 0004")
PYEOF

git diff > "$PATCH_OUT/0004-musl-utmpx.patch"
echo "  generated $(wc -l < $PATCH_OUT/0004-musl-utmpx.patch) lines"
git reset --hard HEAD
git clean -fdx -- src/

# ============================================================
# 0005: signals_posix abort if unrecognized
# ============================================================
echo "[0005] signals-posix-abort-if-unrecognized..."
python3 << 'PYEOF'
fp = '/build/jdk25u/src/hotspot/os/posix/signals_posix.cpp'
with open(fp) as f: s = f.read()

# Parameter is 'context' (same as JDK 21). Replace the JVM_HANDLE_XXX_SIGNAL call
# with one that doesn't abort; gate with __MUSL__ so host buildjdk keeps the
# original strict behavior (avoid affecting jmod/javac runtime).
old = '''  // Only add code to either JVM_HANDLE_XXX_SIGNAL or PosixSignals::pd_hotspot_signal_handler.
  (void)JVM_HANDLE_XXX_SIGNAL(sig, info, context, true);'''
new = '''  // Only add code to either JVM_HANDLE_XXX_SIGNAL or PosixSignals::pd_hotspot_signal_handler.
#ifdef __MUSL__
  // OHOS PATCH: do not abort on unrecognized signal — devices send misc signals.
  (void)JVM_HANDLE_XXX_SIGNAL(sig, info, context, false);
#else
  (void)JVM_HANDLE_XXX_SIGNAL(sig, info, context, true);
#endif'''
assert old in s, "javaSignalHandler call not found"
s = s.replace(old, new, 1)
with open(fp, 'w') as f: f.write(s)
print("OK 0005")
PYEOF

git diff > "$PATCH_OUT/0005-signals-posix-abort-if-unrecognized.patch"
echo "  generated $(wc -l < $PATCH_OUT/0005-signals-posix-abort-if-unrecognized.patch) lines"
git reset --hard HEAD
git clean -fdx -- src/

# 0006/0007保留历史原件但不再生成：共享坏页必须不可读，未知fault不能全局disarm。
# 这里刻意不触碰安全点和AArch64信号文件；编译前会核对其与锁定上游完全一致。

# ============================================================
# 0008: libjli skip re-exec
# ============================================================
echo "[0008] libjli-skip-re-exec..."
python3 << 'PYEOF'
fp = '/build/jdk25u/src/java.base/unix/native/libjli/java_md.c'
with open(fp) as f: s = f.read()

# Gate libjli's re-exec skip with __MUSL__: only OHOS target skips re-exec.
# Host buildjdk's libjli must keep original re-exec logic.
import re
m = re.search(r'(RequiresSetenv\(const char \*jvmpath\) \{\n)', s)
assert m is not None, "RequiresSetenv() function not found"
inject = '''#ifdef __MUSL__
    /* OHOS patch: skip re-exec entirely - our ELF loader handles everything */
    return JNI_FALSE;
#endif
'''
s = s[:m.end()] + inject + s[m.end():]
with open(fp, 'w') as f: f.write(s)
print("OK 0008")
PYEOF

git diff > "$PATCH_OUT/0008-libjli-skip-re-exec.patch"
echo "  generated $(wc -l < $PATCH_OUT/0008-libjli-skip-re-exec.patch) lines"
git reset --hard HEAD
git clean -fdx -- src/

# ============================================================
# 0009: JFR CPU-time per-thread sampler — musl SIGEV_THREAD_ID 不支持
#
# JDK 25 新增 JFR CPU-time profiling（jfrCPUTimeThreadSampler.cpp，JDK 21 没有），
# create_timer_for_thread 用 glibc 扩展 SIGEV_THREAD_ID + ((int*)&sev.sigev_notify)[1]
# 把定时器信号投递到指定线程。musl：
#   1. 不定义 SIGEV_THREAD_ID（只有 SIGEV_SIGNAL/NONE/THREAD）→ 编译报
#      "use of undeclared identifier 'SIGEV_THREAD_ID'"；
#   2. struct sigevent 布局与 glibc 不同（sigev_notify 之后是 sigev_notify_function
#      指针，不是 glibc 的 _tid），glibc 的 ((int*)&sev.sigev_notify)[1] 写法在 musl
#      上会破坏函数指针字段 —— 即便定义了宏也不能正确工作。
#
# 决策：OHOS target 上 create_timer_for_thread 直接 return false（优雅降级）。
# 调用方（on_javathread_start）已处理 false：log 一次 warning + 释放队列后继续。
# JFR CPU-time profiling 是诊断特性，MC 不用，禁用零功能影响。gate __MUSL__。
# ============================================================
echo "[0009] jfr-cpu-time-musl-disable..."
python3 << 'PYEOF'
fp = '/build/jdk25u/src/hotspot/share/jfr/periodic/sampling/jfrCPUTimeThreadSampler.cpp'
with open(fp) as f: s = f.read()

# Anchor on the function body opening. Insert an early `return false` gated by __MUSL__,
# right after the function's opening brace, before `struct sigevent sev;`.
old = '''bool JfrCPUSamplerThread::create_timer_for_thread(JavaThread* thread, timer_t& timerid) {
  struct sigevent sev;'''
new = '''bool JfrCPUSamplerThread::create_timer_for_thread(JavaThread* thread, timer_t& timerid) {
#ifdef __MUSL__
  // OHOS PATCH: musl lacks SIGEV_THREAD_ID and uses a different struct sigevent
  // layout than glibc, so per-thread CPU-time JFR timers can't be created here.
  // Degrade gracefully (caller logs a one-time warning + frees the queue).
  // JFR CPU-time profiling is a diagnostic feature unused by Minecraft.
  (void)thread; (void)timerid;
  return false;
#else
  struct sigevent sev;'''
assert old in s, "create_timer_for_thread opening not found"
s = s.replace(old, new, 1)

# Close the #else branch before the closing brace of THIS function. The function
# ends with the unique sequence below (set_timer_time ... return true; }).
old2 = '''    set_timer_time(timerid, period);
  }
  return true;
}'''
new2 = '''    set_timer_time(timerid, period);
  }
  return true;
#endif
}'''
assert old2 in s, "create_timer_for_thread closing not found"
s = s.replace(old2, new2, 1)

with open(fp, 'w') as f: f.write(s)
print("OK 0009")
PYEOF

git diff > "$PATCH_OUT/0009-jfr-cpu-time-musl-disable.patch"
echo "  generated $(wc -l < $PATCH_OUT/0009-jfr-cpu-time-musl-disable.patch) lines"
git reset --hard HEAD
git clean -fdx -- src/

# ============================================================
# Final: verify all apply cleanly on fresh tree, then list
# ============================================================
echo ""
echo "=== Patches generated, verifying all apply cleanly on fresh tree ==="

git reset --hard HEAD
git clean -fdx -- src/
for p in 0001 0002 0003 0004 0005 0008 0009; do
    pfile=$(ls "$PATCH_OUT"/${p}-*.patch 2>/dev/null | head -1)
    [ -z "$pfile" ] && { echo "MISSING: $p"; exit 1; }
    if git apply --check "$pfile" 2>&1; then
        git apply "$pfile"
        echo "  OK: $(basename $pfile)"
    else
        echo "  FAIL: $(basename $pfile)"
        exit 1
    fi
done

echo ""
echo "=== Selected active base patches applied cleanly on fresh jdk25u tree ==="
ls -la "$PATCH_OUT/"
echo ""
echo "Next: review only the selected generated patches against the active series; never reactivate retired safepoint patches."
