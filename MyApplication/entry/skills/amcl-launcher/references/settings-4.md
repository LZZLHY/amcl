# 更新进度、设置交接与文件选择结果

### updateAccountAccess

查看或检查华为开发者授权，由用户在产品真实登录界面完成授权。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'updateAccountAccess' --args '{"arg1":"inspect"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"按当前状态选择的操作","maxLength":16384,"enum":["inspect","check","login","retry","close"]}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","authorization":"missing","checking":false,"loginVisible":false,"needsLogin":true}`
- `{"state":"needsUser","reason":"developerLogin"}`
- `{"state":"cancelled"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","needsUser","cancelled","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"authorization":{"type":"string"},"checking":{"type":"boolean"},"loginVisible":{"type":"boolean"},"needsLogin":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["authorization"]}}]}
```

### getActiveLauncherUpdate

读取已打开更新事务的原活动、阶段、连接与进度。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getActiveLauncherUpdate' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","activityId":42,"phase":"running","version":"1.0.8-pre2","progress":0,"checkingConnection":false,"connectionReady":false,"loginVisible":false,"needsLogin":false,"recovery":"none","failedPhase":"","canContinue":false}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"activityId":{"type":"integer"},"phase":{"type":"string"},"version":{"type":"string"},"progress":{"type":"number"},"checkingConnection":{"type":"boolean"},"connectionReady":{"type":"boolean"},"needsLogin":{"type":"boolean"},"loginVisible":{"type":"boolean"},"recovery":{"type":"string"},"failedPhase":{"type":"string"},"canContinue":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["activityId","phase","version","progress","checkingConnection","connectionReady","loginVisible","needsLogin","recovery","failedPhase","canContinue"]}}]}
```

### controlActiveLauncherUpdate

只对读到的原活动和阶段展示详情、接力到无线设置、重查或确认继续/退出。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'controlActiveLauncherUpdate' --args '{"arg1":42,"arg2":"running","arg3":"retryConnection"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'controlActiveLauncherUpdate' --args '{"arg1":42,"arg2":"running","arg3":"manualPort"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"integer","description":"原活动号"},"arg2":{"type":"string","description":"getActiveLauncherUpdate返回的原阶段","maxLength":16384},"arg3":{"type":"string","description":"按当前状态选择的操作","maxLength":16384,"enum":["details","viewActivity","manualPort","retryConnection","wirelessSettings","continue","close"]}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]}}
```

执行返回值

返回 `activityId` 时，该值等于原请求的 `arg1`（activityId）。

- `{"state":"needsUser","reason":"awaitingUser","method":"controlActiveLauncherUpdate","operationRef":"current-operation"}`
当请求参数为 `{"activityId":42,"phase":"running","operation":"retryConnection"}` 时：
- `{"state":"accepted","activityId":42}`
- `{"state":"cancelled"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","accepted","cancelled","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"activityId":{"type":"integer"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"accepted"}}},"then":{"required":["activityId"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"controlActiveLauncherUpdate"}},"required":["operationRef","method"]}}]}
```

### navigateLauncherSettings

