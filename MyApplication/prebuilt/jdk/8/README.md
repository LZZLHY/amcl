# OpenJDK 8u452 for HarmonyOS NEXT — 老版本 MC 的 Java 8 运行时

## 状态

✅ **可用（2026-06-12 真机跑通）**。`jdk8-ohos-full.zip` 在 OHOS aarch64/musl 交叉编译成功，
MC **1.16.1** vanilla 用 JDK 8 + LWJGL 3.2.2 套 + gl4es **真机成功出图、入游戏**。
目标：为 MC **1.13–1.16.5**（旧整合包 / 老版 Forge 需 Java 8）提供运行时。

经典布局（classic layout，非模块化）：`jre/lib/aarch64/server/libjvm.so` + `jre/lib/rt.jar`。
`jvm_launcher.cpp` 已识别该布局并做经典布局专属适配（见下）。

License: **GPLv2 + Classpath Exception**（OpenJDK 上游）。

## 这是什么 / 为什么自建

- 老版本 MC（1.13–1.16.5）的固定管线渲染需 gl4es，而这些版本依赖 LWJGL 3.1–3.2 且原生支持 Java 8；
  现代 JDK（17/21/25）跑老 Forge/老 mod 常因字节码/反射差异出问题，故需要一套 **Java 8 运行时**。
- **鸿蒙没有现成的 OHOS aarch64 OpenJDK 8**：OHOS≠Android（musl 非 bionic、自定义 ELF loader 绕签名、
  工具链/加载器不同），现成的 Linux/Android JDK 不能直接跑。故 AMCL 用 OHOS NDK sysroot + clang-15
  交叉编译 jdk8u，并打 OHOS 适配补丁。

## 上游 pin

jdk8u（OpenJDK 8u452，老森林：`hotspot/` `jdk/` `langtools/` …）。boot JDK = 系统 JDK 8。

## 发布物（GitHub Release）

- 仓库：`LZZLHY/mc-ohos-resources`
- **当前**：tag `v8u452-ohos-4`，资产 `jdk8-ohos-full-v4.zip`
  - size = `39555296` B，sha256 = `02c2cedb3539682de3df3d7870b855bfefaac1f4cfe53951cfe90b0dea3d3a63`
  - Gitee 分卷：`jdk8-ohos-full-v4.zip.part01of02` / `part02of02`，各 `19777648` B（2 等分）
  - 校验和 / 字节数已回填 `launch/src/main/ets/JdkManager.ets` 的 `JDK_VERSIONS['8']` 与 `deps.lock [mc-ohos-resources-8]`。
- 历史（**旧 tag 与附件一律保持在线不动**：旧版 HAP 把 size/sha256 硬编码，原地换资产会让那批用户装不上且不自愈）：
  - `v8u452-ohos-3`（2026-06-13，补回 ManifestEntryVerifier 单参构造器，size 39570295 / sha256 478fa9a5a0dfe80bbfcd8d980b2978d4f878d69a38b17f57703daf9a3bff8f6f）。
  - `v8u452-ohos-2`（2026-06-12，修好 4 类 clang UB，size 39689841 / sha256 a1c2632974630c86482648bfbe615855913e6b172dea561df50118aa7e794640）。
  - `v8u452-ohos-1`（2026-06-11，未修 clang UB，会崩；勿用）。
- v3 相对 v2：仅在 rt.jar 内补回 `sun.security.util.ManifestEntryVerifier(Manifest)` 单参构造器
  （patch 0003），让 Forge modlauncher 4.x/8.x（MC 1.13–1.16.5）SecureJarHandler 不再 NoSuchMethodError；
  libjvm.so 与 v2 完全一致。
- **v4 相对 v3**：只替换 `jre/lib/aarch64/libnet.so`（patch 0010，IPv6 沙箱回落），
  120672 → 121048 B。包内其余 108 个文件逐字节相同，条目清单（126 条 = 109 文件 + 17 目录）一致。
  **不打 patch 从容器重编出的 `libnet.so` 与 v3 出货件逐字节相同**（`2a302234…`，120672 B）
  ⇒ JDK 8 的构建位级可复现，本包与 v3 的唯一差异就是该 patch。导出符号 93 → 93 逐个相同，
  `DT_NEEDED` 一致。

> ⚠️ 改 libjvm.so 后必须：重打包 zip → 重算 sha256/size → 同步 JdkManager → 传新 tag 的 Release。

## 补丁（`patches/`，经 `series` 顺序应用）

应用方式：`bash docker/apply_patches.sh --patch-dir prebuilt/jdk/8/patches --target /build/jdk8u`

