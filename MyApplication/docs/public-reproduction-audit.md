# 公开快照构建核验（2026-09-24）

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

- 路径：`entry/build/sideload/outputs/sideload/entry-sideload-unsigned.hap`。
- 大小：`76,922,244` 字节。
- SHA-256：`9f82f9344ccb609e99b60fc707dc80fafe73d6d708b81166767a263b3b87d4d7`。
- `pack.info`：`com.amcl.launcher`，`versionName=1.0.4`，`versionCode=1000671`。
- 最终构建命令：`hvigorw assembleHap --mode module -p product=sideload -p buildMode=release --no-daemon`。

该验证包没有替换 GitHub 上已发布的包。[v1.0.4 正式资产](https://github.com/LZZLHY/amcl/releases/tag/v1.0.4) 为 `amcl-v1.0.4-unsigned.hap`，大小 `76,922,276` 字节，SHA-256 为 `59fce3c9a7631a7ecb86513cdf8485284652ee9f32959b5627f68dd529f21b54`。

两份 HAP 的 ZIP 项目名称完全一致；解压后不同的是三个本地重编 Native 库及 `amcl-launcher.jar`，其余项目相同。尚未逐项归因这些字节差异，因此本次证明的是源码可构建及产品/依赖契约成立，不是与发布资产逐字节相同。

## 保留的验证边界

1. **全部 Native 从源码重建尚未闭环。** 独立目录编译 MobileGL 成功，但其 stripped/unstripped SHA-256 与锁定输入不同；普通 HAP 使用随仓且通过校验的 dist。其它 Native 配方也未在本轮逐项重建验收。
2. **JDK 源码锁与 VMA 重建仍有限制。** `deps.lock [openjdk17].commit` 为 `PENDING`；VMA 差异已作为可审阅补丁保存，未宣称该库的全流程重编验收已经完成。普通 HAP 准备不需要编译设备 JDK。
3. **没有新增真机结论。** 本轮没有安装 HAP 或运行 Minecraft，没有验证完整设备/加载器/光影矩阵，也没有执行生产签名或商店提交。SDK 的既存 API/异常处理告警仍需按各产品的最低 API 验证。
4. **许可附件有明确范围。** [附件清单](../third-party-notices/manifest.json) 覆盖所列源码位置，不代表已完成所有历史 Native、JAR、SDK 和外部分发运行时的许可审查。

本轮之前曾用旧 1.0.3 快照构建 `default/debug`；该结果是历史准备检查，当前复现说明以上述 1.0.4 `sideload/release` 结果为准。
