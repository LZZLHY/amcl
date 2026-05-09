# MC-OHOS 项目架构全景

> **最后对齐**：2026-04-19
> **基线**：`47cec6e` 之后（Forge 1.20.4 能进主菜单）
> **权威源**：`entry/src/main/cpp/`、`entry/src/main/ets/`、`JavaApp/src/`、`docker/patches/*/series`
> 如果本文档与源码冲突，以源码为准，并同步回本文档。

## 一、核心目标

在 HarmonyOS NEXT 上运行 Minecraft Java Edition。
HarmonyOS 没有 JVM、没有桌面 OpenGL、没有 GLFW、没有 OpenAL —— 每一层都需要我们自己实现或适配。

关键约束（影响整体架构的四条硬限制）：

1. **HarmonyOS 代码签名 (MAP_XPM)** — 系统 `dlopen` 拒绝加载运行时下载的 .so。我们用**自定义 ELF loader**（`entry/src/main/cpp/jvm/elf_loader.cpp`）绕过这一限制，加载 `filesDir/jdk/<ver>/` 下的 OpenJDK .so。
2. **JIT 需要可写+可执行内存** — 需要 `ALLOW_WRITABLE_CODE_MEMORY` ACL 权限。
3. **OHOS DFX 信号系统** — `SIGSEGV` 会被 DFX 拦截并杀进程。通过 `add_special_signal_handler` + `libjsig.so` 预加载解决，HotSpot safepoint 轮询照常使用（不要关）。
4. **沙箱 + 单进程** — 系统 `JAVA_HOME` 无法通过 `/proc/self/exe` 推断；通过补丁 + 环境变量桥接解决。

---

## 二、运行时调用链

