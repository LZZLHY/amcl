# 版本安装、启动、存档与文件

### listGameCatalog

查询产品的远程游戏版本清单，带分类、搜索与刷新。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'listGameCatalog' --args '{}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'listGameCatalog' --args '{"arg1":"","arg2":"","arg3":0}')
```

```json
{"type":"object","properties":{"arg1":{"type":["string"],"description":"版本搜索词","maxLength":16384},"arg2":{"type":["string"],"description":"版本分类","maxLength":16384,"enum":["all","release","old","snapshot","aprilfools",""]},"arg3":{"anyOf":[{"type":"integer"},{"const":""}],"description":"分页起点"},"arg4":{"anyOf":[{"type":"boolean"},{"const":""}],"description":"强制刷新"}},"required":[],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"]}}
```

执行返回值

返回 `offset` 时，该值等于原请求的 `arg3`（offset）。

当请求参数为 `{"offset":0}` 时：
- `{"state":"ready","versions":[{"id":"1.21.1","type":"release","date":"2024-08-08"}],"offset":0,"total":1}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"LAUNCHER_NOT_INTERACTIVE"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","initializing","unavailable","busy","unknown"]},"reason":{"type":"string"},"versions":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"type":{"type":"string"}},"required":["id","type"]}},"offset":{"type":"integer"},"total":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["versions","offset","total"]}}]}
```

### listGameLoaders

查询指定游戏版本的加载器类型或已发布加载器版本。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'listGameLoaders' --args '{"arg1":"1.21.1"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'listGameLoaders' --args '{"arg1":"1.21.1","arg2":"fabric"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'listGameLoaders' --args '{"arg1":"1.21.1","arg2":"forge"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'listGameLoaders' --args '{"arg1":"1.21.1","arg2":"neoforge"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"游戏版本 ID","maxLength":16384},"arg2":{"type":["string"],"description":"加载器类型","maxLength":16384,"enum":["fabric","forge","neoforge",""]}},"required":["arg1"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `gameVersion` 时，该值等于原请求的 `arg1`（gameVersion）。

当请求参数为 `{"gameVersion":"1.21.1"}` 时：
- `{"state":"ready","gameVersion":"1.21.1","supported":["fabric","forge","neoforge"]}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"LAUNCHER_NOT_INTERACTIVE"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
当请求参数为 `{"gameVersion":"1.21.1","loader":"fabric"}` 时：
- `{"gameVersion":"1.21.1","versions":[{"version":"0.16.10","stable":true}],"state":"ready"}`
当请求参数为 `{"gameVersion":"1.21.1","loader":"forge"}` 时：
- `{"gameVersion":"1.21.1","versions":[{"version":"51.0.33","stable":true}],"state":"ready"}`
当请求参数为 `{"gameVersion":"1.21.1","loader":"neoforge"}` 时：
- `{"gameVersion":"1.21.1","versions":[{"version":"21.1.42","stable":true}],"state":"ready"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","initializing","unavailable","busy","unknown"]},"reason":{"type":"string"},"supported":{"type":"array","items":{"type":"string"}},"versions":{"type":"array","items":{"type":"object"}},"gameVersion":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["gameVersion"]}}]}
```

### installGameInstance

安装清单中的版本至指定的新实例；受理后按原意图编号回读。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'installGameInstance' --args '{"arg1":"Fabric 1.21.1","arg2":"example-install-42","arg3":"1.21.1","arg4":"fabric","arg5":"0.16.10","arg6":false}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原实例名称","maxLength":16384},"arg2":{"type":"string","description":"本次意图的稳定编号，1–64 位字母数字、下划线或短横线；重试沿用。","maxLength":16384},"arg3":{"type":"string","description":"游戏版本 ID","maxLength":16384},"arg4":{"type":["string"],"description":"加载器类型","maxLength":16384,"enum":["vanilla","fabric","forge","neoforge",""]},"arg5":{"type":["string"],"description":"已列出的加载器版本","maxLength":16384},"arg6":{"anyOf":[{"type":"boolean"},{"const":""}],"description":"同时安装对应 Fabric API"}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"],"arg5":["arg1","arg2","arg3","arg4"],"arg6":["arg1","arg2","arg3","arg4","arg5"]}}
```

执行返回值

返回 `operationRef` 时，该值等于原请求的 `arg2`（operationRef）。

返回 `instance` 时，该值等于原请求的 `arg1`（instance）。

当请求参数为 `{"instance":"Fabric 1.21.1","operationRef":"example-install-42","gameVersion":"1.21.1","loader":"fabric","loaderVersion":"0.16.10","withFabricApi":false}` 时：
- `{"state":"accepted","operationRef":"example-install-42","taskId":"mc:Fabric 1.21.1","activityId":1731870000000}`
当请求参数为 `{"instance":"Fabric 1.21.1","operationRef":"example-install-42","gameVersion":"1.21.1","loader":"fabric","loaderVersion":"0.16.10","withFabricApi":false}` 时：
- `{"state":"ready","operationRef":"example-install-42","stage":"admitted","activityId":1731870000000,"taskId":"mc:Fabric 1.21.1","instance":"Fabric 1.21.1","reason":"","precheck":"","precheckState":"","fix":""}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"LAUNCHER_NOT_INTERACTIVE"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["accepted","ready","unknown","failed","needsUser","initializing","unavailable","busy"]},"reason":{"type":"string"},"operationRef":{"type":"string","minLength":1},"taskId":{"type":"string"},"activityId":{"type":"integer"},"stage":{"type":"string"},"instance":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"accepted"}}},"then":{"required":["operationRef","taskId","activityId"]}},{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["operationRef","stage","activityId","taskId","instance"]}}]}
```

### launchGameInstance

启动当前选择的实例并复用原预检；需要人工授权时显示原界面。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'launchGameInstance' --args '{"arg1":"Fabric 1.21.1","arg2":"example-launch-43"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原实例名称","maxLength":16384},"arg2":{"type":"string","description":"本次意图的稳定编号，1–64 位字母数字、下划线或短横线；重试沿用。","maxLength":16384}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `operationRef` 时，该值等于原请求的 `arg2`（operationRef）。

返回 `instance` 时，该值等于原请求的 `arg1`（instance）。

当请求参数为 `{"instance":"Fabric 1.21.1","operationRef":"example-launch-43"}` 时：
- `{"state":"ready","operationRef":"example-launch-43","instance":"Fabric 1.21.1","activityId":1731870000000,"taskId":"","stage":"dispatched","precheck":"","precheckState":"","fix":"","reason":""}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"LAUNCHER_NOT_INTERACTIVE"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","unknown","failed","needsUser","initializing","unavailable","busy"]},"reason":{"type":"string"},"operationRef":{"type":"string","minLength":1},"activityId":{"type":"integer"},"stage":{"type":"string"},"instance":{"type":"string"},"taskId":{"type":"string"},"precheck":{"type":"string"},"precheckState":{"type":"string"},"fix":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["operationRef","instance","activityId","taskId","stage","precheck","precheckState","fix"]}}]}
```

### getLauncherOperation

以原意图编号观察真实安装或启动进度和活动。 使用原操作返回的 operationRef；如是等待用户时收到的临时引用，应先用 getLauncherHandoff 读取原业务结果。 后继重试入队或出队后只回读原安装的活动。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getLauncherOperation' --args '{"arg1":"example-launch-43"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"本次意图的稳定编号，1–64 位字母数字、下划线或短横线；重试沿用。","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `operationRef` 时，该值等于原请求的 `arg1`（operationRef）。

当请求参数为 `{"operationRef":"example-launch-43"}` 时：
- `{"state":"ready","operationRef":"example-launch-43","instance":"Fabric 1.21.1","activityId":1731870000000,"taskId":"","stage":"dispatched","precheck":"","precheckState":"","fix":"","reason":""}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"operationNotFound"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","unknown","failed","initializing","unavailable","busy"]},"reason":{"type":"string"},"operationRef":{"type":"string"},"instance":{"type":"string","description":"取自该 operationRef 所绑定的原启动或安装记录。"},"activityId":{"type":"integer"},"taskId":{"type":"string"},"stage":{"type":"string"},"taskState":{"type":"string"},"activityState":{"type":"integer"},"precheck":{"type":"string"},"precheckState":{"type":"string"},"fix":{"type":"string"},"companionTaskId":{"type":"string"},"companionActivityId":{"type":"integer"},"companionState":{"type":"string"},"window":{"type":"object","properties":{"ownerPid":{"type":"integer"},"ownerAlive":{"type":"integer"},"windowId":{"type":"integer"},"visibility":{"enum":["attached","unobserved"]}}}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["operationRef","instance","activityId","taskId","stage","precheck","precheckState","fix"]}}]}
```

### listWorlds

列出指定实例的世界及有效性。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'listWorlds' --args '{"arg1":"Fabric 1.21.1"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原实例名称","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `instance` 时，该值等于原请求的 `arg1`（instance）。

当请求参数为 `{"instance":"Fabric 1.21.1"}` 时：
- `{"state":"ready","instance":"Fabric 1.21.1","folder":"02a38130-7fd7-4cf4-b09f-87f6cebd0681","shared":false,"entries":[]}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"panelBusy"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unavailable","busy","unknown"]},"reason":{"type":"string"},"folder":{"type":"string","minLength":1},"shared":{"type":"boolean"},"entries":{"type":"array","items":{"type":"object","properties":{"ref":{"type":"string"},"name":{"type":"string"}},"required":["ref","name"]}},"instance":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["instance","folder","shared","entries"]}}]}
```

### importWorlds

选择本地存档 ZIP 并导入当前目标。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'importWorlds' --args '{"arg1":"instance","arg2":"folder"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原实例名称","maxLength":16384},"arg2":{"type":"string","description":"本次目录查询返回的引用","maxLength":16384}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

- `{"state":"ready","imported":["Example World"],"failedCount":0}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"importWorlds","operationRef":"current-operation"}`
- `{"state":"partial","imported":["Example World"],"failedCount":1,"reason":"fileRejected"}`
- `{"state":"cancelled"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"imported":["Example World"],"failedCount":0,"state":"ready"}`
- `{"imported":["Example World"],"failedCount":1,"state":"partial","reason":"fileRejected"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","partial","cancelled","unavailable","busy","unknown"]},"reason":{"type":"string"},"imported":{"type":"array","items":{"type":"string"}},"failedCount":{"type":"integer"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["imported","failedCount"]}},{"if":{"properties":{"state":{"const":"partial"}}},"then":{"required":["imported","failedCount"]}},{"if":{"required":["state"],"properties":{"state":{"const":"ready"}}},"then":{"required":["imported","failedCount"],"properties":{"failedCount":{"const":0}}}},{"if":{"required":["state"],"properties":{"state":{"const":"partial"}}},"then":{"required":["imported","failedCount"],"properties":{"imported":{"minItems":1},"failedCount":{"minimum":1}}}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"importWorlds"}},"required":["operationRef","method"]}}]}
```

### exportWorld

通过系统保存器导出已选世界。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'exportWorld' --args '{"arg1":"instance","arg2":"folder","arg3":"ref"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原实例名称","maxLength":16384},"arg2":{"type":"string","description":"本次目录查询返回的引用","maxLength":16384},"arg3":{"type":"string","description":"本次目录查询返回的行引用","maxLength":16384}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]}}
```

执行返回值

- `{"state":"ready","exported":"Example World.zip"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"exportWorld","operationRef":"current-operation"}`
- `{"state":"cancelled"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","cancelled","unavailable","busy","unknown"]},"reason":{"type":"string"},"exported":{"type":"string"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["exported"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"exportWorld"}},"required":["operationRef","method"]}}]}
```

### requestWorldDeletion

用户确认所选世界与目录后，通过原存档管理流程删除并核实结果。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'requestWorldDeletion' --args '{"arg1":"instance","arg2":"folder","arg3":"ref"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原实例名称","maxLength":16384},"arg2":{"type":"string","description":"本次目录查询返回的引用","maxLength":16384},"arg3":{"type":"string","description":"本次目录查询返回的行引用","maxLength":16384}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]}}
```

执行返回值

- `{"state":"ready","removed":"Example World","shared":false}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"requestWorldDeletion","operationRef":"current-operation"}`
- `{"state":"cancelled"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","cancelled","unavailable","busy","unknown"]},"reason":{"type":"string"},"removed":{"type":"string"},"shared":{"type":"boolean"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["removed","shared"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"requestWorldDeletion"}},"required":["operationRef","method"]}}]}
```

### listInstanceFiles

浏览当前实例文件夹及条目引用。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'listInstanceFiles' --args '{"arg1":"Fabric 1.21.1"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原实例名称","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `instance` 时，该值等于原请求的 `arg1`（instance）。

当请求参数为 `{"instance":"Fabric 1.21.1"}` 时：
- `{"state":"ready","instance":"Fabric 1.21.1","folder":"02a38130-7fd7-4cf4-b09f-87f6cebd0681","segments":[],"shared":false,"entries":[]}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"panelBusy"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unavailable","busy","unknown"]},"reason":{"type":"string"},"folder":{"type":"string","minLength":1},"shared":{"type":"boolean"},"entries":{"type":"array","items":{"type":"object","properties":{"ref":{"type":"string"},"name":{"type":"string"}},"required":["ref","name"]}},"instance":{"type":"string"},"segments":{"type":"array","items":{"type":"string"}}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["instance","folder","segments","shared","entries"]}}]}
```

### navigateInstanceParent

回到已核实目录的父层。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'navigateInstanceParent' --args '{"arg1":"instance","arg2":"folder"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原实例名称","maxLength":16384},"arg2":{"type":"string","description":"本次目录查询返回的引用","maxLength":16384}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

- `{"state":"ready"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"panelBusy"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unavailable","busy","unknown"]},"reason":{"type":"string"}},"additionalProperties":true}
```

### createInstanceFolder

在已核实目录创建指定新文件夹。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'createInstanceFolder' --args '{"arg1":"instance","arg2":"folder","arg3":"screenshots"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原实例名称","maxLength":16384},"arg2":{"type":"string","description":"本次目录查询返回的引用","maxLength":16384},"arg3":{"type":"string","description":"新文件夹的纯名称","maxLength":16384}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]}}
```

执行返回值

返回 `created` 时，该值等于原请求的 `arg3`（name）。

当请求参数为 `{"instance":"instance","folder":"folder","name":"screenshots"}` 时：
- `{"state":"ready","created":"screenshots"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"panelBusy"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unavailable","busy","unknown"]},"reason":{"type":"string"},"created":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["created"]}}]}
```
