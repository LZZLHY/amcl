# 版本隔离与 Forge 安装审计报告

> 撰写日期: 2026-05-04
> 审计范围: AMCL 全量代码, 对比 PCL2 (Plain Craft Launcher 2) 与 HMCL (Hello Minecraft Launcher)
> 触发问题: 用户反馈 "下载一个 Forge 版本时, 版本列表里同时出现 Forge 版和原版"

> **实施状态 (2026-05-05)**: 方案 B (PCL 风格沙箱) 已完整实施并真机验证通过.
>
> - **P1** `ForgeService.install` 加 `filesDirOverride` 参数, 解耦"mcDir 反推 filesDir"的硬编码. BUILD SUCCESSFUL in 1m35s. 100% 向后兼容 (不传新参数走旧反推).
> - **P2** `DownloadTask` Phase 5 改成在 `filesDir/forge-install-sandbox/<sid>/` 跑 Forge installer, Phase 6 用 `fs.renameSync` (真机验证 O(1) 元数据操作) 把 patches libraries 迁入真实 `mcDir/libraries`. BUILD SUCCESSFUL in 1m1s. 用户真机回归: Forge 版本列表不再出现假的"原版"条目.
> - **P3 加固 (2026-05-05)**:
>   - `EntryAbility.onCreate` 启动时扫 `forge-install-sandbox/` 清孤儿 (防止强杀/崩溃累积 50-100 MB/次 的残留)
>   - `Index.scanVersions` 加 JSON 合法性校验 (识别旧版本遗留的"假原版"残留 → orphan UI 自动显示)
>   - 沙箱目录命名 `forge-install-temp` → `forge-install-sandbox`, 与 ForgeService 内部的 installer zip 解压层区分
>   - Fabric 不再走沙箱 (它不产生 `<gameVersion>/` 污染), 省一次 50 MB vanilla jar copy
>
> 下文的"方案 B 推荐"章节保留作为设计决策记录. 探针数据 (T1-T8) 的真机测量见第 5.5 节.

---

## 0. 结论速读 (TL;DR)

| 维度 | AMCL 现状 | PCL2 | HMCL | 结论 |
|---|---|---|---|---|
| **Forge installer 工作目录** | **真实 `mcDir`**(`.minecraft/`) | **独立临时 mcFolder**(沙箱) | 真实 `mcDir`, 但写到目标版本目录 | AMCL 的工作目录污染了用户的版本列表 |
| **是否在用户 mcDir 下创建原版目录** | **是** (`mcDir/versions/{gameVersion}/`) | 否 (临时 mcFolder 中) | 否 (直接合并到目标版本) | **这是 BUG 的根因** |
| **Forge installer 写出的 `{game}-forge-{loader}` 目录是否被清理** | **否** (即使与最终 versionName 不同) | 是(临时目录被删除) | 不存在 (HMCL 不让 installer 直接写版本目录) | AMCL 残留临时目录 |
| **最终用户可见版本数量** | 1\~3 个 (按 versionName 选择) | 1 个 | 1 个 | AMCL 出现了多余版本 |
| **版本隔离 (gameDir)** | 已正确实现 | 同 AMCL | 同 AMCL | 这一项 AMCL 是正确的 |

**根因**: `entry/src/main/ets/services/DownloadTask.ets` 第 540\~553 行在 Forge 安装前把临时下载好的原版 `client.jar` 和 `version.json` **复制**到 `mcDir/versions/{gameVersion}/{gameVersion}.jar`, 满足了 Forge installer "需要原版 jar 在 mcDir/versions 中"的诉求, 但**完成后没有清理这个目录**, 而 `Index.scanVersions()` 把任何 `versions/{name}/{name}.jar > 1MB` 的目录都识别为有效版本, 于是用户在版本列表里看到原版裸版本.

**最简修复**: 在 `Phase 6 MERGE` 完成后(成功路径), 删除 `mcDir/versions/{gameVersion}/` 与 `mcDir/versions/{gameVersion}-forge-{loaderVersion}/`(当它们与 `versionName` 不同时).
**根本修复**: 改用 PCL 风格的"独立临时 mcFolder"(在 `filesDir/` 下而非 `.minecraft/` 下), Forge installer 在那里跑, 完成后只把"合并 JSON + 原版 jar + libraries 增量"复制回真实 mcDir.

---

## 1. AMCL 现状全景

### 1.1 关键路径常量

| 名称 | 实际路径 | 用途 |
|---|---|---|
| `filesDir` | `/data/storage/el2/base/haps/entry/files` | App 沙箱文件根 |
| `mcDir` | `filesDir + '/.minecraft'` | Minecraft 资产根 (libraries/assets/versions) |
| `gameDir` (无隔离) | `= mcDir` | MC 进程的 user.dir / `--gameDir` 参数 |
| `gameDir` (有隔离) | `mcDir + '/versions/<ver>'` | 当前选中版本的运行时目录 (mods/saves/config) |
| `tempDir` | `mcDir + '/download-temp'` | 下载临时目录(**子目录**, 不是独立 mcFolder!) |