```
┌─────────────────────────────────────────────────────────────────────────┐
│  HarmonyOS App                                                          │
│                                                                         │
│  ArkTS 层 (UI + 生命周期)                                                │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │ Index / McGamePage / VersionSettingsPage / DevToolsPage         │    │
│  │     │                                                           │    │
│  │     │ XComponent (SURFACE 类型)  ← 渲染面                        │    │
│  │     │ onTouch → NAPI 转发触摸事件                                 │    │
│  │     │                                                           │    │
│  │ services/                                                       │    │
│  │   LaunchProfileBuilder.ets  ← 解析 version.json → LaunchProfile │    │
│  │   VersionJsonMerger.ets     ← PCL2 合并 JSON（自包含）           │    │
│  │   DownloadTask.ets          ← 流式下载 + 多任务并行              │    │
│  │   modloader/                ← Forge/Fabric 安装                 │    │
│  │   JdkManager.ets            ← 多版本 JDK 管理（解压 zip 数据）    │    │
│  │   RuntimeDeployer.ets       ← 首次启动 rawfile → filesDir 部署   │    │
│  └──────────┬──────────────────────────────────────────────────────┘    │
│             │ NAPI 调用 (mcLaunchWithProfile)                           │
│             ▼                                                           │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │ Native 层 (C/C++)                                                │    │
│  │                                                                  │    │
│  │ libentry.so ← 主模块，NAPI 入口                                   │    │
│  │     │                                                            │    │
│  │     ├── napi/napi_entry.cpp      ArkTS ↔ C++ 桥接                │    │
│  │     ├── platform/xcomponent.cpp  XComponent 生命周期回调          │    │
│  │     ├── platform/touch_input.cpp 触摸事件从 ArkTS 转发到 GLFW    │    │
│  │     ├── platform/gpu_info.cpp    查询 GPU 信息                    │    │
│  │     ├── platform/mg_config.cpp   MobileGlues 配置管理             │    │
│  │     ├── jvm/elf_loader.cpp       自定义 ELF loader（绕过 MAP_XPM）│    │
│  │     ├── jvm/jvm_launcher.cpp     启动 JVM（JNI_CreateJavaVM）    │    │
│  │     ├── jvm/mc_launcher.cpp      Phase 0-5 阶段化启动 MC          │    │
│  │     ├── jvm/fork_run_java.cpp    fork 子进程跑 Forge installer    │    │
│  │     ├── jvm/jni_registry.cpp     RegisterNatives 统一注册 (36 方法)│   │
│  │     ├── jvm/jvm_common_args.cpp  SSOT: 主/子 JVM 共享 OHOS 兼容参数│    │
│  │     └── utils/amcl_log.cpp       统一 logging                     │    │
│  │             │                                                     │    │
│  │             │ elf_dlopen(filesDir/jdk/<ver>/libjvm.so)             │    │
│  │             │ + add_special_signal_handler(SIGSEGV)                │    │
│  │             │ + JNI_CreateJavaVM()                                │    │
│  │             ▼                                                     │    │
│  │ ┌─────────────────────────────────────────────────────────────┐   │    │
│  │ │  JVM 进程内运行 (libjvm.so + libjava.so + ...)               │   │    │
│  │ │                                                             │   │    │
│  │ │  Java 启动入口：com.amcl.launcher.AmclLauncher              │   │    │
│  │ │  （AmclClassLoader 作为 java.system.class.loader）           │   │    │
│  │ │       │                                                     │   │    │
│  │ │       ├── 动态 addURL 所有 MC jar                           │   │    │
│  │ │       ├── Forge 预处理（写 fml.toml / splash.properties）   │   │    │
│  │ │       └── 反射调用 mainClass.main(mcArgs)                   │   │    │
│  │ │              │                                              │   │    │
│  │ │              ▼  加载 Minecraft .jar + 依赖库                │   │    │
│  │ │                                                             │   │    │
│  │ │       ├── 文件/网络/加密 ──→ JDK 内置 .so (libjava/libnet等) │   │    │
│  │ │       │                      经 ELF loader 加载              │   │    │
│  │ │       │                                                     │   │    │
│  │ │       ├── 窗口/输入 ──→ LWJGL GLFW Java层（改版）           │   │    │
│  │ │       │                    → JNI → liblwjgl.so              │   │    │
│  │ │       │                              → dlopen(libglfw.so)   │   │    │
│  │ │       │                                                     │   │    │
│  │ │       ├── 3D 渲染 ──→ LWJGL OpenGL Java层 (.jar)            │   │    │
│  │ │       │                → JNI → liblwjgl_opengl.so           │   │    │
│  │ │       │                          → dlsym("glXxx")           │   │    │
│  │ │       │                            from libglfw.so          │   │    │
│  │ │       │                              → MobileGlues GL翻译   │   │    │
│  │ │       │                                → libGLESv3.so (GPU) │   │    │
│  │ │       │                                                     │   │    │
│  │ │       ├── 音频 ──→ LWJGL OpenAL Java层 (.jar)               │   │    │
│  │ │       │              → JNI → dlopen(libopenal.so)           │   │    │
│  │ │       │                       → OpenAL Soft + OHAudio 后端  │   │    │
│  │ │       │                                                     │   │    │
│  │ │       ├── AWT (Forge 模组) → Cacio bootclasspath            │   │    │
│  │ │       │   （仅当 filesDir/cacio/*.jar 存在时启用）           │   │    │
│  │ │       │                                                     │   │    │
│  │ │       └── ObjC bridge ──→ stub-objc-bridge.jar              │   │    │
│  │ │                            → JNI → libjcocoa.so (空实现)     │   │    │
│  │ └─────────────────────────────────────────────────────────────┘   │    │
│  │                                                                  │    │
│  │ libglfw.so ← GLFW 兼容层 + MobileGlues GL翻译层 (合并构建)        │    │
│  │     ├── glfwCreateWindow   → XComponent + EGL 初始化              │    │
│  │     ├── glfwPollEvents     → 从 ring buffer 读取触摸事件           │    │
│  │     ├── glfwSwapBuffers    → eglSwapBuffers                      │    │
│  │     ├── glDrawArrays 等    → MobileGlues → GLES3 调用             │    │
│  │     └── glBegin/glEnd 等   → MobileGlues → 翻译为 GLES 等价操作   │    │
│  │                                                                  │    │
│  │ libjni_reregister.so                                             │    │
│  │     └── CallbackBridge.<clinit> System.loadLibrary("jni_reregister")│  │
│  │         → JNI_OnLoad → 用模组加载器的 CL 再次 RegisterNatives     │    │
│  │                                                                  │    │
│  │ libopenal.so  ← OpenAL Soft + OHAudio 后端                       │    │
│  │     └── OHAudio (系统 libohaudio.so) → 真正的音频输出             │    │
│  │                                                                  │    │
│  └──────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 三、各角色职责一览

### 3.1 与 GPU 交互的

| 角色 | 文件/库 | 职责 |
|------|---------|------|
| **MobileGlues** | `mobileglues/MobileGlues-cpp/` → 编译进 `libglfw.so` | 将桌面 OpenGL 调用翻译为 OpenGL ES 调用。MC 调用 `glBegin()`，MobileGlues 翻译为 GLES 的 `glDrawArrays()` |
| **glslang** | MobileGlues 的子依赖 | 解析桌面 GLSL 着色器 |
| **SPIRV-Cross** | MobileGlues 的子依赖 | 将 SPIR-V 着色器翻译为 ESSL (OpenGL ES 着色器语言) |
| **libGLESv3.so** | 系统库 (GPU 驱动) | 真正和 GPU 硬件交互的库，由手机厂商提供 |
| **libEGL.so** | 系统库 | 管理 OpenGL ES 上下文和渲染面 |

### 3.2 创建窗口 / 管理渲染面的

| 角色 | 文件/库 | 职责 |
|------|---------|------|
| **GLFW 兼容层** | `glfw/*.cpp` → 编译进 `libglfw.so` | 模拟桌面 GLFW API，底层用 OHOS XComponent + EGL 实现 |
| **XComponent** | `platform/xcomponent.cpp` + ArkTS 页面 | OHOS 提供的原生渲染组件，提供 NativeWindow 给 EGL |
| **EGL 管理** | `glfw/glfw_egl.cpp` | 创建 EGL Display/Surface/Context，绑定到 XComponent 的 NativeWindow |

### 3.3 处理输入 (触摸/键盘) 的

| 角色 | 文件/库 | 职责 |
|------|---------|------|
| **ArkTS 触摸层** | `VulkanPage.ets` / `McGamePage.ets` | 拦截触摸事件，通过 NAPI 转发到 C 层 |
| **触摸转发** | `platform/touch_input.cpp` | 从 ArkTS 接收触摸数据，写入 ring buffer |
| **输入桥接** | `glfw/input_bridge_ohos.c` | 环形缓冲区 + JNI 回调注册，连接 ArkTS ↔ Java |
| **GLFW 回调** | `glfw/glfw_callbacks.cpp` | 注册/分发 GLFW 回调 (键盘、鼠标、窗口事件) |
| **CallbackBridge.java** | `lwjgl-ohos/src/.../CallbackBridge.java` | Java 层回调桥接，将 OHOS 事件转发到 GLFW 回调 |

### 3.4 运行 Java 代码的 (JVM/JDK)

JDK 分发策略 — `.so` 不打在 HAP 里，而是从 GitHub Release 下载 `jdk<ver>-ohos-data.zip` 解压到 `filesDir/jdk/<ver>/`，再由自定义 ELF loader 加载：

| 角色 | 文件/库 | 加载方式 | 职责 |
|------|---------|---------|------|
| **libjvm.so** (~23MB) | `filesDir/jdk/17/lib/server/` | `elf_dlopen` | JVM 核心：字节码解释器 + JIT + GC + 线程 |
| **libjava.so** / **libjli.so** / **libjsig.so** | `filesDir/jdk/17/lib/` | `elf_dlopen` | JDK 核心 native |
| **libnet.so** / **libnio.so** / **libzip.so** | `filesDir/jdk/17/lib/` | `elf_dlopen` | 网络 / NIO / ZIP |
| **其他 ~35 个 JDK .so** | `filesDir/jdk/17/lib/` | `elf_dlopen` | 字体、加密、图像、调试等子系统 |
| **libcxxabi_shim.so** | `entry/libs/arm64-v8a/` | 系统 `dlopen` | C++ ABI 兼容层（musl ↔ JVM），HAP 打包（多版本共用） |
| **lib/modules** (~128MB) | `filesDir/jdk/17/lib/modules` | JVM 直接读 | JDK 9+ 模块镜像文件（boot class path） |
| **jvm/elf_loader.cpp** | 编译进 `libentry.so` | — | 自定义 ELF loader（匿名 mmap + pread + mprotect + TLSDESC resolver）|
| **jvm/jvm_launcher.cpp** | 编译进 `libentry.so` | — | 设置 sigchain handler，调用 `JNI_CreateJavaVM` 启动 JVM |
| **jvm/mc_launcher.cpp** | 编译进 `libentry.so` | — | Phase 0-5 阶段化启动，反射调用 `AmclLauncher.main` |
| **jvm/fork_run_java.cpp** | 编译进 `libentry.so` | — | `fork()` 子进程 + `JLI_Launch` 跑 Forge installer（独立 JVM，和主进程隔离） |
| **jvm/jni_registry.cpp** | 编译进 `libentry.so` | — | 统一 `RegisterNatives`，把 GLFW/OpenAL 的 36 个 native 方法批量注册 |

> **为什么 JDK .so 不能直接打在 HAP 里？**
> HarmonyOS 强制代码签名（MAP_XPM），`dlopen` 只信任 HAP 内 `libs/arm64-v8a/` 的 .so。但 JDK 体积大（40+ 个 .so，总 50MB+）且希望做多版本并存/按需下载，放在 HAP 里会使 HAP 本体过大。
> **解决**：把 .so 放到 `filesDir/jdk/<ver>/lib/`（可运行时写入），用自定义 ELF loader（匿名 `mmap` + `pread` + `mprotect(PROT_EXEC)`）加载，绕开 MAP_XPM。详见 `@docs/archive/elf_loader_notes.md`。

### 3.5 Java 中间启动层 (`JavaApp/`)

在 C 层反射调用 MC `mainClass.main()` 之前，先经过一个 Java 层中间启动器 `com.amcl.launcher.AmclLauncher`：

| 角色 | 文件 | 职责 |
|------|------|------|
| **AmclLauncher** | `JavaApp/src/com/amcl/launcher/AmclLauncher.java` | Java 入口，解析 JSON 启动配置，动态 addURL 所有 MC jar，反射调用 MC mainClass |
| **AmclClassLoader** | `JavaApp/src/com/amcl/launcher/AmclClassLoader.java` | `URLClassLoader` 子类，通过 `-Djava.system.class.loader=AmclClassLoader` 替换系统 CL |
| **LaunchConfig** | `JavaApp/src/com/amcl/launcher/LaunchConfig.java` | JSON 启动配置数据类（mainClass / classpath / mcArgs / gameDir / mcDir / isForge） |
| **ForgeHelper** | `JavaApp/src/com/amcl/launcher/ForgeHelper.java` | Forge 预处理（写 `config/fml.toml` / `splash.properties`） |

产物：`entry/src/main/resources/rawfile/amcl-launcher.jar`。

构建集成：**已挂进 hvigor 构建图**（`entry/hvigorfile.ts` 注册的 `buildAmclLauncher` task，挂在 `default@BuildJS` 和 `default@PackageHap` 之间）。实际 `javac + jar` 由 `scripts/build-amcl-launcher.mjs` 完成（跨平台 Node，带增量）。DevEco Run ▶️ / `hvigorw` 命令行 / CI 都会自动触发，不再需要 `build-hap.ps1` 先预跑。

### 3.6 LWJGL — Java ↔ Native 桥梁

LWJGL 的 .so 是 HAP 内直接打包的少数几个（和 JDK 不同路径）：

| 角色 | 文件/库 | 职责 |
|------|---------|------|
| **LWJGL Java 层** | `rawfile/lwjgl/*.jar` (10 个 jar，运行时部署到 `filesDir/.minecraft/lwjgl-ohos/`) | MC 直接调用的 Java API。如 `GLFW.glfwCreateWindow()`、`GL11.glDrawArrays()` |
| **liblwjgl.so** | `entry/libs/arm64-v8a/` (HAP 打包) | LWJGL 核心 JNI + libffi。把 Java 调用转为 C 函数调用 |
| **liblwjgl_opengl.so** | `entry/libs/arm64-v8a/` (HAP 打包) | OpenGL JNI 绑定。Java 的 `GL11.glXxx()` → C 的 `glXxx()` |
| **liblwjgl_stb.so** | `entry/libs/arm64-v8a/` (HAP 打包) | STB 图像/字体/音频加载库的 JNI 绑定 |
| **liblwjgl_tinyfd.so** | `entry/libs/arm64-v8a/` (HAP 打包) | 文件对话框 (stub) |
| **libjnidispatch.so** | `entry/libs/arm64-v8a/` (HAP 打包) | JNA — MC 某些库（如 Forge）通过 JNA 而非 JNI 访问 C |
| **GLFW.java (改版)** | `prebuilt/lwjgl3/ohos-glfw/.../GLFW.java` | 修改了窗口创建逻辑以适配 OHOS XComponent |
| **CallbackBridge.java** | `prebuilt/lwjgl3/ohos-glfw/.../CallbackBridge.java` | 新增的回调桥接类；`static { System.loadLibrary("jni_reregister"); }` 让模组加载器的 CL 也能解析 JNI 方法 |

### 3.7 音频（OpenAL Soft + OHAudio）

不再是 stub —— 当前是完整的 OpenAL Soft 3D 音频实现，后端对接 HarmonyOS OHAudio：

| 角色 | 文件/库 | 职责 |
|------|---------|------|
| **libopenal.so** | `entry/src/main/cpp/openal/` + `openal-soft/`（submodule）即时编译 | OpenAL Soft 完整实现，通过 `HAVE_OHAUDIO=1` 接入 OHAudio 后端 |
| **ohaudio.cpp** | `entry/src/main/cpp/openal/ohaudio.cpp` | OpenAL Soft 的 OHAudio BackendFactory（对接系统 `libohaudio.so`） |
| **OpenAL Java 层** | `rawfile/lwjgl/lwjgl-openal.jar` | LWJGL 的 OpenAL Java 绑定（未改动） |

构建要点（见 `@entry/src/main/cpp/openal/CMakeLists.txt` 和 `@setup_deps.sh:78-95`）：
- OpenAL Soft 源码在 `openal-soft/` submodule（由 `setup_deps.sh` 首次拉取时 `git clone --depth 1` 下载；`openal-soft/` 在 `.gitignore` 中）
- **源码落盘后 `setup_deps.sh` 立即用 `sed -i` 原位 patch `alc/alc.cpp`**：
  - 注入 `#include "ohaudio.h"`（条件编译 `#if HAVE_OHAUDIO`）
  - 在 `BackendList` 中 `null` 条目前插入 `BackendInfo{"ohaudio"sv, OHAudioBackendFactory::getFactory}`
- CMake 编译时通过 `target_compile_definitions(OpenAL PRIVATE HAVE_OHAUDIO=1)` 激活上述条件编译
- CMake `target_sources(OpenAL PRIVATE ohaudio.cpp)` 把后端实现文件注入到 OpenAL Soft target，产物是单一 `libopenal.so`

> **注意**：patch 只在 `setup_deps.sh` 第一次克隆（或 `--force` 重新克隆）时生效。如果手动 `rm -rf openal-soft/` 后重新 `git clone` 而没走 `setup_deps.sh`，`BackendList` 里不会有 OHAudio，音频会走 null 后端静音 —— **永远走 `setup_deps.sh`**，不要手动管理 submodule。

### 3.8 兼容性 Stub (让 MC 不崩溃的空实现)

| 角色 | 文件/库 | 职责 |
|------|---------|------|
| **libjcocoa.so** | `stubs/jcocoa_stub.c` → 即时编译 | java-objc-bridge JNI 空实现 (MC 在 macOS 上用，OHOS 上需要 stub) |
| **libobjc.A.so** | `stubs/objc_stub.c` → 即时编译 | ObjC Runtime JNA 空实现 |
| **stub-objc-bridge.jar** | `rawfile/stub-objc-bridge.jar` | java-objc-bridge Java 层空实现 (所有方法返回 null/0/"") |
| **libfakejvm.so** | `tests/fake_jvm.cpp` → 即时编译（仅 `MC_OHOS_BUILD_TESTS=ON` 时） | 测试用的假 JVM |

---

## 四、编译流水线

### 4.1 即时编译 (每次 DevEco Studio 构建 HAP)

CMake 编译以下源码，产出 .so 直接打包进 HAP：

```
entry/src/main/cpp/
├── napi/napi_entry.cpp          ─┐
├── platform/*.cpp                │
├── jvm/                          │
│   ├── jvm_launcher.cpp          │── → libentry.so  (主模块)
│   ├── mc_launcher.cpp           │     NAPI + XComponent + JVM 嵌入
│   ├── jni_registry.cpp          │
│   ├── elf_loader.cpp            │
│   ├── fork_run_java.cpp         │
│   └── ...                       │
├── utils/amcl_log.cpp            │
└── tests/*.cpp  (可选)          ─┘

├── glfw/*.cpp                   ─┐
└── mobileglues/MobileGlues-cpp/  │── → libglfw.so   (GLFW 兼容 + GL 翻译)
    ├── gl/*.cpp                  │
    ├── egl/*.cpp                 │
    ├── gles/*.cpp                │
    ├── glx/*.cpp                 │
    └── config/*.cpp             ─┘

├── glfw/jni_reregister.c        ──→ libjni_reregister.so
│                                     （Fabric/Forge ClassLoader 兼容）
│
├── openal/ohaudio.cpp           ─┐
└── openal/openal-soft/ (submod)  │── → libopenal.so (OpenAL Soft + OHAudio)

├── stubs/jcocoa_stub.c          ──→ libjcocoa.so
├── stubs/objc_stub.c            ──→ libobjc.A.so
└── tests/fake_jvm.cpp           ──→ libfakejvm.so (仅 -DMC_OHOS_BUILD_TESTS=ON)
```

### 4.2 预编译 (Docker 交叉编译，跑一次就行)

| 构建脚本 | 源码 | 产物 | 部署位置 |
|----------|------|------|---------|
| `docker/build_jdk17_ohos.sh` | OpenJDK 17u (Docker 内克隆) | ~35 `.so`（带 `17` 后缀）+ `jdk17-ohos-data.zip` | **不进 HAP**：`.so` 同步到 `prebuilt/jdk/17/natives/`，`data.zip` 上传 GitHub Release 运行时下载 |
| `docker/build_jdk21_ohos.sh` | OpenJDK 21u (Docker 内克隆) | 同上，带 `21` 后缀 | 同上。⚠️ **仅研究产物、未上线**：ArkTS 已 policy lock 到 17（详见 `Constants.SUPPORTED_JDK_VERSION` / `JdkManager.listVersions`），JDK 21 上线待办见 `docs/ROADMAP.md` P2-NEW |
| `docker/build_lwjgl_ohos.sh` | LWJGL 3.3.3 (Docker 内克隆) | 4 `.so` + 10 `.jar` | `prebuilt/lwjgl3/` → `scripts/sync_prebuilt.sh` → `entry/libs/arm64-v8a/` + `rawfile/lwjgl/` |
| `docker/shims/cxxabi_shim.cpp` | 即时编译 | `libcxxabi_shim.so` | `entry/libs/arm64-v8a/`（多 JDK 版本共用） |

`prebuilt/` 目录是所有预编译产物的 **Single Source of Truth**，`scripts/sync_prebuilt.sh` 负责从这里同步到 `entry/libs/arm64-v8a/` 和 `entry/src/main/resources/rawfile/`（详见 `@prebuilt/README.md`）。

### 4.3 Java 层打包

| 源码 | 操作 | 产物 | 部署位置 |
|------|------|------|---------|
| `JavaApp/src/com/amcl/launcher/*.java` (4 个) | hvigor `buildAmclLauncher` task → `scripts/build-amcl-launcher.mjs` → `javac + jar` | `amcl-launcher.jar` | `entry/src/main/resources/rawfile/amcl-launcher.jar` |
| `prebuilt/lwjgl3/ohos-glfw/.../{GLFW,CallbackBridge}.java` | `prebuilt/lwjgl3/ohos-glfw/build.sh` | 打进 `lwjgl-glfw.jar` | `prebuilt/lwjgl3/jars/lwjgl-glfw.jar` → sync |
| `third_party/reference/java-objc-bridge/` | 已编译好 | `stub-objc-bridge.jar` | `rawfile/stub-objc-bridge.jar` |

> ✅ 2026-04-19 起，`JavaApp/` 的编译已经在 hvigor 构建图里（`entry/hvigorfile.ts`
> 的 `buildAmclLauncher` task，挂在 `default@BuildJS` 和 `default@PackageHap` 之间），
> 增量检查：jar 比所有源文件都新就跳过。DevEco Run / `hvigorw` / CI 三端一致。

---

## 五、完整文件清单与作用

### 5.1 ArkTS 层 (`entry/src/main/ets/`)

| 文件 | 作用 |
|------|------|
| `pages/Index.ets` | 首页（版本选择 + 启动 + Tabs） |
| `pages/McGamePage.ets` | MC 游戏页面（XComponent + 触摸覆盖层 + 虚拟按键） |
| `pages/VersionSettingsPage.ets` | 单版本设置（JDK 版本、Xmx、隔离开关） |
| `pages/LayoutSettingsPage.ets` | 虚拟按键布局编辑器 |
| `pages/DevToolsPage.ets` | 开发者工具 |
| `pages/VulkanPage.ets` / `RenderPage.ets` | 早期渲染测试页面 |
| `pages/tabs/` | 首页 Tabs 子页面 |
| `services/LaunchProfileBuilder.ets` | 解析 version.json + 用户设置 → `LaunchProfile`（C 层通过 NAPI 接收） |
| `services/VersionParser.ets` | version.json 解析器（libraries / arguments / mainClass） |
| `services/VersionJsonMerger.ets` | PCL2 合并 JSON 方案：把 Forge/Fabric JSON 和原版合并成自包含版本 |
| `services/DownloadTask.ets` | 流式下载引擎（manifest / client / libraries / assets / modloader） |
| `services/McVersionService.ets` | MC 版本清单查询（正式版/快照/旧版筛选） |
| `services/JdkManager.ets` | 多版本 JDK 运行时管理（下载 / 解压 / 解压校验 / 版本选择） |
| `services/RuntimeDeployer.ets` | 首次启动部署（rawfile → filesDir） |
| `services/LayoutStore.ets` | 按键布局持久化 |
| `services/PreferenceManager.ets` | 全局偏好（JDK 默认版本、Xmx 等） |
| `services/modloader/ForgeService.ets` | Forge installer 一键安装（下 installer → `fork_run_java` → 合并 JSON） |
| `services/modloader/ForgeInstallerUtils.ets` / `MavenUtils.ets` | Forge / Maven 工具 |
| `services/modloader/FabricService.ets` | Fabric 一键安装 |
| `services/modloader/ModLoaderManager.ets` / `ModLoaderTypes.ets` | 模组加载器统一入口 |
| `components/GameControls.ets` | 虚拟按键控件 |
| `components/LayoutEditor.ets` | 布局编辑器 |
| `components/TestPanel.ets` | 测试面板（DevTools 专用） |
| `utils/FileUtils.ets` | 文件工具 |
| `utils/McDownloader.ets` | MC 游戏文件下载（DownloadTask 的底层工具） |
| `common/Constants.ets` | 常量定义 |
| `entryability/EntryAbility.ets` | Ability 生命周期 |
| `gameability/` | MC 游戏进程 Ability（进入全屏后用） |

### 5.2 Native C/C++ 层 (`entry/src/main/cpp/`)

#### napi/ — ArkTS ↔ C++ 桥接

| 文件 | 作用 | 编译进 |
|------|------|--------|
| `napi_entry.cpp` | 注册所有 NAPI 导出函数，ArkTS 调用 C++ 的唯一入口 | libentry.so |

#### platform/ — OHOS 平台适配

| 文件 | 作用 | 编译进 |
|------|------|--------|
| `xcomponent.cpp/.h` | XComponent 生命周期 (创建/销毁渲染面) | libentry.so |
| `touch_input.cpp/.h` | 触摸事件从 ArkTS 转发到 C 层 | libentry.so |
| `gpu_info.cpp/.h` | 查询 GPU 厂商/型号/驱动版本 | libentry.so |
| `mg_config.cpp/.h` | MobileGlues 运行时配置管理 | libentry.so |

#### jvm/ — JVM 嵌入 + ELF loader

| 文件 | 作用 | 编译进 |
|------|------|--------|
| `elf_loader.cpp/.h` | 自定义 ELF loader：匿名 mmap + pread + mprotect + TLSDESC resolver。绕过 HarmonyOS MAP_XPM 代码签名限制，从 `filesDir/jdk/<ver>/` 加载 JDK .so | libentry.so |
| `jvm_launcher.cpp/.h` | 用 `elf_dlopen` 加载 libjvm.so，注册 sigchain handler，调用 `JNI_CreateJavaVM` 启动 JVM（主进程单例） | libentry.so |
| `mc_launcher.cpp/.h` | Phase 0-5 阶段化启动：VALIDATE → INIT_JVM → REGISTER_NATIVES → SET_PROPERTIES → REDIRECT_IO → LAUNCH_MAIN，经 `AmclLauncher` 调 MC `mainClass.main()` | libentry.so |
| `fork_run_java.cpp/.h` | `fork()` 子进程 + `JLI_Launch` 跑 Forge installer 等独立 JVM 场景（避免污染主进程 classpath） | libentry.so |
| `jni_registry.cpp/.h` | 统一 `RegisterNatives`：把 GLFW/OpenAL 的 36 个 JNI 方法一次性注册给 MC 的 ClassLoader | libentry.so |
| `jvm_common_args.cpp/.h` | **SSOT（Single Source of Truth）**：主进程 `jvm_launcher.cpp` + Forge installer 子进程 `fork_run_java.cpp` + ArkTS `LaunchProfileBuilder` 三方共享的 "OHOS 兼容性修复" JVM 参数清单（`--add-opens` / `--add-reads=org.lwjgl.glfw=jdk.unsupported` / `-Djava.security.egd=file:/dev/./urandom` / 基础 `-XX:` 等）。NAPI `getCommonJvmArgs()` 暴露给 ArkTS 做 version.json 去重。修改参数只改这一个文件。 | libentry.so |
| `jni.h` / `jni_md.h` | JNI 头文件（从 OpenJDK 17 提取） | 编译时使用 |
| `hello_world_class.h` | 验证 JVM 可用的最小 Java class 字节码 | 编译时使用 |

> **NAPI 启动协议**：ArkTS 层 `LaunchProfileBuilder` 构造一个 `LaunchProfile` 对象（定义在 `@entry/src/main/ets/services/LaunchProfileBuilder.ets`），通过 NAPI `mcLaunchWithProfileV2(filesDir, gameDir, jdkVersion, xmxMb, mainClass, classpath, mcArgs[], extraJvmArgs[])` **散参**传到 C 层（**不是** struct 传递）。这样保持 NAPI 签名稳定、避免 ArkTS 对象到 C struct 的字段映射脆弱性。历史上曾存在 `jvm/launch_profile.h` 定义 C struct，但它从未被真正消费，已在 2026-04-19 清理。

#### glfw/ — GLFW 兼容层

| 文件 | 作用 | 编译进 |
|------|------|--------|
| `glfw_compat.cpp` | 核心 API: init/createWindow/pollEvents/swapBuffers | libglfw.so |
| `glfw_egl.cpp` | EGL 上下文创建/销毁/makeCurrent | libglfw.so |
| `glfw_callbacks.cpp` | GLFW 回调注册 + 窗口/监视器/输入 stub 函数 | libglfw.so |
| `glfw_jni.cpp` | JNI bridge (Java CallbackBridge ↔ C 输入事件) | libglfw.so |
| `input_bridge_ohos.c` | 输入事件 ring buffer + JNI 回调注册 | libglfw.so |
| `glfw_compat.h` | GLFW 公共头文件 (GLFW API 声明) | 编译时使用 |
| `glfw_internal.h` | GLFW 内部头文件 (模块间共享的结构体和函数) | 编译时使用 |
| `glfw_mg.version` | 符号导出脚本 (控制 libglfw.so 导出 glfw*/gl*/egl* 符号) | 链接时使用 |

