# prebuilt/jdk/17/shims/ — JDK 17 Specific Source Overrides

## 内容

| 文件 | 替换的 JDK 源文件 | 说明 |
|---|---|---|
| `icache_patch.hpp` | `src/hotspot/os_cpu/linux_aarch64/icache_linux_aarch64.hpp` | ARM64 `__clear_cache` 汇编替代（musl libc 不提供该符号）|

License: **GPL-2.0 with Classpath Exception**（OpenJDK 上游许可证，遵循 hotspot 文件头声明）。

## 历史

`icache_patch.hpp` 来自 2024 年早期版本 `prebuilt/jdk/17/` 的 patch 设计 ——
当时 JDK 17 build 直接 `cp` 此文件覆盖 `icache_linux_aarch64.hpp` 来注入 ARM64
内联缓存清理。**目前实际生产构建未启用**（4 个 series patch 已经覆盖了 musl
缺失符号的所有路径，详见 `prebuilt/jdk/17/README.md`）。

JDK 21 已经迁到了 `0005-inline-clear-cache.patch`（标准 git diff），不再用 source override。

## 是否仍需保留？

**保留作研究档案**：

- 如未来某个 JDK 17 LTS patch release 引入了新的 musl `__clear_cache` 失败路径，
  可以考虑切回 source override 模式；
- 该文件是已知可用的 ARM64 inline-asm icache flush 实现，保留作 reference；
- 体积 1.7 KB，对主仓无影响。

如果要重新启用：在 `docker/build_jdk17_ohos.sh` Step 4（apply_patches 之后）加：

```bash
cp "$SHIMS_DIR/icache_patch.hpp" "$WORK_DIR/jdk17u/src/hotspot/os_cpu/linux_aarch64/icache_linux_aarch64.hpp"
```

`SHIMS_DIR` 在 build_jdk17_ohos.sh 顶部已经设置好（指向 `/jdk-spec/shims` 或 legacy `/build/shims`）。
