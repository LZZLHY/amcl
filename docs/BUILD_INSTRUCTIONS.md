# OpenJDK for HarmonyOS 编译指南

> ⚠️ **状态说明（2026-05-08）**
>
> - **JDK 17 编译流程**：✅ 上线运行时的产物来源，请按 §3 走。
> - **JDK 21 编译流程（§4）**：⚠️ **仅供研究**，编译产物不会被 ArkTS 加载（已 policy lock 到 17）。如需上线 JDK 21，先看 `docs/ROADMAP.md` P2-NEW 的上线步骤。

本文档说明如何编译 OpenJDK（17 上线 / 21 研究中）for HarmonyOS NEXT。

## 快速开始

### 1. 准备 Docker 环境

```bash
# 构建 Docker 镜像
cd docker
docker build -f Dockerfile.openjdk-ohos -t openjdk-ohos-builder .
```

### 2. 准备 OHOS NDK Sysroot

从 DevEco Studio 或 OHOS SDK 中获取 sysroot，通常位于：
```
/path/to/ohos-sdk/native/sysroot
```

### 3. 编译 JDK 17

```bash
# 启动容器
docker run -it --name ohos-jdk17 \
  -v "/path/to/ohos-sdk/native/sysroot:/ohos-sysroot:ro" \
  -v "/path/to/output:/output" \
  openjdk-ohos-builder bash

# 在容器内编译
bash /build/build_jdk17_ohos.sh

# 打包（带版本后缀）
JDK_VERSION=17 bash /build/scripts/pack_jdk_split.sh
```

### 4. 编译 JDK 21（⚠️ 仅研究用，未上线）

> ArkTS 端 `Constants.SUPPORTED_JDK_VERSION = '17'`、`JdkManager.listVersions()` 仅暴露 17，**编译出的 JDK 21 产物不会被运行时加载**。
> 上线 JDK 21 需先按 `docs/ROADMAP.md` P2-NEW 完成 5 步前置（真机回归 / Forge 兼容矩阵 / SSOT 解锁 / UI / 下载源）。

```bash
# 启动容器（或复用已有容器）
docker run -it --name ohos-jdk21 \
  -v "/path/to/ohos-sdk/native/sysroot:/ohos-sysroot:ro" \
  -v "/path/to/output:/output" \
  openjdk-ohos-builder bash

# 在容器内编译
bash /build/build_jdk21_ohos.sh

# 打包（带版本后缀）
JDK_VERSION=21 bash /build/scripts/pack_jdk_split.sh
```

## 输出产物

编译完成后，`/output` 目录包含：

```
/output/
├── jdk17-libs/           # JDK 17 的 .so 文件（带版本后缀）
│   ├── libjvm17.so
│   ├── libjava17.so
│   ├── libjsig17.so
│   ├── libcxxabi_shim.so  # 共用
│   └── ...
├── jdk17-data.zip        # JDK 17 数据文件
├── jdk21-libs/           # JDK 21 的 .so 文件（带版本后缀）
│   ├── libjvm21.so
│   ├── libjava21.so
│   ├── libjsig21.so
│   └── ...
└── jdk21-data.zip        # JDK 21 数据文件
```

## 部署到项目

### 1. 复制 .so 文件

```bash
# JDK 17
cp /output/jdk17-libs/*.so entry/libs/arm64-v8a/

# JDK 21
cp /output/jdk21-libs/*.so entry/libs/arm64-v8a/

# 注意：libcxxabi_shim.so 只需复制一次（共用）
```

### 2. 上传数据文件到 GitHub Releases

```bash
# 创建 Release tag
git tag v17.0.13-ohos-1
git push origin v17.0.13-ohos-1

# 上传 jdk17-data.zip 到该 Release

git tag v21.0.5-ohos-1
git push origin v21.0.5-ohos-1

# 上传 jdk21-data.zip 到该 Release
```

### 3. 更新 JdkManager.ets

确保 `JDK_VERSIONS` 配置正确：

```typescript
'21': {
  tag: 'v21.0.5-ohos-1',
  dataFile: 'jdk21-ohos-data.zip',
  dataSizeMB: 105,
  markerFile: 'lib/modules',
  minMcVersion: '1.20.5',
  maxMcVersion: '99.99',
  available: true,  // 改为 true
},
```

## 多版本 .so 命名规范

为支持多版本 JDK 并存，.so 文件名添加版本后缀：

| 原始文件名 | JDK 17 | JDK 21 |
|-----------|--------|--------|
| libjvm.so | libjvm17.so | libjvm21.so |
| libjava.so | libjava17.so | libjava21.so |
| libjsig.so | libjsig17.so | libjsig21.so |
| libzip.so | libzip17.so | libzip21.so |
| ... | ... | ... |

**例外**：`libcxxabi_shim.so` 不加版本后缀，所有版本共用。

## 运行时加载逻辑

`jvm_launcher.cpp` 中的 `jvmInit(filesDir, jdkVersion)` 函数：

1. 根据 `jdkVersion` 参数（如 "17" 或 "21"）构建 .so 文件名
2. 优先加载带版本后缀的文件（如 `libjvm17.so`）
3. 如果不存在，回退到无后缀版本（向后兼容）

## 补丁说明

### JDK 17 补丁（patches/jdk17u/）

| 补丁 | 作用 |
|------|------|
| 0001-musl-dlvsym-dlinfo.patch | musl libc 兼容性 |
| 0002-java-home-env.patch | JAVA_HOME 环境变量 |
| 0003-dll-dir-env.patch | dll_dir 环境变量 |
| 0004-musl-utmpx.patch | musl utmpx 兼容性 |

### JDK 21 补丁（patches/jdk21u/，5 个）

在 JDK 17 的 4 个补丁之上多一个 `0005-inline-clear-cache.patch`（因为 JDK 21 的
`ICache` 结构调整后不再方便在 libentry 侧导出 `__clear_cache`，改为直接内联进
HotSpot 源码）。行号也根据 JDK 21 源码做了调整。

**注意**：我们**不**依赖 "关掉 safepoint polling" 这种危险做法（历史教训详见
`JDK_ADAPTATION_GUIDE.md` 5.4 节），sigchain handler 会把 SIGSEGV 正确转发给
HotSpot 自己处理。JDK 21 的 thread-local handshake 只是让这个过程走得更顺，不
代表可以关 polling page。

## 故障排查

### 补丁应用失败

```bash
# 重置源码
cd /build/jdk17u
git reset --hard HEAD
git clean -fdx

# 手动应用补丁查看错误
git apply --verbose /build/patches/jdk17u/0001-musl-dlvsym-dlinfo.patch
```

### 编译错误

```bash
# 查看详细日志
gmake images JOBS=1 LOG=debug
```

### .so 加载失败

检查 HAP 中是否包含所有必需的 .so 文件：

```bash
# 列出 HAP 中的 .so 文件
unzip -l app.hap | grep "\.so"
```

## 参考文档

- [JDK_ADAPTATION_GUIDE.md](JDK_ADAPTATION_GUIDE.md) — 完整适配方案文档
- [patches/README.md](patches/README.md) — 补丁说明