#### mobileglues/ — MobileGlues GL→GLES 翻译层

| 文件 | 作用 | 编译进 |
|------|------|--------|
| `MobileGlues-cpp/gl/*.cpp` | 桌面 OpenGL 函数翻译为 GLES 等价调用 | libglfw.so |
| `MobileGlues-cpp/egl/*.cpp` | EGL 加载和管理 | libglfw.so |
| `MobileGlues-cpp/gles/*.cpp` | GLES 函数指针加载 | libglfw.so |
| `MobileGlues-cpp/glx/*.cpp` | GLX (X11 OpenGL) 兼容层 | libglfw.so |
| `MobileGlues-cpp/config/*.cpp` | MobileGlues 配置 (GPU 特定优化) | libglfw.so |
| `MobileGlues-cpp/gl/glsl/*.cpp` | GLSL 着色器翻译 (桌面 GLSL → ESSL) | libglfw.so |
| `MobileGlues-cpp/3rdparty/glslang/` | 着色器编译器 (submodule) | libglfw.so |
| `MobileGlues-cpp/3rdparty/SPIRV-Cross/` | SPIR-V 到 ESSL 翻译器 (submodule) | libglfw.so |
| `MobileGlues-cpp/3rdparty/glm/` | 数学库 (submodule) | 头文件 |
| `MobileGlues-cpp/3rdparty/xxhash/` | 快速哈希 (submodule) | 头文件 |

