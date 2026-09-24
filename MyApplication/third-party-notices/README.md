# 随源码附带的第三方许可正文

本目录从已恢复的锁定依赖中原样复制许可正文（统一 LF 换行）。
[manifest.json](manifest.json) 为每份文件记录来源仓库、不可变提交、上游路径、链接和 SHA-256。
覆盖 LWJGL、MobileGlues、MobileGL、OpenAL Soft、SDL3，以及其中已准备的部分图形、音频依赖。

准备依赖后，可在公开仓库根运行 `node tools/collect-third-party-notices.mjs` 重建这些附件。
`node tools/check-public-release.mjs` 会核对它们的内容身份。

这些副本保留第三方原有条款，不由 AMCL 的 GPL-3.0-only 替代。该目录的覆盖范围以
manifest 为准；它不是所有历史 Native、JAR、SDK 或运行时分发物的完整许可审查报告。
更多组件来源和重建边界见 [CREDITS.md](../docs/CREDITS.md)。
