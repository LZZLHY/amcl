# 手动发布源码同步

本文面向维护者，说明怎样从私有主工程的实际发布提交形成公开源码候选。贡献接纳、作者保留与版本回流见[贡献维护流程](contributions.md)；贡献者的本地构建步骤见[公开构建说明](../../MyApplication/docs/BUILD_SNAPSHOT.md)。

应用源码继续在私有主工程开发。只有维护者手动发版时执行本文的导出流程；日常提交、PR 检查和 CI 通过不会自动同步源码。公开仓自身的工具、说明和模板可以独立维护。

## 输入与交付边界

同步工具是 [`tools/sync-source-snapshot.mjs`](../../tools/sync-source-snapshot.mjs)，边界策略是 [`tools/source-export-policy.json`](../../tools/source-export-policy.json)。工具只生成或应用本地候选，不提交、不推送、不创建 Release，也不修改或发布应用更新 feed。

每次同步需要同时固定：

- **私有源码提交**：本次实际构建所用的完整 40 位 commit，且与干净源工程的 HEAD 相同。不要在打包后从继续变化的开发目录临时取一个“最新提交”。
- **公开候选基线**：已核对的公开仓 HEAD，使用独占分支和干净 checkout，不在其他任务的工作树上操作。
- **公开策略和依赖**：本次审阅的导出策略、冻结 gitlink、公开可取得的固定依赖和已锁定制品。
- **外部计划位置**：仓库外的新文件，与公开候选位于同一文件系统，供审阅、暂存和失败恢复使用。

源码字节从冻结提交的 Git 对象读取，不从未提交工作树拼装。必要的 ignored MobileGL 制品仍通过既有 `verifyDist` 门禁核对；干净的 Git 状态不能代替该制品检查。`--require-clean` 保留给旧调用者兼容，干净源工程现在始终是正式导出的要求。

## 1. 核对范围与贡献状态