#### openal/ — OpenAL Soft + OHAudio 后端

| 文件 | 作用 | 编译进 |
|------|------|--------|
| `ohaudio.cpp` / `ohaudio.h` | OpenAL Soft 的 BackendFactory 实现，封装 HarmonyOS `libohaudio.so` 的渲染回调 | libopenal.so |
| `CMakeLists.txt` | 编译配置（`HAVE_OHAUDIO=1` 注入 OpenAL Soft target） | 编译时使用 |
| `openal-soft/` (submodule) | OpenAL Soft 上游源码（gitignored，`setup_deps.sh` 拉取） | libopenal.so |
| `patches/` | 对 OpenAL Soft 源码的小补丁（`BackendList` 注册 OHAudio） | 编译时使用 |

#### stubs/ — 兼容性空实现

| 文件 | 作用 | 编译进 |
|------|------|--------|
| `jcocoa_stub.c` | java-objc-bridge JNI 空实现 | libjcocoa.so |
| `objc_stub.c` | ObjC Runtime JNA 空实现 | libobjc.A.so |

> 早期的 `openal_stub.c`（OpenAL 空实现）已下线，被 `openal/` 目录下的 OpenAL Soft + OHAudio 方案替代。

#### tests/ — 验证测试

| 文件 | 作用 | 编译进 |
|------|------|--------|
| `fake_jvm.cpp` | 测试用假 JVM | libfakejvm.so |
| `jvm_test.cpp` | JVM 启动测试 | libentry.so |
| `jit_test.cpp` | JIT 编译测试 (验证 mmap/mprotect) | libentry.so |
| `glfw_test.cpp` | GLFW 兼容层测试 | libentry.so |
| `gl4_test.cpp` | OpenGL 4.x 功能测试 | libentry.so |
| `mg_test.cpp` | MobileGlues 翻译层测试 | libentry.so |
| `lwjgl_test.cpp` | LWJGL 加载测试 | libentry.so |
| `tests.h` | 测试公共头文件 | 编译时使用 |

