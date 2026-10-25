# 参与 AMCL

欢迎提交问题、复现步骤、文档改进和代码修复。第一次参与时，可以先选择一个能够独立说明、独立验证的小问题；功能设计或改动第三方依赖前，先开 Issue 说明目标和方案，方便确认方向。

## 先了解源码同步方式

AMCL 的日常开发在私有主工程进行。本仓库在维护者手动发布版本时同步对应源码、必要的第三方输入和构建说明，不实时镜像开发中的功能。公开应用源码位于 [`MyApplication/`](MyApplication/)，版本与来源记录见 [`SOURCE_SNAPSHOT.json`](MyApplication/SOURCE_SNAPSHOT.json)。

你可以基于公开版本研究、构建、修改代码并提交 PR。应用代码的通常处理路径是：

**公开 PR 与验证 → 维护者评审 → 导入私有主工程 → 已接纳、待发布 → 随后续版本同步 → 关联公开版本并关闭 PR。**

因此，应用代码 PR 被接纳后可能暂时保持打开；这不代表贡献被忽略。维护者会说明采用、需要调整、延期或不采用的状态。公开仓自身的贡献指南、README、CI 等改进可以独立合入。详细的维护者操作见[贡献接纳与回流](docs/maintainers/contributions.md)。

## 选择入口

