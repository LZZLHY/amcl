# 公开快照构建核验

## 1.0.7 独立公开检出核验（2026-11-14）

本节仅记录公开源码的复建资格。下方 1.0.4 的历史实测保留原始身份，不能作为本版的验证依据。

- 实际构建公开提交：`79106ba8be75f4cb7277abbd18429e7ba7cb8c30`。
- 对应主工程来源：`1e9890d8d7eb4db1b43e5faaec0fcbbf018d2fb6`；来源清单和依赖输入见 [SOURCE_SNAPSHOT.json](../SOURCE_SNAPSHOT.json) 及 [DEPENDENCY_INPUTS.json](../DEPENDENCY_INPUTS.json)。
- 版本 `1.0.7 / 1000911`，产品 `sideload`，模式 `release`，产物 `unsigned`。
- 在独立公开克隆中准备依赖，完成公开 OpenAL 检查器修复后切到上述精确提交；第一次 HAP 构建前工作树洁净。未复制维护者的签名材料或旧 HAP 构建输出。
- 2026-11-14 17:45:37 至 17:48:07（Asia/Shanghai），按 [BUILD_SNAPSHOT.md](BUILD_SNAPSHOT.md) 生成本机无签名配置，执行 `ohpm install --all` 和 `hvigorw assembleHap --mode module -p product=sideload -p buildMode=release --no-daemon`；结果为 **112 个任务全部执行、0 个 up-to-date，BUILD SUCCESSFUL**。

| 检查 | 本次结果 |
|---|---|
| 公开源码与依赖身份 | 精确公开提交和来源快照核对通过；Windows Git 操作显式启用 `core.longpaths` |
| LWJGL 新鲜重建 | 16 个 JAR 全部从公开输入恢复，逐文件 SHA-256 与锁定输入一致 |
| TinyFD 后处理 | Java 布尔接口回填先完成 ZIP 改写，最后写 Native 指纹；新鲜获取和增量准备采用相同顺序 |
| OpenAL 源码 | 钉版 HEAD 上应用实际补丁序列，再逐文件核对完整内容；5 项真实 Git 正反例通过 |
| 源码导出 | 22 项实际 Git 回归通过 |
| HAP 内部身份 | 产品、版本、Native provider、SDL 和 LWJGL 包内检查通过 |

公开复建 HAP 位于 `entry/build/sideload/outputs/sideload/entry-sideload-unsigned.hap`，大小 **122,906,020 字节**，SHA-256 为 `a83c6621ad40c99affc95bd0110fba0707c28c64529819c7a5b357090d4542ae`。

维护者通过完整正式构建门禁保留的 unsigned 发布原件大小为 **122,905,956 字节**，SHA-256 为 `4cc219cd47937e8f882fd2792733f31053ff2b75725fede864dbac271517bf4d`。两者身份分别记录：本节证明公开源码可构建和包内契约通过，**没有证明两个 HAP 逐字节相同，也不授予公开复建包真机或生产签名资格**。

构建后生成了产品配置、两份 zstd JNI 库、音频/CPU agent JAR 和侧载签名工具附件；“构建前洁净”不等于“构建后没有生成文件”。本轮继续使用已锁定的部分 Native 制品，没有完成所有第三方 Native 的源码重建，也没有将已登记的依赖限制自动改为已解决。设备 JDK 正式包、签名测试包与公开 unsigned 包各自保留独立的资格和验收记录。

## 历史核验：1.0.4（2026-09-24）

公开工程已按 [BUILD_SNAPSHOT.md](BUILD_SNAPSHOT.md) 恢复公开依赖，并完成 **1.0.4 / 1000671、sideload / release / unsigned** HAP 构建。本文记录实际交付边界，不把编译通过写成真机验收或全部第三方二进制的逐字节复现。

## 快照身份与环境

- 当前同步来自干净的主工程 `main`；精确提交、三个依赖 gitlink 和 1,814 个直接输入的 SHA-256 见 [SOURCE_SNAPSHOT.json](../SOURCE_SNAPSHOT.json)，`sourceDirty=false`。
- 公开说明、许可附件和依赖准备入口由公开仓库维护；VMA 适配补丁正式纳入源仓版本控制，三个依赖工作树均为干净状态。
- Windows x64，HarmonyOS SDK `26.0.0.105`，Hvigor `6.26.4`，BiSheng clang `15.0.4`。
- JDK `21.0.3`，Python `3.13.7`；准备入口 Node `22.20.0`，Hvigor Node `24.14.1`。
- 本机配置由模板生成，移除产品的 `signingConfig` 引用，保留空签名列表；没有使用维护者签名材料。

## 已验证内容

