# OpenJDK for HarmonyOS NEXT 适配指南

> ⚠️ **状态说明（2026-05-08）**
>
> - **JDK 17**：✅ 唯一上线运行时。`OpenJDK 17.0.13-internal v4` + 4 个 patch，`prebuilt/jdk/17/` 完整产物。ArkTS 端 `Constants.SUPPORTED_JDK_VERSION = '17'` policy lock。
> - **JDK 21**：⚠️ **仅研究产物、未上线**。`prebuilt/jdk/21/`、`docker/build_jdk21_ohos.sh`、`patches/jdk21u/` 5 patch 是历史调研产物，**未做真机回归**，ArkTS 端 `JdkManager.listVersions()` 不会暴露。本文档提及的 JDK 21 内容仅供参考，**不代表当前发布支持**。
> - JDK 21 上线步骤见 `docs/ROADMAP.md` P2-NEW。

本文档详细记录了 OpenJDK 在 HarmonyOS NEXT 上的适配方案，包括 **JDK 17 的完整上线实现**和 **JDK 21 的研究/适配计划**（未上线）。

## 目录

1. [整体架构](#一整体架构)
2. [核心设计原则](#二核心设计原则)
3. [HotSpot 源码补丁](#三hotspot-源码补丁)
4. [C++ Shim 库](#四c-shim-库)
5. [信号处理机制](#五信号处理机制)
6. [Docker 编译流程](#六docker-编译流程)
7. [运行时加载流程](#七运行时加载流程)
8. [多版本 JDK 并存方案](#八多版本-jdk-并存方案)
9. [JDK 21 适配计划](#九jdk-21-适配计划)

---

## 一、整体架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                      HarmonyOS App (HAP)                             │
├─────────────────────────────────────────────────────────────────────┤
│  entry/libs/arm64-v8a/              │  rawfile/ 或 GitHub 下载       │
│  ├── libjvm17.so (23MB)             │  └── jdk17-ohos-data.zip       │
│  ├── libjava17.so                   │      ├── lib/modules           │
│  ├── libjsig17.so                   │      ├── lib/jvm.cfg           │
│  ├── libcxxabi_shim.so (共用)       │      ├── conf/                 │
│  ├── libjvm21.so (未来)             │      └── release               │
│  ├── libjava21.so (未来)            │  └── jdk21-ohos-data.zip       │
│  └── ... (每版本约35个.so)          │      └── ...                   │
├─────────────────────────────────────┴───────────────────────────────┤
│  运行时目录结构：                                                     │
│  filesDir/jdk/17/                   ← jdk17-ohos-data.zip 解压       │
│  ├── lib/modules                    ← JDK 模块文件（核心数据）        │
│  ├── lib/jvm.cfg                                                     │
│  ├── lib/*.so → 从 HAP 复制         ← copySoFiles() 复制             │
│  └── conf/                                                           │
│  filesDir/jdk/21/                   ← jdk21-ohos-data.zip 解压       │
│  └── ...                                                             │
└─────────────────────────────────────────────────────────────────────┘
```

## 二、核心设计原则

### 2.1 .so 文件必须随 HAP 打包

**原因**：HarmonyOS 强制代码签名，`dlopen` 无法加载运行时下载的 .so 文件（报错 "File exists"）。

**位置**：`entry/libs/arm64-v8a/` 目录

**加载路径检测**：
```cpp
// 通过 /proc/self/maps 检测 libentry.so 路径，推断 native lib 目录
static std::string detectNativeLibDir() {
    FILE* f = fopen("/proc/self/maps", "r");
    // 查找 libentry.so 所在目录
    // 返回类似 /data/storage/el1/bundle/libs/arm64
}
```

### 2.2 数据文件可以下载

**内容**：
- `lib/modules` — JDK 模块文件（核心，约 90MB）
- `conf/` — 配置文件
- `release` — 版本信息

**来源**：GitHub Releases 下载 `jdk17-ohos-data.zip`

**存放**：`filesDir/jdk/<version>/`

### 2.3 环境变量桥接

由于 HarmonyOS 沙箱机制，JVM 无法通过 `libjvm.so` 路径推断 `JAVA_HOME`：

```cpp
// jvm_launcher.cpp
setenv("JAVA_HOME", jdkDataDir.c_str(), 1);           // filesDir/jdk/17
setenv("SUN_BOOT_LIBRARY_PATH", nativeLibDir.c_str(), 1);  // HAP native lib 目录
```

对应的 HotSpot 补丁会优先读取这些环境变量。

## 三、HotSpot 源码补丁

### 3.1 JDK 17 补丁清单（4 个）

权威清单在 `docker/patches/jdk17u/series`（apply_patches.sh 按顺序用 `git apply` 应用）：

| 补丁文件 | 修改的源文件 | 作用 |
|---------|-------------|------|
| `0001-musl-dlvsym-dlinfo.patch` | `os_linux.cpp` | musl libc 已提供 `dlvsym`，移除重复定义；跳过不支持的 `dlinfo()` |
| `0002-java-home-env.patch` | `os_linux.cpp` | 优先使用 `JAVA_HOME` 环境变量设置 `java.home` |
| `0003-dll-dir-env.patch` | `os_linux.cpp` | 优先使用 `SUN_BOOT_LIBRARY_PATH` 设置 `dll_dir` |
| `0004-musl-utmpx.patch` | `os_posix.cpp` | 跳过 musl 不支持的 `setutxent/getutxent/endutxent` |

> `__clear_cache` 在 JDK 17 没做源码 patch —— 我们在 `jvm_launcher.cpp` 里用
> `__attribute__((visibility("default")))` 直接在 `libentry.so` 导出一份 ARM64 汇编
> 实现，HotSpot 加载 libjvm 时通过链接时的 undefined symbol 解析拿到。

### 3.1.1 JDK 21 补丁清单（5 个）

权威清单在 `docker/patches/jdk21u/series`：

| 补丁文件 | 修改的源文件 | 作用 |
|---------|-------------|------|
| `0001-musl-dlvsym-dlinfo.patch` | `os_linux.cpp` | 同 JDK 17 |
| `0002-java-home-env.patch` | `os_linux.cpp` | 同 JDK 17 |
| `0003-dll-dir-env.patch` | `os_linux.cpp` | 同 JDK 17 |
| `0004-musl-utmpx.patch` | `os_posix.cpp` | 同 JDK 17 |
| `0005-inline-clear-cache.patch` | HotSpot ICache | 把 `__clear_cache` 内联进 HotSpot 源码（JDK 21 不再方便在 libentry 侧导出） |

> JDK 21 默认使用 thread-local handshake，原则上不需要 "safepoint polling page"
> 相关补丁。但我们同时也**不依赖**任何 `-XX:-UsePollingPageSafepoint` 这种危险开关，
> sigchain handler 负责把 SEGV 转发给 HotSpot，HotSpot 自己处理 safepoint。

### 3.2 补丁示例：JAVA_HOME 环境变量

```diff
// 0002-java-home-env.patch
@@ -463,7 +463,13 @@ void os::init_system_properties_values() {
         *pslash = '\0';        // Get rid of /lib.
       }
     }
-    Arguments::set_java_home(buf);
+    // OHOS: prefer JAVA_HOME env var (sandbox path inference fails)
+    const char* java_home_env = ::getenv("JAVA_HOME");
+    if (java_home_env != NULL && java_home_env[0] != '\0') {
+      Arguments::set_java_home(java_home_env);
+    } else {
+      Arguments::set_java_home(buf);
+    }
```

### 3.3 补丁应用流程

```bash
# 使用 apply_patches.sh 脚本
bash /build/apply_patches.sh jdk17u /build/jdk17u

# 脚本读取 patches/jdk17u/series 文件，按顺序应用补丁
# 支持 git apply 和 --3way 宽松模式
```

## 四、C++ Shim 库

### 4.1 libcxxabi_shim.so

**作用**：提供 `libjvm.so` 依赖的 C++ ABI 符号，HarmonyOS musl libc 不提供这些符号。

**导出符号**：
- `std::nothrow` — C++ new 操作符需要
- `operator new/delete` — 内存分配
- `__gxx_personality_v0` — 异常处理
- `__cxa_*` 系列 — C++ ABI 函数

**源码**：`docker/shims/cxxabi_shim.cpp` + `eh_stubs.c`

**编译命令**：
```bash
/usr/bin/ohos-clang++ --target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} \
    -shared -fPIC -fvisibility=hidden -fno-exceptions -fno-rtti \
    -o libcxxabi_shim.so cxxabi_shim.cpp eh_stubs.o \
    -fuse-ld=lld -Wl,-soname,libcxxabi_shim.so -nostdlib++ -nodefaultlibs -lc
```

### 4.2 __clear_cache 实现

**问题**：HarmonyOS musl libc 不提供 `__clear_cache` 函数，但 HotSpot JIT 需要它来刷新指令缓存。

**解决方案 1**：在 `jvm_launcher.cpp` 中导出 ARM64 汇编实现

```cpp
extern "C" __attribute__((visibility("default")))
void __clear_cache(void* start, void* end) {
    static size_t ctr_el0 = 0;
    if (ctr_el0 == 0) {
        __asm__ volatile("mrs %0, ctr_el0" : "=r"(ctr_el0));
    }
    size_t icache_line = 4 << ((ctr_el0 >> 0) & 0xf);
    size_t dcache_line = 4 << ((ctr_el0 >> 16) & 0xf);
    // dc cvau + ic ivau 指令序列
    // ...
}
```

**解决方案 2**：替换 HotSpot 的 `ICache` 类（`docker/shims/icache_patch.hpp`）

## 五、信号处理机制

### 5.1 问题背景

HotSpot 使用 SIGSEGV 实现：
- **Safepoint polling**：安全点轮询，用 `mprotect(PROT_NONE)` 触发 SIGSEGV
- **Implicit null checks**：隐式空指针检查，访问 NULL 附近地址触发 SIGSEGV

HarmonyOS 的 DFX crash handler 会拦截 SIGSEGV 并杀死进程，导致 JVM 无法正常工作。

### 5.2 解决方案

```cpp
// jvm_launcher.cpp - jvmInit() 函数

// 步骤 1：JVM 启动前清除所有 signal handler
{
    struct sigaction clean_sa;
    memset(&clean_sa, 0, sizeof(struct sigaction));
    sigemptyset(&clean_sa.sa_mask);
    for (int sigid = 1; sigid < 32; sigid++) {
        if (sigid == SIGSEGV) {
            clean_sa.sa_handler = SIG_IGN;  // SIGSEGV 设为忽略
        } else if (sigid == SIGKILL || sigid == SIGSTOP) {
            continue;  // 不能修改
        } else {
            clean_sa.sa_handler = SIG_DFL;
        }
        sigaction(sigid, &clean_sa, nullptr);
    }
}

// 步骤 2：预加载 libjsig.so（JVM signal chaining 库）
void* jsigH = dlopen("libjsig.so", RTLD_NOW | RTLD_GLOBAL);

// 步骤 3：创建 JVM
jint rc = createVM(&jvm, (void**)&env, &vm_args);

// 步骤 4：JVM 启动后，用 OHOS sigchain API 注册 handler
add_special_signal_handler(SIGSEGV, &s_chainAction);
```

### 5.3 Sigchain Handler 逻辑

```cpp
s_chainAction.sca_sigaction = [](int sig, siginfo_t* info, void* ctx) -> bool {
    ucontext_t* uc = (ucontext_t*)ctx;
    uintptr_t oldPC = (uintptr_t)uc->uc_mcontext.pc;
    
    // 调用 JVM 的 SIGSEGV handler
    s_jvmSigHandler(sig, info, ctx);
    
    uintptr_t newPC = (uintptr_t)uc->uc_mcontext.pc;
    if (newPC != oldPC) {
        // PC 被修改 → JVM 处理了这个 SIGSEGV
        return true;  // 阻止 DFX crash handler
    }
    
    // PC 不变 → 真正的 crash
    return false;  // 让 DFX 处理
};
```

### 5.4 JVM 参数配置

> ⚠️ **重要教训**：不要关闭 safepoint polling page（`-XX:-UsePollingPageSafepoint`），
> 也不要在 sigchain handler 里对 fault page 做 `mprotect`。否则 JVM 的 safepoint
> 同步被破坏，Forge `Module.implAddExportsOrOpens(syncVM=true)` 会触发全 VM 死锁（黑屏）。
>
> 正确做法：
>   - OHOS sigchain handler 只负责**把 SIGSEGV 转发给 HotSpot 的 handler**，然后 `return true`；
>   - PC 未变是 safepoint polling 的正常行为，kernel 会重试指令，HotSpot 届时已把 polling page 恢复为 `PROT_READ`。

```cpp
// 真正需要在 OHOS 上添加的 HotSpot 参数
"-XX:+UnlockExperimentalVMOptions"
"-XX:+DisablePrimordialThreadGuardPages"  // OHOS 线程栈 guard page 分配失败 → crash
"-XX:+UnlockDiagnosticVMOptions"
// 不要传这些（历史教训）：
//   -XX:-ImplicitNullChecks            sigchain 已正确转发 SIGSEGV，禁用反而拖慢 JIT
//   -XX:+ThreadLocalHandshakes         JDK 17 默认且强制，显式传会警告
//   -XX:-UsePollingPageSafepoint       禁用会导致 Forge handshake 死锁
//   -XX:+AllowUserSignalHandlers       会让 JVM 跳过必要的 signal handler
```

## 六、Docker 编译流程

### 6.1 Docker 镜像

```dockerfile
# Dockerfile.openjdk-ohos
FROM ubuntu:22.04

# 安装 clang-15（与 OHOS NDK clang 15.0.4 版本匹配）
RUN apt-get install -y clang-15 lld-15 llvm-15 libc++-15-dev libc++abi-15-dev

# 安装 OpenJDK 17 作为 boot JDK
RUN apt-get install -y openjdk-17-jdk

# 复制编译脚本和补丁
COPY setup_toolchain.sh build_jdk17_ohos.sh apply_patches.sh /build/
COPY patches/ /build/patches/
COPY shims/ /build/shims/
COPY stubs/ /build/stubs/
```

### 6.2 编译命令

```bash
# 构建 Docker 镜像
docker build -f docker/Dockerfile.openjdk-ohos -t openjdk-ohos-builder .

# 运行编译（挂载 OHOS sysroot 和输出目录）
docker run --rm \
  -v "/path/to/ohos/sysroot:/ohos-sysroot:ro" \
  -v "/path/to/output:/output" \
  openjdk-ohos-builder /build/build_jdk17_ohos.sh
```

### 6.3 编译流程（build_jdk17_ohos.sh）

1. **设置工具链**：创建 OHOS 交叉编译器包装脚本
2. **克隆 JDK 源码**：`git clone --depth 1 https://github.com/openjdk/jdk17u.git`
3. **安装 stub 头文件**：CUPS、Fontconfig、X11、ALSA
4. **应用源码补丁**：`apply_patches.sh jdk17u /build/jdk17u`
5. **Configure**：配置交叉编译参数
6. **Build**：`gmake images JOBS=$JOBS`
7. **Post-build**：
   - 创建 `libcxxabi_shim.so`
   - 重编 `libjli.so`（含 exit 拦截）
   - 分离打包（libs + data）

### 6.4 输出产物

```
/output/
├── jdk-libs/           # .so 文件（复制到 entry/libs/arm64-v8a/）
│   ├── libjvm.so
│   ├── libjava.so
│   ├── libcxxabi_shim.so
│   └── ... (共约 35 个)
└── jdk-data.zip        # 数据文件（上传到 GitHub Releases）
    ├── lib/modules
    ├── lib/jvm.cfg
    ├── conf/
    └── release
```

## 七、运行时加载流程

### 7.1 App 启动时

```typescript
// JdkManager.ets - checkAndExtract()
async checkAndExtract(): Promise<boolean> {
    // 1. 检查 filesDir/jdk/17/lib/modules 是否存在
    if (this.isInstalled('17')) {
        return true;
    }
    
    // 2. 尝试从 rawfile 解压（内置版本）
    try {
        const rawData = this.context.resourceManager.getRawFileContentSync('jdk-data.zip');
        if (rawData.byteLength > 0) {
            return await this.extractZipToDir(rawData, this.getJdkDir('17'));
        }
    } catch (e) { }
    
    // 3. 从 GitHub 下载
    return await this.downloadAndInstall('17');
}
```

### 7.2 MC 启动时

```cpp
// jvm_launcher.cpp - jvmInit()
extern "C" int jvmInit(const char* appFilesDir, const char* jdkVersion) {
    // 1. 检测 native lib 目录
    std::string nativeLibDir = detectNativeLibDir();
    
    // 2. 构建 JDK 数据目录路径
    std::string jdkDataDir = std::string(appFilesDir) + "/jdk/" + jdkVersion;
    
    // 3. 复制 .so 到 jdkDataDir/lib/（JVM 需要）
    copySoFiles(jdkDataDir, nativeLibDir, ss);
    
    // 4. 设置环境变量
    setenv("JAVA_HOME", jdkDataDir.c_str(), 1);
    setenv("SUN_BOOT_LIBRARY_PATH", nativeLibDir.c_str(), 1);
    
    // 5. 预加载 libjsig.so
    dlopen((nativeLibDir + "/libjsig.so").c_str(), RTLD_NOW | RTLD_GLOBAL);
    
    // 6. 加载 libjvm.so
    void* jvmH = dlopen((nativeLibDir + "/libjvm.so").c_str(), RTLD_NOW | RTLD_GLOBAL);
    
    // 7. 创建 JVM
    auto createVM = (JNI_CreateJavaVM_t)dlsym(jvmH, "JNI_CreateJavaVM");
    jint rc = createVM(&jvm, (void**)&env, &vm_args);
    
    // 8. 注册 sigchain handler
    add_special_signal_handler(SIGSEGV, &s_chainAction);
    
    return 0;
}
```

## 八、多版本 JDK 并存方案

### 8.1 设计目标

- 支持 JDK 17、21 甚至更多版本同时打包在 HAP 中
- 运行时根据 MC 版本自动选择合适的 JDK
- 最小化 HAP 体积增长

### 8.2 .so 文件命名规范

为避免符号冲突和加载混乱，每个 JDK 版本的 .so 文件需要添加版本后缀：

```
entry/libs/arm64-v8a/
├── libcxxabi_shim.so      # 共用（所有版本兼容）
├── libjvm17.so            # JDK 17 的 libjvm.so
├── libjava17.so           # JDK 17 的 libjava.so
├── libjsig17.so           # JDK 17 的 libjsig.so
├── libzip17.so            # ...
├── libjvm21.so            # JDK 21 的 libjvm.so
├── libjava21.so           # JDK 21 的 libjava.so
├── libjsig21.so           # JDK 21 的 libjsig.so
└── libzip21.so            # ...
```

### 8.3 编译时重命名

在 `pack_jdk_split.sh` 中添加重命名逻辑：

```bash
JDK_VERSION=${JDK_VERSION:-17}  # 从环境变量获取版本号

for f in $JDK/lib/*.so; do
    bname=$(basename "$f" .so)
    # 重命名：libjvm.so → libjvm17.so
    cp "$f" "$LIBS_DIR/${bname}${JDK_VERSION}.so"
done
```

### 8.4 运行时加载逻辑

```cpp
// jvm_launcher.cpp
extern "C" int jvmInit(const char* appFilesDir, const char* jdkVersion) {
    // 根据版本号构建 .so 文件名
    std::string suffix = jdkVersion;  // "17" 或 "21"
    std::string libjvmName = "libjvm" + suffix + ".so";
    std::string libjsigName = "libjsig" + suffix + ".so";
    
    // 加载对应版本的 .so
    dlopen((nativeLibDir + "/" + libjsigName).c_str(), RTLD_NOW | RTLD_GLOBAL);
    void* jvmH = dlopen((nativeLibDir + "/" + libjvmName).c_str(), RTLD_NOW | RTLD_GLOBAL);
    // ...
}
```

### 8.5 数据文件分离

每个版本的数据文件独立存放：

```
GitHub Releases:
├── v17.0.13-ohos-1/
│   └── jdk17-ohos-data.zip
└── v21.0.1-ohos-1/
    └── jdk21-ohos-data.zip

filesDir/jdk/
├── 17/
│   ├── lib/modules
│   └── ...
└── 21/
    ├── lib/modules
    └── ...
```

### 8.6 版本选择策略

```typescript
// JdkManager.ets
autoSelectVersion(mcVersion: string): string {
    // MC 1.20.4 及以下 → JDK 17
    // MC 1.20.5 及以上 → JDK 21
    if (mcVersion >= '1.20.5') return '21';
    return '17';
}
```

### 8.7 HAP 体积估算

| 组件 | JDK 17 | JDK 21 | 合计 |
|------|--------|--------|------|
| .so 文件 | ~35 MB | ~38 MB | ~73 MB |
| data.zip | ~97 MB | ~105 MB | 分开下载 |

**优化建议**：
- 使用 `strip` 去除调试符号
- 考虑按需下载 .so（但 HarmonyOS 不支持）
- 压缩 HAP（系统自动处理）

## 九、JDK 21 适配计划

### 9.1 与 JDK 17 的主要差异

| 方面 | JDK 17 | JDK 21 |
|------|--------|--------|
| Safepoint | 需要禁用 polling page | 默认使用 thread-local handshake |
| Virtual Threads | 不支持 | 支持（Project Loom） |
| 模块系统 | 成熟 | 更成熟 |
| 源码结构 | 稳定 | 部分文件可能变化 |

### 9.2 预计需要的补丁

```
patches/jdk21u/
├── series
├── 0001-musl-dlvsym-compat.patch       # dlvsym 声明冲突
├── 0002-musl-utmpx-compat.patch        # utmpx 函数缺失
├── 0003-java-home-env.patch            # JAVA_HOME 环境变量
├── 0004-dll-dir-env.patch              # dll_dir 环境变量
├── 0005-jli-exit-visibility.patch      # JLI_Exit 符号可见性（可选）
├── 0006-exit-intercept.patch           # exit() 拦截（可选）
└── 0007-getjrepath-ohos.patch          # GetJREPath 适配（可选）
```

**注意**：JDK 21 默认使用 thread-local handshake，可能不需要 safepoint polling page 补丁。

### 9.3 适配步骤

1. **克隆 JDK 21u 源码**
2. **逐个移植 JDK 17 补丁**
3. **创建 JDK 21 编译脚本**
4. **编译测试**
5. **更新 App 代码支持多版本**
6. **打包发布**

### 9.4 测试重点

- SIGSEGV 处理（JDK 21 的 safepoint 机制）
- Virtual Threads 兼容性
- MC 1.20.5+ 的启动和运行
- 内存占用对比

---

## 附录

### A. 关键文件清单

| 文件 | 作用 |
|------|------|
| `docker/build_jdk17_ohos.sh` | JDK 17 编译主脚本 |
| `docker/apply_patches.sh` | 补丁应用脚本 |
| `docker/patches/jdk17u/series` | JDK 17 补丁列表 |
| `docker/shims/cxxabi_shim.cpp` | C++ ABI shim 源码 |
| `docker/shims/icache_patch.hpp` | ICache 替换头文件 |
| `docker/scripts/pack_jdk_split.sh` | 产物分离打包脚本 |
| `entry/src/main/cpp/jvm/jvm_launcher.cpp` | JVM 加载和初始化 |
| `entry/src/main/ets/services/JdkManager.ets` | JDK 版本管理 |

### B. 常用命令

```bash
# 进入 Docker 容器
docker exec -it ohos-debug bash

# 编译 JDK 17
bash /build/build_jdk17_ohos.sh

# 只编译 hotspot（增量）
cd /build/jdk17u && gmake hotspot JOBS=16

# 打包产物
bash /build/scripts/pack_jdk_split.sh

# 复制到项目
bash /build/scripts/copy_jdk_to_project.sh
```

### C. 故障排查

| 问题 | 原因 | 解决方案 |
|------|------|---------|
| dlopen 失败 "File exists" | 尝试加载下载的 .so | .so 必须随 HAP 打包 |
| SIGSEGV 崩溃 | DFX crash handler 拦截 | 使用 sigchain API |
| java.home 错误 | 路径推断失败 | 检查 JAVA_HOME 环境变量 |
| 找不到 libjimage.so | dll_dir 错误 | 检查 SUN_BOOT_LIBRARY_PATH |
| __clear_cache 未定义 | musl 不提供 | 使用内联汇编实现 |

---

*文档版本：1.0*
*最后更新：2026-03-02*
*作者：MC-OHOS 项目组*
