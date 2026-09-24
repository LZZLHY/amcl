# JNA Native 协议槽

1.0.5 保留游戏最终 classpath 中的 JNA Java 依赖，在创建 JVM 前读取其 `com/sun/jna/Version.class` 的 `VERSION_NATIVE` 常量，选择兼容的包内 dispatch。Java 依赖不会被统一升级，JNA 自身的版本校验继续保留。

| 文件 | Native 协议 | 官方 Java 归档 | 兼容选择 |
| --- | --- | --- | --- |
| `libjnidispatch_v5.so` | 5.1.0 | JNA 4.4.0 | major 5、minor ≤ 1 |
| `libjnidispatch_v6.so` | 6.1.6 | JNA 5.13.0 | major 6、minor ≤ 1 |
| `libjnidispatch.so` | 7.0.0 | JNA 5.14.0 | major 7、minor 0 |

规则遵循上游的协议判断：major 相同，实际 minor 不小于所需 minor，patch 不参与。三个文件是不同协议的真实上游制品；不能复制同一份 SO 后改名代替，也不能仅凭 JNA Java 版本范围推测未知协议。

[manifest.json](manifest.json) 记录官方归档 URL、摘要、ZIP 条目、Native 全文摘要、运行分配节和原始 SONAME；[deps.lock](../../deps.lock) 的 `[jna-runtime]` 锁定此清单。清单固定使用 LF，以保持 Windows 与 Linux 的原始字节摘要一致。库文件保留上游 ELF 字节，v5/v6 仅更改交付文件名。

本目录和 [entry/libs/arm64-v8a](../../entry/libs/arm64-v8a) 的三份库必须逐字节一致。[sync_prebuilt.sh](../../scripts/sync_prebuilt.sh) 负责同步，Hvigor 的 JAR 同步任务不代替这一步。恢复制品时，先在仓库外下载清单指定的官方 JAR，核对摘要，再读取指定 ZIP 条目并核对 Native 摘要。

未知协议、多个候选、无法可靠读取以及 JNA 核心类的多版本覆盖，会保留具体的 deferred 原因并交回 JNA 自身处理；这不保证任意第三方原生模组均兼容 OHOS。已确认协议但对应包内库缺失时，报告 `jna_runtime_artifact_missing`。

[build-hap.ps1](../../build-hap.ps1) 在构建前后执行协议与制品检查。也可独立运行：

```powershell
node scripts/check-jna-runtime.mjs
node scripts/test-check-jna-runtime.mjs
python scripts/test-jna-runtime-contract.py
node scripts/check-jna-runtime.mjs <实际HAP路径>
```

生产读取器的宿主测试需要 C++ 和系统 zlib；Windows 使用 WSL，Linux 使用本机工具链。HAP 检查允许 SDK 剥离非运行节，但所有分配节必须与锁定输入一致。宿主测试及包内核验不等同于设备上的游戏运行验收。

工程构建、第三方范围与许可入口见 [BUILD_SNAPSHOT.md](../../docs/BUILD_SNAPSHOT.md)、[CREDITS.md](../../docs/CREDITS.md) 和 [third-party-notices](../../third-party-notices)。
