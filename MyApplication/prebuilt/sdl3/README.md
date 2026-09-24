# SDL3：OHOS 窗口、输入与宿主运行时适配

当前基线来自 icculus/SDL 的 sdl3-harmonyos 分支，精确提交以 [deps.lock](../../deps.lock) 的 [sdl3-native] 节为准。AMCL 在该基线上按 [patches/series](patches/series) 顺序应用适配；现役栈为 0001–0019，共 19 个补丁。该目录不是“空补丁、只用自有 fork 提交”的早期布局。

## 输入与产物

| 内容 | 位置/用途 |
|---|---|
| 干净上游源码 | prebuilt/sdl3/sdl3_src/，由公开依赖准备取得 |
| AMCL 补丁 | patches/series 及对应 patch，构建时在独立 worktree 应用 |
| HAP Native 输入 | [entry/libs/arm64-v8a/libSDL3.so](../../entry/libs/arm64-v8a/libSDL3.so)，公开快照已保留 |
| 来源和指纹 | deps.lock 的 commit、abi_base、patchset_sha256、size/sha256、HAP 指纹字段 |
| 宿主测试冻结输入 | [tests/fixtures/e293db30d/](tests/fixtures/e293db30d/)，含来源 manifest 与 LICENSE.txt |

补丁内容覆盖宿主窗口/输入、存活窗口代际、辅助 pbuffer、typed 输入与文字、桌面服务、presentation session、实际 consumer 的初始化所有权、资源几何身份和图形观测。最新三项为：

- 0017：图形功能观测。
- 0018：公共 context 准入、真实呈现证据与失败后的资源保留。
- 0019：原生 OpenGL provider 报告零 pbuffer 总像素上限时，通过真实创建和精确尺寸回查验证；其他 provider 仍保留原限制。

功能描述应结合补丁和宿主 ABI 阅读，不能把旧补丁阶段的设备结论当作 0019 栈的验收结果。

## 准备与独立重建

以下命令在 MyApplication/ 执行：

```powershell
node scripts/prepare-public-deps.mjs
pwsh -File scripts/build-sdl3-ohos.ps1
node scripts/check-sdl3-artifact.mjs
```

普通 HAP 构建只需要第一步准备所需输入，并使用快照中的 SDL3 库；后两条用于单独重编和核验。Windows 配方 [scripts/build-sdl3-ohos.ps1](../../scripts/build-sdl3-ohos.ps1) 使用本机 SDK，在独立构建 worktree 按顺序先 git apply --check 再应用补丁，核对补丁摘要、来源和最终产物。Docker 配方另见 [docker/build_sdl3_ohos.sh](../../docker/build_sdl3_ohos.sh)，需要相应容器环境。

scripts/check-sdl3-artifact.mjs 校验补丁/产物身份；scripts/check-sdl3-launch-contract.mjs、test-sdl3-host-runtime.mjs 等检查宿主契约。补丁摘要会进入 SDL revision，因此只改 series 而继续使用旧 SO 应被拒绝。

编译、ABI/符号、HAP 包内身份与实际设备运行是不同层次的验证。公开快照没有附带内部设备原始日志，也不声明所有游戏、加载器、窗口恢复和性能组合都已通过。

## 来源与署名

当前依赖基线与历史 LZZLHY/SDL ohos fallback 的来源不同。保留的 scripts/rebuild-sdl3-ohos-history.mjs 用于历史 fork，不是当前 19 个补丁栈的重建入口；不能混用两者的源码、补丁或产物 hash。

保留 SDL 上游许可证、版权与提交作者信息；具体文本见准备后的上游 LICENSE.txt，fixture 的许可证仅针对其对应材料。工程构建总入口见 [BUILD_SNAPSHOT.md](../../docs/BUILD_SNAPSHOT.md)，组件来源见 [CREDITS.md](../../docs/CREDITS.md)。