- **0001-ohos-musl-clang-source-fixes.patch** — musl/clang/aarch64 源码级合并补丁（7 文件）
  + OHOS 运行时 patch（`__MUSL__` 门控）：
  - `globalDefinitions_gcc.hpp` isnanf→isnan；`copy_linux_aarch64.s` prfm→prfum；
    `jvm_linux.cpp` SIGCLD；`os_linux.cpp` libc-version 兜底 + **set_java_home 优先 `JAVA_HOME` 环境变量**
    + set_dll_dir 优先 `SUN_BOOT_LIBRARY_PATH`；`os_linux_aarch64.cpp` fpu_control；`NativeThread.c`/
    `linux_close.c` __SIGRTMAX；`java_md_solinux.c` RequiresSetenv→FALSE（避免 musl re-exec 死锁）。

- **0002-ohos-clang-codegen-ub-fixes.patch** — clang 把 JDK8 老代码 UB「优化」坏的 4 类代码生成问题
  （真机 1.16.1 逐崩定位，反汇编 + aarch64-glibc/qemu 实证，非盲改）：
  1. **逻辑立即数表 UB**（`immediate_aarch64.cpp` `replicate()`）：`result <<= nbits` 当 nbits=64
     是移位≥位宽 UB；clang **-O3** 让 poison 值算坏编码 `0xFFFFFFFFFFFFFFF0`（`generate_call_stub`
     的 `andr(sp, rscratch1, -16)`）的表项 → 首条逻辑立即数指令即 `guarantee("Field too big for
     insn")` SIGABRT。改 `if(nbits<64) result<<=nbits`。
  2. **markOop 伪指针对齐 UB**（`markOop.hpp` `value()`）：markOop 是 tagged 伪指针（指针数值即
     mark word，低位编码锁态），clang 假设 `markOopDesc*`（对齐≥8）低 3 位为 0，把
     `has_locker/has_monitor/is_neutral` 常量折叠 → `ObjectSynchronizer::inflate()` 把 neutral 对象
     误当栈锁解引用 mark word → SIGSEGV（与 -O2/-O3 无关）。用空内联汇编 `__asm__("":"+r"(v))`
     launder 指针，禁止对齐假设（一次修好所有 markword 判定）。
  3. **null-this UB**（`gcc.make` 加 `-fno-delete-null-pointer-checks`）：JDK8 依赖经由可能为 NULL 的
     this 调成员函数 + 函数内部自带空指针保护（如 `Arena::destruct_contents` 的 `_first->chop()` /
     `Chunk::chop`）；clang 视 null-this 为 UB 删除保护 → `C2Compiler::initialize` 阶段 SIGSEGV。
     该旗标全局保留这类保护（Linux 内核同款）。
  4. **initLITables 懒初始化**（`immediate_aarch64.cpp`）：原 `__attribute__((constructor))` 依赖
     libjvm `.init_array`，自定义 ELF loader 不跑它 → 表为空；改 `pthread_once` 懒初始化（双保险）。

## 构建

```bash
# 1) 应用补丁
bash docker/apply_patches.sh --patch-dir prebuilt/jdk/8/patches --target /build/jdk8u
# 2) configure + 全量 image 构建（容器内）
docker exec ohos-debug bash /build/build_jdk8_ohos.sh build
#    产物：build/linux-aarch64-normal-server-release/images/j2sdk-image/
# 3) 打包（zip 根 = jre/，含 jre/lib/aarch64/server/libjvm.so + jre/lib/rt.jar）
```

构建要点（`docker/build_jdk8_ohos.sh`，jdk8u 构建系统不原生支持 clang/libc++/musl，大量在「构建系统
workaround」层）：
- **伪 gcc banner 包装器**：jdk8u configure 只认 gcc，给 `aarch64-linux-ohos-gcc/g++` 包装器在
  `--version`/`-dumpversion` 时伪造 gcc 4.9.2 banner，其余 exec ohos-clang。
- **X11/ALSA stub .so**（headful configure 需要）+ stub-headers；freetype 显式给路径（8 不 bundle）。
- **libstdc++→libc++**：包装器把 `-lstdc++`→`-lc++`，链接 `libcxxabi_shim.so`（含 musl 兼容符号
  isnanf/isinff/__xpg_strerror_r + JAWT awt_* 桩，见 `docker/jdk8_musl_compat.c`）。
- make 旗标：`USE_CLANG=true`（走 clang 分支）、`WARNINGS_ARE_ERRORS=`（关裸 -Werror）、
  `BUILDLIBSAPROC=` + `ADD_SA_BINARIES/aarch64=`（跳 SA native）、`BUILD_HEADLESS_ONLY=true`、
  `EXTRA_SOUND_JNI_LIBS=`、`HOST_*` 旗标清成干净 host 旗标（adlc 等构建期工具不被当成交叉编）。
- ⚠️ 增量重编 libjvm 时**不要装 `gcc-aarch64-linux-gnu`**：它会污染 clang 默认头搜索路径，令
  `<sys/poll.h>` 解析到 glibc 交叉头 → POLLERR 未定义编译失败。

## 字体配置（`fontconfig.properties`）— 运行时部署，非源码补丁

