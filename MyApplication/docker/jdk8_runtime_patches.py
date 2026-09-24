#!/usr/bin/env python3
# JDK 8 OHOS 运行时 patch（可干净移植的子集，__MUSL__ 门控）：
#   0002 java-home-env   : 沙箱路径推断不可靠 → 优先 JAVA_HOME 环境变量
#   0003 dll-dir-env     : 优先 SUN_BOOT_LIBRARY_PATH（注入的 native lib 目录）
#   0008 libjli-skip-reexec : RequiresSetenv 直接返回 JNI_FALSE（ELF loader 已处理库解析）
# 注：0005/0006/0007（signal/safepoint）针对 JDK17 thread-local handshake 机制，
#     JDK8 是旧全局 polling-page 机制，不可机械移植，需单独设计 + 真机验证，故不在此。
import sys

def patch(path, old, new, desc, count=1):
    s = open(path).read()
    if new.strip() in s:
        print("  [skip] already patched:", desc); return
    n = s.count(old)
    if n != count:
        print("  [FAIL] %s: expected %d match of anchor, got %d" % (desc, count, n)); sys.exit(1)
    open(path, "w").write(s.replace(old, new, count))
    print("  [ok]", desc)

OL = "/build/jdk8u/hotspot/src/os/linux/vm/os_linux.cpp"
JM = "/build/jdk8u/jdk/src/solaris/bin/java_md_solinux.c"

patch(OL,
    "    Arguments::set_java_home(buf);\n",
    "#ifdef __MUSL__\n"
    "    {\n"
    "      const char* amcl_java_home = ::getenv(\"JAVA_HOME\");\n"
    "      if (amcl_java_home != NULL && amcl_java_home[0] != '\\0') {\n"
    "        Arguments::set_java_home((char*)amcl_java_home); // OHOS: sandbox path inference unreliable\n"
    "      } else {\n"
    "        Arguments::set_java_home(buf);\n"
    "      }\n"
    "    }\n"
    "#else\n"
    "    Arguments::set_java_home(buf);\n"
    "#endif\n",
    "0002 java-home-env")

patch(OL,
    "    Arguments::set_dll_dir(buf);\n",
    "#ifdef __MUSL__\n"
    "    {\n"
    "      const char* amcl_boot_lib = ::getenv(\"SUN_BOOT_LIBRARY_PATH\");\n"
    "      if (amcl_boot_lib != NULL && amcl_boot_lib[0] != '\\0') {\n"
    "        Arguments::set_dll_dir((char*)amcl_boot_lib); // OHOS: prefer injected native lib dir\n"
    "      } else {\n"
    "        Arguments::set_dll_dir(buf);\n"
    "      }\n"
    "    }\n"
    "#else\n"
    "    Arguments::set_dll_dir(buf);\n"
    "#endif\n",
    "0003 dll-dir-env")

patch(JM,
    "RequiresSetenv(int wanted, const char *jvmpath) {\n",
    "RequiresSetenv(int wanted, const char *jvmpath) {\n"
    "#ifdef __MUSL__\n"
    "    /* OHOS: ELF loader resolves libs; never re-exec (avoids musl re-exec deadlock) */\n"
    "    return JNI_FALSE;\n"
    "#endif\n",
    "0008 libjli-skip-reexec")

print("runtime patches applied.")