| 项目 | 结果 |
|---|---|
| 快照完整性 | 所有直接同步输入、VMA 补丁及脱敏 Gate 0 文档校验通过 |
| Git 序列化 | 快照文本以 LF 计算身份；正式发布前从 Git 对象重新克隆核验，避免只在原目录通过 |
| 公开依赖 | 三个顶层 gitlink 与锁文件一致；必需嵌套模块、Asio 和 glslang External 已恢复 |
| OpenAL | 精确源码提交与 OHAudio 注册补丁核验通过 |
| LWJGL | 现代槽 15 个 JAR、后处理和 Native 表面检查通过；module-info ZIP 主机标记已固定 |
| SDL3 / MobileGL | 来源、锁定二进制、补丁集合、绑定及 HAP 包内身份检查通过 |
| HAP | ArkTS、Java、Native 和资源编译打包成功；产品契约核验为 sideload / release、版本 1.0.4 / 1000671 |
| 大日志回归 | 原大文本脱敏栈溢出已修复；26 项证据、14 项快捷分享、15 项日志 UX 及 Node 22/24 协议回归通过 |
| 许可附件 | 18 个已准备源码位置的 23 份上游许可正文随仓提供，逐份记录提交与 SHA-256 |

此前依赖准备中 SDL3 首次克隆误判脏目录、OpenAL 旧 sed 锚点失效、MobileGL 嵌套依赖缺项均已修复。Gate 0 原文仅由 CRLF 规范化为 Git 中已有的 LF 正文，批准条件和 G1–G7 风险接受没有变化；公开副本另行脱敏并记录自己的内容身份。

## 公开工程的复建产物

第一份产物来自独立公开工程目录：

- 路径：`entry/build/sideload/outputs/sideload/entry-sideload-unsigned.hap`。
- 大小：`76,922,244` 字节。
- SHA-256：`9f82f9344ccb609e99b60fc707dc80fafe73d6d708b81166767a263b3b87d4d7`。
- `pack.info`：`com.amcl.launcher`，`versionName=1.0.4`，`versionCode=1000671`。
- 最终构建命令：`hvigorw assembleHap --mode module -p product=sideload -p buildMode=release --no-daemon`。

随后又从 Git 对象创建全新克隆，并从公开远端更新到 `ed54c84d89ca520ea5e57f4951672e18f86da313`。
该目录没有复用旧工程的构建输出；依赖入口从公开地址恢复全部必需源码/JAR，`ohpm install --all`
后执行同一条 Hvigor 命令，结果为 **111 个任务全部执行、0 个 up-to-date，BUILD SUCCESSFUL**。
新克隆产物为 `76,927,830` 字节，SHA-256
`efbc0300a9ae1c42c78b7e3e69f14e02c182f465d58d6d9350c3a34155b7a6f8`；包内版本与
产品/MobileGL 契约再次通过，构建后 1,814 个源码输入的完整性检查仍为零失败。

这次还发现并修复了 Windows 深层 External 依赖检出时 `core.longpaths` 未传递的问题。
新入口对所有 Git 写入显式启用长路径；最终 SDK 构建仍使用文档建议的短目录。

该验证包没有替换 GitHub 上已发布的包。[v1.0.4 正式资产](https://github.com/LZZLHY/amcl/releases/tag/v1.0.4) 为 `amcl-v1.0.4-unsigned.hap`，大小 `76,922,276` 字节，SHA-256 为 `59fce3c9a7631a7ecb86513cdf8485284652ee9f32959b5627f68dd529f21b54`。

第一份复建 HAP 与正式资产的 ZIP 项目名称完全一致；解压后不同的是三个本地重编 Native 库及 `amcl-launcher.jar`，其余项目相同。尚未逐项归因各次构建的字节差异，因此本次证明的是源码可构建及产品/依赖契约成立，不是与发布资产逐字节相同。

## 保留的验证边界

1. **全部 Native 从源码重建尚未闭环。** 独立目录编译 MobileGL 成功，但其 stripped/unstripped SHA-256 与锁定输入不同；普通 HAP 使用随仓且通过校验的 dist。其它 Native 配方也未在本轮逐项重建验收。
2. **JDK 源码锁与 VMA 重建仍有限制。** `deps.lock [openjdk17].commit` 为 `PENDING`；VMA 差异已作为可审阅补丁保存，未宣称该库的全流程重编验收已经完成。普通 HAP 准备不需要编译设备 JDK。
3. **没有新增真机结论。** 本轮没有安装 HAP 或运行 Minecraft，没有验证完整设备/加载器/光影矩阵，也没有执行生产签名或商店提交。SDK 的既存 API/异常处理告警仍需按各产品的最低 API 验证。
4. **许可附件有明确范围。** [附件清单](../third-party-notices/manifest.json) 覆盖所列源码位置，不代表已完成所有历史 Native、JAR、SDK 和外部分发运行时的许可审查。

本轮之前曾用旧 1.0.3 快照构建 `default/debug`；该结果是历史准备检查，当前复现说明以上述 1.0.4 `sideload/release` 结果为准。
