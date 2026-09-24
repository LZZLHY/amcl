# OpenJDK 17 for HarmonyOS NEXT (aarch64)

## 状态

✅ **生产运行时**。当前 release: `v17.0.13-ohos-5`（commit `jdk-17.0.13+11`）。

License: **GPL-2.0 with Classpath Exception**（OpenJDK 上游许可证不变）。

## 完整产物

`jdk17-ohos-full-v4.zip`（109 MB）**不再入主仓 git**。由 `mc-ohos-resources` Release
通道下发：https://github.com/LZZLHY/mc-ohos-resources/releases/tag/v17.0.13-ohos-5

> ⚠️ **v5（2026-08-29）相对 v4 只替换了 `lib/libnet.so`**（IPv6 沙箱回落 patch，
> `patches/0010-ipv6-supported-sandbox-fallback.patch`），包内其余 71 个文件逐字节相同、
> 条目清单（72 条，与 v4 一样不含目录条目）完全一致。
> **旧 tag `v17.0.13-ohos-4` 及其附件保持在线不动** —— 已发布的 tag 只增不改不删，
> 否则旧 HAP 里硬编码的 size/sha256 会对不上，那批用户新装/重装会 100% 失败且不自愈。


运行时由 `launch/src/main/ets/JdkManager.ets` 下载到 `filesDir/jdk/17/` 后通过
自定义 ELF loader 加载（绕过 HarmonyOS MAP_XPM 签名验证）。

zip 内容：
- `lib/`：~35 个 .so（libjvm17.so 等，带 17 后缀以支持多版本并存）
- `lib/modules`：约 95 MB 的 JDK 数据
- `lib/libfontconfig.so.1`：随 JDK 一起下发的字体后端（不在 HAP `entry/libs/`）
- `conf/`：JDK 配置
- `release`：安装标记 + 版本元数据

## SoT (Single Source of Truth)

`deps.lock` 的 `[mc-ohos-resources]` 段是版本元数据 SoT：

```ini
[mc-ohos-resources]
repo      = LZZLHY/mc-ohos-resources
tag       = v17.0.13-ohos-5
asset     = jdk17-ohos-full-v5.zip
sizeBytes = 113762513
sha256    = 0e26b0dece38156838456cfb12058d863aa9856cdd8fd648f06f9bc5e91f8ecd
```

ArkTS 端三处必须一致（CI 自动校验）：
- `commons/src/main/ets/common/Constants.ets`：`SUPPORTED_RELEASE_TAG / ASSET`
- `launch/src/main/ets/JdkManager.ets`：`JDK_VERSIONS['17'].{tag,dataFile,sha256,sizeBytes}`

## 编译方式（仅 release engineer 需要）

使用 Docker 容器交叉编译，详见 `docker/build_jdk17_ohos.sh`：

```bash
cd docker
docker build -t openjdk-ohos-builder -f Dockerfile.openjdk-ohos .

docker run --rm \
  -v "/path/to/ohos/sysroot:/ohos-sysroot:ro" \
  -v "/path/to/output:/output" \
  -v "$(pwd)/..:/workspace:ro" \
  openjdk-ohos-builder /build/build_jdk17_ohos.sh
```

详细背景见 `docs/adaptation/JDK_ADAPTATION_GUIDE.md` + `docs/guides/openjdk_ohos_build_guide.md`。

## Patches & Shims

主仓只保留 patches / shims，不存源码 / 不存编译产物：

```
prebuilt/jdk/17/
├── README.md       # 本文件
├── patches/        # 标准 git diff，按 series 顺序应用到 openjdk/jdk17u
│   ├── series
│   ├── 0001-musl-dlvsym-dlinfo.patch
│   ├── 0002-java-home-env.patch
│   ├── 0003-dll-dir-env.patch
│   ├── 0004-musl-utmpx.patch
│   ├── 0005-signals-posix-abort-if-unrecognized.patch
│   ├── 0006-aarch64-elf-safepoint-fallback.patch
│   ├── 0007-safepoint-mechanism-mem-prot-read.patch
│   └── 0008-libjli-skip-re-exec.patch
└── shims/          # JDK 17 specific source override
    └── icache_patch.hpp    # ARM64 __clear_cache 汇编替代
```

> **2026-05-15 P6.5 评审更正**：series 现有 **8 个 patch**。早期文档曾写 4 个 +
> 4 个"已废弃"是认知误差 —— 0005/0006/0007/0008 这 4 个 OHOS 运行时关键 patch
> 当时已经直接打在 `ohos-debug` 容器的 `/build/jdk17u` 工作树里、但**没有归档为
> 标准 .patch**。本次评审通过 `git diff` 提取入仓 + 全部在 fresh tree 上重新
> 验证 `git apply --check OK`。

跨依赖共享的 ABI shim 在另一处 — `prebuilt/stubs/src/`：
- `cxxabi_shim.cpp` + `eh_stubs.c`：JDK / LWJGL / OpenAL 都链接它编出来的 `libcxxabi_shim.so`

### 升级到 JDK 17 新 LTS patch

1. `git ls-remote --tags https://github.com/openjdk/jdk17u.git` 看新 tag
2. 改 `deps.lock` 的 `[openjdk].tag` + `commit`
3. `bash docker/build_jdk17_ohos.sh`（会自动 `apply_patches.sh --patch-dir prebuilt/jdk/17/patches/`）
4. 验证产物：`du -sh /output/`、`file /output/lib/server/libjvm.so`、加载 + JNI 创建 + 运行 MC
5. 上传新 zip 到 `mc-ohos-resources` Release，tag 命名 `v<jdk-version>-ohos-<rev>`
6. 更新 `deps.lock` 的 `[mc-ohos-resources]`（tag/asset/sha256/sizeBytes）+ ArkTS 三处
7. CI 校验三处一致 → PR

## HotSpot Patches 简要

| Patch | 作用 |
|---|---|
| `0001-musl-dlvsym-dlinfo.patch` | musl libc 不支持 dlvsym 重定义；跳过 dlinfo() |
| `0002-java-home-env.patch` | OHOS 沙箱 JAVA_HOME 优先用 env var |
| `0003-dll-dir-env.patch` | dll_dir 同理，优先 SUN_BOOT_LIBRARY_PATH |
| `0004-musl-utmpx.patch` | 跳过不支持的 setutxent/getutxent/endutxent |
| `0005-signals-posix-abort-if-unrecognized.patch` | javaSignalHandler 不在未识别信号上 abort |
| `0006-aarch64-elf-safepoint-fallback.patch` | aarch64 SEGV fallback for ELF-loaded code |
| `0007-safepoint-mechanism-mem-prot-read.patch` | polling page 用 MEM_PROT_READ（配合 0006）|
| `0008-libjli-skip-re-exec.patch` | libjli 跳过 re-exec 路径（`RequiresSetenv → JNI_FALSE`）|
| `shims/icache_patch.hpp` | ARM64 `__clear_cache` 汇编替换（compiler-rt vs glibc 差异，仅作 reference，当前未启用 source override；详见 shims/README.md） |