### 5.3 预编译 JDK 产物（`prebuilt/jdk/<ver>/natives/`）

**注意：这批 .so 不在 `entry/libs/arm64-v8a/`**，由 `docker/build_jdk<ver>_ohos.sh` 交叉编译产出，同步到 `prebuilt/jdk/<ver>/natives/`，打包成 `jdk<ver>-ohos-data.zip` 上传 GitHub Release，运行时解压到 `filesDir/jdk/<ver>/lib/`，由自定义 ELF loader 加载。

文件名规范：**每个 .so 名带版本后缀**（`libjvm17.so` / `libjvm21.so`），支持多 JDK 版本同时共存（见 `JDK_ADAPTATION_GUIDE.md` 第八节）。下表以 JDK 17 为例：

#### JVM 核心 (来自 OpenJDK 17 交叉编译)

| .so | 大小 | 职责 |
|-----|------|------|
| `libjvm17.so` | ~23 MB | **JVM 核心** — 字节码解释 + C2 JIT 编译器 + GC + 线程调度 |
| `libjava17.so` | ~200 KB | JDK 核心类 native 实现 (IO/反射/进程) |
| `libjli17.so` | ~70 KB | JVM 启动引导（`JLI_Launch`） |
| `libjsig17.so` | ~13 KB | 信号处理链 |
| `libverify17.so` | ~60 KB | 字节码验证器 |

