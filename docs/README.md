# MC-OHOS 文档索引

> 最后整理：2026-05-05（下载系统 9 份重叠设计稿合并为单一权威文档 `guides/download-system.md`）。
> 归档的历史调试/重构文档在 `archive/`，本索引只保留当前有效的文档。

## 零、第一次接触本仓库

- **[getting-started.md](getting-started.md)** — ⭐ **7 步把 MC 跑起来**（ACL → 拉源 → 编 JDK → 打 HAP → 装设备 → 下 JDK → 下 MC → 启动）

## 一、必读

- **[ROADMAP.md](ROADMAP.md)** — ⭐ **待办 / 优化 / 新功能建议**
- **[architecture.md](architecture.md)** — 项目架构全景（调用链 / 文件清单 / 编译流水线）
- **[JDK_ADAPTATION_GUIDE.md](JDK_ADAPTATION_GUIDE.md)** — JDK 在 OHOS 上的适配要点（patch 清单、信号链、Forge 黑屏教训警示）
- **[elf_loader_notes.md](elf_loader_notes.md)** — 自定义 ELF loader 的踩坑记录（改 `elf_loader.cpp` / sigchain 前必读）
- **[BUILD_INSTRUCTIONS.md](BUILD_INSTRUCTIONS.md)** — 如何构建 HAP（含 `build-hap.ps1` 使用说明）

## 二、开发指南（guides/）

- **[guides/download-system.md](guides/download-system.md)** — ⭐ **下载系统权威总览**（架构 + 完成度 + 未完成项 + 历史索引）。**取代了 9 份重叠的 v2/v3/v4.1/v4.5/v5/v5.1/v5.2/audit/v6 设计稿**，全部归档到 `archive/download-history/`。
- **[guides/version-isolation-and-forge-install-audit.md](guides/version-isolation-and-forge-install-audit.md)** — 版本隔离 + Forge 沙箱化设计与审计（2026-05-04）
- **[guides/openjdk_ohos_build_guide.md](guides/openjdk_ohos_build_guide.md)** — 在 Docker 中交叉编译 OpenJDK for OHOS（长文，深入讲 toolchain/configure/patch 细节）
- **[guides/java-launcher-layer-design.md](guides/java-launcher-layer-design.md)** — JavaApp 层（`AmclLauncher`）设计（✅ 已落地，保留作为设计背景）
- **[guides/glfw_input_design.md](guides/glfw_input_design.md)** — GLFW 输入翻译层设计
- **[guides/genuine-login-and-account-system-plan.md](guides/genuine-login-and-account-system-plan.md)** — 🆕 **正版登录与账户体系规划**（2026-05-09，主 HMCL Auth Code+PKCE+WebView，备 PCL Device Code，含 Azure 注册教程 + 风险评审）

## 三、测试与报告

- **[testing/debug-testing-guide.md](testing/debug-testing-guide.md)** — 调试 & 测试手册（日志抓取、hdc、设备安装）
- **[reports/feasibility_report.md](reports/feasibility_report.md)** — 最初的可行性验证报告（基线）
- **[self-inspection/](self-inspection/)** — 项目全面评审报告（2026-04-25 / 2026-05-04 / 2026-05-06 / 2026-05-09 四版）
- **[security-signing.md](security-signing.md)** — 签名证书与 SHA-256 校验和管理

## 四、归档（archive/）— 仅供考古

所有下面的目录都是**历史记录**，不代表当前项目方向：

- `archive/download-history/` — **下载系统 9 份历史设计稿**（v2 → v6-analysis），已被 `guides/download-system.md` 取代
- `archive/forge-analysis/` — Forge 问题多轮分析（2026-03 ~ 04 初）
- `archive/forge-fix-2026-04-18/` — 本次 Forge 修复之前的问题报告
- `archive/refactor-proposals/` — 历史重构提案（已执行或搁置）
- `archive/obsolete-guides/` — 含误导性 JVM 参数建议的老文档
- `archive/old-chinese-docs/` — 早期中文名百科式文档（技术概念手册 / 项目文档 / 待优化项）
- `archive/jvm_crash_fix_memo.md` — JVM 崩溃修复备忘（旧）
- `archive/architecture_refactor_v1.md` / `v2.md` — 架构重构历史版本
- `archive/project-evaluation-and-optimization.md` — 4/16 的旧评估报告（评分 8.4，现已回落至 6.5）

## 五、文档维护约定

1. 新的方案、评估、路线图**一律写进对应权威文档**（`ROADMAP.md` 或 `guides/download-system.md` 等），**不要再开"v7 / v8 / vN"系列**。
2. 阶段性完成后，把老版本直接 `git mv` 进 `archive/<分类>/`，不要散在根目录。
3. 任何含 `-XX:-UsePollingPageSafepoint` / `-XX:+AllowUserSignalHandlers` / 在 sigchain 里手写 `mprotect` 的建议，直接归档到 `archive/obsolete-guides/` —— 这些做法已被实测证伪，见 `JDK_ADAPTATION_GUIDE.md` 警示框。
4. **下载系统专用约定**：所有下载相关方案 / Bug 修复 / 优化都改 `guides/download-system.md` 的对应章节（§4 待办 / §1 状态快照），不要再创建新文件。