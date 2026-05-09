# OpenJDK for HarmonyOS NEXT — 源码交叉编译指南

> ⚠️ **状态说明（2026-05-08）**
>
> 本文档讨论 JDK 8 / 17 / 21 的源码交叉编译方法。**当前实际上线运行时只有 JDK 17**：
> - **JDK 17**：✅ 上线运行时，`prebuilt/jdk/17/` 完整产物
> - **JDK 8 / 21**：⚠️ 仅研究产物或方案讨论，**未上线**。ArkTS 端 `Constants.SUPPORTED_JDK_VERSION = '17'` policy lock，编译产物即使存在也不会被运行时加载。
> - JDK 21 上线步骤见 `docs/ROADMAP.md` P2-NEW。

**目标**: 从源码交叉编译 OpenJDK 8/17/21 (HotSpot JVM) for HarmonyOS NEXT (musl libc, aarch64)
**产物**: libjvm.so + libjava.so + 完整 JRE，可直接打包进 HAP 的 native lib 目录
**参考**: [PojavLauncher android-openjdk-build-multiarch](https://github.com/PojavLauncherTeam/android-openjdk-build-multiarch)、[FCL-Team Android-OpenJDK-Build](https://github.com/FCL-Team/Android-OpenJDK-Build)、[JEP 386 (Project Portola)](https://openjdk.org/jeps/386)

---

## 一、背景与方案选择

### 1.1 为什么要从源码编译？

| 问题 | 说明 |
|------|------|
| Linker Namespace 限制 | HarmonyOS musl linker 限制应用只能从安装目录加载 .so，数据目录的 dlopen 会被拒绝 |
| Alpine 预编译 JDK 不可用 | 需要 patch ELF NEEDED/PT_INTERP，且 .so SONAME 不匹配 (libc.musl-aarch64.so.1 vs libc.so) |
| PojavLauncher 的成功经验 | 自编译 OpenJDK 8/17 for Android (bionic libc)，.so 打包进 APK，已在数百万设备上验证 |
| .NET/Avalonia 的验证 | NativeAOT 编译为 linux-musl-arm64 .so，在鸿蒙上成功运行，证明 OHOS musl 与标准 musl ABI 兼容 |

### 1.2 编译策略总览

参考 PojavLauncher 的编译流程，但将目标平台从 Android (bionic) 改为 HarmonyOS (musl):

```
PojavLauncher 方案:                    我们的方案:
┌─────────────────────┐               ┌─────────────────────┐
│ Target: Android     │               │ Target: HarmonyOS   │
│ libc: bionic        │               │ libc: musl          │
│ NDK: Android NDK    │               │ NDK: OHOS NDK       │
│ Triple: aarch64-    │               │ Triple: aarch64-    │
│   linux-android     │               │   linux-ohos        │
│ Linker: lld         │               │ Linker: lld         │
│ JVM: server/client  │               │ JVM: server         │
└─────────────────────┘               └─────────────────────┘
```

### 1.3 各 JDK 版本对比

| 版本 | 源码仓库 | Boot JDK | musl 原生支持 | 备注 |
|------|----------|----------|--------------|------|
| JDK 8u | PojavLauncherTeam/openjdk-multiarch-jdk8u | JDK 7 或 8 | ❌ 需要大量补丁 | 最成熟的移植方案，Pojav 已验证 |
| JDK 17u | openjdk/jdk17u (含 Portola 补丁) | JDK 16 或 17 | ✅ JEP 386 已合入 | LTS 版本，推荐优先尝试 |
| JDK 21u | openjdk/jdk21u | JDK 20 或 21 | ✅ 原生支持 musl | 最新 LTS，musl 支持最完善 |

> **推荐路线**: JDK 17 > JDK 21 > JDK 8。JDK 17/21 自带 musl 支持 (Project Portola, JEP 386)，补丁量最少。


### 1.4 HarmonyOS NDK 关键信息

```
SDK 路径 (Windows): D:\Huawei\DevEco Studio\sdk\default\openharmony\native\
SDK 路径 (Linux):   ~/ohos-sdk/native/
编译器:             native/llvm/bin/clang (OHOS clang 15.0.4, 基于 LLVM 15)
Sysroot:            native/sysroot/
Target Triple:      aarch64-linux-ohos
```

**OHOS musl 特性** (与标准 Linux glibc 的区别):

| 特性 | OHOS musl | glibc |
|------|-----------|-------|
| libpthread | 内含于 libc.so | 独立 libpthread.so |
| libdl | 内含于 libc.so | 独立 libdl.so |
| libm | 内含于 libc.so | 独立 libm.so |
| librt | 内含于 libc.so | 独立 librt.so |
| libc++/libstdc++ | 无 (需自带或静态链接) | 系统提供 |
| libz | ✅ 可用 | ✅ 可用 |
| GNU 扩展 (__GLIBC__) | ❌ 不可用 | ✅ 可用 |
| LFS64 接口 (pread64等) | ❌ 不可用 | ✅ 可用 |
| error.h | ❌ 不存在 | ✅ 存在 |
| sys/cdefs.h | ❌ 不存在 | ✅ 存在 |
| utmp/wtmp | ❌ stub 实现 | ✅ 完整实现 |
| 默认栈大小 | 较小 (128KB) | 较大 (8MB) |

---

## 二、编译环境准备

### 2.1 宿主机要求

推荐使用 **Linux x86_64** (Ubuntu 22.04/24.04) 作为编译宿主机。

Windows 用户获取 Linux 环境:
- **WSL2** (推荐): `wsl --install -d Ubuntu-22.04`
- **Docker**: `docker run -it ubuntu:22.04`
- **虚拟机**: VMware/VirtualBox + Ubuntu

### 2.2 安装编译依赖 (Ubuntu)

```bash
sudo apt update
sudo apt install -y \
    build-essential autoconf automake libtool make cmake ninja-build \
    unzip zip curl wget git python3 pkg-config \
    libx11-dev libxext-dev libxrender-dev libxrandr-dev libxtst-dev libxt-dev \
    libcups2-dev libfontconfig1-dev libasound2-dev libfreetype6-dev

# Boot JDK — 根据目标版本安装对应的 Boot JDK
# JDK 8 编译需要 JDK 7 或 8:
sudo apt install -y openjdk-8-jdk

# JDK 17 编译需要 JDK 16 或 17:
sudo apt install -y openjdk-17-jdk

# JDK 21 编译需要 JDK 20 或 21:
sudo apt install -y openjdk-21-jdk
```


### 2.3 获取 HarmonyOS NDK (Linux 版)

**方式 A: 从 DevEco Studio 复制 (推荐)**
```bash
mkdir -p ~/ohos-sdk
# 从 Windows 复制到 WSL
cp -r /mnt/d/Huawei/DevEco\ Studio/sdk/default/openharmony/native ~/ohos-sdk/
```

**方式 B: 下载 Command Line Tools**
```bash
# 从华为开发者网站下载 Linux 版 command-line-tools
# https://developer.huawei.com/consumer/cn/download/
# 解压后 SDK 在: command-line-tools/sdk/default/openharmony/native/
```

验证 NDK:
```bash
export OHOS_NDK=~/ohos-sdk/native
ls $OHOS_NDK/llvm/bin/clang          # 编译器
ls $OHOS_NDK/sysroot/usr/include/pthread.h  # 头文件
ls $OHOS_NDK/sysroot/usr/lib/aarch64-linux-ohos/libc.so  # musl libc
```

### 2.4 创建 OHOS 交叉编译工具链包装脚本

OpenJDK 的 configure 系统期望标准的 GCC 风格工具链命名。我们创建包装脚本将调用转发给 OHOS NDK 的 clang:

```bash
mkdir -p ~/ohos-toolchain

# C 编译器
cat > ~/ohos-toolchain/aarch64-linux-ohos-gcc << 'EOF'
#!/bin/bash
exec ${OHOS_NDK}/llvm/bin/clang --target=aarch64-linux-ohos --sysroot=${OHOS_NDK}/sysroot "$@"
EOF

# C++ 编译器
cat > ~/ohos-toolchain/aarch64-linux-ohos-g++ << 'EOF'
#!/bin/bash
exec ${OHOS_NDK}/llvm/bin/clang++ --target=aarch64-linux-ohos --sysroot=${OHOS_NDK}/sysroot "$@"
EOF

# 二进制工具
for tool in ar ranlib strip objcopy nm objdump readelf; do
    cat > ~/ohos-toolchain/aarch64-linux-ohos-${tool} << EOF
#!/bin/bash
exec \${OHOS_NDK}/llvm/bin/llvm-${tool} "\$@"
EOF
done

chmod +x ~/ohos-toolchain/aarch64-linux-ohos-*
export PATH=~/ohos-toolchain:$PATH
```

验证工具链:
```bash
aarch64-linux-ohos-gcc --version
# 应输出: clang version 15.0.4 (OHOS ...)
```

---

## 三、获取 OpenJDK 源码

### 3.1 JDK 8u — 基于 PojavLauncher patched 版本

PojavLauncher 团队维护了包含 Android/iOS 移植补丁的 OpenJDK 8u，我们基于此进行 OHOS 适配:

```bash
mkdir -p ~/openjdk-ohos && cd ~/openjdk-ohos

# 克隆 PojavLauncher 的 patched OpenJDK 8u (含 aarch64 + 移动端补丁)
git clone --depth 1 https://github.com/PojavLauncherTeam/openjdk-multiarch-jdk8u.git jdk8u
cd jdk8u

# OpenJDK 8 使用 forest 结构，需要获取子仓库
bash get_source.sh || true

# 验证目录结构
ls hotspot/src/os/linux/  # HotSpot Linux 平台代码
ls jdk/src/share/native/  # JDK 核心 native 代码
```

### 3.2 JDK 17u — 官方源码 (含 Portola/musl 支持)

JDK 16+ 已通过 JEP 386 (Project Portola) 合入了 musl libc 支持，补丁量大幅减少:

```bash
cd ~/openjdk-ohos

# 克隆 OpenJDK 17u (LTS)
git clone --depth 1 https://github.com/openjdk/jdk17u.git jdk17u

# 或使用 PojavLauncher 的 fork (如果有额外移动端补丁):
# git clone --depth 1 -b mobile https://github.com/nicholasgasior/jdk17u.git jdk17u
```

### 3.3 JDK 21u — 官方源码 (musl 支持最完善)

```bash
cd ~/openjdk-ohos

# 克隆 OpenJDK 21u (最新 LTS)
git clone --depth 1 https://github.com/openjdk/jdk21u.git jdk21u
```


---

## 四、源码补丁 — OHOS 适配

### 4.1 补丁总览

| 补丁类别 | JDK 8 | JDK 17/21 | 说明 |
|----------|-------|-----------|------|
| musl libc 兼容 | ✅ 必须 | ⚠️ 少量 | glibc 特有 API 替换 |
| OHOS 平台识别 | ✅ 必须 | ✅ 必须 | 让 configure/HotSpot 识别 ohos target |
| 链接器修复 | ✅ 必须 | ✅ 必须 | musl 下 -lpthread/-ldl/-lrt 不需要 |
| HotSpot OS 层 | ✅ 必须 | ⚠️ 少量 | /proc 文件系统差异、信号处理 |
| AWT/GUI 禁用 | ✅ 必须 | ✅ 必须 | headless-only 模式 |

### 4.2 补丁 1: musl libc 兼容性 (主要针对 JDK 8)

OpenJDK 8 大量使用 glibc 特有 API，需要逐一修复:

#### 4.2.1 hotspot/src/os/linux/vm/os_linux.cpp

```diff
--- a/hotspot/src/os/linux/vm/os_linux.cpp
+++ b/hotspot/src/os/linux/vm/os_linux.cpp
@@ -头部包含区域
+// OHOS musl 兼容: musl 没有 <error.h>，用 fprintf+exit 替代
+#ifndef __GLIBC__
+#include <sys/syscall.h>
+// musl 没有 dlvsym，用 dlsym 替代
+#define dlvsym(handle, symbol, version) dlsym(handle, symbol)
+// musl 的 pthread_getattr_np 在 <pthread.h> 中
+#endif
+
 // 修复 sched_getcpu — musl 没有此函数，需要用 syscall
+#ifndef __GLIBC__
+#include <sys/syscall.h>
+static int sched_getcpu(void) {
+    unsigned cpu;
+    int r = syscall(SYS_getcpu, &cpu, NULL, NULL);
+    if (r < 0) return 0;
+    return (int)cpu;
+}
+#endif

 // 修复 active_processor_count — musl 的 sched_getaffinity 行为不同
+#ifndef __GLIBC__
+// musl 的 sched_getaffinity 直接返回 0/-1，不返回 cpuset 大小
+// 需要用 /proc/self/status 或 sysconf 获取 CPU 数
 int os::active_processor_count() {
-    // glibc 版本使用 sched_getaffinity
+    int cpus = sysconf(_SC_NPROCESSORS_ONLN);
+    return cpus > 0 ? cpus : 1;
 }
+#endif
```

#### 4.2.2 hotspot/src/os/linux/vm/os_linux.inline.hpp

```diff
--- a/hotspot/src/os/linux/vm/os_linux.inline.hpp
+++ b/hotspot/src/os/linux/vm/os_linux.inline.hpp
@@ -修复 gettid
+#ifndef __GLIBC__
+// musl 2020+ 提供 gettid()，但旧版本没有
+#include <sys/syscall.h>
+#ifndef gettid
+static inline pid_t gettid(void) {
+    return (pid_t)syscall(SYS_gettid);
+}
+#endif
+#endif
```

#### 4.2.3 jdk/src/solaris/native/java/net/linux_close.c

```diff
--- a/jdk/src/solaris/native/java/net/linux_close.c
+++ b/jdk/src/solaris/native/java/net/linux_close.c
@@ -修复 RTLD_NEXT 使用
+// musl 支持 RTLD_NEXT，但需要 _GNU_SOURCE
+#ifndef _GNU_SOURCE
+#define _GNU_SOURCE
+#endif
 #include <dlfcn.h>
-// glibc 使用 __REDIRECT 宏，musl 没有
+
+#ifndef __GLIBC__
+// musl 没有 __REDIRECT 宏，直接用函数指针
+typedef int (*close_fn_t)(int);
+typedef int (*read_fn_t)(int, void*, size_t);
+static close_fn_t os_close = NULL;
+static read_fn_t os_read = NULL;
+
+static void init_funcs(void) {
+    os_close = (close_fn_t)dlsym(RTLD_NEXT, "close");
+    os_read = (read_fn_t)dlsym(RTLD_NEXT, "read");
+}
+#endif
```


#### 4.2.4 jdk/src/share/native/common/jni_util.h

```diff
--- a/jdk/src/share/native/common/jni_util.h
+++ b/jdk/src/share/native/common/jni_util.h
@@ -修复 __GLIBC_PREREQ 宏
+// musl 没有 __GLIBC_PREREQ 宏
+#ifndef __GLIBC_PREREQ
+#define __GLIBC_PREREQ(x, y) 0
+#endif
```

#### 4.2.5 修复 LFS64 接口 (pread64/pwrite64/mmap64 等)

musl 不提供 LFS64 后缀的函数，标准函数已经是 64-bit:

```diff
--- a/多个文件
+++ b/多个文件
+// 在使用 LFS64 接口的文件头部添加:
+#ifndef __GLIBC__
+#define pread64   pread
+#define pwrite64  pwrite
+#define mmap64    mmap
+#define ftruncate64 ftruncate
+#define lseek64   lseek
+#define stat64    stat
+#define fstat64   fstat
+#define lstat64   lstat
+#define open64    open
+#define fopen64   fopen
+#endif
```

涉及的文件 (JDK 8):
- `jdk/src/solaris/native/sun/nio/ch/FileChannelImpl.c`
- `jdk/src/solaris/native/sun/nio/ch/FileDispatcherImpl.c`
- `jdk/src/solaris/native/java/io/FileInputStream_md.c`
- `jdk/src/solaris/native/java/io/FileOutputStream_md.c`
- `jdk/src/solaris/native/java/io/UnixFileSystem_md.c`
- `hotspot/src/os/linux/vm/os_linux.cpp`
- `hotspot/src/os/linux/vm/perfMemory_linux.cpp`

### 4.3 补丁 2: OHOS 平台识别

#### 4.3.1 configure 脚本 — 识别 ohos target

JDK 8 的 autoconf 不认识 `ohos`，需要修改 `common/autoconf/platform.m4`:

```diff
--- a/common/autoconf/platform.m4
+++ b/common/autoconf/platform.m4
@@ -PLATFORM_EXTRACT_TARGET_AND_BUILD
   case "${VAR_OS}" in
     *linux*)
       VAR_OS=linux
       VAR_OS_API=posix
+      # OHOS 使用 musl libc，但 OS 层面兼容 Linux
+      ;;
+    *ohos*)
+      VAR_OS=linux
+      VAR_OS_API=posix
       ;;
```

JDK 17/21 的 `make/autoconf/platform.m4` 类似修改:

```diff
--- a/make/autoconf/platform.m4
+++ b/make/autoconf/platform.m4
@@ -PLATFORM_EXTRACT_VARS_FROM_OS
+    *ohos*)
+      OPENJDK_TARGET_OS=linux
+      OPENJDK_TARGET_OS_TYPE=unix
+      ;;
```

#### 4.3.2 HotSpot — 添加 OHOS 识别

```diff
--- a/hotspot/src/os/linux/vm/os_linux.cpp (JDK 8)
+++ b/hotspot/src/os/linux/vm/os_linux.cpp
@@ -get_distro_info 或类似函数
+// 识别 OHOS
+static bool is_ohos() {
+    // OHOS 的 musl libc SONAME 是 libc.so (不是 libc.musl-*.so.1)
+    // 且 /system/lib/ld-musl-aarch64.so.1 存在
+    struct stat st;
+    return stat("/system/lib/ld-musl-aarch64.so.1", &st) == 0 ||
+           stat("/system/lib64/ld-musl-aarch64.so.1", &st) == 0;
+}
```

### 4.4 补丁 3: 链接器修复

musl 将 pthread/dl/m/rt 全部内含于 libc.so，链接时不需要 -lpthread -ldl 等:

#### 4.4.1 JDK 8: make/lib/*.gmk

```diff
--- a/jdk/make/lib/Lib-java.base.gmk (或对应的 .gmk 文件)
+++ b/jdk/make/lib/Lib-java.base.gmk
@@ -链接标志
-LDFLAGS += -lpthread -ldl -lrt
+# musl: pthread/dl/rt 已内含于 libc.so
+ifeq ($(call isTargetMusl), true)
+  LDFLAGS +=
+else
+  LDFLAGS += -lpthread -ldl -lrt
+endif
```

更简单的做法 — 在工具链包装脚本中过滤:

```bash
# 修改 ~/ohos-toolchain/aarch64-linux-ohos-gcc
cat > ~/ohos-toolchain/aarch64-linux-ohos-gcc << 'WRAPPER'
#!/bin/bash
# 过滤掉 musl 不需要的链接参数
ARGS=()
for arg in "$@"; do
    case "$arg" in
        -lpthread|-ldl|-lrt|-lresolv) ;; # musl 内含，跳过
        *) ARGS+=("$arg") ;;
    esac
done
exec ${OHOS_NDK}/llvm/bin/clang --target=aarch64-linux-ohos --sysroot=${OHOS_NDK}/sysroot "${ARGS[@]}"
WRAPPER
chmod +x ~/ohos-toolchain/aarch64-linux-ohos-gcc
```

对 g++ 包装脚本做同样处理。


### 4.5 补丁 4: HotSpot 平台层修复

#### 4.5.1 /proc 文件系统

OHOS 的 /proc 与标准 Linux 基本一致，但部分路径可能受限:

```diff
--- a/hotspot/src/os/linux/vm/os_linux.cpp
+++ b/hotspot/src/os/linux/vm/os_linux.cpp
@@ -读取 /proc/self/exe
+// OHOS 沙箱中 /proc/self/exe 可能不可读
+// 备选: 通过 dladdr 获取 libjvm.so 路径
+#include <dlfcn.h>
+static bool get_jvm_path_from_dladdr(char* buf, size_t buflen) {
+    Dl_info info;
+    if (dladdr((void*)get_jvm_path_from_dladdr, &info) && info.dli_fname) {
+        strncpy(buf, info.dli_fname, buflen);
+        return true;
+    }
+    return false;
+}
```

#### 4.5.2 信号处理

```diff
--- a/hotspot/src/os/linux/vm/os_linux.cpp
+++ b/hotspot/src/os/linux/vm/os_linux.cpp
@@ -信号栈大小
+// musl 默认栈较小，增大信号栈
+#ifndef __GLIBC__
+#define SIGSTKSZ (16 * 1024)  // musl 默认可能只有 8KB
+#endif
```

#### 4.5.3 线程栈大小

```diff
--- a/hotspot/src/os/linux/vm/os_linux.cpp
+++ b/hotspot/src/os/linux/vm/os_linux.cpp
@@ -默认线程栈大小
+// musl 默认线程栈 128KB，对 JVM 太小
+// 在 JVM 启动时设置更大的默认值
+#ifndef __GLIBC__
+// 确保 Java 线程栈至少 512KB
+static size_t adjust_stack_size(size_t requested) {
+    const size_t MIN_STACK = 512 * 1024;
+    return requested < MIN_STACK ? MIN_STACK : requested;
+}
+#endif
```

### 4.6 补丁 5: libc++ / C++ 标准库

OHOS NDK 不提供系统级 libc++.so，HotSpot 的 C++ 代码需要静态链接:

```diff
--- a/hotspot/make/linux/makefiles/gcc.make (JDK 8)
+++ b/hotspot/make/linux/makefiles/gcc.make
@@ -C++ 标准库链接
-LIBS += -lstdc++
+# OHOS: 静态链接 libc++
+ifeq ($(TARGET_OS), ohos)
+  LIBS += -static-libstdc++ -lc++_static -lc++abi
+else
+  LIBS += -lstdc++
+endif
```

或者在 configure 的 extra-ldflags 中指定:
```bash
--with-extra-ldflags="... -static-libstdc++"
```

---

## 五、配置与编译

### 5.1 通用环境变量

```bash
export OHOS_NDK=~/ohos-sdk/native
export PATH=~/ohos-toolchain:$PATH
export BUILD_DIR=~/openjdk-ohos/build
```

### 5.2 编译 JDK 8u

```bash
# Boot JDK
export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64

cd ~/openjdk-ohos/jdk8u

# 应用 OHOS 补丁 (假设补丁文件在 ~/openjdk-ohos/patches/jdk8/)
# git apply ~/openjdk-ohos/patches/jdk8/*.patch

bash configure \
    --openjdk-target=aarch64-linux-gnu \
    --with-jvm-variants=server \
    --with-debug-level=release \
    --with-native-debug-symbols=none \
    --with-boot-jdk=$JAVA_HOME \
    --with-extra-cflags="\
        --target=aarch64-linux-ohos \
        --sysroot=${OHOS_NDK}/sysroot \
        -fPIC \
        -D__musl__ \
        -DOHOS \
    " \
    --with-extra-cxxflags="\
        --target=aarch64-linux-ohos \
        --sysroot=${OHOS_NDK}/sysroot \
        -fPIC \
        -D__musl__ \
        -DOHOS \
    " \
    --with-extra-ldflags="\
        --target=aarch64-linux-ohos \
        --sysroot=${OHOS_NDK}/sysroot \
        -fuse-ld=lld \
    " \
    --x-includes=/dev/null \
    --x-libraries=/dev/null \
    --with-cups-include=/dev/null \
    --with-freetype=bundled \
    --enable-headless-only \
    --disable-warnings-as-errors \
    --with-toolchain-type=clang \
    CC=aarch64-linux-ohos-gcc \
    CXX=aarch64-linux-ohos-g++ \
    AR=aarch64-linux-ohos-ar \
    STRIP=aarch64-linux-ohos-strip \
    NM=aarch64-linux-ohos-nm \
    OBJCOPY=aarch64-linux-ohos-objcopy

# 编译 (使用所有 CPU 核心)
make images JOBS=$(nproc)

# 产物在:
ls build/linux-aarch64-normal-server-release/images/j2re-image/
```


### 5.3 编译 JDK 17u (推荐)

JDK 17 自带 musl 支持 (JEP 386)，configure 系统更现代，补丁量最少:

```bash
# Boot JDK
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64

cd ~/openjdk-ohos/jdk17u

bash configure \
    --openjdk-target=aarch64-linux-gnu \
    --with-jvm-variants=server \
    --with-debug-level=release \
    --with-native-debug-symbols=none \
    --with-boot-jdk=$JAVA_HOME \
    --with-extra-cflags="\
        --target=aarch64-linux-ohos \
        --sysroot=${OHOS_NDK}/sysroot \
        -fPIC \
        -DMUSL_LIBC \
        -D_LARGEFILE64_SOURCE \
    " \
    --with-extra-cxxflags="\
        --target=aarch64-linux-ohos \
        --sysroot=${OHOS_NDK}/sysroot \
        -fPIC \
        -DMUSL_LIBC \
        -D_LARGEFILE64_SOURCE \
    " \
    --with-extra-ldflags="\
        --target=aarch64-linux-ohos \
        --sysroot=${OHOS_NDK}/sysroot \
        -fuse-ld=lld \
        -static-libstdc++ \
    " \
    --x-includes=/dev/null \
    --x-libraries=/dev/null \
    --with-cups-include=/dev/null \
    --with-freetype=bundled \
    --enable-headless-only \
    --disable-warnings-as-errors \
    --with-toolchain-type=clang \
    CC=aarch64-linux-ohos-gcc \
    CXX=aarch64-linux-ohos-g++ \
    AR=aarch64-linux-ohos-ar \
    STRIP=aarch64-linux-ohos-strip \
    NM=aarch64-linux-ohos-nm \
    OBJCOPY=aarch64-linux-ohos-objcopy

make images JOBS=$(nproc)

# 产物在:
ls build/linux-aarch64-server-release/images/jdk/
```

### 5.4 编译 JDK 21u

```bash
# Boot JDK
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64

cd ~/openjdk-ohos/jdk21u

bash configure \
    --openjdk-target=aarch64-linux-gnu \
    --with-jvm-variants=server \
    --with-debug-level=release \
    --with-native-debug-symbols=none \
    --with-boot-jdk=$JAVA_HOME \
    --with-extra-cflags="\
        --target=aarch64-linux-ohos \
        --sysroot=${OHOS_NDK}/sysroot \
        -fPIC \
        -DMUSL_LIBC \
    " \
    --with-extra-cxxflags="\
        --target=aarch64-linux-ohos \
        --sysroot=${OHOS_NDK}/sysroot \
        -fPIC \
        -DMUSL_LIBC \
    " \
    --with-extra-ldflags="\
        --target=aarch64-linux-ohos \
        --sysroot=${OHOS_NDK}/sysroot \
        -fuse-ld=lld \
        -static-libstdc++ \
    " \
    --x-includes=/dev/null \
    --x-libraries=/dev/null \
    --with-cups-include=/dev/null \
    --with-freetype=bundled \
    --enable-headless-only \
    --disable-warnings-as-errors \
    --with-toolchain-type=clang \
    CC=aarch64-linux-ohos-gcc \
    CXX=aarch64-linux-ohos-g++ \
    AR=aarch64-linux-ohos-ar \
    STRIP=aarch64-linux-ohos-strip \
    NM=aarch64-linux-ohos-nm \
    OBJCOPY=aarch64-linux-ohos-objcopy

make images JOBS=$(nproc)

# 产物在:
ls build/linux-aarch64-server-release/images/jdk/
```

### 5.5 configure 关键参数说明

| 参数 | 说明 |
|------|------|
| `--openjdk-target=aarch64-linux-gnu` | 目标平台。虽然实际是 musl，但 configure 用 gnu 识别 Linux ABI |
| `--with-jvm-variants=server` | HotSpot Server VM，支持 C2 JIT 编译器，性能最佳 |
| `--enable-headless-only` | 无头模式，禁用 AWT/Swing GUI (OHOS 不需要) |
| `--with-freetype=bundled` | 使用 OpenJDK 内置 FreeType，避免系统依赖 |
| `--target=aarch64-linux-ohos` | 传给 clang 的 target triple，决定 ABI 和 sysroot |
| `-fuse-ld=lld` | 使用 LLVM lld 链接器 (OHOS NDK 自带) |
| `-fPIC` | 位置无关代码，.so 必须 |
| `-DMUSL_LIBC` | 自定义宏，用于条件编译 musl 兼容代码 |
| `-static-libstdc++` | 静态链接 C++ 标准库 (OHOS 无系统 libc++) |
| `--disable-warnings-as-errors` | 交叉编译时 clang 可能产生额外警告 |


---

## 六、常见编译错误与解决方案

### 6.1 musl 相关编译错误

#### `error: use of undeclared identifier '__GLIBC_PREREQ'`
```c
// 解决: 在报错文件头部添加
#ifndef __GLIBC_PREREQ
#define __GLIBC_PREREQ(x, y) 0
#endif
```

#### `error: use of undeclared identifier 'RTLD_NOLOAD'`
```c
// 解决: musl 需要 _GNU_SOURCE
#define _GNU_SOURCE
#include <dlfcn.h>
```

#### `error: unknown type name 'cpu_set_t'`
```c
// 解决: musl 需要 _GNU_SOURCE 才暴露 cpu_set_t
#define _GNU_SOURCE
#include <sched.h>
```

#### `error: 'MADV_HUGEPAGE' undeclared`
```c
// 解决: musl 可能不定义此宏
#ifndef MADV_HUGEPAGE
#define MADV_HUGEPAGE 14
#endif
```

#### `error: 'MINCORE_INCORE' undeclared`
```c
// 解决: 这是 BSD 特有的
#ifndef MINCORE_INCORE
#define MINCORE_INCORE 1
#endif
```

#### `error: undefined reference to 'dlvsym'`
```c
// 解决: musl 没有 dlvsym (带版本的 dlsym)
#ifndef __GLIBC__
#define dlvsym(handle, symbol, version) dlsym(handle, symbol)
#endif
```

#### `error: undefined reference to '__xpg_strerror_r'`
```c
// 解决: musl 只有 POSIX strerror_r，没有 GNU 版本
// 确保使用 POSIX 版本:
#define _POSIX_C_SOURCE 200112L
```

### 6.2 链接错误

#### `ld.lld: error: unable to find library -lpthread`
```bash
# 解决: musl 将 pthread 内含于 libc.so
# 在工具链包装脚本中过滤 -lpthread (见 4.4.1)
# 或创建空的 libpthread.a:
ar rcs ${OHOS_NDK}/sysroot/usr/lib/aarch64-linux-ohos/libpthread.a
ar rcs ${OHOS_NDK}/sysroot/usr/lib/aarch64-linux-ohos/libdl.a
ar rcs ${OHOS_NDK}/sysroot/usr/lib/aarch64-linux-ohos/librt.a
```

#### `ld.lld: error: unable to find library -lstdc++`
```bash
# 解决: OHOS 没有 libstdc++，使用 libc++
# 在 extra-ldflags 中添加:
--with-extra-ldflags="... -static-libstdc++"
# 或替换为:
--with-extra-ldflags="... -lc++ -lc++abi"
```

#### `ld.lld: error: undefined symbol: __cxa_thread_atexit_impl`
```c
// 解决: musl 1.1.20+ 支持此函数，但旧版本不支持
// 添加弱符号定义:
__attribute__((weak)) int __cxa_thread_atexit_impl(void (*)(void*), void*, void*) { return 0; }
```

### 6.3 configure 错误

#### `configure: error: Cannot find GNU make`
```bash
# 解决: 确保 make 版本 >= 3.81
make --version
# 如果版本太旧:
sudo apt install make
```

#### `configure: error: Could not find freetype`
```bash
# 解决: 使用 bundled freetype
--with-freetype=bundled
```

#### `configure: error: Cannot determine toolchain type`
```bash
# 解决: 明确指定 clang 工具链
--with-toolchain-type=clang
```

---

## 七、编译产物处理与打包

### 7.1 产物目录结构

编译成功后，JRE 产物位于:

```
# JDK 8:
build/linux-aarch64-normal-server-release/images/j2re-image/
├── lib/
│   ├── aarch64/
│   │   ├── server/
│   │   │   └── libjvm.so          ← HotSpot JVM (最大，约 15-25MB)
│   │   ├── libjava.so             ← Java 核心
│   │   ├── libjli.so              ← JVM 启动器
│   │   ├── libverify.so           ← 字节码验证
│   │   ├── libzip.so              ← ZIP 支持
│   │   ├── libnet.so              ← 网络
│   │   ├── libnio.so              ← NIO
│   │   └── ...
│   ├── rt.jar                     ← Java 运行时类库
│   ├── charsets.jar
│   └── ...
└── bin/
    └── java (不需要，我们通过 JNI 嵌入)

# JDK 17/21:
build/linux-aarch64-server-release/images/jdk/
├── lib/
│   ├── server/
│   │   └── libjvm.so
│   ├── libjava.so
│   ├── libjli.so
│   ├── libzip.so
│   ├── libnet.so
│   ├── libnio.so
│   ├── modules                    ← 模块化类库 (替代 rt.jar)
│   └── ...
└── conf/
    └── ...
```


### 7.2 Strip 与瘦身

```bash
JRE_DIR=build/linux-aarch64-server-release/images/jdk  # JDK 17/21
# JDK 8 用: JRE_DIR=build/linux-aarch64-normal-server-release/images/j2re-image

# Strip 所有 .so (如果编译时没有 --with-native-debug-symbols=none)
find $JRE_DIR -name "*.so" -exec aarch64-linux-ohos-strip --strip-unneeded {} \;

# 删除不需要的文件
rm -rf $JRE_DIR/bin/           # 不需要命令行工具
rm -rf $JRE_DIR/include/       # 不需要开发头文件
rm -rf $JRE_DIR/man/           # 不需要手册
rm -rf $JRE_DIR/demo/          # 不需要示例
rm -rf $JRE_DIR/sample/

# 查看大小
du -sh $JRE_DIR/
du -sh $JRE_DIR/lib/server/libjvm.so
```

### 7.3 打包进 HAP

有两种方式将 JRE 集成到 HarmonyOS 应用:

#### 方式 A: .so 文件放入 native lib 目录 (推荐)

将所有 .so 放入 HAP 的 `libs/arm64-v8a/` 目录，安装时会被复制到应用的 native lib 目录，
该目录在 linker namespace 允许范围内:

```
entry/
├── libs/
│   └── arm64-v8a/
│       ├── libjvm.so
│       ├── libjava.so
│       ├── libjli.so
│       ├── libverify.so
│       ├── libzip.so
│       ├── libnet.so
│       ├── libnio.so
│       └── ... (其他 JDK .so)
├── src/main/
│   └── resources/rawfile/
│       └── jre/              ← Java 类库 (rt.jar 或 modules)
│           ├── lib/
│           │   ├── rt.jar    (JDK 8)
│           │   └── modules   (JDK 17/21)
│           └── conf/
```

在 `build-profile.json5` 中配置:
```json5
{
  "externalNativeOptions": {
    "abiFilters": ["arm64-v8a"]
  }
}
```

#### 方式 B: 全部放入 rawfile，运行时复制

将整个 JRE 目录放入 rawfile，首次运行时解压到应用沙箱，然后将 .so 复制到可 dlopen 的位置。
这种方式更灵活但首次启动较慢。

### 7.4 JNI 嵌入调用

编译产物的核心用法 — 通过 JNI 嵌入 JVM:

```cpp
#include <dlfcn.h>

// 加载自编译的 libjvm.so (在 native lib 目录中，linker namespace 允许)
void* handle = dlopen("libjvm.so", RTLD_NOW);

// 获取 JNI_CreateJavaVM 函数指针
typedef jint (*CreateJavaVM_t)(JavaVM**, void**, void*);
auto JNI_CreateJavaVM = (CreateJavaVM_t)dlsym(handle, "JNI_CreateJavaVM");

// 配置 JVM 参数
JavaVMInitArgs vm_args;
JavaVMOption options[3];

// JDK 8: 指定 classpath
options[0].optionString = "-Djava.class.path=/path/to/rt.jar:/path/to/your.jar";
// JDK 17/21: 指定模块路径
// options[0].optionString = "--module-path=/path/to/modules";

options[1].optionString = "-Djava.library.path=/path/to/native/libs";
options[2].optionString = "-Xmx256m";

vm_args.version = JNI_VERSION_1_8;  // JDK 8
// vm_args.version = JNI_VERSION_10; // JDK 17/21
vm_args.nOptions = 3;
vm_args.options = options;
vm_args.ignoreUnrecognized = JNI_FALSE;

// 创建 JVM
JavaVM* jvm;
JNIEnv* env;
jint rc = JNI_CreateJavaVM(&jvm, (void**)&env, &vm_args);
if (rc == JNI_OK) {
    // JVM 启动成功，可以调用 Java 代码
    jclass cls = env->FindClass("com/example/Main");
    jmethodID mid = env->GetStaticMethodID(cls, "main", "([Ljava/lang/String;)V");
    env->CallStaticVoidMethod(cls, mid, NULL);
}
```


---

## 八、自动化编译脚本

### 8.1 一键编译脚本 build_openjdk_ohos.sh

```bash
#!/bin/bash
set -e

# ============================================================
#  OpenJDK for HarmonyOS NEXT — 一键编译脚本
#  用法: ./build_openjdk_ohos.sh [8|17|21]
# ============================================================

JDK_VERSION=${1:-17}
WORK_DIR=~/openjdk-ohos
OHOS_NDK=${OHOS_NDK:-~/ohos-sdk/native}
TOOLCHAIN_DIR=~/ohos-toolchain
JOBS=${JOBS:-$(nproc)}

echo "=========================================="
echo " Building OpenJDK ${JDK_VERSION} for OHOS"
echo "=========================================="

# --- 验证 NDK ---
if [ ! -f "$OHOS_NDK/llvm/bin/clang" ]; then
    echo "ERROR: OHOS NDK not found at $OHOS_NDK"
    echo "Set OHOS_NDK environment variable to your NDK path"
    exit 1
fi

# --- 创建工具链包装脚本 ---
mkdir -p $TOOLCHAIN_DIR

create_wrapper() {
    local name=$1 cmd=$2
    cat > $TOOLCHAIN_DIR/$name << WRAPPER
#!/bin/bash
ARGS=()
for arg in "\$@"; do
    case "\$arg" in
        -lpthread|-ldl|-lrt|-lresolv) ;;
        *) ARGS+=("\$arg") ;;
    esac
done
exec $cmd "\${ARGS[@]}"
WRAPPER
    chmod +x $TOOLCHAIN_DIR/$name
}

create_wrapper "aarch64-linux-ohos-gcc" \
    "$OHOS_NDK/llvm/bin/clang --target=aarch64-linux-ohos --sysroot=$OHOS_NDK/sysroot"
create_wrapper "aarch64-linux-ohos-g++" \
    "$OHOS_NDK/llvm/bin/clang++ --target=aarch64-linux-ohos --sysroot=$OHOS_NDK/sysroot"

for tool in ar ranlib strip objcopy nm objdump readelf; do
    cat > $TOOLCHAIN_DIR/aarch64-linux-ohos-${tool} << EOF
#!/bin/bash
exec $OHOS_NDK/llvm/bin/llvm-${tool} "\$@"
EOF
    chmod +x $TOOLCHAIN_DIR/aarch64-linux-ohos-${tool}
done

export PATH=$TOOLCHAIN_DIR:$PATH

# --- 创建空的 stub 库 (musl 不需要独立的 pthread/dl/rt) ---
STUB_DIR=$OHOS_NDK/sysroot/usr/lib/aarch64-linux-ohos
for lib in libpthread.a libdl.a librt.a; do
    if [ ! -f "$STUB_DIR/$lib" ]; then
        $OHOS_NDK/llvm/bin/llvm-ar rcs $STUB_DIR/$lib
        echo "Created stub: $lib"
    fi
done

# --- 克隆源码 ---
mkdir -p $WORK_DIR && cd $WORK_DIR

case $JDK_VERSION in
    8)
        REPO_URL="https://github.com/PojavLauncherTeam/openjdk-multiarch-jdk8u.git"
        SRC_DIR="jdk8u"
        BOOT_JDK="/usr/lib/jvm/java-8-openjdk-amd64"
        ;;
    17)
        REPO_URL="https://github.com/openjdk/jdk17u.git"
        SRC_DIR="jdk17u"
        BOOT_JDK="/usr/lib/jvm/java-17-openjdk-amd64"
        ;;
    21)
        REPO_URL="https://github.com/openjdk/jdk21u.git"
        SRC_DIR="jdk21u"
        BOOT_JDK="/usr/lib/jvm/java-21-openjdk-amd64"
        ;;
    *)
        echo "Unsupported JDK version: $JDK_VERSION (use 8, 17, or 21)"
        exit 1
        ;;
esac

if [ ! -d "$SRC_DIR" ]; then
    echo "Cloning $REPO_URL ..."
    git clone --depth 1 $REPO_URL $SRC_DIR
    if [ "$JDK_VERSION" = "8" ]; then
        cd $SRC_DIR && bash get_source.sh || true && cd ..
    fi
fi

# --- 验证 Boot JDK ---
if [ ! -f "$BOOT_JDK/bin/java" ]; then
    echo "ERROR: Boot JDK not found at $BOOT_JDK"
    echo "Install: sudo apt install openjdk-${JDK_VERSION}-jdk"
    exit 1
fi

# --- Configure ---
cd $WORK_DIR/$SRC_DIR

COMMON_CFLAGS="--target=aarch64-linux-ohos --sysroot=$OHOS_NDK/sysroot -fPIC"
COMMON_LDFLAGS="--target=aarch64-linux-ohos --sysroot=$OHOS_NDK/sysroot -fuse-ld=lld"

if [ "$JDK_VERSION" = "8" ]; then
    EXTRA_CFLAGS="$COMMON_CFLAGS -D__musl__ -DOHOS"
    EXTRA_LDFLAGS="$COMMON_LDFLAGS"
else
    EXTRA_CFLAGS="$COMMON_CFLAGS -DMUSL_LIBC"
    EXTRA_LDFLAGS="$COMMON_LDFLAGS -static-libstdc++"
fi

echo "Running configure..."
bash configure \
    --openjdk-target=aarch64-linux-gnu \
    --with-jvm-variants=server \
    --with-debug-level=release \
    --with-native-debug-symbols=none \
    --with-boot-jdk=$BOOT_JDK \
    --with-extra-cflags="$EXTRA_CFLAGS" \
    --with-extra-cxxflags="$EXTRA_CFLAGS" \
    --with-extra-ldflags="$EXTRA_LDFLAGS" \
    --x-includes=/dev/null \
    --x-libraries=/dev/null \
    --with-cups-include=/dev/null \
    --with-freetype=bundled \
    --enable-headless-only \
    --disable-warnings-as-errors \
    --with-toolchain-type=clang \
    CC=aarch64-linux-ohos-gcc \
    CXX=aarch64-linux-ohos-g++ \
    AR=aarch64-linux-ohos-ar \
    STRIP=aarch64-linux-ohos-strip \
    NM=aarch64-linux-ohos-nm \
    OBJCOPY=aarch64-linux-ohos-objcopy

# --- Build ---
echo "Building with $JOBS jobs..."
make images JOBS=$JOBS

# --- 定位产物 ---
if [ "$JDK_VERSION" = "8" ]; then
    IMAGE_DIR=$(find build -path "*/images/j2re-image" -type d 2>/dev/null | head -1)
else
    IMAGE_DIR=$(find build -path "*/images/jdk" -type d 2>/dev/null | head -1)
fi

if [ -z "$IMAGE_DIR" ]; then
    echo "ERROR: Build output not found"
    exit 1
fi

echo ""
echo "=========================================="
echo " Build successful!"
echo " Output: $WORK_DIR/$SRC_DIR/$IMAGE_DIR"
echo "=========================================="
du -sh $IMAGE_DIR
echo ""
echo "Key files:"
find $IMAGE_DIR -name "libjvm.so" -o -name "libjava.so" | head -5
```


---

## 九、验证与测试

### 9.1 基本验证 — 检查 ELF 格式

```bash
# 确认是 aarch64 ELF
file libjvm.so
# 期望: ELF 64-bit LSB shared object, ARM aarch64, version 1 (SYSV), dynamically linked

# 检查动态依赖
aarch64-linux-ohos-gcc -Wl,--no-as-needed -print-file-name=libc.so  # 验证工具链
readelf -d libjvm.so | grep NEEDED
# 期望看到:
#  (NEEDED) Shared library: [libc.so]
#  (NEEDED) Shared library: [libm.so]    (可能)
#  (NEEDED) Shared library: [libz.so]    (可能)
# 不应看到:
#  libc.musl-aarch64.so.1  ← Alpine 特有
#  libpthread.so.0         ← glibc 特有
#  libdl.so.2              ← glibc 特有
#  libstdc++.so.6          ← 应该静态链接

# 检查是否有 PT_INTERP (不应该有)
readelf -l libjvm.so | grep INTERP
# 期望: 无输出 (共享库不应有 interpreter)
```

### 9.2 在设备上测试

```bash
# 1. 将编译产物推送到设备
hdc file send ~/openjdk-ohos/jdk17u/build/.../images/jdk/ /data/local/tmp/jdk/

# 2. 在应用中通过 JNI 加载测试 (参考 jvm_launcher.cpp)
# 或者如果有 shell 访问:
hdc shell
export LD_LIBRARY_PATH=/data/local/tmp/jdk/lib:/data/local/tmp/jdk/lib/server
/data/local/tmp/jdk/bin/java -version  # 可能因 namespace 限制失败
```

### 9.3 常见运行时问题

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| `dlopen failed: namespace restricted` | Linker namespace 限制 | .so 必须在 HAP 安装目录中 |
| `SIGBUS` 崩溃 | 内存对齐问题 | 检查 mmap 参数，确保 page-aligned |
| `StackOverflowError` | musl 默认栈太小 | 启动参数加 `-Xss512k` |
| `UnsatisfiedLinkError: libz.so` | 找不到 zlib | 将 libz.so 一起打包，或确认系统 libz 可用 |
| `JVM 启动后立即 SIGSEGV` | HotSpot 信号处理与 OHOS 冲突 | 检查 libjsig.so 是否正确加载 |

---

## 十、PojavLauncher 编译流程参考

### 10.1 PojavLauncher 的编译架构

PojavLauncher 的 [android-openjdk-build-multiarch](https://github.com/PojavLauncherTeam/android-openjdk-build-multiarch) 仓库 (已归档于 2025-05-19) 提供了完整的 Android 交叉编译流程:

```
编译流程:
extractndk.sh    → 解压 Android NDK r10e
maketoolchain.sh → 创建 standalone toolchain
getlibs.sh       → 下载 CUPS headers + FreeType 源码
buildlibs.sh     → 交叉编译 FreeType
clonejdk.sh      → 克隆 OpenJDK 源码
buildjdk.sh      → configure + make
tarjdk.sh        → 打包产物
```

支持的版本与分支:
- `buildjre8` 分支: OpenJDK 8u (JDK 8)
- `buildjre17` 分支: OpenJDK 17 (JDK 17)
- Releases 中有预编译的 JRE8 和 JRE17 for Android

### 10.2 关键差异: Android vs OHOS

| 方面 | Android (Pojav) | OHOS (我们) |
|------|-----------------|-------------|
| libc | bionic | musl |
| NDK | Android NDK r10e | OHOS NDK (clang 15) |
| Target | aarch64-linux-android | aarch64-linux-ohos |
| C++ 库 | libc++ (NDK 自带) | 需要静态链接 |
| 链接器 | gold/lld | lld |
| pthread | 独立 libpthread | 内含于 libc |
| dlopen 限制 | namespace (Android 7+) | namespace (更严格) |
| .so 打包位置 | APK lib/ | HAP libs/ |

### 10.3 FCL-Team 的改进

[FCL-Team/Android-OpenJDK-Build](https://github.com/FCL-Team/Android-OpenJDK-Build) 是 FoldCraftLauncher 的 fork，使用 GitHub Actions CI 自动化编译，可参考其 workflow 文件设置 CI。

---

## 十一、进阶: 完整 OHOS 补丁集参考

### 11.1 需要修改的文件清单 (JDK 8)

```
hotspot/
├── src/os/linux/vm/
│   ├── os_linux.cpp              ← 主要修改: musl 兼容、CPU 检测、内存管理
│   ├── os_linux.inline.hpp       ← gettid、sched_getcpu
│   └── perfMemory_linux.cpp      ← mmap64 → mmap
├── src/os_cpu/linux_aarch64/vm/
│   └── os_linux_aarch64.cpp      ← 信号处理
├── src/share/vm/runtime/
│   └── os.hpp                    ← 平台检测宏
└── make/linux/
    └── makefiles/gcc.make        ← 编译标志

jdk/
├── src/solaris/native/
│   ├── java/net/linux_close.c    ← RTLD_NEXT、dlvsym
│   ├── java/io/*_md.c            ← LFS64 接口
│   └── sun/nio/ch/*.c            ← LFS64 接口
├── src/share/native/common/
│   └── jni_util.h                ← __GLIBC_PREREQ
└── make/lib/
    └── *.gmk                     ← 链接标志

common/autoconf/
└── platform.m4                   ← ohos target 识别
```

### 11.2 需要修改的文件清单 (JDK 17/21)

JDK 17/21 已有 musl 支持，修改量大幅减少:

```
make/autoconf/
└── platform.m4                   ← 添加 ohos target 识别

src/hotspot/os/linux/
├── os_linux.cpp                  ← 少量 OHOS 特定调整
└── os_linux.inline.hpp           ← 可能需要微调

src/java.base/unix/native/
└── libjava/java_props_md.c       ← 系统属性检测 (可选)
```

---

## 十二、参考资源

| 资源 | 链接 | 说明 |
|------|------|------|
| PojavLauncher 编译脚本 | [android-openjdk-build-multiarch](https://github.com/PojavLauncherTeam/android-openjdk-build-multiarch) | Android 交叉编译参考 (已归档) |
| PojavLauncher patched JDK8 | [openjdk-multiarch-jdk8u](https://github.com/PojavLauncherTeam/openjdk-multiarch-jdk8u) | 含 aarch64 + 移动端补丁 |
| FCL 编译脚本 | [Android-OpenJDK-Build](https://github.com/FCL-Team/Android-OpenJDK-Build) | CI 自动化编译参考 |
| JEP 386 (Project Portola) | [openjdk.org/jeps/386](https://openjdk.org/jeps/386) | OpenJDK musl/Alpine 官方支持 |
| Portola 项目 | [openjdk.org/projects/portola](https://openjdk.org/projects/portola/) | musl 移植项目主页 |
| musl 移植笔记 | [Gentoo Musl porting notes](https://wiki.gentoo.org/wiki/Musl_porting_notes) | musl 兼容性问题大全 |
| Gentoo 交叉编译 OpenJDK | [Cross compiling openjdk](https://wiki.gentoo.org/wiki/User:Aslantis/Cross_compiling_openjdk) | 交叉编译通用指南 |
| OHOS Rust 交叉编译 | [rustc OpenHarmony](https://doc.rust-lang.org/nightly/rustc/platform-support/openharmony.html) | OHOS NDK 使用参考 |
| .NET on OHOS | [harmony-developers.com](https://www.harmony-developers.com/p/netavalonia-adaptation-to-harmonyos) | linux-musl-arm64 在 OHOS 上的验证 |
| musl FAQ | [musl-libc.org/faq](https://wiki.musl-libc.org/faq) | musl 与 glibc 差异 |