| 你想做什么 | 从哪里开始 |
|---|---|
| 报告崩溃、功能异常或构建失败 | [创建问题](https://github.com/LZZLHY/amcl/issues/new/choose)，提供版本、环境和最小复现 |
| 提出功能或较大的架构调整 | 先创建功能建议，说明使用场景、预期行为和可验证的范围 |
| 修复一个明确的问题 | 查看关联 Issue，再按下文建立分支和提交 PR |
| 修改文字、构建说明或贡献引导 | 直接提交聚焦的 PR，注明涉及的文档和实际核对结果 |
| 修改第三方组件或升级依赖 | 先说明源码来源、固定提交、补丁、许可和影响的构建链路 |

提交前请搜索已有 Issue 和 PR。一个 PR 尽量解决一个问题，避免把功能修复、全仓格式化、依赖升级和目录整理放在一起。

## 1. Fork、克隆和建立分支

在 GitHub 上 Fork [LZZLHY/amcl](https://github.com/LZZLHY/amcl)，然后克隆自己的 Fork。下面将 `YOUR_NAME` 换成你的 GitHub 用户名；命令在仓库根目录执行，工程目录在下一层 `MyApplication/`。

```powershell
git -c core.longpaths=true clone https://github.com/YOUR_NAME/amcl.git amcl
Set-Location amcl
git remote add upstream https://github.com/LZZLHY/amcl.git
git fetch upstream main
git switch -c fix/describe-the-problem upstream/main
git config core.longpaths true
```

选择简短的本地路径，避免 Windows 的 Native 工具遇到过长路径。请保留完整的外层 Git 仓库；GitHub 源码 ZIP 没有第三方子模块工作树及这些检查所需的 Git 身份。

在首次修改前，可以检查刚取得的官方版本输入：

```powershell
node MyApplication/scripts/check-public-snapshot.mjs
```

该命令核对的是官方快照原件。开始修改后，源码与原件哈希不同是正常现象；提交贡献时使用后文的 PR 检查，不需要反复把修改后的文件当作官方原件校验。

## 2. 按改动范围准备环境

**只改公开文档或模板**，先检查文字、相对链接、示例和模板显示即可，无需初始化整套应用依赖。

**修改应用源码或需要执行相应测试**，先阅读[公开源码构建说明](MyApplication/docs/BUILD_SNAPSHOT.md)。它是 SDK、JDK、Rust、工具路径、签名和 HAP 构建步骤的权威入口，本指南不维护另一套工具版本。

应用依赖的准备入口在工程目录中执行：

```powershell
Set-Location MyApplication
node scripts/prepare-public-deps.mjs
node scripts/prepare-public-deps.mjs --check
```

准备入口会恢复普通构建需要的固定第三方源码和输入；只运行递归子模块更新不能替代这些步骤。修改过第三方工作树后，先保留自己的改动，再决定怎样准备或切换版本。

贡献者使用自己的本机配置和签名即可，维护者的正式证书不是参与贡献的条件。unsigned HAP 的编译成功不等于能安装运行；设备运行还需要你自己的有效签名和对应 profile。详细操作均见[构建说明](MyApplication/docs/BUILD_SNAPSHOT.md)。

## 3. 编写改动

- 先核实源码、调用方和已有测试，说明问题在什么条件下发生，以及改动如何处理这个条件。
- 保持改动集中，沿用附近代码的风格。新写或修改的 AMCL 自有逻辑请补充准确的中文注释，解释职责、关键条件、失败处理和必要的线程或资源约束；第三方原有代码与注释不需要统一翻译。
- 修复行为时优先补一个能区分修复前后的定向测试。文字、链接等低影响改动不必为了提交 PR 额外搭建应用环境。
- 添加或修改第三方适配时，提供上游地址、精确 commit/tag、补丁及应用顺序、构建方法、许可来源；修改子模块需要让所引用的提交能够从公开地址取得。
- 必要的源码、测试固定输入和构建配方应随 PR 提交。不要提交本机 SDK、缓存、设备私钥、账号令牌或原始个人数据；日志保留与问题相关的片段并检查内容。

普通功能修复不需要修改以下发行记录：

- `MyApplication/SOURCE_SNAPSHOT.json` 及官方快照哈希；
- 官方应用版本号、更新 feed 和对外发行日志；
- 官方签名、设备能力批准或发布身份。

如果问题恰好涉及依赖锁、版本机制或上述记录本身，在 PR 中单独解释原因和预期处理方式。依赖升级可以提交必要的锁文件和补丁变更，不要用改写摘要的办法掩盖来源或构建失败。

## 4. 验证并如实说明范围

回到仓库根目录，先运行公共贡献检查和空白检查：

```powershell
$BaseCommit = git merge-base HEAD upstream/main
node tools/check-public-contribution.mjs --base $BaseCommit
git diff --check
```

`$BaseCommit` 是当前分支与已取得的 `upstream/main` 的共同公开基线，值应为完整的 40 位提交哈希。贡献检查用于核对公开基线、改动范围和基础契约。它的通过不代表已完成 ArkTS/Native 编译、HAP 构建或真机运行。维护者可能要求补充与具体改动相关的验证。

| 改动类型 | 建议提供的验证 |
|---|---|
| 文档、Issue/PR 模板 | 相对链接、示例命令、渲染和模板字段核对 |
| Node/Python/构建工具 | 相关脚本检查和定向回归，特别说明失败场景 |
| ArkTS、Java、Native 或资源 | 相关测试；按[构建说明](MyApplication/docs/BUILD_SNAPSHOT.md)执行适用的 HAP 构建 |
| 输入、窗口、图形、音频、安装或生命周期行为 | 除编译外，提供实际覆盖的设备、版本和操作步骤；未验证项单独列出 |
| 第三方源码、补丁或制品 | 来源身份、准备/应用结果和对应构建验证；源码重建与制品字节一致分别报告 |

PR 中请直接写出“执行了什么、结果是什么、还没验证什么”。例如可以说明“公共检查和定向测试通过，缺少 HarmonyOS 设备，未做安装和游戏运行验证”。环境不足时先提交 Draft PR 并描述阻碍，也可以贡献最小复现和调查结果。

构建可能生成 JAR、产品元数据等文件。提交前检查差异，保留本次真正需要的源码、固定输入和配套说明，不把偶然生成变化混入 PR，也不要删除尚未确认用途的文件。

## 5. 提交并创建 PR

检查状态，精确暂存本次文件，提交到自己的分支并推送。下面路径是示例，应换成你实际修改的文件。

```powershell
git status --short
git add -- path/to/changed-file path/to/related-test
git diff --cached --check
git diff --cached --stat
git commit -m "fix: describe the corrected behavior"
git push -u origin fix/describe-the-problem
```

在 GitHub 创建指向 `LZZLHY/amcl:main` 的 PR，按[PR 模板](.github/PULL_REQUEST_TEMPLATE.md)填写：

- 问题或目标、关联 Issue，以及最小复现；
- 基于哪个公开版本或 commit；
- 具体修改和选择理由；
- 已执行的验证及结果、未验证的部分；
- 涉及的第三方输入和来源变化。

请保持评审期间的改动仍在同一个 PR 中。需要追上新的公开发行版时，可以合并或变基到新的 `upstream/main`；先保存自己的修改，不要用强制清理丢弃本地材料。修改行为后，应重新执行受到影响的检查。

## 评审后会发生什么

维护者会根据公开版本与私有工程的差异处理贡献。代码采用后可能需要适配当前内部实现，最终公开结果可与原补丁有所调整；有实质变化时应在 PR 中解释。

应用源码 PR 的常见状态是“评审中”“需要修改”“已接纳、待发布”“已随版本发布”。最后一种会关联实际公开 tag/commit，并记录贡献者；尚未发布时不承诺具体发布日期。公开文档和 CI 的独立改进通常走直接合入流程。

提交贡献即表示你愿意按所修改部分现有的[许可证](LICENSE)贡献自己有权提交的内容。第三方代码、图像或其他素材请一并提供来源和许可说明，便于维护者核对。
