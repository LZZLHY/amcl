# 版本维护、详情与运行要求

### getLaunchChecks

读取当前实例预检阶段、具体检查和此次允许的选择。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getLaunchChecks' --args '{"arg1":"instance"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前业务目标实例","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `instance` 时，该值等于原请求的 `arg1`（instance）。

当请求参数为 `{"instance":"instance"}` 时：
- `{"state":"ready","instance":"instance","jdk":"21","choiceRef":"precheck-ref","actions":["cancel"],"checks":[{"check":"jit","title":"JIT 可执行内存","status":"running","fix":""},{"check":"jdk","title":"JDK 版本匹配","status":"pending","fix":""},{"check":"runtime","title":"运行时环境","status":"pending","fix":""},{"check":"files","title":"版本文件完整性","status":"pending","fix":""},{"check":"contract","title":"启动契约","status":"pending","fix":""},{"check":"assets","title":"游戏资源完整性","status":"pending","fix":""},{"check":"mod_install_state","title":"模组安装状态","status":"pending","fix":""}],"stage":"running"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","unknown","unavailable","busy"]},"reason":{"type":"string"},"choiceRef":{"type":"string","minLength":1},"actions":{"type":"array","items":{"type":"string"}},"checks":{"type":"array","items":{"type":"object","properties":{"check":{"type":"string"},"status":{"type":"string"}},"required":["check","status"]}},"stage":{"type":"string"},"instance":{"type":"string"},"jdk":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["instance","jdk","choiceRef","actions","checks","stage"]}}]}
```

### chooseLaunchCheckAction

按原预检的真实选择继续或取消。 需要在应用继续时通过 reason 区分授权或 JDK 管理；accepted 附带已提交的 choice。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'chooseLaunchCheckAction' --args '{"arg1":"instance","arg2":"failed-precheck-ref","arg3":"retry"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'chooseLaunchCheckAction' --args '{"arg1":"instance","arg2":"precheck-ref","arg3":"cancel"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前业务目标实例","maxLength":16384},"arg2":{"type":"string","description":"本次待确认选择的标识","maxLength":16384},"arg3":{"type":"string","description":"原表允许的决定","maxLength":16384,"enum":["cancel","automaticJdk","keepJdk","retry","jitHelp","installJdk","jdkManager","fix"]}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]}}
```

执行返回值

返回 `choice` 时，该值等于原请求的 `arg3`（choice）。

- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"jitGuide"}`
- `{"state":"cancelled"}`
当请求参数为 `{"instance":"instance","choiceRef":"failed-precheck-ref","choice":"retry"}` 时：
- `{"state":"accepted","choice":"retry"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["failed","needsUser","cancelled","accepted","unknown","unavailable","busy"]},"reason":{"type":"string"},"choice":{"type":"string","enum":["retry","automaticJdk","keepJdk","installJdk","fix"]}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"accepted"}}},"then":{"required":["choice"]}}]}
```

### getGraphicsRecovery

只读查询一次独立游戏启动后产生的原始及自动重试图形票据。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getGraphicsRecovery' --args '{"arg1":1}')
```

```json
{"type":"object","properties":{"arg1":{"type":"integer","description":"原始启动活动 ID"}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","attempts":[{"activityId":1731870000000,"rootActivityId":1731870000000,"attempt":0,"instance":"Fabric 1.21.1","retryProfile":"","failureCode":"","outcome":"unknown","stage":"","profile":"","savedOutcome":false}]}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"LAUNCHER_NOT_INTERACTIVE"}`
- `{"state":"initializing"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"attempts":[{"activityId":1731870000000,"rootActivityId":1731870000000,"attempt":0,"instance":"Fabric 1.21.1","retryProfile":"","failureCode":"","outcome":"unknown","stage":"","profile":"","savedOutcome":false}],"state":"ready"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","initializing","unknown","unavailable","busy"]},"reason":{"type":"string"},"attempts":{"type":"array","items":{"type":"object"}}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["attempts"]}},{"if":{"required":["state"],"properties":{"state":{"const":"ready"}}},"then":{"required":["attempts"],"properties":{"attempts":{"minItems":1}}}}]}
```

### showCatalogVersion

从游戏目录选择明确版本打开安装详情。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'showCatalogVersion' --args '{"arg1":"1.21.1"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"真实清单中的版本","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `gameVersion` 时，该值等于原请求的 `arg1`（gameVersion）。

- `{"state":"failed","reason":"invalidArguments"}`
当请求参数为 `{"gameVersion":"1.21.1"}` 时：
- `{"state":"needsUser","reason":"versionDetailOpened","gameVersion":"1.21.1"}`
- `{"state":"initializing"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
当请求参数为 `{"gameVersion":"1.21.1"}` 时：
- `{"gameVersion":"1.21.1","state":"needsUser","reason":"versionDetailOpened"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["failed","needsUser","initializing","unknown","unavailable","busy"]},"reason":{"type":"string"},"gameVersion":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"required":["state","reason"],"properties":{"state":{"const":"needsUser"},"reason":{"const":"versionDetailOpened"}}},"then":{"required":["gameVersion"],"properties":{}}}]}
```

### getGameVersionRequirements

读取已打开的游戏安装详情中的 Wiki 说明、JDK/JIT、加载器及 Vulkan 提示。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getGameVersionRequirements' --args '{"arg1":"1.21.1"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"showCatalogVersion 已打开的版本","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `gameVersion` 时，该值等于原请求的 `arg1`（gameVersion）。

当请求参数为 `{"gameVersion":"1.21.1"}` 时：
- `{"state":"ready","gameVersion":"1.21.1","category":"release","description":"","descriptionLoaded":true,"runtimeJdk":21,"installedJdk":[21],"loaders":[{"type":"vanilla","supported":true,"runtimeJdk":0,"installerJdk":0},{"type":"fabric","supported":true,"runtimeJdk":0,"installerJdk":0},{"type":"forge","supported":true,"runtimeJdk":21,"installerJdk":21},{"type":"neoforge","supported":true,"runtimeJdk":21,"installerJdk":21},{"type":"quilt","supported":false,"runtimeJdk":0,"installerJdk":0}],"jitAvailable":true,"vulkan":"","vulkanStatus":"notApplicable"}`
- `{"state":"failed","reason":"invalidArguments"}`
当请求参数为 `{"gameVersion":"1.21.1"}` 时：
- `{"state":"initializing","gameVersion":"1.21.1","category":"release","description":"","descriptionLoaded":false,"runtimeJdk":21,"installedJdk":[21],"loaders":[{"type":"vanilla","supported":true,"runtimeJdk":0,"installerJdk":0},{"type":"fabric","supported":true,"runtimeJdk":0,"installerJdk":0},{"type":"forge","supported":true,"runtimeJdk":21,"installerJdk":21},{"type":"neoforge","supported":true,"runtimeJdk":21,"installerJdk":21},{"type":"quilt","supported":false,"runtimeJdk":0,"installerJdk":0}],"jitAvailable":true,"vulkan":"","vulkanStatus":"notApplicable"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
当请求参数为 `{"gameVersion":"1.21.1"}` 时：
- `{"gameVersion":"1.21.1","category":"release","description":"","descriptionLoaded":true,"runtimeJdk":21,"installedJdk":[21],"loaders":[{"type":"vanilla","supported":true,"runtimeJdk":0,"installerJdk":0},{"type":"fabric","supported":true,"runtimeJdk":0,"installerJdk":0},{"type":"forge","supported":true,"runtimeJdk":21,"installerJdk":21},{"type":"neoforge","supported":true,"runtimeJdk":21,"installerJdk":21},{"type":"quilt","supported":false,"runtimeJdk":0,"installerJdk":0}],"jitAvailable":true,"vulkan":"","vulkanStatus":"notApplicable","state":"ready"}`
当请求参数为 `{"gameVersion":"1.21.1"}` 时：
- `{"gameVersion":"1.21.1","category":"release","description":"","descriptionLoaded":false,"runtimeJdk":21,"installedJdk":[21],"loaders":[{"type":"vanilla","supported":true,"runtimeJdk":0,"installerJdk":0},{"type":"fabric","supported":true,"runtimeJdk":0,"installerJdk":0},{"type":"forge","supported":true,"runtimeJdk":21,"installerJdk":21},{"type":"neoforge","supported":true,"runtimeJdk":21,"installerJdk":21},{"type":"quilt","supported":false,"runtimeJdk":0,"installerJdk":0}],"jitAvailable":true,"vulkan":"","vulkanStatus":"notApplicable","state":"initializing"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","initializing","unknown","unavailable","busy"]},"reason":{"type":"string"},"description":{"type":"string"},"descriptionLoaded":{"type":"boolean"},"runtimeJdk":{"type":"integer"},"loaders":{"type":"array","items":{"type":"object"}},"vulkan":{"type":"string"},"gameVersion":{"type":"string"},"category":{"type":"string"},"installedJdk":{"type":"array","items":{"type":"integer"}},"jitAvailable":{"type":"boolean"},"vulkanStatus":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["gameVersion","category","description","descriptionLoaded","runtimeJdk","installedJdk","loaders","jitAvailable","vulkan","vulkanStatus"]}},{"if":{"properties":{"state":{"const":"initializing"}}},"then":{"required":["gameVersion","category","description","descriptionLoaded","runtimeJdk","installedJdk","loaders","jitAvailable","vulkan","vulkanStatus"]}},{"if":{"required":["state"],"properties":{"state":{"const":"ready"}}},"then":{"required":["descriptionLoaded","loaders"],"properties":{"descriptionLoaded":{"const":true},"loaders":{"minItems":5}}}},{"if":{"required":["state"],"properties":{"state":{"const":"initializing"}}},"then":{"required":["descriptionLoaded","loaders"],"properties":{"descriptionLoaded":{"const":false},"loaders":{"minItems":5}}}}]}
```

### listActivityHistory

搜索或刷新真实活动账本，按首页分类返回当日统计、总数和当前页。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'listActivityHistory' --args '{}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'listActivityHistory' --args '{"arg1":"","arg2":"","arg3":0}')
```

```json
{"type":"object","properties":{"arg1":{"type":["string"],"description":"过滤条件","maxLength":16384,"enum":["all","game","download","export","abnormal",""]},"arg2":{"type":["string"],"description":"过滤文本","maxLength":16384},"arg3":{"anyOf":[{"type":"integer"},{"const":""}],"description":"分页起点"},"arg4":{"anyOf":[{"type":"boolean"},{"const":""}],"description":"是否重新加载"}},"required":[],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"]}}
```

执行返回值

返回 `offset` 时，该值等于原请求的 `arg3`（offset）。

当请求参数为 `{"offset":0}` 时：
- `{"state":"ready","records":[],"offset":0,"count":0,"today":{"total":0,"done":0,"failed":0,"interrupted":0},"localLogBytes":0}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"historyBusy"}`
- `{"state":"initializing"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","initializing","unknown","unavailable","busy"]},"reason":{"type":"string"},"records":{"type":"array","items":{"type":"object","properties":{"activityId":{"type":"integer"},"title":{"type":"string"},"category":{"type":"string"},"status":{"type":"string"},"hasEvidence":{"type":"boolean"}},"required":["activityId","title","category","status","hasEvidence"]}},"offset":{"type":"integer"},"count":{"type":"integer"},"today":{"type":"object","properties":{"total":{"type":"integer"},"done":{"type":"integer"},"failed":{"type":"integer"},"interrupted":{"type":"integer"}},"required":["total","done","failed","interrupted"]},"localLogBytes":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["records","offset","count","today","localLogBytes"]}}]}
```

### openHistoryRecord

打开原活动对应的详情、日志、导出、分享面板或错误结果。核对当前选中活动或已到达的路由与原业务参数。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'openHistoryRecord' --args '{"arg1":1731870000000,"arg2":"overview"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"integer","description":"已列出的活动 ID"},"arg2":{"type":"string","description":"处理方式","maxLength":16384,"enum":["overview","error","log","exportResult","share","customShare"]}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `activityId` 时，该值等于原请求的 `arg1`（activityId）。

- `{"state":"failed","reason":"invalidArguments"}`
当请求参数为 `{"activityId":1731870000000,"action":"overview"}` 时：
- `{"state":"needsUser","reason":"continueInLauncher","activityId":1731870000000,"destinationReached":true}`
- `{"state":"initializing"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
当请求参数为 `{"activityId":1731870000000,"action":"overview"}` 时：
- `{"activityId":1731870000000,"destinationReached":true,"state":"needsUser","reason":"continueInLauncher"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["failed","needsUser","initializing","unknown","unavailable","busy"]},"reason":{"type":"string"},"activityId":{"type":"integer"},"destinationReached":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"required":["state","reason"],"properties":{"state":{"const":"needsUser"},"reason":{"const":"continueInLauncher"}}},"then":{"required":["activityId","destinationReached"],"properties":{"destinationReached":{"const":true}}}}]}
```

### manageActivityHistory

在产品界面管理日志占用、分享记录，或经确认清空本地账本。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'manageActivityHistory' --args '{"arg1":"storage"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"管理选择","maxLength":16384,"enum":["storage","shares","clear"]}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"manageActivityHistory","operationRef":"current-operation"}`
- `{"state":"initializing"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","initializing","unknown","unavailable","busy"]},"reason":{"type":"string"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"manageActivityHistory"}},"required":["operationRef","method"]}}]}
```

### inspectGameInstance

核对实际安装的游戏与加载器身份；旧原版可提供预期游戏版本以校验清单和客户端。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'inspectGameInstance' --args '{"arg1":"Fabric 1.21.1"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"本地实例名称","maxLength":16384},"arg2":{"type":["string"],"description":"核验旧版元数据的可选游戏版本","maxLength":16384}},"required":["arg1"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `instance` 时，该值等于原请求的 `arg1`（instance）。

当请求参数为 `{"instance":"Fabric 1.21.1"}` 时：
- `{"state":"ready","instance":"Fabric 1.21.1","gameVersion":"1.21.1","loader":"fabric","loaderVersion":"0.16.10"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"LAUNCHER_NOT_INTERACTIVE"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","unknown","failed","needsUser","initializing","unavailable","busy"]},"reason":{"type":"string"},"instance":{"type":"string"},"gameVersion":{"type":"string"},"loader":{"type":"string"},"loaderVersion":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["instance","gameVersion"]}}]}
```

### focusRunningGame

用户明确要返回当前正在运行的游戏时，复用启动器原有聚焦操作。仅请求把已有游戏带到前台，不创建新的 JVM。要打开指定实例请使用 launchGameInstance。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'focusRunningGame' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"accepted","reason":"existingWindowFocusRequested"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"LAUNCHER_NOT_INTERACTIVE"}`
- `{"state":"initializing"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["accepted","failed","needsUser","initializing","busy","unavailable","unknown"]},"reason":{"type":"string"}},"additionalProperties":true}
```

### getTaskControlOperation

查询暂停、恢复、重试、取消或包选项确认的原操作。按原行引用或确认引用查询；实际出队、调度拒绝、选择已提交和自然终态分别报告。 使用原操作返回的 operationRef；如是等待用户时收到的临时引用，应先用 getLauncherHandoff 读取原业务结果。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getTaskControlOperation' --args '{"arg1":"7cc6a8e9-e662-477a-b58a-000000000003"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"控制返回的操作号；回包丢失时等于原任务行 ref 或本轮 choiceRef。","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `operationRef` 时，该值等于原请求的 `arg1`（operationRef）。

当请求参数为 `{"operationRef":"7cc6a8e9-e662-477a-b58a-000000000003"}` 时：
- `{"state":"ready","operationRef":"7cc6a8e9-e662-477a-b58a-000000000003","taskId":"mc:Fabric 1.21.1","activityId":1731870000000,"outcome":"returned","originalActivityId":1731870000000,"selectedTaskId":"mc:Fabric 1.21.1","action":"pause","started":true,"choiceState":"notApplicable","phase":"paused"}`
当请求参数为 `{"operationRef":"7cc6a8e9-e662-477a-b58a-000000000003"}` 时：
- `{"state":"accepted","operationRef":"7cc6a8e9-e662-477a-b58a-000000000003","taskId":"mc:Fabric 1.21.1","activityId":1731870000000,"outcome":"pending","originalActivityId":1731870000000,"selectedTaskId":"mc:Fabric 1.21.1","action":"pause","started":true,"choiceState":"notApplicable","phase":"downloading"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
当请求参数为 `{"operationRef":"7cc6a8e9-e662-477a-b58a-000000000003"}` 时：
- `{"operationRef":"7cc6a8e9-e662-477a-b58a-000000000003","taskId":"mc:Fabric 1.21.1","activityId":1731870000000,"outcome":"pending","originalActivityId":1731870000000,"selectedTaskId":"mc:Fabric 1.21.1","action":"pause","started":true,"choiceState":"notApplicable","phase":"downloading","state":"accepted"}`
当请求参数为 `{"operationRef":"7cc6a8e9-e662-477a-b58a-000000000003"}` 时：
- `{"operationRef":"7cc6a8e9-e662-477a-b58a-000000000003","taskId":"mc:Fabric 1.21.1","activityId":1731870000000,"outcome":"returned","originalActivityId":1731870000000,"selectedTaskId":"mc:Fabric 1.21.1","action":"pause","started":true,"choiceState":"notApplicable","phase":"paused","state":"ready"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","accepted","failed","unknown","initializing","unavailable","busy"]},"reason":{"type":"string"},"operationRef":{"type":"string"},"selectedTaskId":{"type":"string"},"originalActivityId":{"type":"integer"},"taskId":{"type":"string"},"activityId":{"type":"integer"},"action":{"type":"string"},"started":{"type":"boolean"},"choiceState":{"type":"string"},"outcome":{"type":"string"},"phase":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["operationRef","taskId","activityId","outcome","originalActivityId","selectedTaskId","action","started","choiceState","phase"]}},{"if":{"properties":{"state":{"const":"accepted"}}},"then":{"required":["operationRef","taskId","activityId","outcome","originalActivityId","selectedTaskId","action","started","choiceState","phase"]}},{"if":{"required":["state"],"properties":{"state":{"const":"accepted"}}},"then":{"required":["outcome"],"properties":{"outcome":{"const":"pending"}}}},{"if":{"required":["state"],"properties":{"state":{"const":"ready"}}},"then":{"required":["outcome"],"properties":{"outcome":{"const":"returned"}}}}]}
```