#### JDK 子系统 (来自 OpenJDK 17 交叉编译)

| .so | 职责 | MC 是否需要 |
|-----|------|------------|
| `libnet17.so` / `libnio17.so` / `libextnet17.so` | 网络 (TCP/UDP/NIO) | ✅ 联机/下载资源 |
| `libzip17.so` | ZIP 读写 | ✅ 读取 .jar 和资源包 |
| `libjimage17.so` | JDK 模块镜像 | ✅ JDK 9+ 模块系统 |
| `libfontmanager17.so` / `libfreetype17.so` | 字体渲染 | ✅ 游戏内文字 |
| `libawt17.so` / `libawt_headless17.so` | AWT 图形工具包 | ⚠️ Forge 部分 mod 需要（配 Cacio） |
| `libjavajpeg17.so` / `liblcms17.so` / `libmlib_image17.so` | 图像处理 | ⚠️ 纹理/截图 |
| `libj2pkcs1117.so` / `libj2gss17.so` / `libjaas17.so` | 安全/加密 | ⚠️ MC 正版验证 |
| `libjsound17.so` | Java Sound API | ❌ MC 用 OpenAL 不用 JavaSound |
| `libjdwp17.so` / `libdt_socket17.so` | 调试器 | ❌ 仅调试用 |
| `libattach17.so` / `libinstrument17.so` / `libmanagement*17.so` | JVM 管理/监控 | ❌ 生产可移除 |
| `libsaproc17.so` | Serviceability Agent | ❌ 仅诊断用 |
| `librmi17.so` / `libsctp17.so` / `libprefs17.so` | RMI/SCTP/Preferences | ❌ MC 不使用 |

#### 数据文件（随 `jdk<ver>-ohos-data.zip` 下发）

| 文件 | 大小 | 职责 |
|-----|------|------|
| `lib/modules` | ~128 MB | JDK 9+ 模块镜像（boot class path，启动必需） |
| `lib/jvm.cfg` | <1 KB | `-server KNOWN` 配置 |
| `conf/` | - | Java 安全策略、字体配置 |
| `release` | <1 KB | 版本信息 |

### 5.3.1 预编译主 HAP 伴随 .so（`entry/libs/arm64-v8a/`）

这是真正随 HAP 打包的预编译产物，目前只包含 LWJGL 系列 + JNA + cxxabi_shim：