### 1.2 文件结构

启动时所需:

```
.minecraft/
├── assets/                                      共享
├── libraries/                                   共享
└── versions/
    └── <versionName>/
        ├── <versionName>.json                   合并后的自包含 JSON (无 inheritsFrom)
        └── <versionName>.jar                    原版 client.jar 的副本
```

下载/启动时, `LaunchProfileBuilder` 用 `mcDir + '/versions/' + version + '/' + version + '.json'` 解析 (`@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\LaunchProfileBuilder.ets:101`).

### 1.3 版本扫描逻辑

`@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\pages\Index.ets:252-285`

```@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\pages\Index.ets:266-276
        let jarPath = dirPath + '/' + name + '.jar'
        try {
          let stat = fs.statSync(jarPath)
          if (stat.size > 1024 * 1024) {
            versions.push(name)
          } else {
            orphans.push(name)
          }
        } catch (e) {
          orphans.push(name)
        }
```

判定标准: **`versions/{name}/{name}.jar > 1MB` 即视为有效版本**.

这个标准本身合理(与 HMCL/PCL 一致). 问题是有"非用户版本目录"在 versions/ 里.

### 1.4 版本隔离实现 (这部分**正确**)

`@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\pages\Index.ets:325-371`

```@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\pages\Index.ets:332-337
    let mcDir = this.context.filesDir + '/.minecraft'
    let gameDir = mcDir
    if (this.versionIsolation) {
      gameDir = mcDir + '/versions/' + this.mcVersion
      try { fs.mkdirSync(gameDir, true) } catch (e) { /* exists */ }
    }
```

启动时把 `gameDir` 设为版本子目录, MC 进程的 `user.dir` / `--gameDir` 都指向这里, mods/saves/config/screenshots 全部落在版本目录下. 这与 PCL/HMCL/Zalith Launcher 文档描述的隔离机制一致.

### 1.5 下载与 Forge 安装编排

`@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\DownloadTask.ets`

| Phase | 动作 | 写入位置 |
|---|---|---|
| 1 PREPARE | 拉取 manifest + version.json | `tempDir/versions/<gameVersion>/<gameVersion>.json` |
| 2 CLIENT | 下载 client.jar | `tempDir/versions/<gameVersion>/<gameVersion>.jar` |
| 3 LIBRARIES | 下载 libraries | `mcDir/libraries/` (**真实 mcDir**) |
| 4 ASSETS | 下载 assets | `mcDir/assets/` (**真实 mcDir**) |
| **5 MODLOADER** | **(关键 BUG 点)** | 见下文 |
| 6 MERGE | `VersionJsonMerger.merge()` | `mcDir/versions/<versionName>/<versionName>.json` + `.jar` |

### 1.6 BUG 焦点: Phase 5 详解

`@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\DownloadTask.ets:537-569`

```@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\DownloadTask.ets:537-569
      // Phase 5: 安装模组加载器（如果有）
      let loaderJsonPath: string | null = null;
      if (this.loaderType) {
        // Forge installer 需要原版 version.json 和 jar 在真实 mcDir 中
        // 将临时目录中的原版文件复制到真实 mcDir/versions/<gameVersion>/
        let realVersionDir = this.mcDir + '/versions/' + this.gameVersion;
        try { fs.mkdirSync(realVersionDir, true); } catch (e) { /* exists */ }
        let realJsonPath = realVersionDir + '/' + this.gameVersion + '.json';
        let realJarPath = realVersionDir + '/' + this.gameVersion + '.jar';
        let tempJarPath = tempVersionDir + '/' + this.gameVersion + '.jar';

        // 复制原版 JSON
        hilog.info(0x0000, TAG, 'Copying vanilla JSON: %{public}s -> %{public}s', tempJsonPath, realJsonPath);
        fs.copyFileSync(tempJsonPath, realJsonPath);

        // 复制原版 jar
        hilog.info(0x0000, TAG, 'Copying vanilla jar: %{public}s -> %{public}s', tempJarPath, realJarPath);
        fs.copyFileSync(tempJarPath, realJarPath);

        // 验证
        let jsonSize = 0;
        let jarSize = 0;
        try { jsonSize = fs.statSync(realJsonPath).size; } catch (e) { /* */ }
        try { jarSize = fs.statSync(realJarPath).size; } catch (e) { /* */ }
        hilog.info(0x0000, TAG, 'Vanilla files in real mcDir: json=%{public}d jar=%{public}d', jsonSize, jarSize);
        if (jarSize < 1024 * 1024) {
          throw new Error('原版 jar 复制失败或文件过小: ' + jarSize + ' bytes');
        }

        this.setPhase(DownloadPhase.MODLOADER);
        loaderJsonPath = await this.installModLoader(info.versionJson);
```

**关键事实**:

