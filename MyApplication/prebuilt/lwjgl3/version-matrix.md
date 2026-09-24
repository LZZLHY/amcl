# LWJGL ↔ MC 兼容性矩阵与历史记录

## 当前部署契约

当前为现代 LWJGL3、3.2.3 兼容槽、真实 LWJGL2 三槽；选择依据是安装游戏的依赖清单，不能只按显示名称或下方旧 MC 区间猜测。现代槽的版本、模块和哈希以 [modern-slot.manifest.json](modern-slot.manifest.json) 为准；精确 classpath/制品验证见 [RuntimeSlotClasspath](../../launch/src/main/ets/RuntimeSlotClasspath.ets) 与 [LwjglSlotIntegrity](../../launch/src/main/ets/LwjglSlotIntegrity.ets)。窗口 provider 与 renderer profile 独立选择，旧固定管线已使用 GL4ES。

下方保留早期升级时点的版本表、故障与决策作为历史证据，不作为当前部署或支持矩阵。当前游戏/设备成功范围应读取绑定包身份的报告，例如[统一图形验证](../../docs/reports/unified-graphics-20260918/README.md)；旧记录中的“单版本”“尚无 LWJGL2”“固定管线待实现”不再适用于当前工作树。

## 历史记录：早期 3.4.1 升级与多槽过渡

> **作用**：升级 LWJGL（特别是大版本，如 3.3.x → 3.4 / 4.x）时用来判断会不会
> 破坏老 MC 兼容性。**不是**部署表 —— LWJGL 3.x 在 HAP 内永远单版本部署。
>
> **读法**：MC 期望的 LWJGL 版本来自上游 `version.json` 的 `libraries` 数组；
> 我们 HAP 内部署的 LWJGL 版本由 `deps.lock` `[lwjgl-jars].version` 决定。
> ABI 在 LWJGL 3.x 内大体向后兼容，跨大版本（2.x → 3.x → 4.x）破裂。

### 当时的部署版本

> ⚠️ **2026-06-11 更新（多版本方案 C 落地）**：不再是"HAP 内永远单版本"。现在**双套共存**：
> - **341 套**（LWJGL 3.4.1）：MC **1.19+** / 26.x。无后缀 `liblwjgl.so` 等。
> - **322 套**（LWJGL 3.2.3）：MC **1.13–1.18.2**（绑 3.1–3.2，调 mallocStack 等 3.3 已删 API）。
>   带 `_v322` 后缀 native + 字节码改名 jar，详见 `prebuilt/lwjgl3/3.2.3/README.md`、
>   `docs/adaptation/LWJGL_MULTIVERSION_PLAN.md` §10。`LaunchProfileBuilder` 按 MC 声明的 lwjgl 版本路由。
> - 真机（1.16.5）已验证 322 套**能正确加载**（`Backend library: LWJGL version 3.2.3`），mallocStack 崩溃消除；
>   但卡在渲染层 `glAlphaFunc`（MobileGlues 固定管线，见下表备注）。

`deps.lock`：

```ini
[lwjgl-jars]       version = 3.4.1   # 341 套
[lwjgl-jars-322]   version = 3.2.3   # 322 套（新增）
```

`prebuilt/lwjgl3/jars/` 全部上游 jar 都 `3.4.1`。
`lwjgl-glfw.jar` 用**上游原版 `3.4.1`**（方案 B：保留上游 `GLFW.class`，只注入我们的
`CallbackBridge`/`GLFWWindowProperties` 桥接类，GLFW C 符号由 `libglfw.so` 导出）。
`liblwjgl*.so` 由 `docker/build_lwjgl_ohos.sh`（`LWJGL_TAG=3.4.1`，libffi 3.5.1）基于
**LWJGL 官方 release tag `3.4.1`** (commit `b800ccff…`) 编出。

## 兼容性矩阵

