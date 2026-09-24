# OpenJDK 25 for HarmonyOS NEXT (aarch64)

> **状态（2026-05-30）：三版本上线，"⚠️ 实验性"**
>
> - MC 26.1 "Tiny Takeover"（2026-03-24）是首个要求 **Java 25** 的版本，且启用全新
>   **YY.D.H** 版本号格式（`26.1` / `26.1.1` / `26.2`）。
> - `JdkManager.autoSelectVersion(mcVersion)` 三段式纪元路由：
>   YEARLY（26.1+）→ 25；CLASSIC ≥ 1.20.5 → 21；CLASSIC ≤ 1.20.4 → 17。
>   纪元判定见 `entry/src/main/ets/utils/McVersionUtils.detectMcEra`。
> - GitHub Release：`LZZLHY/mc-ohos-resources` tag `v25.0.4-ohos-2` 资产 `jdk25-ohos-full-v2.zip`（sha256 `d8e31df5d199a9b3…`，118872200 B）。
> - 与 21 同构架构：完整 zip 含 `lib/server/libjvm.so` + `lib/modules` + `conf/` + `release`，
>   通过自定义 ELF loader 加载（绕过 HarmonyOS MAP_XPM 签名验证）。
> - 真 headless 模式（`-Djava.awt.headless=true` + OpenJDK 自带 `sun.awt.HeadlessToolkit`），
>   无 patch 0009 / 无 libawt_xawt.so stub（与 21 v6 一致）。
>
> 完整评估见 `docs/adaptation/JDK25_ADAPTATION_ASSESSMENT.md`。

## Patches

8 个 OHOS 真 patch（git diff series 格式，全部用 `__MUSL__` 宏门控只对 aarch64-linux-musl
target 生效；buildjdk 走 host glibc 时这些 patch 都是 no-op）：

| # | 文件 | 影响 |
|---|------|------|
| 0001 | musl-dlvsym-dlinfo | 删除 jdk25u 自带的 static dlvsym shim（现代 OHOS musl + host glibc 都自带 dlvsym，shim 反而冲突）；dlinfo() 在 `MUSL_LIBC && !__GLIBC__` 时走 no-op fallback |
| 0002 | java-home-env | OHOS 沙箱无法路径推断 JAVA_HOME，优先读环境变量（gate `__MUSL__`） |
| 0003 | dll-dir-env | 同 0002，针对 SUN_BOOT_LIBRARY_PATH |
| 0004 | musl-utmpx | musl 没有 `setutxent`/`getutxent`/`endutxent` |
| 0005 | signals-posix-abort-if-unrecognized | OHOS 设备会向进程发未识别信号，不要 abort（gate `__MUSL__`）；参数名 `context`（同 21） |
| 0006 | aarch64-elf-safepoint-fallback | ELF loader 加载的代码不在 CodeCache 里，SafePoint polling SEGV 时手动 disarm polling page 让 CPU 重试（gate `__MUSL__`） |
| 0007 | safepoint-mechanism-mem-prot-read | polling page 用 MEM_PROT_READ 而不是 MEM_PROT_NONE，配合 0006（gate `__MUSL__`） |
| 0008 | libjli-skip-re-exec | RequiresSetenv 始终返回 JNI_FALSE，跳过 re-exec 死锁路径（gate `__MUSL__`） |

详细 patch 描述见 `patches/series` 注释。

### 与 JDK 21 patch 的源码差异（已在生成器锚点处理）

| patch | jdk21u → jdk25u 差异 |
|---|---|
| 0002 / 0003 | jdk25u 删除了 `set_java_home` / `set_dll_dir` 前的 `// Get rid of /lib.` / `// Get rid of /{client\|server\|hotspot}.` 行内注释，锚点改用完整 pslash block |
| 0004 | `bootsec` 赋值加了 `(int)` 强制转换（`bootsec = (int)ent->ut_tv.tv_sec`），正则锚点已对应 |
| 0001/0005/0006/0007/0008 | 与 21 完全同构（锚点 verbatim 命中） |

## ⚠️ Patches 不包含 stub .so（重要）

仅靠 `patches/` + 跑 `make images` 重建 JDK，**最终 zip 会缺一个关键 .so**：

| 文件 | 来源 | 为什么 patch 不带 |
|---|---|---|
| `lib/libcxxabi_shim.so` | `prebuilt/stubs/src/cxxabi_shim.cpp` + `eh_stubs.c` 编 | OHOS musl 缺 Itanium C++ ABI 符号；不是 jdk25u 源码改动 |

这个 stub 由 **`docker/scripts/pack_jdk_full.sh`** 在打 zip 时现编现塞，
配合 `docker/build_jdk25_ohos.sh` 完整链路才能产生最终的 `jdk25-ohos-full.zip`。

**正确重建步骤**：
```bash
docker exec ohos-debug bash /build/build_jdk25_ohos.sh
```
此脚本依次：① 应用 8 个 patch、② configure + make images、③ 重链 libjli、
④ 跑 `pack_jdk_full.sh`（这一步加 cxxabi_shim stub）。

## 编译方式

```bash
docker run -it --name ohos-debug \
  -v <ohos_sysroot_cache>:/ohos-sysroot:ro \
  -v $(pwd)/docker/output:/output \
  -v $(pwd)/prebuilt/jdk/25:/jdk25-spec:ro \
  -v $(pwd)/prebuilt/stubs:/stubs-src:ro \
  -v $(pwd)/docker/scripts:/build/scripts:ro \
  -v $(pwd)/docker/stubs:/build/stubs:ro \
  openjdk-ohos-builder
docker exec ohos-debug bash /build/build_jdk25_ohos.sh
```

输出：`/output/jdk25-ohos-full.zip`。需要 boot JDK 25（脚本自动选 temurin-25-jdk；
容器内 `apt-get install -y temurin-25-jdk`，Adoptium 源已配置）。

## 与 JDK 17 / 21 的关系

- **共存**：`filesDir/jdk/17/`、`filesDir/jdk/21/`、`filesDir/jdk/25/` 互不影响。
- **运行时切换**：Index.launchMC 把 `selectedJdkVersion` / `autoSelectVersion(mcVersion)` 的结果作为 `jdkVersion` Want 参数；GameAbility / McGamePage 据此挑路径。
- **Forge/NeoForge installer JDK 按纪元自动匹配**（方案 B，1000338 起）：安装器 fork 子进程走 `jvmInit`（含 sigchain），21/25 不再 init 期 SIGSEGV，installer JDK 与运行时同套纪元判定（`commons.requiredJdkMajorForMc` + `pickInstalledJdkMajor`），不再固定 17。见 `ForgelikeInstaller` / `ForgeService.buildForgeProfile`。

## 上游 base

- repo: `https://github.com/openjdk/jdk25u.git`
- tag: `jdk-25.0.4+3`
- commit: `e8f9ebe5e`（grafted，locked in `deps.lock` 的 `[openjdk-25]` 节）

## Patch 生成

如需改动（升级到 jdk-25.0.x 新 tag、加新 patch），跑：

```bash
docker exec ohos-debug bash /build/port_jdk25_patches.sh
# 输出到 /tmp/jdk25-patches-new/，再手动 cp 到 prebuilt/jdk/25/patches/ 并更新 series
```
