# 公开文档索引

首次接触工程建议先看构建说明，再按架构和依赖索引定位源码。

| 文档 | 用途 |
|---|---|
| [BUILD_SNAPSHOT.md](BUILD_SNAPSHOT.md) | 工具链基线、克隆和依赖准备、DevEco/Hvigor 构建、结果检查、常见错误与第三方重建范围 |
| [public-reproduction-audit.md](public-reproduction-audit.md) | 2026-09-24 实际构建结果、HAP 哈希、Git 导出校验与尚未解决的复现边界 |
| [architecture.md](architecture.md) | 应用模块、游戏进程、Native/JVM 运行链路和产品配置 |
| [CREDITS.md](CREDITS.md) | 第三方组件来源、适配补丁、配方及许可证入口 |
| [../SOURCE_SNAPSHOT.json](../SOURCE_SNAPSHOT.json) | 同步来源、工作区状态和文件身份 |
| [../gate0-evidence.lock](../gate0-evidence.lock)、[testing/gate0-raw-relative-evidence.md](testing/gate0-raw-relative-evidence.md) | 默认 Native 构建所需的脱敏输入能力记录；原批准与未闭合缺口均保留 |
| [../LICENSE](../LICENSE)、[../NOTICE](../NOTICE) | AMCL 自有源码许可和第三方边界 |
| [../third-party-notices/README.md](../third-party-notices/README.md) | 已附上游许可正文及其来源/哈希清单 |

依赖版本以 [../deps.lock](../deps.lock)、Git 子模块指针和对应来源清单为准；产品定义以 [../config/products.json](../config/products.json) 为准；具体编译行为以 Hvigor、CMake 与构建脚本为准。

本目录不包含原始设备日志，仅包含构建所需的脱敏输入能力记录；其原始与公开文档身份分别记录，原批准状态、日期、风险接受事实和未闭合缺口不因导出而改变，也不构成新验收。其他内部诊断、历史施工记录和发布签名流程未复制。源码注释中可能保留历史文档名称，这些名称不是公开构建步骤。公开构建应从上表中的入口开始，不依赖未迁移的内部资料。
