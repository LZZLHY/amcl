# 队列控制、整合包选择与资源来源

### continueModpackRecovery

从选定的原持久记录恢复。仅本次 adapter 实际入队才返回 accepted；旧卡需要用户检查。可用 getResourceInstall 按 operationRef 查询原结果。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'continueModpackRecovery' --args '{"arg1":"id"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"恢复记录 ID","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"existingTaskRequiresReview","taskId":"modpack:persistent-pack-42"}`
- `{"state":"accepted","operationRef":"02a38130-7fd7-4cf4-b09f-87f6cebd0681","taskId":"modpack:persistent-pack-42","activityId":1731870000000,"reason":"originalTaskAdmitted"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"taskId":"modpack:persistent-pack-42","state":"needsUser","reason":"existingTaskRequiresReview"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["failed","needsUser","accepted","unknown","unavailable","busy"]},"reason":{"type":"string"},"taskId":{"type":"string","minLength":1},"activityId":{"type":"integer"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"accepted"}}},"then":{"required":["operationRef","taskId","activityId"]}},{"if":{"required":["state","reason"],"properties":{"state":{"const":"needsUser"},"reason":{"const":"existingTaskRequiresReview"}}},"then":{"required":["taskId"],"properties":{"taskId":{"minLength":1}}}}]}
```

### dismissModpackRecovery

前台确认放弃指定的原持久安装/补齐记录。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'dismissModpackRecovery' --args '{"arg1":"persistent-pack-42"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"恢复记录 ID","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `id` 时，该值等于原请求的 `arg1`（id）。

当请求参数为 `{"id":"persistent-pack-42"}` 时：
- `{"state":"ready","id":"persistent-pack-42"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"dismissModpackRecovery","operationRef":"current-operation"}`
- `{"state":"cancelled"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","cancelled","unknown","unavailable","busy"]},"reason":{"type":"string"},"id":{"type":"string"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["id"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"dismissModpackRecovery"}},"required":["operationRef","method"]}}]}
```

### resourceProjectSource

