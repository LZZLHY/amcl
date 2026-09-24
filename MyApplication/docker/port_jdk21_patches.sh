#!/bin/bash
# port_jdk21_patches.sh — 把 JDK 17 的 8 个 OHOS patch 移植到 jdk21u
#
# 在 ohos-debug 容器内运行：
#   docker exec ohos-debug bash /build/scripts/../port_jdk21_patches.sh
#   # 或 mount 在 /build/port_jdk21_patches.sh 后直接 bash
#
# 输出：jdk21u/.git 下生成 8 个 git diff，最终保存到 /jdk21-spec/patches/（host 可写）
#
# 策略：
#   1. 重置 jdk21u 工作树
#   2. 对每个 patch 应用对应修改
#   3. git diff > patch 文件
#   4. 重置工作树，再 apply --check 验证
set -euo pipefail

JDK=/build/jdk21u
PATCH_OUT=/tmp/jdk21-patches-new
mkdir -p "$PATCH_OUT"

cd "$JDK"
git config user.email "build@amcl.local" 2>/dev/null || true
git config user.name "AMCL Build" 2>/dev/null || true
git reset --hard HEAD
git clean -fdx -- src/

echo "=== Generating JDK 21 OHOS patches ==="

# ============================================================
# 0001: musl dlvsym + dlinfo
# Strategy:
#   - JDK 21u shipped a fallback `static dlvsym` shim guarded by `#ifdef MUSL_LIBC`,
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
fp = '/build/jdk21u/src/hotspot/os/linux/os_linux.cpp'
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
new = '''// OHOS PATCH: dropped the JDK 21u shim `static dlvsym` for MUSL_LIBC.
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
fp = '/build/jdk21u/src/hotspot/os/linux/os_linux.cpp'
with open(fp) as f: s = f.read()

# Gate with __MUSL__: host buildjdk must NOT use JAVA_HOME env var
# (that points to boot JDK and would break buildjdk runtime).
old = '''        *pslash = '\\0';        // Get rid of /lib.
      }
    }
    Arguments::set_java_home(buf);'''
new = '''        *pslash = '\\0';        // Get rid of /lib.
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
fp = '/build/jdk21u/src/hotspot/os/linux/os_linux.cpp'
with open(fp) as f: s = f.read()

# Gate with __MUSL__: host buildjdk must NOT use SUN_BOOT_LIBRARY_PATH env var.
old = '''      *pslash = '\\0';            // Get rid of /{client|server|hotspot}.
    }
    Arguments::set_dll_dir(buf);'''
new = '''      *pslash = '\\0';            // Get rid of /{client|server|hotspot}.
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
fp = '/build/jdk21u/src/hotspot/os/posix/os_posix.cpp'
with open(fp) as f: s = f.read()

# JDK 21 print_uptime_info: setutxent loop without endutxent() trailer.
# Wrap setutxent..break;}\n  } block with #ifndef __MUSL__ ... #else (void)ent; #endif.
# Anchor: the unique '  setutxent();\n' line. Capture from that line through the closing '  }\n'
# of the while loop. Insert wrap markers on their own lines so we don't merge with the line above.
import re
m = re.search(
    r'(  setutxent\(\);\n  while \(\(ent = getutxent\(\)\)\) \{\n    if \(!strcmp\("system boot", ent->ut_line\)\) \{\n      bootsec = ent->ut_tv\.tv_sec;\n      break;\n    \}\n  \}\n)(  endutxent\(\);\n)?',
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
fp = '/build/jdk21u/src/hotspot/os/posix/signals_posix.cpp'
with open(fp) as f: s = f.read()

# JDK 21 renamed parameter to 'context'. We replace the JVM_HANDLE_XXX_SIGNAL call
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

# ============================================================
# 0006: aarch64 ELF safepoint fallback
# ============================================================
echo "[0006] aarch64-elf-safepoint-fallback..."
python3 << 'PYEOF'
fp = '/build/jdk21u/src/hotspot/os_cpu/linux_aarch64/os_linux_aarch64.cpp'
with open(fp) as f: s = f.read()

# Insert the ELF-loader safepoint fallback before "if (stub != nullptr) {".
# os_linux_aarch64.cpp only compiles for aarch64 target, never for x86_64
# buildjdk, so we can leave this unconditional. But adding __MUSL__ guard
# is harmless extra safety (in case someone ever builds buildjdk on aarch64 host).
import re
m = re.search(r'(\n)(\n  if \(stub != nullptr\) \{\n    // save all thread context in case we need to restore it\n)', s)
if m is None:
    m = re.search(r'(\n)(\n  if \(stub != NULL\) \{\n    // save all thread context in case we need to restore it\n)', s)
assert m is not None, "stub != nullptr anchor not found in os_linux_aarch64.cpp"

insert = '''
#ifdef __MUSL__
  // OHOS PATCH: fallback for ELF-loaded code that CodeCache doesn't know about.
  // When JVM handler can't find a stub (ELF code not in CodeCache), handle
  // safepoint polling SEGV by disarming the polling page directly.
  if (stub == nullptr && sig == SIGSEGV && info != nullptr) {
    address fault_addr = (address)info->si_addr;
    if (SafepointMechanism::is_poll_address(fault_addr)) {
      // Safepoint polling from ELF-loaded code: disarm polling page
      os::protect_memory((char*)SafepointMechanism::get_polling_page(),
                         os::vm_page_size(), os::MEM_PROT_READ);
      return true; // retry the faulting instruction (now readable)
    }
  }
