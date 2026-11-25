# 诊断、Java 版本与启动器更新

### openLauncherDiagnostic

在产品实际允许的情况下进入指定诊断页，界面内的探针由用户操作。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'openLauncherDiagnostic' --args '{"arg1":"vulkan"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"允许的诊断页面","maxLength":16384,"enum":["tools","gles","vulkan","input","desktop"]}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `tool` 时，该值等于原请求的 `arg1`（tool）。

当请求参数为 `{"tool":"vulkan"}` 时：
- `{"state":"needsUser","tool":"vulkan","reason":"performDiagnosticsInApp"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"tool":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["tool","reason"]}}]}
```

### readDiagnosticObservation

读取当前前台诊断页的摘要，不读取或传出完整控制台日志。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readDiagnosticObservation' --args '{"arg1":"gles"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readDiagnosticObservation' --args '{"arg1":"tools"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前前台诊断页面","maxLength":16384,"enum":["tools","gles","vulkan","input","desktop"]}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `page` 时，该值等于原请求的 `arg1`（tool）。

当请求参数为 `{"tool":"gles"}` 时：
- `{"state":"ready","page":"gles","running":false,"hasOutput":false,"status":""}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"page":{"type":"string"},"tool":{"type":"string"},"running":{"type":"boolean"},"status":{"type":"string"},"hasOutput":{"type":"boolean"},"vulkanAvailable":{"type":"boolean"},"paused":{"type":"boolean"},"events":{"type":"integer"},"verdict":{"type":"string"},"saved":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["page"]}}]}
```

### listJavaRuntimes

读取真实JDK目录及本机槽位；分别返回目录来源、最新刷新状态和槽数组，缓存或失败不会充当成功空目录。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'listJavaRuntimes' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","channel":"stable","checking":false,"importing":false,"slots":[{"major":"17","installed":false,"available":true,"imported":false,"repairRequired":false,"rollback":false,"updateAvailable":false,"running":false,"installedBuild":"","recommendedBuild":"jdk17-build-1"}],"catalogSource":"network","refreshState":"updated","catalogChannel":"stable","catalogRevision":1,"recommendationUsable":true,"refreshSerial":1}`
- `{"state":"initializing","channel":"stable","checking":true,"importing":false,"slots":[{"major":"17","installed":false,"available":true,"imported":false,"repairRequired":false,"rollback":false,"updateAvailable":false,"running":false,"installedBuild":"","recommendedBuild":"jdk17-build-1"}],"catalogSource":"verifiedSnapshot","refreshState":"refreshing","catalogChannel":"stable","catalogRevision":1,"recommendationUsable":true,"refreshSerial":1,"reason":"readingCatalog"}`
- `{"state":"unknown","reason":"noFreshCatalog","channel":"stable","checking":false,"importing":false,"slots":[{"major":"17","installed":false,"available":true,"imported":false,"repairRequired":false,"rollback":false,"updateAvailable":false,"running":false,"installedBuild":"","recommendedBuild":"jdk17-build-1"}],"catalogSource":"verifiedSnapshot","refreshState":"notRequested","catalogChannel":"stable","catalogRevision":1,"recommendationUsable":true,"refreshSerial":1}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","initializing","unknown","failed","busy","unavailable"]},"reason":{"type":"string"},"channel":{"type":"string"},"checking":{"type":"boolean"},"importing":{"type":"boolean"},"slots":{"type":"array","items":{"type":"object","properties":{"major":{"type":"string"},"installed":{"type":"boolean"},"available":{"type":"boolean"},"imported":{"type":"boolean"},"repairRequired":{"type":"boolean"},"rollback":{"type":"boolean"},"updateAvailable":{"type":"boolean"},"running":{"type":"boolean"},"installedBuild":{"type":"string"},"recommendedBuild":{"type":"string"}},"required":["major","installed","available","imported","repairRequired","rollback","updateAvailable","running","installedBuild","recommendedBuild"]}},"catalogSource":{"type":"string","enum":["builtin","verifiedSnapshot","network"],"description":"当前展示身份：随包目录、之前接受并保留的可信快照、或此代刷新取得的网络目录。"},"refreshState":{"type":"string","enum":["notRequested","configurationMismatch","loadingCache","refreshing","updated","failed"],"description":"当前配置代次的实际获取状态；刷新失败仍可展示内置槽和已核验缓存。"},"catalogChannel":{"type":"string","description":"展示快照实际所属的通道，可能与请求通道不同。"},"catalogRevision":{"type":"integer","description":"已显示目录的真实代次。"},"recommendationUsable":{"type":"boolean","description":"快照是否具备推荐资格，单个槽还需要通过原安装策略。"},"refreshSerial":{"type":"integer","description":"本进程仓库实际发起的刷新序号，不代表成功。"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["channel","checking","importing","slots","catalogSource","refreshState","catalogChannel","catalogRevision","recommendationUsable","refreshSerial"]}}]}
```

### refreshJavaRuntimes

对选中的通道发起实际目录刷新，并等原请求完成后回读同一可信代次；失败返回仍可见的本机槽，未发起或来源变化说明原因。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'refreshJavaRuntimes' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","channel":"stable","checking":false,"importing":false,"slots":[{"major":"17","installed":false,"available":true,"imported":false,"repairRequired":false,"rollback":false,"updateAvailable":false,"running":false,"installedBuild":"","recommendedBuild":"jdk17-build-1"}],"catalogSource":"network","refreshState":"updated","catalogChannel":"stable","catalogRevision":1,"recommendationUsable":true,"refreshSerial":1}`
- `{"state":"initializing","channel":"stable","checking":true,"importing":false,"slots":[{"major":"17","installed":false,"available":true,"imported":false,"repairRequired":false,"rollback":false,"updateAvailable":false,"running":false,"installedBuild":"","recommendedBuild":"jdk17-build-1"}],"catalogSource":"verifiedSnapshot","refreshState":"refreshing","catalogChannel":"stable","catalogRevision":1,"recommendationUsable":true,"refreshSerial":1,"reason":"readingCatalog"}`
- `{"state":"unknown","reason":"noFreshCatalog","channel":"stable","checking":false,"importing":false,"slots":[{"major":"17","installed":false,"available":true,"imported":false,"repairRequired":false,"rollback":false,"updateAvailable":false,"running":false,"installedBuild":"","recommendedBuild":"jdk17-build-1"}],"catalogSource":"verifiedSnapshot","refreshState":"notRequested","catalogChannel":"stable","catalogRevision":1,"recommendationUsable":true,"refreshSerial":1}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","initializing","unknown","failed","busy","unavailable"]},"reason":{"type":"string"},"channel":{"type":"string"},"checking":{"type":"boolean"},"importing":{"type":"boolean"},"slots":{"type":"array","items":{"type":"object","properties":{"major":{"type":"string"},"installed":{"type":"boolean"},"available":{"type":"boolean"},"imported":{"type":"boolean"},"repairRequired":{"type":"boolean"},"rollback":{"type":"boolean"},"updateAvailable":{"type":"boolean"},"running":{"type":"boolean"},"installedBuild":{"type":"string"},"recommendedBuild":{"type":"string"}},"required":["major","installed","available","imported","repairRequired","rollback","updateAvailable","running","installedBuild","recommendedBuild"]}},"catalogSource":{"type":"string","enum":["builtin","verifiedSnapshot","network"],"description":"当前展示身份：随包目录、之前接受并保留的可信快照、或此代刷新取得的网络目录。"},"refreshState":{"type":"string","enum":["notRequested","configurationMismatch","loadingCache","refreshing","updated","failed"],"description":"当前配置代次的实际获取状态；刷新失败仍可展示内置槽和已核验缓存。"},"catalogChannel":{"type":"string","description":"展示快照实际所属的通道，可能与请求通道不同。"},"catalogRevision":{"type":"integer","description":"已显示目录的真实代次。"},"recommendationUsable":{"type":"boolean","description":"快照是否具备推荐资格，单个槽还需要通过原安装策略。"},"refreshSerial":{"type":"integer","description":"本进程仓库实际发起的刷新序号，不代表成功。"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["channel","checking","importing","slots","catalogSource","refreshState","catalogChannel","catalogRevision","recommendationUsable","refreshSerial"]}}]}
```

### pickJavaRuntimeArchive

请求系统文件选择器导入本地JDK包，用户自己指定归属槽。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'pickJavaRuntimeArchive' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"needsUser","reason":"systemFilePicker","reference":"picker-1"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"reason":"systemFilePicker","reference":"picker-1","state":"needsUser"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"reference":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["reason","reference"]}},{"if":{"required":["state","reason"],"properties":{"state":{"const":"needsUser"},"reason":{"const":"systemFilePicker"}}},"then":{"required":["reference"],"properties":{}}}]}
```

### manageJavaRuntime

安装目录项或经确认替换、修复和删除指定槽，按原任务和目录回读。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'manageJavaRuntime' --args '{"arg1":"17","arg2":"install"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"从listJavaRuntimes返回的主版本","maxLength":16384},"arg2":{"type":"string","description":"按当前状态选择的操作","maxLength":16384,"enum":["install","replace","remove"]}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `major` 时，该值等于原请求的 `arg1`（major）。

当请求参数为 `{"major":"17","operation":"install"}` 时：
- `{"state":"accepted","major":"17","taskId":"jdk:17","activityId":42}`
- `{"state":"needsUser","reason":"awaitingUser","method":"manageJavaRuntime","operationRef":"current-operation"}`
- `{"state":"cancelled"}`
- `{"state":"failed","reason":"invalidArguments"}`
当请求参数为 `{"major":"17","operation":"install"}` 时：
- `{"state":"ready","major":"17","removed":true}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
当请求参数为 `{"major":"17","operation":"install"}` 时：
- `{"major":"17","removed":true,"state":"ready"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["accepted","needsUser","cancelled","failed","ready","unknown","busy","unavailable"]},"reason":{"type":"string"},"major":{"type":"string"},"taskId":{"type":"string"},"removed":{"type":"boolean"},"activityId":{"type":"integer","description":"生产队列为原任务分配的活动号；排队尚未分配时为0"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"accepted"}}},"then":{"required":["major","taskId","activityId"]}},{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["major","removed"]}},{"if":{"required":["state","removed"],"properties":{"state":{"const":"ready"},"removed":{"const":true}}},"then":{"required":["major"],"properties":{}}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"manageJavaRuntime"}},"required":["operationRef","method"]}}]}
```

