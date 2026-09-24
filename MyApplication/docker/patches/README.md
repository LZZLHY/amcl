# OpenJDK Patches — 已迁移到 `prebuilt/jdk/<ver>/patches/`

> **状态**：📦 此目录已迁出，2026-05-15 P6.5 完成。

## 新位置

```
prebuilt/jdk/17/patches/      ← jdk17u 4 个 series patch（生产）
prebuilt/jdk/21/patches/      ← jdk21u 8 个 series patch（生产，与 17 同构，2026-05-19 v6 上线）
prebuilt/jdk/17/shims/        ← icache_patch.hpp（jdk17 specific source override）
prebuilt/stubs/src/           ← cxxabi_shim.cpp + eh_stubs.c（跨依赖共享 ABI shim 源码）
```

## 为什么迁移

- 单一来源（SoT）原则：依赖配方按依赖归类，`prebuilt/<dep>/patches/` 模式统一
- `docker/` 目录回归"构建机器"职责（Dockerfile + 编排脚本 + host-only stub headers），
  不再混杂依赖源码 patch
- patches 改动不再需要 rebuild Docker image —— 改由 mount 注入

详见 `docs/guides/third-party-deps-restructure-plan.md` §3.6。

## 调用方式

```bash
# 推荐（mount-based）
docker run --rm \
  -v "$(pwd)/prebuilt/jdk/17:/jdk-spec:ro" \
  -v "$(pwd)/prebuilt/stubs/src:/stubs-src:ro" \
  -v "/path/to/ohos/sysroot:/ohos-sysroot:ro" \
  -v "/path/to/output:/output" \
  openjdk-ohos-builder /build/build_jdk17_ohos.sh
```

JDK 21（实验产物）：

```bash
docker run --rm \
  -v "$(pwd)/prebuilt/jdk/21:/jdk21-spec:ro" \
  -v "$(pwd)/prebuilt/stubs/src:/stubs-src:ro" \
  ... \
  openjdk-ohos-builder /build/build_jdk21_ohos.sh
```

build 脚本仍兼容旧 layout（`/build/patches/jdk17u` + `/build/shims`），如果 mount 缺失
会 fallback 到旧位置 + 打 WARNING。新 PR 一律按推荐方式调用。

## 历史 README（patch 清单 / 适配指南）

迁移到 `prebuilt/jdk/17/README.md` 和 `prebuilt/jdk/21/README.md`。