| MC 版本 | MC 期望 LWJGL | HAP 内 LWJGL | 兼容性 | 备注 |
|---|---|---|---|---|
| **26.1.x** | 3.4.1 | 3.4.1 | ✅ 完全匹配 | 升级目标；Sodium 0.8.12 / Iris 1.10.9 要求 ≥ 3.4.1 |
| **1.21.x** | 3.3.3 | 3.4.1 | 🟡 ABI 向后兼容 | 3.4 向后兼容 3.3 调用面，需真机回归 |
| **1.20.6** | 3.3.3 | 3.4.1 | 🟡 ABI 向后兼容 | 同上 |
| **1.20.4** | 3.3.1 | 3.4.1 | 🟡 跨两 minor | **当前主力版本，3.4.1 后必须真机回归确认不退化** |
| **1.20.1 / 1.19.4 / 1.19.2** | 3.3.1 | 3.4.1 | 🟡 跨 minor | 未做完整回归 |
| **1.18.x** | 3.3.1 | 3.4.1 | 🟡 跨 minor，多数兼容 | 未测 |
| **1.17.x** | 3.2.2 | **322 套 3.2.3** | 🟢 LWJGL 匹配 | 走 322 套（需 Java≤16，1.17 要 Java16）；渲染层同 1.16.5 待解 |
| **1.16.5 / 1.16.x** | 3.2.2 | **322 套 3.2.3** | 🟢 LWJGL 加载 OK / 🔴 渲染阻塞 | 真机：3.2.3 已加载、mallocStack 消除；崩 `glAlphaFunc`（MobileGlues 缺固定管线）。**LWJGL 任务到此完成，剩渲染层** |
| **1.13–1.15** | 3.2.x | **322 套 3.2.3** | 🟢 LWJGL 匹配 / 🔴 渲染待测 | 同上，走 322 套；固定管线 GL 支持是下一步 |
| **1.12.2 及以下** | LWJGL **2.x** | 3.4.1 | ❌ 大版本不兼容 | 需要 LWJGL 2 兼容方案（详见 §3.1.4 / P9） |

**ABI 兼容性原则**：

- **3.3.x 之间**：`org.lwjgl.glfw.GLFW`、`org.lwjgl.opengl.GL30` 等核心 API 行为
  锁定，新版本通常只加新方法。已知例外：3.3.0 → 3.3.1 重命名了 `MemoryUtil.memCallocStruct` 等少量内部 API
- **3.2.x → 3.3.x**：`MemoryStack` API 调整、`Configuration` 类签名调整。MC 1.13–
  1.16 调用面少，影响不大；mod 多的整合包风险增大
- **2.x → 3.x**：完全不同的包名（`org.lwjgl.opengl.Display` vs GLFW），不兼容。
  MC ≤ 1.12 必须用 LWJGL 2

## ⚠️ Sodium / Iris 的精确版本校验（单版本部署的致命约束）

> 2026-06-06 真机定位：MC 1.21.1 + Fabric + Sodium/Iris 在 HAP 内 LWJGL 3.4.1 上**启动即崩**。

上面矩阵的 🟡（"3.4 向后兼容 3.3 调用面"）**只对纯原版成立**。一旦装了 **Sodium / Iris**，
情况完全不同：

- **Sodium 有一道启动前硬校验**（caffeinemc，GH issue #2561）：把【运行时实际加载的 LWJGL 版本】
  与【该 MC 版本 Mojang 捆绑的、Sodium 编译时锁定的 LWJGL 版本】做比对，**不一致就 `System.exit` 拒绝启动**，
  且**连更高版本也拒绝**（要 3.3.3，给 3.4.1 也报错）。真机日志：
  ```
  [ERROR]: The game failed to start because the currently active LWJGL version is not compatible.
    Installed version: 3.4.1-snapshot
    Required version:  3.3.3
  ```
  原因：Sodium 深度调用 LWJGL 底层内存 / GL 函数加载，版本错配历史上造成难查崩溃，故快速失败。

- **后果**：装了 Sodium/Iris 时，矩阵里的 🟡 实际是 ❌。即"LWJGL 向下兼容"对 **MC 本体**成立，
  但对**硬查版本的 mod 不成立**。