1. `realVersionDir = this.mcDir + '/versions/' + this.gameVersion` — 这是用户真实 `.minecraft/versions/1.20.4/`, 是用户能看到的版本列表里的"原版 1.20.4"目录.
2. 把原版 JSON + JAR 复制进去, 此时 `1.20.4.jar > 1MB`, 满足 `scanVersions` 的"有效版本"判定.
3. 之后调用 `ForgeService.install(gameVersion, loaderVersion, mcDir, ...)` 让 Forge installer 在真实 mcDir 中跑, installer 会创建 `mcDir/versions/{gameVersion}-forge-{loaderVersion}/` 目录(**第二个多余目录**).
4. Phase 6 `VersionJsonMerger.merge` 写入 `mcDir/versions/{versionName}/`.

### 1.7 Forge installer 的额外副作用

`@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\modloader\ForgeService.ets:436-441`

```@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\modloader\ForgeService.ets:436-441
      // 清理之前失败安装留下的残余
      let forgeVerDir = mcDir + '/versions/' + gameVersion + '-forge-' + loaderVersion;
      try { this.rmDirRecursive(forgeVerDir); } catch (e) { /* */ }
      let forgeVerDir2 = mcDir + '/versions/' + gameVersion + '-forge-' + gameVersion + '-' + loaderVersion;
      try { this.rmDirRecursive(forgeVerDir2); } catch (e) { /* */ }
      let versionDirsBefore = this.listVersionDirs(mcDir);
```

ForgeService 在跑 installer 前**先清掉**了 `gameVersion-forge-loaderVersion` 目录, 但 installer 跑完后又会**重新生成**该目录(`@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\modloader\ForgeService.ets:535-549` 中通过目录差分识别 installer 写出的版本目录), 然后 `findForgeVersionDirFromDiff()` 找到这个目录后把它的 JSON 路径作为 `loaderJsonPath` 返回给 DownloadTask.

也就是说, Forge 安装结束时, 真实 `.minecraft/versions/` 下有这些目录:

| 目录 | 大小 | 来源 | 是否被清理 |
|---|---|---|---|
| `1.20.4/1.20.4.json` + `1.20.4.jar (>1MB)` | 大 | DownloadTask Phase 5 复制 | **❌ 永远不清理(成功路径)** |
| `1.20.4-forge-49.0.0/1.20.4-forge-49.0.0.json` (无 jar) | 小 | Forge installer 自己写出 | 视情况 |
| `<versionName>/<versionName>.json` + `.jar` | 大 | Phase 6 VersionJsonMerger | 这才是用户期望的版本 |

### 1.8 失败路径"反而正确", 成功路径"忘了清理"

`@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\DownloadTask.ets:641-657`

```@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\DownloadTask.ets:641-657
      // v6 统一清理：失败时总是清理不完整的目标版本目录，防止"已存在"卡死。
      // tempDir（client.jar / version.json）保留供 retry 复用。
      if (this.versionName !== this.gameVersion) {
        try {
          removeDirRecursive(targetDir);
          hilog.info(0x0000, TAG, 'Cleaned up incomplete target dir: %{public}s', targetDir);
        } catch (e2) { /* ignore */ }
      }

      // Forge/Fabric 安装失败时，清理复制到真实目录的原版文件
      if (this.loaderType && this.gameVersion !== this.versionName) {
        let realVersionDir = this.mcDir + '/versions/' + this.gameVersion;
        try {
          removeDirRecursive(realVersionDir);
          hilog.info(0x0000, TAG, 'Cleaned up leaked vanilla dir: %{public}s', realVersionDir);
        } catch (e2) { /* ignore */ }
      }
```

**注意**: 这段清理逻辑只在 **catch (e)** 块里(失败路径). 成功路径(`Phase = DONE`)只走 `cleanTempDir()`, 不会动 `mcDir/versions/`.

### 1.9 默认 versionName

`@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\components\VersionConfigPanel.ets:294-305`

```@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\components\VersionConfigPanel.ets:294-305
  private updateAutoName(): void {
    if (this.isNameEdited) return
    let name = this.gameVersion
    if (this.loaderChoice === 1 && this.selectedLoaderVersion) {
      name = 'fabric-loader-' + this.selectedLoaderVersion + '-' + this.gameVersion
    } else if (this.loaderChoice === 2 && this.selectedLoaderVersion) {
      name = this.gameVersion + '-forge-' + this.selectedLoaderVersion
    }
```

默认 `versionName == gameVersion + '-forge-' + loaderVersion`(例如 `1.20.4-forge-49.0.0`), 与 Forge installer 自己写出的目录名相同, 所以默认情况下 #2 和 #3 重叠(VersionJsonMerger 会覆写 installer 的 JSON 并补上 jar). 但 #1(`mcDir/versions/1.20.4/`)是独立存在的, 永远多一个版本.