| .so | 大小 | 职责 | 来自 |
|-----|------|------|------|
| `liblwjgl.so` | ~460 KB | LWJGL JNI 核心 + libffi | `prebuilt/lwjgl3/natives/` |
| `liblwjgl_opengl.so` | ~337 KB | OpenGL JNI 绑定 | `prebuilt/lwjgl3/natives/` |
| `liblwjgl_stb.so` | ~317 KB | STB 图像/字体/音频加载 | `prebuilt/lwjgl3/natives/` |
| `liblwjgl_tinyfd.so` | ~80 KB | TinyFileDialogs stub | `prebuilt/lwjgl3/natives/` |
| `libjnidispatch.so` | ~160 KB | JNA — Forge 等某些库用 | `prebuilt/jna/` |
| `libcxxabi_shim.so` | ~8 KB | C++ ABI 兼容层（多 JDK 版本共用） | `docker/shims/cxxabi_shim.cpp` 即时编 |

### 5.4 Java 层 jar 文件 (`rawfile/lwjgl/`)

| jar | 职责 |
|-----|------|
| `lwjgl.jar` | LWJGL 核心 (内存管理/库加载/回调框架) |
| `lwjgl-glfw.jar` | **GLFW Java 绑定 (已修改版)**，MC 通过它创建窗口和处理输入 |
| `lwjgl-opengl.jar` | OpenGL Java 绑定，MC 通过它调用所有 GL 函数 |
| `lwjgl-openal.jar` | OpenAL Java 绑定 (音频) |
| `lwjgl-stb.jar` | STB 图像/字体 Java 绑定 |
| `lwjgl-tinyfd.jar` | TinyFileDialogs Java 绑定 |
| `lwjgl-jemalloc.jar` | jemalloc 内存分配器 Java 绑定 |
| `lwjgl-vulkan.jar` | Vulkan Java 绑定 (MC 1.20.4 暂不使用) |
| `lwjgl-opengles.jar` | OpenGL ES Java 绑定 |
| `lwjgl-egl.jar` | EGL Java 绑定 |
| `stub-objc-bridge.jar` | java-objc-bridge 空实现 (所有方法返回 null) |

### 5.5 Java 启动层（`entry/src/main/resources/rawfile/`）

| 文件 | 作用 |
|------|------|
| `amcl-launcher.jar` | `AmclLauncher` + `AmclClassLoader` + `LaunchConfig` + `ForgeHelper` 四类打包产物，由 hvigor `buildAmclLauncher` task（即 `scripts/build-amcl-launcher.mjs` 跨平台 Node 脚本）从 `JavaApp/src/` 编译。详见 §3.5 |
| `stub-objc-bridge.jar` | java-objc-bridge 空实现 |
| `lwjgl/*.jar` | 见 5.4 节 |
| `cacio/cacio-shared.jar` / `cacio-tta.jar` | Caciocavallo AWT 后端（Forge 模组 GUI 需要，条件启用） |

### 5.6 项目根目录

| 文件/目录 | 作用 |
|-----------|------|
| `setup_deps.sh` | 一键克隆 MobileGlues + LWJGL + OpenAL Soft 源码 |
| `deps.versions` | 依赖版本定义 |
| `build-hap.ps1` | Windows 一键构建入口（**已基本由 hvigor 接管**：本脚本仅在调用 `hvigorw clean assembleHap` 前先单独跑一次 `scripts/build-amcl-launcher.mjs` 预热增量缓存 + 早期 surface javac 错误，比 hvigor DAG 执行到 `buildAmclLauncher` 更早。DevEco Run ▶️ / `hvigorw` 命令行 / CI 都会自动触发 `buildAmclLauncher`，无需先跑此脚本） |
| `docker/` | Docker 构建环境（Dockerfile + `build_jdk17_ohos.sh`（上线运行时） / `build_jdk21_ohos.sh`（⚠️ 仅研究、未上线） / `build_lwjgl_ohos.sh` + `patches/` + `shims/`） |
| `prebuilt/` | 所有预编译产物的 Single Source of Truth（`jdk/17`：上线运行时 / `jdk/21`：⚠️ 研究产物、未上线 / `lwjgl3` / `lwjgl2` / `jna` / `stubs` / `forge`） |
| `scripts/sync_prebuilt.sh` | 从 `prebuilt/` 同步到 `entry/libs/arm64-v8a/` 和 `rawfile/` |
| `JavaApp/` | Java 中间启动层源码（见 3.5 节） |
| `third_party/` | 第三方依赖参考文件 |
| `docs/` | 项目文档 |

---

## 六、数据流图

### 6.1 一帧画面的渲染过程

```
MC Java 代码: GL11.glClear(GL_COLOR_BUFFER_BIT)
    │
    ▼
LWJGL Java 层 (lwjgl-opengl.jar): 调用 native 方法
    │
    │ JNI
    ▼
liblwjgl_opengl.so: 找到 glClear 的函数指针 (之前通过 dlsym 从 libglfw.so 获取)
    │
    │ C 函数调用
    ▼
libglfw.so 内的 MobileGlues: glClear() 实现
    │
    │ 翻译为 GLES 调用
    ▼
libGLESv3.so (系统 GPU 驱动): 真正清除帧缓冲
    │
    │ GPU 命令
    ▼
GPU 硬件: 执行渲染

... (更多 GL 调用: glDrawArrays, glBindTexture, ...)

MC Java 代码: GLFW.glfwSwapBuffers(window)
    │
    ▼
LWJGL Java 层 → JNI → liblwjgl.so → dlsym("glfwSwapBuffers")
    │
    ▼
libglfw.so: glfwSwapBuffers() → eglSwapBuffers()
    │
    ▼
EGL + GPU: 将渲染结果显示到屏幕
```

### 6.2 一次触摸事件的传递过程

```
用户手指触摸屏幕
    │
    ▼
HarmonyOS 系统: 产生触摸事件
    │
    ▼
ArkTS 覆盖层 (Column onTouch): 拦截触摸坐标和类型
    │
    │ NAPI 调用
    ▼
touch_input.cpp: 将触摸数据写入 ring buffer
    │
    ▼
input_bridge_ohos.c: ring buffer 中存储事件
    │
    ▼
MC 主循环调用 GLFW.glfwPollEvents()
    │
    │ LWJGL Java → JNI → libglfw.so
    ▼
glfw_compat.cpp: glfwPollEvents() 从 ring buffer 读取所有待处理事件
    │
    │ 调用注册的回调
    ▼
MC 的鼠标/触摸回调: 处理输入，控制视角/移动/点击
```

### 6.3 JVM 启动过程（Phase 0-5）