选择产品当前项目对应的网站、真实匹配的来源网页或下载来源。域与项目变化、没有对应网址和系统拒绝会说明无法交接。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'resourceProjectSource' --args '{"arg1":"example-project","arg2":"modrinth","arg3":"switch","arg4":"curseforge"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'resourceProjectSource' --args '{"arg1":"example-project","arg2":"modrinth","arg3":"website"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'resourceProjectSource' --args '{"arg1":"example-project","arg2":"modrinth","arg3":"crossSourceWeb","arg4":"curseforge"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'resourceProjectSource' --args '{"arg1":"project","arg2":"modrinth","arg3":"switch","arg4":"modrinth"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'resourceProjectSource' --args '{"arg1":"project","arg2":"curseforge","arg3":"switch","arg4":"curseforge"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"项目 ID","maxLength":16384},"arg2":{"type":"string","description":"当前来源","maxLength":16384,"enum":["modrinth","curseforge"]},"arg3":{"type":"string","description":"来源操作","maxLength":16384,"enum":["website","crossSourceWeb","switch"]},"arg4":{"type":["string"],"description":"新的来源","maxLength":16384,"enum":["modrinth","curseforge",""]}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"]},"allOf":[{"if":{"properties":{"arg3":{"const":"switch"}},"required":["arg3"]},"then":{"required":["arg4"],"properties":{"arg4":{"type":"string","minLength":1}}}},{"if":{"properties":{"arg3":{"const":"crossSourceWeb"}},"required":["arg3"]},"then":{"required":["arg4"],"properties":{"arg4":{"type":"string","minLength":1}}}}]}
```

执行返回值

返回 `source` 时，该值等于原请求的 `arg4`（target）。

当结果为 `{"state":"ready"}` 时，`project` 等于原请求 `arg1`（project）。

当结果为 `{"state":"ready"}` 时，`project` 等于原请求 `arg1`（project）。

当请求参数为 `{"project":"example-project","source":"modrinth","choice":"switch","target":"curseforge"}` 时：
- `{"state":"ready","project":"example-project","source":"curseforge"}`
- `{"state":"failed","reason":"invalidArguments"}`
当请求参数为 `{"project":"example-project","source":"modrinth","choice":"website"}` 时：
- `{"state":"needsUser","reason":"browserOpened"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
请求参数为 `{"choice":"website"}` 时不会返回 `{"state":"ready"}`。

请求参数为 `{"choice":"crossSourceWeb"}` 时不会返回 `{"state":"ready"}`。

当请求参数为 `{"project":"project","source":"modrinth","choice":"switch","target":"modrinth"}` 时：
- `{"project":"project","source":"modrinth","state":"ready"}`
当请求参数为 `{"project":"project","source":"curseforge","choice":"switch","target":"curseforge"}` 时：
- `{"project":"project","source":"curseforge","state":"ready"}`
请求参数为 `{"choice":"switch"}` 时不会返回 `{"state":"needsUser"}`。

当请求参数为 `{"project":"example-project","source":"modrinth","choice":"website"}` 时：
- `{"reason":"browserOpened","state":"needsUser"}`
当请求参数为 `{"project":"example-project","source":"modrinth","choice":"website"}` 时：
- `{"reason":"browserOpened","state":"needsUser"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","unavailable","busy"]},"reason":{"type":"string"},"project":{"type":"string"},"source":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["project","source"]}}]}
```

### renameGameInstance

前台确认后将指定的已装实例重命名。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'renameGameInstance' --args '{"arg1":"instance","arg2":"Renamed 1.21.1"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前业务目标实例","maxLength":16384},"arg2":{"type":"string","description":"新实例名","maxLength":16384}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `instance` 时，该值等于原请求的 `arg2`（newName）。

当请求参数为 `{"instance":"instance","newName":"Renamed 1.21.1"}` 时：
- `{"state":"ready","instance":"Renamed 1.21.1"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"renameGameInstance","operationRef":"current-operation"}`
- `{"state":"cancelled"}`
- `{"state":"initializing"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","cancelled","initializing","unknown","unavailable","busy"]},"reason":{"type":"string"},"instance":{"type":"string"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["instance"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"renameGameInstance"}},"required":["operationRef","method"]}}]}
```

### verifyGameInstance

检查指定实例的真实版本文件，在启动器查看或决定修复。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'verifyGameInstance' --args '{"arg1":"instance"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前业务目标实例","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","checked":3,"corrupt":0,"missing":0,"missingAssets":0,"metadataAvailable":true,"totalAssets":1}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"LAUNCHER_NOT_INTERACTIVE"}`
- `{"state":"initializing"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"checked":3,"corrupt":0,"missing":0,"missingAssets":0,"metadataAvailable":true,"totalAssets":1,"state":"ready"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","initializing","unknown","unavailable","busy"]},"reason":{"type":"string"},"checked":{"type":"integer"},"corrupt":{"type":"integer"},"missing":{"type":"integer"},"missingAssets":{"type":"integer"},"metadataAvailable":{"type":"boolean"},"totalAssets":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["checked","corrupt","missing","missingAssets","metadataAvailable","totalAssets"]}},{"if":{"required":["state"],"properties":{"state":{"const":"ready"}}},"then":{"required":["metadataAvailable"],"properties":{"metadataAvailable":{"const":true}}}}]}
```

### repairGameInstance

为已安装或中断的实例提交原修复任务。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'repairGameInstance' --args '{"arg1":"instance"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前业务目标实例","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"LAUNCHER_NOT_INTERACTIVE"}`
- `{"state":"initializing"}`
- `{"state":"accepted","taskId":"repair:Fabric 1.21.1","activityId":1731870000000}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["failed","needsUser","initializing","accepted","unknown","unavailable","busy"]},"reason":{"type":"string"},"taskId":{"type":"string"},"activityId":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"accepted"}}},"then":{"required":["taskId","activityId"]}}]}
```

### clearIncompleteInstances

显示全批残留目录和内容。取得整批安装租约、用户确认及库存身份复核后清理；含其他用户文件、符号链接和在途任务须保留。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'clearIncompleteInstances' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

`removed`、`remaining` 合起来每个目标最多出现一次。

返回 `affected` 时，该目标必须在 `remaining` 中。

- `{"state":"ready","removed":["unfinished-instance"],"remaining":[]}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"clearIncompleteInstances","operationRef":"current-operation"}`
- `{"state":"cancelled"}`
- `{"state":"initializing"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"partial","removed":[],"remaining":["unfinished-instance"],"affected":"unfinished-instance","reason":"cleanupIncomplete"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"removed":[],"remaining":["unfinished-instance"],"state":"partial","affected":"unfinished-instance","reason":"cleanupIncomplete"}`
- `{"removed":["unfinished-instance"],"remaining":[],"state":"ready"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","cancelled","initializing","unknown","unavailable","partial","busy"]},"reason":{"type":"string"},"removed":{"type":"array","items":{"type":"string"}},"remaining":{"type":"array","items":{"type":"string"}},"affected":{"type":"string"},"retainedDirectory":{"type":"string"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["removed","remaining"]}},{"if":{"properties":{"state":{"const":"partial"}}},"then":{"required":["removed","remaining"]}},{"if":{"required":["state"],"properties":{"state":{"const":"partial"}}},"then":{"required":["remaining","removed"],"properties":{"remaining":{"minItems":1},"removed":{"type":"array"}}}},{"if":{"required":["state"],"properties":{"state":{"const":"ready"}}},"then":{"required":["removed","remaining"],"properties":{"removed":{"minItems":1},"remaining":{"const":[]}}}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"clearIncompleteInstances"}},"required":["operationRef","method"]}}]}
```

### getInstancePack

读取已安装整合包的来源、安装身份与缺件。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getInstancePack' --args '{"arg1":"Example Pack"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前业务目标实例","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `instance` 时，该值等于原请求的 `arg1`（instance）。

当请求参数为 `{"instance":"Example Pack"}` 时：
- `{"state":"ready","instance":"Example Pack","source":"modrinth","pack":"Example Pack","packVersion":"1.0","gameVersion":"1.21.1","loader":"fabric","loaderVersion":"0.16.10","installedAt":1731870000000,"missing":[],"canRepair":false}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"showInstanceDetail"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","unavailable","busy"]},"reason":{"type":"string"},"instance":{"type":"string"},"source":{"type":"string"},"gameVersion":{"type":"string"},"packVersion":{"type":"string"},"missing":{"type":"array","items":{"type":"object"}},"canRepair":{"type":"boolean"},"pack":{"type":"string"},"loader":{"type":"string"},"loaderVersion":{"type":"string"},"installedAt":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["instance","source","pack","packVersion","gameVersion","loader","loaderVersion","installedAt","missing","canRepair"]}}]}
```

### repairInstancePack

提交原整合包计划的补齐。既有任务仍在时只打开原卡片，不能视为本次新补齐已受理。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'repairInstancePack' --args '{"arg1":"instance"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前业务目标实例","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"existingTaskRequiresReview","taskId":"modpack:persistent-pack-42"}`
- `{"state":"accepted","taskId":"modpack:persistent-pack-42","activityId":1731870000000}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"taskId":"modpack:persistent-pack-42","state":"needsUser","reason":"existingTaskRequiresReview"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["failed","needsUser","accepted","unknown","unavailable","busy"]},"reason":{"type":"string"},"taskId":{"type":"string"},"activityId":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"accepted"}}},"then":{"required":["taskId","activityId"]}},{"if":{"required":["state","reason"],"properties":{"state":{"const":"needsUser"},"reason":{"const":"existingTaskRequiresReview"}}},"then":{"required":["taskId"],"properties":{"taskId":{"minLength":1}}}}]}
```

### copyInstancePackMissing

复制该实例原缺件清单至系统剪贴板。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'copyInstancePackMissing' --args '{"arg1":"instance"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前业务目标实例","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"showInstanceDetail"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","unavailable","busy"]},"reason":{"type":"string"}},"additionalProperties":true}
```

### openInstanceSystemFolder

用系统文件管理器展示允许的外部存储目录。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'openInstanceSystemFolder' --args '{"arg1":"instance","arg2":"root"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前业务目标实例","maxLength":16384},"arg2":{"type":"string","description":"允许的版本目录","maxLength":16384,"enum":["root","mods","saves","resourcepacks","shaderpacks"]}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"systemFileManager"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["failed","needsUser","unknown","unavailable","busy"]},"reason":{"type":"string"}},"additionalProperties":true}
```

### setInstanceLanguage

保存该实例游戏语言或选择继承全局。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'setInstanceLanguage' --args '{"arg1":"instance","arg2":"zh_cn"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前业务目标实例","maxLength":16384},"arg2":{"type":"string","description":"游戏支持的语言代码或 inherit","maxLength":16384}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `language` 时，该值等于原请求的 `arg2`（language）。

当请求参数为 `{"instance":"instance","language":"zh_cn"}` 时：
- `{"state":"ready","language":"zh_cn"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","unknown","unavailable","busy"]},"reason":{"type":"string"},"language":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["language"]}}]}
```