在实际设置页返回、清除搜索或浏览当前可见的设置分区。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'navigateLauncherSettings' --args '{"arg1":"overview"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"overview、back、clearSearch 或 findLauncherSettings 返回的分区","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","section":"overview","editorOpen":false}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"section":{"type":"string"},"editorOpen":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["section","editorOpen"]}}]}
```

### readSettingHandoff

按原引用回读人工 JVM 编辑或存储迁移／切换结果，保留取消和失败。 存储请求返回 requestedTarget（请求指定时）和 selectedTarget（用户提交后）；changedTarget 表示用户成功保存了不同位置。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readSettingHandoff' --args '{"arg1":"editor-1"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"openLauncherSetting 或 prepareStorageChange 返回的当前编辑引用","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `reference` 时，该值等于原请求的 `arg1`（reference）。

当请求参数为 `{"reference":"editor-1"}` 时：
- `{"state":"ready","reference":"editor-1","item":"storage","outcome":"waiting"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
当请求参数为 `{"reference":"editor-1"}` 时：
- `{"reference":"editor-1","item":"storage","outcome":"changedTarget","requestedTarget":"external","selectedTarget":"sandbox","state":"ready"}`
当请求参数为 `{"reference":"editor-1"}` 时：
- `{"reference":"editor-1","item":"storage","outcome":"saved","selectedTarget":"sandbox","state":"ready","requestedTarget":"sandbox"}`
当请求参数为 `{"reference":"editor-1"}` 时：
- `{"reference":"editor-1","item":"storage","outcome":"changedTarget","selectedTarget":"external","state":"ready","requestedTarget":"sandbox"}`
当请求参数为 `{"reference":"editor-1"}` 时：
- `{"reference":"editor-1","item":"storage","outcome":"saved","selectedTarget":"external","state":"ready","requestedTarget":"external"}`
当请求参数为 `{"reference":"editor-1"}` 时：
- `{"reference":"editor-1","item":"storage","outcome":"changedTarget","selectedTarget":"sandbox","state":"ready","requestedTarget":"external"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"item":{"type":"string"},"reference":{"type":"string"},"outcome":{"enum":["waiting","saving","saved","submitted","unconfirmed","cancelled","permissionDenied","unavailable","failed","changedTarget"],"type":"string"},"requestedTarget":{"type":"string","enum":["sandbox","external"]},"selectedTarget":{"type":"string","enum":["sandbox","external"]}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["reference","item","outcome"]}},{"if":{"required":["outcome","state"],"properties":{"outcome":{"const":"changedTarget"},"state":{"const":"ready"}}},"then":{"required":["requestedTarget","selectedTarget","item","reference"],"properties":{"item":{"const":"storage"},"state":{"const":"ready"}}}},{"if":{"required":["state","outcome","requestedTarget"],"properties":{"state":{"const":"ready"},"outcome":{"const":"saved"},"requestedTarget":{"const":"sandbox"}}},"then":{"required":["item","selectedTarget","reference"],"properties":{"item":{"const":"storage"},"selectedTarget":{"const":"sandbox"}}}},{"if":{"required":["state","outcome","requestedTarget"],"properties":{"state":{"const":"ready"},"outcome":{"const":"changedTarget"},"requestedTarget":{"const":"sandbox"}}},"then":{"required":["item","selectedTarget","reference"],"properties":{"item":{"const":"storage"},"selectedTarget":{"const":"external"}}}},{"if":{"required":["state","outcome","requestedTarget"],"properties":{"state":{"const":"ready"},"outcome":{"const":"saved"},"requestedTarget":{"const":"external"}}},"then":{"required":["item","selectedTarget","reference"],"properties":{"item":{"const":"storage"},"selectedTarget":{"const":"external"}}}},{"if":{"required":["state","outcome","requestedTarget"],"properties":{"state":{"const":"ready"},"outcome":{"const":"changedTarget"},"requestedTarget":{"const":"external"}}},"then":{"required":["item","selectedTarget","reference"],"properties":{"item":{"const":"storage"},"selectedTarget":{"const":"sandbox"}}}}]}
```

### copyLauncherDiagnostic

经用户确认后由原启动器将脱敏应用日志摘要复制到系统剪贴板。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'copyLauncherDiagnostic' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","copied":true}`
- `{"state":"cancelled"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"copyLauncherDiagnostic","operationRef":"current-operation"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","cancelled","failed","needsUser","busy","unavailable","unknown"]},"reason":{"type":"string"},"copied":{"type":"boolean"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["copied"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"copyLauncherDiagnostic"}},"required":["operationRef","method"]}}]}
```

### getUpdateNotice

查看当前 App／JDK 联合更新提醒及可选运行时；不发起更新。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getUpdateNotice' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","reference":"mxy1k8so-1","required":false,"version":"稳定通道","items":[{"id":"17","title":"JDK 17","current":"旧安装","target":"jdk17-build-1","selected":true}]}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"reference":{"type":"string","minLength":1},"required":{"type":"boolean"},"version":{"type":"string"},"items":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"title":{"type":"string"},"current":{"type":"string"},"target":{"type":"string"},"selected":{"type":"boolean"}},"required":["id","title","current","target","selected"]}}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["reference","required","version","items"]}}]}
```

### chooseRuntimeUpdateItem

绑定当前可选 JDK 提示与槽位，选择或取消一项，最终安装由用户确认。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'chooseRuntimeUpdateItem' --args '{"arg1":"mxy1k8so-1","arg2":"17","arg3":false}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"getUpdateNotice 返回的本次提示引用","maxLength":16384},"arg2":{"type":"string","description":"当前可选运行时 ID","maxLength":16384},"arg3":{"type":"boolean","description":"是否选中"}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]}}
```

执行返回值

返回 `reference` 时，该值等于原请求的 `arg1`（reference）。

当请求参数为 `{"reference":"mxy1k8so-1","id":"17","selected":false}` 时：
- `{"state":"ready","reference":"mxy1k8so-1","selected":[]}`
- `{"state":"failed","reason":"itemChanged"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"reference":{"type":"string","minLength":1},"selected":{"type":"array","items":{"type":"string"}}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["reference","selected"]}}]}
```

### answerUpdateNotice

暂缓当前提示或展示详细目标给用户确认，保留产品必要更新的准入条件。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'answerUpdateNotice' --args '{"arg1":"mxy1k8so-1","arg2":"review"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'answerUpdateNotice' --args '{"arg1":"mxy1k8so-1","arg2":"later"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"getUpdateNotice 返回的提示引用","maxLength":16384},"arg2":{"type":"string","description":"用户意图","maxLength":16384,"enum":["later","review"]}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `reference` 时，该值等于原请求的 `arg1`（reference）。

- `{"state":"ready","outcome":"postponed","required":false}`
当请求参数为 `{"reference":"mxy1k8so-1","answer":"review"}` 时：
- `{"state":"needsUser","reason":"confirmDisplayedTarget","reference":"mxy1k8so-1"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
当请求参数为 `{"reference":"mxy1k8so-1","answer":"review"}` 时：
- `{"reason":"confirmDisplayedTarget","reference":"mxy1k8so-1","state":"needsUser"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","needsUser","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"reference":{"type":"string","minLength":1},"required":{"type":"boolean"},"outcome":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["outcome","required"]}},{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["reason","reference"]}},{"if":{"required":["state","reason"],"properties":{"state":{"const":"needsUser"},"reason":{"const":"confirmDisplayedTarget"}}},"then":{"required":["reference"],"properties":{}}}]}
```

### readJavaArchiveImport

从本次选择引用回读系统JDK导入的取消、失败或真实槽结果。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readJavaArchiveImport' --args '{"arg1":"picker-1"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"pickJavaRuntimeArchive 返回的本次选择器引用","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"waiting"}`
- `{"state":"ready","major":"17"}`
- `{"state":"cancelled","major":"17"}`
- `{"state":"failed","reason":"importExpired"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["waiting","ready","cancelled","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"major":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["major"]}}]}
```

### readUpdatePackageSelection

按原引用从任意启动器页面查询本地 HAP 是否已转交更新流程，重启后可查最近终态。读取不会再次打开选择器或发起安装。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readUpdatePackageSelection' --args '{"arg1":"picker-1"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"openUpdateSource(localPackage) 返回的本次选择引用","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"waiting"}`
- `{"state":"accepted","target":"v1.0.8:1000912:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}`
- `{"state":"cancelled"}`
- `{"state":"failed","reason":"selectionExpired"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["waiting","accepted","cancelled","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"target":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"accepted"}}},"then":{"required":["target"]}}]}
```