如果用户**自定义 versionName**(如 `MyForge`), 则 #2 也变成多余目录(被识别为 orphan, 因为没有 jar), 加上 #1 就会出现两个多余条目(一个有效原版, 一个残留 orphan).

### 1.10 触发场景汇总

| 场景 | 用户在版本列表看到 | 多余项 |
|---|---|---|
| 下载原版 (无加载器), versionName=`1.20.4` | `1.20.4` | 0 |
| 下载 Forge, 默认 versionName=`1.20.4-forge-49.0.0` | `1.20.4-forge-49.0.0`, **`1.20.4`** | **1 (原版)** |
| 下载 Forge, 自定义 versionName=`MyForge` | `MyForge`, **`1.20.4`**, (`1.20.4-forge-49.0.0` 作为 orphan 提示) | **1 + 1 残留** |
| 安装失败 (任何阶段) | (失败路径会清理) | 0 |

**用户描述的问题精确匹配场景 2 / 3**.

---

## 2. PCL2 (Plain Craft Launcher 2) 设计

源码: `Plain Craft Launcher 2/Pages/PageDownload/ModDownloadLib.vb` (`McInstallLoader` + `MergeJson`)

### 2.1 独立临时 mcFolder

```vb
'获取缓存目录（安装 Mod 加载器的文件夹不能包含空格）
Dim TempMcFolder As String = RequestTaskTempFolder(...)

'获取参数
Dim VersionFolder As String = McFolderSelected & "versions\" & Request.NewInstanceName & "\"
If Directory.Exists(TempMcFolder) Then DeleteDirectory(TempMcFolder)

If Request.ForgeVersion IsNot Nothing Then
    ForgeFolder = TempMcFolder & "versions\forge-" & Request.ForgeVersion
End If
```

**关键**: `TempMcFolder` 是**独立**的 mc 目录(不在用户 `.minecraft` 下), 是一个完整的临时 mc 工作区, 含自己的 `versions/`, `libraries/`, `mods/` 子目录.

### 2.2 安装流程

1. 在 `TempMcFolder/versions/<MinecraftName>/` 下载原版 JSON + jar
2. 在 `TempMcFolder/versions/forge-<ForgeVersion>/` 跑 Forge installer (`McDownloadForgelikeLoader`)
3. **`MergeJson(VersionFolder, ...)`**: 把临时目录里的所有 JSON 合并写到用户真实路径
   - 输出路径: `McFolderSelected\versions\{NewInstanceName}\{NewInstanceName}.json`
   - 复制原版 jar: `CopyFile(MinecraftJar, OutputJar)` → `versions/{NewInstanceName}/{NewInstanceName}.jar`
4. **迁移 libraries**: `If Directory.Exists(TempMcFolder & "libraries") Then CopyDirectory(TempMcFolder & "libraries", McFolderSelected & "libraries")`
5. 创建 `mods/`, `resourcepacks/` 目录(在 `New McInstance(VersionFolder).PathIndie` 下, 即版本隔离根)

### 2.3 .pclignore 标识

```vb
'添加忽略标识
LoaderList.Add(New LoaderTask(...)("添加忽略标识",
    Sub() FileUtils.Write(VersionFolder & ".pclignore", "用于临时地在 PCL 的版本列表中屏蔽此版本。")))
...
'删除忽略标识
LoaderList.Add(New LoaderTask(...)("删除忽略标识", Sub() File.Delete(VersionFolder & ".pclignore")))
```

PCL 在版本目录创建之初就放一个 `.pclignore` 文件, 版本扫描时跳过含此文件的目录, 安装完成最后一步才删除该文件. 这避免了"半完成版本"短暂出现在列表里的并发问题.

### 2.4 失败清理策略

```vb
If Directory.Exists(Loader.Input & "saves\") OrElse Directory.Exists(Loader.Input & "versions\") Then
    Log("[Download] 由于版本已被独立启动，不清理版本文件夹：" & Loader.Input)
Else
    DeleteDirectory(Loader.Input)
End If
```

只有当版本目录还没被用户跑过(没有 `saves/` 或 `versions/`)时才删除, 避免误删用户数据.

### 2.5 PCL 的版本结构 (用户视角)

下载 `1.20.4-forge-49.0.0` 后, 用户的 `.minecraft/versions/` 下**只有**:

```
versions/
└── 1.20.4-forge-49.0.0/
    ├── 1.20.4-forge-49.0.0.json  ← 合并后的自包含 JSON
    └── 1.20.4-forge-49.0.0.jar   ← 原版 client.jar 副本
```

完全没有 `1.20.4/`, 也没有任何中间产物.

---

## 3. HMCL (Hello Minecraft Launcher) 设计

源码: `HMCLCore/src/main/java/org/jackhuang/hmcl/download/forge/ForgeNewInstallTask.java`, `DefaultGameBuilder.java`

### 3.1 patches 数组 (而不是多个版本目录)