- **单版本部署在此约束下数学上不可解**：

  | MC | Sodium 期望 LWJGL | HAP 单版本 3.4.1 | 结果 |
  |---|---|---|---|
  | 26.1+ | 3.4.1 | 3.4.1 | ✅ |
  | 1.21.x | 3.3.3 | 3.4.1 | ❌ Sodium 拒启 |
  | 1.20.x | 3.3.x | 3.4.1 | ❌ Sodium 拒启 |

  历史记录（见文末）里 AMCL 一直在追最新 Sodium 往上 bump 全局 LWJGL，但每 bump 一次就把
  老 MC 的 Sodium 弄崩——**只要同时支持"装 Sodium 的老 MC"和"装 Sodium 的新 MC"，
  单一全局 LWJGL 必然顾此失彼**。

**结论**：要兼容带 Sodium/Iris 的多代 MC，**首选**注入 Sodium 官方关闭开关
`-Dsodium.checks.issue2561=false`（对齐 PojavLauncher / FCL 的实际做法——移动端启动器都用
定制 LWJGL，单一全局版本 + 关掉 Sodium 的精确校验，而**不是**为每个 MC minor 备一套 LWJGL）。
"3.3.x ↔ 3.4.x 多版本并存"是纯粹主义的长期可选项，不是解决 Sodium 的推荐路径。
设计与取舍见 [`docs/adaptation/LWJGL_MULTIVERSION_PLAN.md`](../../docs/adaptation/LWJGL_MULTIVERSION_PLAN.md) §2.5 / §9。
（本表"纯原版可向后兼容"的乐观判断在有 Sodium 时不成立；真正的修复是关检查，而非换 LWJGL。）

## 升级触发条件

LWJGL **不应该跟着上游 release 自动升**，按以下两种触发：

1. **支持新 MC 大版本**（比如 1.22 出来要求 3.4.x）→ 评估升级
2. **修关键 bug**（GPU 兼容性、安全 CVE、Sodium / Iris 兼容性）→ 评估升级

不在以下情况升级：

- 上游发了 minor 版本但我们当前主力 MC 版本没要求（无收益的迁移成本）
- 仅有性能优化（除非显著）

## 升级流程

详见 `prebuilt/lwjgl3/README.md` "升级 LWJGL 版本" 一节 + `docs/guides/third-party-deps-restructure-plan.md` §3.1.3。

简单来说：

1. `git ls-remote --tags https://github.com/LWJGL/lwjgl3.git` 看新 tag
2. 改 `deps.lock` 的 `[lwjgl-jars].version` + 9 个 sha256（先 PENDING，下载后填）
3. `bash setup_deps.sh --force --skip-jars=false` 拉新 jar + 校验
4. `node scripts/build-prebuilt-jars.mjs` 用新 baseline 重新嵌入我们的 GLFW class
5. natives：`docker/build_lwjgl_ohos.sh` 重编（同步改 `[lwjgl-natives].tag` + commit）
6. **本表新增一行**记录新版本对当前各 MC 版本的兼容性
7. 真机回归（至少 1.20.4 + 1.21.x），不通过的回退

## 历史记录

| 日期 | 版本变化 | 触发原因 |
|---|---|---|
| 2026-05-30 | 3.3.3 → **3.4.1** + 切方案 B（上游原版 GLFW.class） | MC 26.1.2 / Sodium 0.8.12 / Iris 1.10.9 要求 LWJGL ≥ 3.4.1；详见 `docs/archive/lwjgl-3.4.1-upgrade/`（评估 + 方案 B + 执行日志） |
| 2026-05-19 | jars 真升 3.3.3（之前 jars 实际是 3.3.2-snapshot fork） | sodium 1.20.6 检查 LWJGL ≥ 3.3.3 失败；详见 `docs/archive/lwjgl-3.4.1-upgrade/LWJGL_3.3.3_UPGRADE.md` |
| 2026-04-20 | 3.3.2 → 3.3.3 | PojavLauncherTeam 适配 wip/rebase_3.3.3 释出 + MC 1.20.5/1.20.6 要求 |
| 2026-02 | 初始 3.3.2 | 项目开始（基于 PojavLauncher 既有 work） |