**问题**：本 JDK 8 构建产物 `jre/lib/` 下**既无 `fontconfig.properties` 也无 `fonts/`**
（`make images` + headless 交叉构建未生成逻辑字体映射；上游模板指向 Linux/X11 字体路径，
对 OHOS 无意义）。任何调用 AWT 字体子系统的 mod 会崩：
- 触发链：`GraphicsEnvironment.getAllFonts()` → `sun.awt.X11FontManager.createFontConfiguration`
  → `FontConfiguration.init` → `readFontConfigFile` → **`getVersion()` 因内部表为空抛 NPE**。
- 真机实例（2026-06-23）：RLCraft（MC 1.12.2）的 **Varied Commodities** 在
  `TrueTypeFont.<clinit>` 调 `getAllFonts()` → `LoaderExceptionModCrash` → 整个游戏崩。
  注意这**与内存无关**（RLCraft 仅约百 mod、内存充足）。

**修复方式（为何不走 patch）**：这是一份**数据/配置文件**，不是 jdk8u 源码补丁，故
**不进 `patches/series`**。与 `libfontconfig.so.1` 同类，采用**运行时部署**（App 启动时铺到
沙箱 JDK 目录），好处是对**已分发的 `jdk8-ohos-full.zip` 立即生效、无需重打包/重传 Release/
重下 JDK**。

- **SoT（唯一来源）**：`entry/src/main/resources/rawfile/jdk8/fontconfig.properties`
  （按 OpenJDK `fontconfig.properties` 规范：serif/sansserif/monospaced/dialog/dialoginput ×
  4 字形 → `/system/fonts` 的 HarmonyOS Sans；`awtfontpath.default=/system/fonts` 让
  `getAllFonts()` 能枚举系统字体）。
- **部署**：`launch/src/main/ets/RuntimeDeployer.ets` 的 `deployJdk8FontConfig()`，在 `deployAll`
  中调用；仅当 `<sandbox>/jdk/8/jre/lib` 存在时铺到 `jdk/8/jre/lib/fontconfig.properties`。
- **范围**：仅 JDK 8（经典布局走 `sun.awt.FontConfiguration`）。模块化 JDK 17/21/25 字体机制不同、
  不受此问题影响，**不处理**。
- **若将来重建并重传 JDK8 zip**：可选地把该文件一并 bake 进 `jre/lib/`（在 `pack_jdk_full.sh`
  JDK_VERSION=8 分支复制 rawfile 那份），使 zip 自包含；但因运行时部署已覆盖，重建非必需。

> ⚠️ 修改字体映射只需改上述 rawfile 那一份 SoT + 重新打 HAP，**无需动 JDK8 zip / libjvm.so**。

## 运行时适配（`entry/src/main/cpp/jvm/jvm_launcher.cpp`，仅经典布局 JDK 8）

- **`java.home` 指向 `jdk/8/jre`**（不是 jdk 根）：经典布局 `os::set_boot_path` 按 `<java.home>/lib/
  rt.jar` 等定位引导类；指错会 `NoClassDefFoundError: java/lang/Object`。模块化（17/21/25）= jdk 根。
- **`-Dos.name=Linux`**：OHOS `uname -s` = `HarmonyOS`，JDK8 NIO `DefaultFileSystemProvider.create()`
  仅认 Linux/SunOS/OS X/AIX，否则抛 `AssertionError: Platform not recognized`。JDK9+ 的 provider 是
  编译期固定的，故 17/21/25 无此问题。
- **完整分层编译（C1+C2）**：1000150 曾因 C2 init 崩临时加 `-XX:TieredStopAtLevel=1`（C1-only），
  但该崩溃真根因是上面的 null-this UB（`Arena::destruct_contents`→`_first->chop()`），被
  `-fno-delete-null-pointer-checks` 修好后 C2 即可正常初始化；1000151 已移除该限制，恢复默认
  分层编译（峰值性能更好）。仍保留 jvm_common_args 对 `CompletableFuture.*` 的 C2 exclude
  （另一已知 C2 误编译）。
- **JNI 版本 `JNI_VERSION_1_8`**、剔除 JDK9+ 的 `--add-opens/--add-exports/--add-reads`（1000149）。

## 已知限制 / 后续

- C2（server JIT）已启用并真机验证可用（null-this UB 修复后）；仅对 `CompletableFuture.*` 做 C2
  exclude（已知误编译）。若后续发现其他热点方法被 C2 误编译，可按同法 `CompileCommand=exclude` 规避。
- auto 路由仍不主动选 JDK 8（仅手动选择，给老 Forge/整合包用）；≤1.16.5 走 gl4es + LWJGL 3.2.2 套。
- signal/safepoint 适配沿用 JDK8 旧全局 polling-page 机制，已随真机出图间接验证；如遇运行期偶发崩溃
  再针对性排查。