#endif
'''

s = s[:m.start(2)] + insert + s[m.start(2):]
with open(fp, 'w') as f: f.write(s)
print("OK 0006")
PYEOF

git diff > "$PATCH_OUT/0006-aarch64-elf-safepoint-fallback.patch"
echo "  generated $(wc -l < $PATCH_OUT/0006-aarch64-elf-safepoint-fallback.patch) lines"
git reset --hard HEAD
git clean -fdx -- src/

# ============================================================
# 0007: safepoint mechanism MEM_PROT_READ
# ============================================================
echo "[0007] safepoint-mechanism-mem-prot-read..."
python3 << 'PYEOF'
fp = '/build/jdk21u/src/hotspot/share/runtime/safepointMechanism.cpp'
with open(fp) as f: s = f.read()

# Gate change with __MUSL__: only OHOS target uses MEM_PROT_READ; host buildjdk
# keeps MEM_PROT_NONE so its polling SIGSEGV mechanism still works.
old = '    os::protect_memory(bad_page,  page_size, os::MEM_PROT_NONE);'
new = '''#ifdef __MUSL__
    // OHOS PATCH: avoid SIGSEGV for safepoint polling; readable + 0006 fallback handles it.
    os::protect_memory(bad_page,  page_size, os::MEM_PROT_READ);
#else
    os::protect_memory(bad_page,  page_size, os::MEM_PROT_NONE);
#endif'''
if old in s:
    s = s.replace(old, new, 1)
else:
    raise SystemExit("safepoint MEM_PROT_NONE not found")
with open(fp, 'w') as f: f.write(s)
print("OK 0007")
PYEOF

git diff > "$PATCH_OUT/0007-safepoint-mechanism-mem-prot-read.patch"
echo "  generated $(wc -l < $PATCH_OUT/0007-safepoint-mechanism-mem-prot-read.patch) lines"
git reset --hard HEAD
git clean -fdx -- src/

# ============================================================
# 0008: libjli skip re-exec
# ============================================================
echo "[0008] libjli-skip-re-exec..."
python3 << 'PYEOF'
fp = '/build/jdk21u/src/java.base/unix/native/libjli/java_md.c'
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
# 0009 (REMOVED in v6 — 2026-05-19)
#
# 历史：v3-v5 期间 patch 0009 (ohos-platform-graphics-info) 试图改 java.desktop
# 模块的 PlatformGraphicsInfo.createGE/createToolkit/getDefaultHeadlessProperty，
# 让 OHOS 走自带的 OhosHeadlessGE/Toolkit 绕开 X11。
#
# 失败原因：jvm_launcher.cpp / fork_run_java.cpp 同时设了 -Djava.awt.headless=false
# (Cacio 模式遗留)，system property 优先级高于 platform default，patch 完全被
# 绕过；崩点最终落在 Insets.<clinit>.initIDs（native 在 --enable-headless-only
# 编译已不构建的 libawt_xawt.so 里）。
#
# v6 决策：放弃 Cacio，主进程 + Forge installer 子进程都设 -Djava.awt.headless=true，
# 让 OpenJDK 自带 sun.awt.HeadlessToolkit 接管。所有 AWT 类的 <clinit> 通过
# if (!isHeadless()) 保护跳过 native initIDs() 调用 —— 不需要 patch 源码。
#
# 详见 docs/archive/jdk21-awt-headless-journey-202605.md §5（第一阶段方案）。
# ============================================================

# ============================================================
# Final: copy to /jdk21-spec/patches (host writable mount)
# ============================================================
echo ""
echo "=== Patches generated, verifying all apply cleanly on fresh tree ==="

# Verify each patch applies cleanly when applied in series
git reset --hard HEAD
git clean -fdx -- src/
for p in 0001 0002 0003 0004 0005 0006 0007 0008; do
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
echo "=== All 8 patches applied cleanly on fresh jdk21u tree ==="
ls -la "$PATCH_OUT/"

