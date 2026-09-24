# prebuilt/stubs/src/ — 跨依赖共享的 C++ ABI shim 源码

## 内容

| 文件 | 说明 |
|---|---|
| `cxxabi_shim.cpp` | inline asm 写的 Itanium C++ ABI 符号 shim（vtable / typeinfo / 异常处理 stub）|
| `eh_stubs.c` | 异常处理 stub（提供 `__gxx_personality_v0`, `operator new/delete` 等）|

License: **MIT**（我们写的代码）。

## 用途

这两个源文件编出 `libcxxabi_shim.so`（约 14 KB），由以下产物在链接期 `-lcxxabi_shim`：

- **JDK 17 / 21**：`docker/build_jdk17_ohos.sh` Step 5 + Post-1，`rebuild_libjli.sh`
- **LWJGL natives**：`docker/build_lwjgl_ohos.sh`（如有需要）
- **OpenAL Soft**：`entry/src/main/cpp/openal/CMakeLists.txt`
- **libcurl 静态链**：`docker/build_curl_ohos.sh`（如有需要）

成品 `libcxxabi_shim.so` 在 `prebuilt/stubs/`，由 `sync_prebuilt.sh` 同步到 `entry/libs/arm64-v8a/`。

## 历史位置

2026-05-15 P6.5 之前在 `docker/shims/cxxabi_shim.cpp` + `docker/shims/eh_stubs.c`。
迁移到 `prebuilt/stubs/src/` 是为了：

1. 单一来源（SoT）—— 跨依赖共享的 shim 不归任何特定依赖管
2. `docker/` 目录回归"构建机器"职责
3. 跟 `prebuilt/stubs/<产物>.so` 物理上相邻，便于看出"源 → 产物"的映射

build 脚本通过 `-v "$(pwd)/prebuilt/stubs/src:/stubs-src:ro"` mount 进 Docker 容器；
保留 `/build/shims` 作为 legacy fallback，详见 `docs/guides/third-party-deps-restructure-plan.md` §3.6。

## 编译命令

```bash
ohos-clang     -c -fPIC -o eh_stubs.o    eh_stubs.c
ohos-clang++ -shared -fPIC -fvisibility=hidden -fno-exceptions -fno-rtti \
             -o libcxxabi_shim.so cxxabi_shim.cpp eh_stubs.o \
             -fuse-ld=lld -Wl,-soname,libcxxabi_shim.so \
             -nostdlib++ -nodefaultlibs -lc
```

详见 `docker/scripts/incremental_rebuild.sh` 或 `docker/build_jdk17_ohos.sh` 的 `[Post-1]` 段。