```java
public Task<?> buildAsync() {
    Task<Version> libraryTask = Task.supplyAsync(() -> new Version(name));   // 单个 Version 对象, name = 用户起的名字
    libraryTask = libraryTask.thenComposeAsync(libraryTaskHelper(gameVersion, "game", gameVersion));  // 添加原版 patch

    for (Map.Entry<String, String> entry : toolVersions.entrySet()) {
        libraryTask = libraryTask.thenComposeAsync(libraryTaskHelper(gameVersion, entry.getKey(), entry.getValue()));  // 添加 forge / fabric / optifine patch
    }
    ...
    return libraryTask.thenComposeAsync(dependencyManager.getGameRepository()::saveAsync)
        .whenComplete(exception -> {
            if (exception != null)
                dependencyManager.getGameRepository().removeVersionFromDisk(name);   // 失败统一清理
        });
}
```

HMCL 把 Forge 的 version.json 作为一个 **patch** 加入 `Version` 对象的 `patches` 数组里, 最后只 `saveAsync(version)` 一次, 写入 `versions/{name}/{name}.json`.

### 3.2 ForgeNewInstallTask 不写额外目录

```java
@Override
public void execute() throws Exception {
    tempDir = Files.createTempDirectory("forge_installer");

    Map<String, String> vars = new HashMap<>();
    vars.put("MINECRAFT_JAR", FileUtils.getAbsolutePath(gameRepository.getVersionJar(version)));
    // gameRepository.getVersionJar(version) → versions/{name}/{name}.jar
    // 即 Forge installer 直接在用户的目标版本 jar 上跑 processor

    Task<?> processorsTask = Task.runSequentially(
            processors.stream().map(processor -> createProcessorTask(processor, vars))...);
    ...
    setResult(forgeVersion
            .setPriority(Version.PRIORITY_LOADER)
            .setId(LibraryAnalyzer.LibraryType.FORGE.getPatchId())   // patchId = "forge"
            .setVersion(selfVersion));
}

@Override
public void postExecute() throws Exception {
    FileUtils.deleteDirectory(tempDir);   // 临时目录清理
}
```

HMCL 不让 Forge installer 自由选择输出目录, processor 的 `MINECRAFT_JAR` 变量直接指向**目标版本 jar**, 跑完后 forge 的 version.json 被合入 patches 里.

### 3.3 HMCL 的版本结构 (用户视角)

下载 `1.20.4-Forge` 后:

```
versions/
└── 1.20.4-Forge/
    ├── 1.20.4-Forge.json  ← patches: [game, forge] 自包含
    └── 1.20.4-Forge.jar   ← 原版 client.jar
```

跟 PCL 一样, 只有一个目录.

---

## 4. 三方对比矩阵

| 维度 | AMCL (现状) | PCL2 | HMCL |
|---|---|---|---|
| 版本隔离机制 | gameDir = `versions/<ver>/` | 同 | 同 |
| Forge installer 工作目录 | 真实 `mcDir` | 独立 `TempMcFolder` | 真实 `gameRepository`, 但目标版本 jar 即用户最终 jar |
| 原版 jar 是否曾出现在 `mcDir/versions/<gameVersion>/` | **是 (持久)** | 否 (临时目录中) | 否 |
| Forge installer 是否在 `mcDir/versions/<g>-forge-<l>/` 创建目录 | **是 (持久)** | 是 (但在临时目录) | 否 (不让 installer 自定目录名) |
| 临时目录回收 | ❌ 未回收 (`mcDir/versions/<gv>/` + `<g>-forge-<l>/`) | ✅ 整个 TempMcFolder 删除 | ✅ tempDir 删除 |
| 完成后用户可见版本数量 | 1\~3 | 1 | 1 |
| 失败清理 | ✅ catch 路径有清理 | ✅ saves/versions 检测后清理 | ✅ removeVersionFromDisk |
| 部分完成幂等 | ⚠️ retry 时清 targetDir, 但 `1.20.4/` 残留可能干扰 | ✅ TempMcFolder 重建 | ✅ patches 增量 |
| `.ignore` 屏蔽未完成版本 | ❌ 无 | ✅ `.pclignore` | ❌ (用 patches 中间状态不写盘) |

---

## 5. 根因结论

### 5.1 为什么会出现"原版 + Forge 版" 

`@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\DownloadTask.ets:541-553`:

> 在 Forge 安装前, 把临时 `download-temp/versions/{gameVersion}/{gameVersion}.jar` 复制到了**真实的** `mcDir/versions/{gameVersion}/{gameVersion}.jar` (size > 1MB).

成功路径在 Phase 6 后**没有删除**这个目录, 而 `Index.scanVersions()` 把 `versions/{name}/{name}.jar > 1MB` 的目录全部识别为有效版本, 所以原版"1.20.4"出现在了版本列表.

### 5.2 为什么 AMCL 当初要这样做

代码注释明确写了原因(`@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\DownloadTask.ets:539-540`):

> Forge installer 需要原版 version.json 和 jar 在真实 mcDir 中

