# OpenJDK 21 for HarmonyOS NEXT (aarch64)

> **状态（2026-05-19 v6）：双版本上线，"⚠️ 实验性"**
>
> - 用户在 SettingsTab 中可手动切换 17 / 21；MC ≥ 1.20.5 时 JdkManager.autoSelectVersion 会推荐 21。
> - GitHub Release：`LZZLHY/mc-ohos-resources` tag `v21.0.5-ohos-7` 资产 `jdk21-ohos-full-v7.zip`（sha256 `21556d0d4fc5eea0…`，114267146 B）。
> - 与 17 同构架构：完整 zip 含 `lib/server/libjvm.so` + `lib/modules` + `conf/` + `release`，
>   通过自定义 ELF loader 加载（绕过 HarmonyOS MAP_XPM 签名验证）。
>
> **v6 (2026-05-19) 关键变化**：放弃 Cacio AWT 路径，改走真 headless 模式
> （`-Djava.awt.headless=true` + OpenJDK 自带 `sun.awt.HeadlessToolkit`）。
> 移除 patch 0009 (ohos-platform-graphics-info) 和 `libawt_xawt.so` 空 stub。
> 详见 `docs/archive/jdk21-awt-headless-journey-202605.md` §5（第一阶段方案）。

## Patches

8 个 OHOS 真 patch（git diff series 格式，全部用 `__MUSL__` 宏门控只对 aarch64-linux-musl
target 生效；buildjdk 走 host glibc 时这些 patch 都是 no-op）：

| # | 文件 | 影响 |
|---|------|------|
| 0001 | musl-dlvsym-dlinfo | 删除 JDK 21u 自带的 static dlvsym shim（现代 OHOS musl + host glibc 都自带 dlvsym，shim 反而冲突）；dlinfo() 在 `MUSL_LIBC && !__GLIBC__` 时走 no-op fallback |
| 0002 | java-home-env | OHOS 沙箱无法路径推断 JAVA_HOME，优先读环境变量（gate `__MUSL__`） |
| 0003 | dll-dir-env | 同 0002，针对 SUN_BOOT_LIBRARY_PATH |
| 0004 | musl-utmpx | musl 没有 `setutxent`/`getutxent`/`endutxent` |
| 0005 | signals-posix-abort-if-unrecognized | OHOS 设备会向进程发未识别信号，不要 abort（gate `__MUSL__`）；JDK 21 参数名从 17 的 `ucVoid` 改成 `context` |
| 0006 | aarch64-elf-safepoint-fallback | ELF loader 加载的代码不在 CodeCache 里，SafePoint polling SEGV 时手动 disarm polling page 让 CPU 重试（gate `__MUSL__`） |
| 0007 | safepoint-mechanism-mem-prot-read | polling page 用 MEM_PROT_READ 而不是 MEM_PROT_NONE，配合 0006（gate `__MUSL__`） |
| 0008 | libjli-skip-re-exec | RequiresSetenv 始终返回 JNI_FALSE，跳过 re-exec 死锁路径（gate `__MUSL__`） |

详细 patch 描述见 `patches/series` 注释。

> **历史**：v3-v5 期间存在 patch 0009 (ohos-platform-graphics-info)，试图修改
> `java.desktop/.../sun/awt/PlatformGraphicsInfo.java` 让 OHOS 走自带的
> OhosHeadlessGE/Toolkit。v6 已彻底删除 — `-Djava.awt.headless=true` 在 jvm_launcher.cpp /
> fork_run_java.cpp 起作用，OpenJDK 自带的 `sun.awt.HeadlessToolkit` 已经够用。

## ⚠️ Patches 不包含 stub .so（重要）

仅靠 `patches/` + 跑 `make images` 重建 JDK，**最终 zip 会缺一个关键 .so**：

| 文件 | 来源 | 为什么 patch 不带 |
|---|---|---|
| `lib/libcxxabi_shim.so` | `prebuilt/stubs/src/cxxabi_shim.cpp` + `eh_stubs.c` 编 | OHOS musl 缺 Itanium C++ ABI 符号；不是 jdk21u 源码改动 |

> v6 起不再需要 `lib/libawt_xawt.so` 空 stub（真 headless 模式不依赖它，详见上方 v6 说明）。

这个 stub 由 **`docker/scripts/pack_jdk_full.sh`** 在打 zip 时现编现塞，
配合 `docker/build_jdk21_ohos.sh` 完整链路才能产生最终的 `jdk21-ohos-full.zip`。

**正确重建步骤**：
```bash
docker exec ohos-debug bash /build/build_jdk21_ohos.sh
```
此脚本依次：① 应用 8 个 patch、② configure + make images、③ 重链 libjli、
④ 跑 `pack_jdk_full.sh`（这一步加 cxxabi_shim stub）。

**错误重建步骤（会出问题）**：
```bash
# ❌ 跳过 pack 脚本只跑 make
docker exec ohos-debug bash -c "cd /build/jdk21u && make images"
# 出来的 build/.../images/jdk/lib/ 里没有 libcxxabi_shim.so
# 最后 ELF loader 加载 libjvm.so 时会因为缺 NEEDED libcxxabi_shim 而失败。
```

## 编译方式

JDK 21 上线后唯一受支持的编译路径：

```bash
docker run -it --name ohos-debug \
  -v <ohos_sysroot_cache>:/ohos-sysroot:ro \
  -v $(pwd)/docker/output:/output \
  -v $(pwd)/prebuilt/jdk/21:/jdk21-spec:ro \
  -v $(pwd)/prebuilt/stubs:/stubs-src:ro \
  -v $(pwd)/docker/scripts:/build/scripts:ro \
  -v $(pwd)/docker/stubs:/build/stubs:ro \
  openjdk-ohos-builder
docker exec ohos-debug bash /build/build_jdk21_ohos.sh
```

输出：`/output/jdk21-ohos-full.zip`。需要 boot JDK 21（脚本自动 apt install
`temurin-21-jdk` from Adoptium repo；JDK 17 作为 boot JDK 会被 jdk21u configure 拒绝）。

## 与 JDK 17 的关系

- **共存**：`filesDir/jdk/17/` 和 `filesDir/jdk/21/` 互不影响。
- **运行时切换**：Index.launchMC 把 `selectedJdkVersion` / `autoSelectVersion(mcVersion)` 的结果作为 `jdkVersion` Want 参数；GameAbility / McGamePage 据此挑路径。
- **Forge/NeoForge installer JDK 按纪元自动匹配**（方案 B，1000338 起）：安装器 fork 子进程走
  `jvmInit`（含 sigchain），21/25 不再 init 期 SIGSEGV，故 installer JDK 与运行时同套纪元判定
  （`commons.requiredJdkMajorForMc` + `pickInstalledJdkMajor`），不再固定 17。见
  `ForgelikeInstaller` / `ForgeService.buildForgeProfile`。

## 上游 base

- repo: `https://github.com/openjdk/jdk21u.git`
- tag: `jdk-21.0.5+11`
- commit: `dfcd8d2ee` (locked in `deps.lock` 的 `[openjdk-21]` 节)

## Patch 生成

如需改动（升级到 jdk-21.0.x 新 tag、加新 patch），跑：

```bash
docker exec ohos-debug bash /build/port_jdk21_patches.sh
# 输出到 /tmp/jdk21-patches-new/，再手动 cp 到 prebuilt/jdk/21/patches/ 并更新 series
```