```
用户点击 "启动游戏"
    │
    ▼
ArkTS: McGamePage → LaunchProfileBuilder.build()
       解析 version.json → 构建 classpath / mcArgs / extraJvmArgs
       → NAPI: mcLaunchWithProfile(LaunchProfile)
    │
    ▼
mc_launcher.cpp (主线程):
    Phase 0 VALIDATE        检查 .minecraft/versions/<ver>/<ver>.jar 存在
    Phase 1 INIT_JVM        调 jvm_launcher.cpp jvmInit()
    │                         ├── detectNativeLibDir() 扫 /proc/self/maps
    │                         ├── setenv JAVA_HOME / SUN_BOOT_LIBRARY_PATH
    │                         ├── 清所有 signal handler，SIGSEGV 暂设 SIG_IGN
    │                         ├── elf_set_search_path(filesDir/jdk/<ver>/lib)
    │                         ├── elf_dlopen(libcxxabi_shim.so) — HAP 内
    │                         ├── elf_dlopen(filesDir/jdk/<ver>/lib/server/libjvm17.so)
    │                         ├── JNI_CreateJavaVM(vm_args: -XX:+UseSerialGC,
    │                         │                    -XX:+DisablePrimordialThreadGuardPages,
    │                         │                    --add-opens / --add-exports / ...,
    │                         │                    -Djava.system.class.loader=AmclClassLoader)
    │                         └── add_special_signal_handler(SIGSEGV, s_chainAction)
    │                            — sigchain 把 SEGV 转发给 HotSpot handler，
    │                            — PC 变了说明是 safepoint polling，返回 true 拦下 DFX
    ▼
mc_launcher.cpp (后台线程，Phase 2-5):
    Phase 2 REGISTER_NATIVES  jni_registry.cpp 把 36 个 GLFW/OpenAL native
                              方法批量注册给 MC 的 ClassLoader
    Phase 3 SET_PROPERTIES   System.setProperty(os.name=Linux, os.version=5.10,
                              user.home/dir=gameDir, amcl.mc.dir=..., ...)
    Phase 4 REDIRECT_IO      stdout/stderr → gameDir/mc_output.log
                              启动 logTailThread 定时 grep 关键行到 hilog
    Phase 5 LAUNCH_MAIN      反射调 com.amcl.launcher.AmclLauncher.main(JSON)
    │
    ▼
Java 层（AmclLauncher.main，在 JVM 内运行）:
    1. 解析 JSON LaunchConfig（mainClass / classpath / mcArgs / gameDir / isForge）
    2. 拿系统 ClassLoader（应该是 AmclClassLoader）
    3. 对每个 MC jar 调 loader.addJar(path)
    4. Forge: ForgeHelper 写 config/fml.toml、splash.properties
    5. 设 Thread.contextClassLoader = 系统 CL
    6. Class.forName(mainClass, true, 系统 CL).getMethod("main", String[].class)
         .invoke(null, (Object) mcArgs)
    │
    ▼
MC 主类开始运行: 创建窗口 → 加载资源 → 渲染 → 主循环
```

### 6.4 Forge installer 子进程（fork_run_java）

ForgeService 一键安装 Forge 时，走子进程独立 JVM 路线，避免污染主进程 classpath：

```
ArkTS: ForgeService.install()
    → 下载 forge-<ver>-installer.jar
    → 解压 → 预下载 maven libraries（到临时目录）
    → NAPI: forkRunJava(installer.jar, "com.bangbang93.ForgeInstaller", args)
    │
    ▼
fork_run_java.cpp:
    1. fork() 创建子进程
    2. 子进程：重定向 stdout/stderr → installer.log
    3. 子进程：chdir 到 gameDir
    4. 子进程：elf_set_search_path + setenv LD_LIBRARY_PATH
       （serverLib 必须在前面，否则 JLI 会触发 re-exec 失败）
    5. 子进程：elf_dlopen(libjli.so) → elf_dlsym("JLI_Launch")
    6. 子进程：JLI_Launch(argc, argv, ...) — 等价于命令行 java -jar
    7. 父进程：waitpid 等子进程结束，返回退出码
    │
    ▼
ArkTS: 读 installer.log 校验结果
    → VersionJsonMerger 合并 Forge JSON + 原版 JSON（PCL2 方式）
    → 删 inheritsFrom / jar 字段 → 写入自包含的 <ver>.json
```

---

## 七、为什么需要这么多层？

```
问: 为什么不能直接运行 MC？
答: MC 是 Java 程序 → OHOS 没有 JVM → 需要自己编译 OpenJDK for OHOS

问: 有了 JVM 为什么还要搞 ELF loader？
答: HarmonyOS 代码签名（MAP_XPM）拒绝运行时加载的 .so。但 JDK 体积大要做按需下载、
    多版本并存，无法全塞进 HAP。用自己实现的 ELF loader 从 filesDir 加载就绕过了。

问: 有了 JVM 为什么还要搞 AmclLauncher？
答: JNI_CreateJavaVM 的 classpath 一旦设定无法修改；MC 启动前需要做 Forge 预处理
    （fml.toml / splash）、动态 addURL 跳过 JPMS 模块限制、统一的 ClassLoader
    让 Fabric/Forge 的 TransformingClassLoader 正确继承。所有这些都放 Java 中间层。

问: 为什么 Forge installer 要用子进程？
答: Forge installer 会调 System.exit()、加载大量奇怪的 classpath，
    主进程 JVM 只能 CreateJavaVM 一次，被污染后就再启动不了 MC。
    fork() 隔离出一个完全独立的 JVM 来跑它。

问: 为什么 LWJGL 有 Java 和 Native 两层？
答: Java 不能直接调 C 函数，必须通过 JNI 桥接。Java 层给 MC 用，Native 层和系统交互

问: 为什么需要 MobileGlues？
答: MC 用桌面 OpenGL (glBegin/glEnd/...) → OHOS 只有 OpenGL ES → 需要翻译层

问: 为什么需要 GLFW 兼容层？
答: MC 通过 GLFW 创建窗口和处理输入 → OHOS 没有 GLFW → 用 XComponent + EGL 模拟

问: 为什么需要 Cacio？
答: Forge 部分 mod 会触发 java.awt 类初始化，HarmonyOS 没有 X11/真 AWT，
    Cacio 提供纯 Java 的 AWT 后端实现。仅在 filesDir/cacio/ 存在时启用。

问: 为什么音频从 stub 变成 OpenAL Soft？
答: stub 能让 MC 启动但没有声音。现在完整编译了 OpenAL Soft 并写了 OHAudio 后端，
    MC 的 3D 音效、方块碰撞音效等能真正播放出来。
```