发布前先查[贡献台账要求](contributions.md#3-维护可追溯的贡献台账)，确认本次应交付的已接纳贡献进入了实际发布提交；部分采用、延期和撤回分别记录。不要在公开同步时把未经私有集成的 PR 混入应用源码。

导出策略区分源仓文件、公共专属文件、派生记录、生成物和私有材料。新增源码根未分类时会拒绝导出，先检查实际用途，再更新策略并重新生成计划。

当前策略纳管 `JavaCpuAgent`、`JavaAudioServiceAgent` 等自有源码。`docs/` 只公开明确评审过的必要输入，不能因为某个检查缺文档就自动公开整棵内部资料。需要新增事实文档、测试固定输入或构建配方时，核对内容及调用方后纳入策略。

公开 README、构建说明、公共准备脚本等保护项由策略声明，同步时保留。其他受管路径按上次导出清单、当前公开内容和新源结果比较：公开仍等于上次导出的路径才能被更新或精确删除；公开有额外修改时报告冲突，先查清是否已经回到私有工程。

第三方依赖按 Git gitlink、锁文件、补丁和制品来源取得。普通同步不初始化一套重构建环境，也不隐含重编 JDK 或全部 Native 库；需要逐项确认所用公开 URL 和固定提交能够取得。

## 2. 准备干净的公开候选

在已经核对来源的公开仓独占 checkout 中，从最新审阅的公开基线建立候选分支。以下是示例，版本和分支名应替换为本次实际值：

```powershell
git fetch origin main
git switch -c release/source-vNEXT origin/main
git status --short
```

源工程和公开候选均须没有待提交或未跟踪的独有修改。原有材料先保存、提交或交接，不能用强制清理换取“干净”。AMCL 维护者工作区的新增候选与运行材料按当前工作区路由落盘；候选在 E 盘时，计划及其恢复目录也放在 E 盘。

外部计划不能放在源仓或公开仓内部；工具会核对真实物理路径，拒绝通过 junction 或链接回流仓内。计划父目录与公开候选必须同一文件系统，以支持原子替换；跨盘应准备同盘候选与计划，不修改全局 TEMP/TMP。

## 3. 只预检并生成计划

下面变量是格式示例，应换成实际绝对路径和构建收据中的提交。命令在公开候选的仓库根目录执行：

```powershell
$Source = 'E:/release-work/MyApplication-frozen'
$SourceCommit = '<实际构建使用的完整40位源码commit>'
$Plan = 'E:/release-work/records/source-plan-01.json'

node tools/sync-source-snapshot.mjs --source $Source --expected-commit $SourceCommit --plan $Plan
if ($LASTEXITCODE -ne 0) { throw '源码同步预检失败；保留材料并处理原因' }
```

该步骤只读源仓和公开候选，在指定仓库外位置创建计划，不应用源码差异。它列出来源、策略身份、新增、修改、删除及依赖等信息。省略 `--plan` 时只向 stdout 打印只读计划，不能用于后续 `--write`。

计划文件必须是新文件；工具不覆盖已有计划。修改源码、公开 HEAD、策略、依赖或制品后，需要换新文件名重新预检，例如 `source-plan-02.json`。保留旧计划作为审阅与更正记录，不手改计划让其符合新输入。

核对计划时至少确认：

1. source commit、应用版本与实际构建来源一致；本次产品另与构建收据核对，导出计划不替代产品验收。
2. 所有必要自有源码、配方和测试输入都在范围内，私有材料与公开专属文件处理正确。
3. 删除和重命名涉及的精确路径符合源仓变化，没有待导入的公开贡献被覆盖。
4. gitlink、源码 pin、补丁与制品身份能够对应，公开引用可取得。
5. “已接纳、待发布”的贡献与本次导出结果一致，剩余事项仍有记录。

## 4. 应用同一份已审阅计划

预检通过并完成审阅后，保持源、公开候选与策略稳定，使用完全相同的参数加 `--write`：

```powershell
node tools/sync-source-snapshot.mjs --source $Source --expected-commit $SourceCommit --plan $Plan --write
if ($LASTEXITCODE -ne 0) { throw '源码同步应用失败；检查计划、现场与恢复材料' }

git diff --cached --name-status
git diff --cached --stat
git diff --cached --check
```

应用前会重新做预检并比对计划，发现 source、公开基线、策略或输入漂移即拒绝，不能继续复用旧计划。

`--write` 会精确暂存本次计划的文件增改删和 gitlink，并保留 Git mode/可执行位；它不自动创建 commit。审阅要看 `git diff --cached`，同时用 `git status --short` 检查是否出现计划外的未暂存或未跟踪内容，不用全仓 `git add` 混入其他材料。

优先使用尚未初始化依赖的轻量候选。新增 gitlink 由工具创建空目录；更新已有 gitlink 时，索引会前进，已经初始化的依赖工作树仍可能停在旧 HEAD。按构建说明运行 `prepare-public-deps.mjs` 更新至新 pin，再做构建；不能把旧子模块 HEAD 重新 `git add` 回索引。发现依赖自身有修改时先保全，不强制更新。

新增/更新的记录包括：

- `MyApplication/SOURCE_SNAPSHOT.json`：兼容 schema 1，增加 exporter 信息，关联冻结私有提交、导出内容与依赖身份。
- `MyApplication/DEPENDENCY_INPUTS.json`：从现有锁汇总组件输入，帮助查找源码、补丁、构建和制品来源；清单存在不代表所有第三方已经重建通过。

这次流程改进本身没有同步新应用源码。现有 1.0.6 的历史构建/验证记录保持原义；下一次人工同步才按新策略补入相关缺失输入，不能提前把现有发行描述为已完成新的完整公开构建。

## 5. 验证源码候选并形成公开提交

先在公开候选执行原版与基础配置检查：

```powershell
node MyApplication/scripts/check-public-snapshot.mjs
node MyApplication/scripts/test-project-json5.mjs
git diff --cached --check
```

检查每条命令退出码，失败时停止后续发布。先执行本次受影响的定向检查，审阅暂存内容，然后创建本地候选提交，取得实际公开 Git 身份：

```powershell
git commit -m "release: synchronize reviewed version source"
if ($LASTEXITCODE -ne 0) { throw '候选提交失败' }
$PublicSourceCommit = git rev-parse HEAD
```

随后从这个**精确候选提交**创建干净公开克隆，核对该克隆的 `HEAD` 等于 `$PublicSourceCommit`，再按[公开构建说明](../../MyApplication/docs/BUILD_SNAPSHOT.md)准备依赖和构建所选产品。不能在暂存内容尚未提交时克隆旧 HEAD，再把旧版本编译结果写成新候选通过。独立克隆不应依赖私有仓权限、内部绝对路径或未公开的必要输入。

记录实际公开 commit、私有 source commit、依赖/工具链、命令和结果。源码完整性、依赖准备、HAP 编译、签名安装及设备/游戏运行分别给出真实结果；导出成功不授予这些验证资格。

本地候选提交不等于完成发行。验证失败时保留候选与日志，修正后形成新候选并重新验证受影响部分；未经验证的旧候选不能沿用资格。**公开源码 candidate commit** 与 `SOURCE_SNAPSHOT.json` 中的私有 `sourceCommit` 是两种身份，发布时分别核对。

## 6. 与 Release、更新 feed 的顺序衔接

源码同步 commit 可以先留在公开候选分支。新源码版本与当前已发布 feed 可能暂时不同，不要为了让一致性检查变绿，提前改写或发布更新 feed。

新 Release 的 tag 应显式指向经审阅的**公开源码 candidate commit**，不能误指私有 source commit 或未核对的公开 `main`。这一步仍须按本次实际授权和既有发布流程执行，导出工具不代办。

按既有资产、官网、镜像和通道流程确认实际发行就绪后，才把本次源码与真正导出的 feed 一起合入或推进公开 `main`。当前 `tools/check-public-release.mjs` 要求源码版本与 feed 一致，应在该交付组合成立后执行；独立源码候选阶段先跑快照、依赖和构建验证，不把尚未 ready 的 feed 写成已发布。

仅维护旧版本 feed、补通道推荐或恢复已有发布时，不重新导出应用源码。执行任何合入前重新核对公开主干基线；发生他人修改时先整合并重验，不强行覆盖。

公开源码、实际 tag 与发行确认可访问后，按[贡献回流步骤](contributions.md#5-发布后完成回流)补记本次采用的 PR、作者和公开版本，再完成 PR 的发布状态闭环。

## 失败处理与恢复

| 失败阶段 | 处理方式 |
|---|---|
| 预检拒绝或发现未分类输入 | 公开源码未应用。处理真实来源、范围或冲突，保留旧计划，使用新计划名重新预检。 |
| 应用前发现计划漂移 | 不编辑旧计划。核对 source/公开 HEAD/策略/制品发生的变化，再生成新计划。 |
| 写入或暂存失败 | 工具尝试恢复本轮替换文件和原索引，并保留计划父目录中的独占暂存/恢复材料。先查看错误、仓库状态及恢复记录，确认结果后再决定后续操作。 |
| 恢复时出现外部修改 | 保护外部修改和现场，人工核对每个冲突路径及索引身份；不删除锁、不强行覆盖、不重复盲跑。 |
| 候选检查或公开构建失败 | 保留候选提交/差异与必要日志，定位缺项或实现问题；尚未通过的候选不作为完成发布。 |

计划父目录承担本轮临时暂存与恢复材料，保持独占。成功后按任务输出生命周期保存必要的小型计划/收据并回收确认可再生的本轮材料；失败先提取原因、保全独有字节和恢复入口，再评估退役。不要递归清理共享父目录，也不要对工作区使用 `git clean -fdx` 或 `git reset --hard`。