以及 `installModLoader` (`@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\DownloadTask.ets:681-683`):

> Forge 也必须在真实 mcDir 中安装，因为 ForgeService 从 mcDir 推导 filesDir 来找 JDK

`ForgeService.install()` (`@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\modloader\ForgeService.ets:175-177`):

```ets
let installerPath = mcDir + '/forge-installer.jar';
let filesDir = mcDir.substring(0, mcDir.lastIndexOf('/'));
```

`ForgeService` 从 `mcDir` 反推 `filesDir`(再去找 JDK), 因此调用方传入"独立 TempMcFolder"会让 `filesDir` 推导失败.

这是一个**设计耦合**问题: ForgeService 把"用户 mcDir"和"installer 工作目录"绑定到同一参数, 失去了 PCL 那样的临时沙箱能力.

### 5.3 用户描述精确还原

> 我们现在的 forge 安装会出现下载一个版本出现一个 forge 版和原版同时出现在版本列表里面

精确匹配上文 §1.10 场景 2/3.

---

## 6. 修复方案

### 方案 A: 最小补丁 (低风险, 解决用户报告的具体问题)

**目标**: 在 Phase 6 成功后清理 Phase 5 留下的中间目录.

**改动文件**: `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\DownloadTask.ets`

**改动位置**: Phase 6 完成后(`@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\DownloadTask.ets:583-591`):

```ets
this.completePhase(DownloadPhase.MERGE, '版本合并完成')

// 完成
this.phase = DownloadPhase.DONE
this.progress = 100
```

**新增逻辑**(在 `completePhase(DownloadPhase.MERGE, ...)` 之前):

```ets
// 清理 Forge 安装中间产生的版本目录, 避免污染版本列表
// 这两类目录都是 Phase 5 的副产物:
//   1. mcDir/versions/{gameVersion}/  — DownloadTask 复制的原版 (满足 ForgeService 的"原版必须在 mcDir"诉求)
//   2. mcDir/versions/{gameVersion}-forge-{loaderVersion}/ — Forge installer 自己写出的目录
// 它们都不应在最终版本列表中可见. 仅当与最终 versionName 不同时才清理.
if (this.loaderType) {
  let intermediateDirs: string[] = []
  let vanillaDir = this.mcDir + '/versions/' + this.gameVersion
  if (this.gameVersion !== this.versionName) intermediateDirs.push(vanillaDir)
  if (this.loaderType === ModLoaderType.FORGE) {
    let forgeDir = this.mcDir + '/versions/' + this.gameVersion + '-forge-' + this.loaderVersion
    if (forgeDir !== targetDir) intermediateDirs.push(forgeDir)
  }
  for (let dir of intermediateDirs) {
    try {
      removeDirRecursive(dir)
      hilog.info(0x0000, TAG, 'Cleaned intermediate version dir: %{public}s', dir)
    } catch (e) { /* ignore */ }
  }
}
```

**优点**:
- 改动量小(< 20 行), 不动核心架构
- 不影响 Forge 安装的流程(installer 仍在真实 mcDir 中跑)
- 不影响 retry/cancel 的现有清理逻辑
- 兼容 fabric (虽然 fabric 不会留 `mcDir/versions/{gameVersion}/`, 但补丁中的 if 包了 loaderType, 不会误删)

**缺点**:
- 仍有"半完成时刻", 用户在 Phase 5\~6 之间打开"版本管理"会看到原版裸目录(虽然只有几秒\~几分钟)
- 没解决 ForgeService.install 与 DownloadTask 的目录耦合, 未来加 NeoForge / OptiFine 还得记得在这里加清理
- 没有 PCL `.pclignore` 那样的"中间状态屏蔽"

### 方案 B: PCL 风格沙箱 (重构, 根除问题)

**目标**: Forge installer 在独立的临时 mcFolder 跑, 完成后只把"最终 jar/json + libraries 增量"写入用户真实 mcDir.

**改动**:

1. 给 `ForgeService.install()` 加一个可选 `filesDirOverride` 参数, 解除"`filesDir = mcDir.substring(0, mcDir.lastIndexOf('/'))`"的硬编码:

   ```ets
   async install(
     gameVersion: string, loaderVersion: string,
     mcDir: string,
     callback?: ModLoaderInstallCallback,
     filesDirOverride?: string,   // 新增: 显式指定 filesDir, 用于沙箱场景
   ): Promise<ModLoaderInstallResult>
   ```

2. `DownloadTask` 创建独立沙箱: `tempMcDir = filesDir + '/forge-install-temp/<sessionId>'`, 在那里下载原版 + 跑 installer:
   - `tempMcDir/versions/{gameVersion}/<g>.jar`
   - `tempMcDir/versions/{g}-forge-{l}/<x>.json`
   - `tempMcDir/libraries/...`
   - `forgeService.install(gameVersion, loaderVersion, tempMcDir, cb, filesDir)` — 传入真实 filesDir 让 ForgeService 找 JDK.