### inspectNetwork

读取或重跑真实网络检测、按用户要求复制原诊断报告。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'inspectNetwork' --args '{"arg1":"copy"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'inspectNetwork' --args '{"arg1":"read"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"按当前状态选择的操作","maxLength":16384,"enum":["read","retry","copy"]}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

当请求参数为 `{"operation":"copy"}` 时：
- `{"state":"ready","copied":true}`
- `{"state":"accepted"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"failed","reason":"noReport"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
当请求参数为 `{"operation":"copy"}` 时：
- `{"copied":true,"state":"ready"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","accepted","busy","failed","unavailable","unknown"]},"reason":{"type":"string"},"verdict":{"type":"string"},"probes":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"status":{"type":"string"}}}},"copied":{"type":"boolean","description":"系统剪贴板是否确认写入本次报告。"}},"additionalProperties":true}
```

### getLauncherUpdate

读取侧载更新页当前版本、真实通道及推荐身份。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getLauncherUpdate' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","current":"1.0.7","currentCode":1000911,"channel":"stable","developer":false,"checking":false,"importing":false,"pending":false,"recommended":"","target":"","installable":false}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","unknown","busy","unavailable"]},"reason":{"type":"string"},"current":{"type":"string"},"channel":{"type":"string"},"developer":{"type":"boolean"},"checking":{"type":"boolean"},"importing":{"type":"boolean"},"pending":{"type":"boolean"},"recommended":{"type":"string"},"target":{"type":"string"},"installable":{"type":"boolean"},"currentCode":{"type":"integer","description":"系统 BMS 实际安装码，仅身份得到确认时返回"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["current","currentCode","channel","developer","checking","importing","pending","recommended","target","installable"]}}]}
```

### checkLauncherUpdate

按当前通道检查推荐，保留网络失败与开发者版主动选择限制。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'checkLauncherUpdate' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","current":"1.0.7","currentCode":1000911,"channel":"stable","developer":false,"checking":false,"importing":false,"pending":false,"recommended":"","target":"","installable":false}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","unknown","busy","unavailable"]},"reason":{"type":"string"},"current":{"type":"string"},"channel":{"type":"string"},"developer":{"type":"boolean"},"checking":{"type":"boolean"},"importing":{"type":"boolean"},"pending":{"type":"boolean"},"recommended":{"type":"string"},"target":{"type":"string"},"installable":{"type":"boolean"},"currentCode":{"type":"integer","description":"系统 BMS 实际安装码，仅身份得到确认时返回"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["current","currentCode","channel","developer","checking","importing","pending","recommended","target","installable"]}}]}
```

### selectLauncherUpdateChannel

选择稳定或预览更新订阅；开发者版按产品退出流程处理。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'selectLauncherUpdateChannel' --args '{"arg1":"stable"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"更新通道","maxLength":16384,"enum":["stable","preview"]}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `channel` 时，该值等于原请求的 `arg1`（channel）。

当请求参数为 `{"channel":"stable"}` 时：
- `{"state":"ready","current":"1.0.7","currentCode":1000911,"channel":"stable","developer":false,"checking":false,"importing":false,"pending":false,"recommended":"","target":"","installable":false}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","unknown","busy","unavailable"]},"reason":{"type":"string"},"current":{"type":"string"},"channel":{"type":"string"},"developer":{"type":"boolean"},"checking":{"type":"boolean"},"importing":{"type":"boolean"},"pending":{"type":"boolean"},"recommended":{"type":"string"},"target":{"type":"string"},"installable":{"type":"boolean"},"currentCode":{"type":"integer","description":"系统 BMS 实际安装码，仅身份得到确认时返回"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["current","currentCode","channel","developer","checking","importing","pending","recommended","target","installable"]}}]}
```

### openUpdateSource

打开正版发布页、系统本地HAP选择器或原先挂起的更新流程。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'openUpdateSource' --args '{"arg1":"officialReleasePage"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'openUpdateSource' --args '{"arg1":"previousAttempt"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'openUpdateSource' --args '{"arg1":"localPackage"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"更新来源","maxLength":16384,"enum":["officialReleasePage","localPackage","previousAttempt"]}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

当请求参数为 `{"source":"localPackage"}` 时：
- `{"state":"needsUser","reason":"systemFilePicker","reference":"picker-1"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
当请求参数为 `{"source":"localPackage"}` 时：
- `{"reason":"systemFilePicker","reference":"picker-1","state":"needsUser"}`
当请求参数为 `{"source":"localPackage"}` 时：
- `{"reason":"systemFilePicker","reference":"picker-1","state":"needsUser"}`
当请求参数为 `{"source":"officialReleasePage"}` 时：
- `{"reason":"browser","state":"needsUser"}`
当请求参数为 `{"source":"previousAttempt"}` 时：
- `{"reason":"existingUpdate","state":"needsUser"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"reference":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["reason"]}},{"if":{"required":["state","reason"],"properties":{"state":{"const":"needsUser"},"reason":{"const":"systemFilePicker"}}},"then":{"required":["reference"],"properties":{}}}]}
```

### installRecommendedUpdate

向用户展示已查到的确切候选，获得同意后进入原安装流程。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'installRecommendedUpdate' --args '{"arg1":"v1.0.8:1000912:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"getLauncherUpdate返回的当前候选引用","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `target` 时，该值等于原请求的 `arg1`（target）。

- `{"state":"needsUser","reason":"awaitingUser","method":"installRecommendedUpdate","operationRef":"current-operation"}`
- `{"state":"cancelled"}`
- `{"state":"failed","reason":"targetChanged"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
当请求参数为 `{"target":"v1.0.8:1000912:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}` 时：
- `{"target":"v1.0.8:1000912:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","state":"needsUser","reason":"updatePageOpened"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","cancelled","failed","unknown","busy","unavailable"]},"reason":{"type":"string"},"target":{"type":"string"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"required":["state","reason"],"properties":{"state":{"const":"needsUser"},"reason":{"const":"updatePageOpened"}}},"then":{"required":["target"],"properties":{}}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"installRecommendedUpdate"}},"required":["operationRef","method"]}}]}
```