3. Phase 6 合并时 (基于 SandboxProbe 真机数据, 见下文):
   - 输出 JSON: `mcDir/versions/{versionName}/{versionName}.json` (同现状)
   - **rename 原版 jar**: `tempMcDir/versions/{gameVersion}/<g>.jar` → `mcDir/versions/{versionName}/{versionName}.jar` (50 MB 实测 1 ms, O(1) 元数据)
   - **rename libraries 增量**: 对每个 `tempMcDir/libraries/<groupId>/<artifactId>/<version>/<jar>`, 若 `mcDir` 对应路径不存在则 rename, 存在则 unlink temp
   - **可选优化**: 若 `mcDir/libraries` 整目录不存在 (首次装 Forge), 一次性 `fs.renameSync(tempMcDir/libraries, mcDir/libraries)` (T8 实测 0 ms)

4. 完成后整个 `tempMcDir` 删除.

5. 可选: 在 `mcDir/versions/{versionName}/` 创建 `.amclpending` 标识文件, `Index.scanVersions` 跳过这种目录, 完成最后一步才删除.

**优点**:
- 彻底消除多余版本目录的产生路径
- 失败时整个临时目录可直接 `rm -rf`, 不污染用户 mcDir
- 与 PCL/HMCL 设计对齐, 未来加 NeoForge/OptiFine/LiteLoader 时不需要在每个 service 里重复清理逻辑
- libraries 也走临时目录, 减少失败时半下载文件污染 `mcDir/libraries`
- **沙箱→真实 mcDir 迁入是 O(1) 元数据操作**, 总耗时与方案 A 持平 (见下文探针报告)

**缺点**:
- 改动量较大: ForgeService 接口改、DownloadTask Phase 3-5 重写、Phase 6 加 libraries rename
- 沙箱目录会临时占用 \~65 MB (MC 1.20.4 ≈ 50 MB libraries + 15 MB client jar), 装完即清

**性能验证 (`@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\utils\SandboxProbe.ets`, 真机 hilog 2026-05-05 12:52:17)**:

| 工况 | 耗时 | 与 copy+unlink 对比 |
|---|---|---|
| 50 MB 单文件跨子目录 rename | **1 ms** | copy+unlink 47 ms, **47× 提速** |
| 200 个 64 KB 文件批量 rename | **5 ms** | copy+unlink 29 ms, **5.8× 提速** |
| 整目录 (10 子文件) rename | **0 ms** | — (一次性元数据切换) |
| rename 覆盖目标 | **0 ms** | 行为正确, 原子覆盖 |

→ 鸿蒙 `@kit.CoreFileKit.fileIo.renameSync` **在 app 沙箱内跨目录是真正的 O(1) 元数据操作** (同设备/同分区), 这意味着方案 B 原本最大的性能顾虑(N 次 IO 拖慢安装)**不存在**.
→ libraries 迁入策略二选一: ① 整目录 rename (首次装) — 0 ms, ② per-jar rename 增量 — 几毫秒.

### 方案 C: 完全 patches 化 (HMCL 风格, 最理想但代价最大)

把当前的"合并 JSON 写入磁盘"改成"运行时合并 patches", 即 `version.json` 里存 `patches: [game, forge]` 数组, `LaunchProfileBuilder` 解析时合并. 这种重构会动到 `VersionParser` 和 `LaunchProfileBuilder`, 不在本次议题范围.

### 推荐 (2026-05-05 探针验证后修订)

**直接做方案 B**. 原本"先 A 后 B"是基于"libraries 迁入需要 N 次 copy 可能拖慢安装"的保守假设, 探针证明该假设不成立, 方案 B 在性能上等价于方案 A 但根除问题, 没有继续保留方案 A 路线的必要.

实施顺序 (建议拆 3 个 commit):

1. **P1 — ForgeService 解耦** (\~1 h)
   - `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\modloader\ForgeService.ets:install` 加 `filesDirOverride?: string`
   - 内部把 `filesDir = mcDir.substring(...)` 的硬编码改成"参数优先, 回退到旧推导"
   - `FabricService.install` 同步加同名参数 (用于一致性, 内部可空实现)
   - 验证: 不传新参数时, 既有调用路径 100% 兼容

2. **P2 — DownloadTask 沙箱化 + rename 迁入** (\~3 h)
   - 新增 `tempMcDir = filesDir + '/forge-install-temp/<sessionId>'`, 替代 Phase 5 写入真实 mcDir
   - Phase 5 把 client.jar / version.json 写到 `tempMcDir/versions/{gameVersion}/`, 而不是 `mcDir/versions/{gameVersion}/`
   - 调用 `forgeService.install(gameVersion, loaderVersion, tempMcDir, cb, filesDir)` (新签名)
   - Phase 6 合并完成后:
     - rename `tempMcDir/versions/{gameVersion}/<g>.jar` → `mcDir/versions/{versionName}/{versionName}.jar`
     - 若 `mcDir/libraries` 不存在 → 一次性 rename `tempMcDir/libraries` → `mcDir/libraries` (0 ms 路径)
     - 若已存在 → 递归遍历 `tempMcDir/libraries`, 不存在的文件 rename, 已存在的 unlink temp
   - finally: `removeDirRecursive(tempMcDir)`

3. **P3 — 防御措施** (\~1 h)
   - `Index.scanVersions` 跳过包含 `.amclpending` 标识文件的目录 (DownloadTask 在 P5 末尾创建, P6 末尾清除), 防御进程崩溃后留下的"半成品"
   - 删除当前的 `orphanVersionDirs` 清理 UI 入口 (沙箱化后不应再产生孤儿)

### 备选: 方案 A 仍可作为"零风险快速止血"路径

如果方案 B 在主分支推进过程中发现新问题需要快速回滚, 可以先 cherry-pick 一个 \~30 行的方案 A 补丁: 在 `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\DownloadTask.ets:Phase 6 末尾` 加清理代码, 删除 `mcDir/versions/{gameVersion}/` 与 `mcDir/versions/{gameVersion}-forge-{loaderVersion}/` (当它们与 `versionName` 不同时). 但不推荐作为最终形态.

---

## 7. 验证清单

修复后回归测试:

| 编号 | 操作 | 期望结果 |
|---|---|---|
| T1 | 全新安装 1.20.4 (无加载器), versionName=1.20.4 | `versions/` 下只有 `1.20.4/` |
| T2 | 全新安装 1.20.4-forge-49.0.0, 默认 versionName | `versions/` 下只有 `1.20.4-forge-49.0.0/`, 无 `1.20.4/` |
| T3 | 全新安装 1.20.4-forge, 自定义 versionName=`MyForge` | `versions/` 下只有 `MyForge/`, 无 `1.20.4/`, 无 `1.20.4-forge-49.0.0/` |
| T4 | 安装 1.20.4-fabric-0.16.10, 默认 versionName | `versions/` 下只有 `fabric-loader-0.16.10-1.20.4/` |
| T5 | 安装失败 (任意阶段), retry | 不残留 `1.20.4/`, 也不残留 `targetVersion/` |
| T6 | 装两个 Forge: 1.20.4-forge-49.0.0 + 1.20.4-forge-49.0.5 | 两个版本目录共存, libraries 共享, 不互相污染 |
| T7 | 装一个 Forge 后再装原版 1.20.4 (versionName=1.20.4) | `versions/1.20.4/` 含原版 jar, `versions/1.20.4-forge-49.0.0/` 不被破坏 |
| T8 | 启动版本隔离 + 进游戏后退出 | `versions/<ver>/saves`, `mods`, `config` 在该版本目录内 |

---

## 8. 关联文件清单 (供修复者参考)

| 文件 | 作用 | 是否需改动(方案 A) | 是否需改动(方案 B) |
|---|---|---|---|
| `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\DownloadTask.ets` | 安装编排 | ✅ Phase 6 后加清理 | ✅ Phase 3-6 重构沙箱 |
| `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\modloader\ForgeService.ets` | Forge installer 调用 | ❌ | ✅ 加 filesDirOverride 参数 |
| `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\modloader\FabricService.ets` | Fabric installer | ❌ | ⚠️ 同步调整接口签名(可保持兼容) |
| `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\VersionJsonMerger.ets` | JSON 合并 | ❌ | ❌ |
| `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\pages\Index.ets` | 版本扫描 | ❌ | ⚠️ 可选: 加 `.amclpending` 跳过 |
| `@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\LaunchProfileBuilder.ets` | 启动参数构建 | ❌ | ❌ |

---

## 9. 附录: 关键证据片段

### 9.1 BUG 触发点

`@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\DownloadTask.ets:541-553`

### 9.2 失败路径已有清理(成功路径缺失)

`@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\DownloadTask.ets:643-657`

### 9.3 版本扫描判定标准

`@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\pages\Index.ets:266-276`

### 9.4 默认 versionName 生成

`@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\components\VersionConfigPanel.ets:294-305`

### 9.5 ForgeService filesDir 推导(目录耦合源头)

`@d:\SystemDefalt\Desktop\123\Project\DevEcoStudioProjects\MyApplication\entry\src\main\ets\services\modloader\ForgeService.ets:175-176`

### 9.6 PCL2 临时 mcFolder 设计

`Plain Craft Launcher 2/Pages/PageDownload/ModDownloadLib.vb` 中 `McInstallLoader` 的 `TempMcFolder` 与 `MergeJson(VersionFolder, ...)`.

### 9.7 HMCL ForgeNewInstallTask

`HMCLCore/src/main/java/org/jackhuang/hmcl/download/forge/ForgeNewInstallTask.java` 的 `MINECRAFT_JAR = gameRepository.getVersionJar(version)` 和 `tempDir = Files.createTempDirectory("forge_installer")`.
