# 资源搜索、安装与已装内容

### closeResourceDetails

用原搜索引用收起由它打开的同一个详情。后台刷新或目标换代后仍可收起原详情，不能关闭玩家另开的详情。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'closeResourceDetails' --args '{"arg1":"searchRef"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"本次搜索的标识","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready"}`
- `{"state":"failed","reason":"searchChanged"}`
- `{"state":"needsUser","reason":"resourcePageUnavailable"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","unavailable","busy"]},"reason":{"type":"string"}},"additionalProperties":true}
```

### chooseLocalModpack

在整合包页经系统文件选择器选择本地整合包。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'chooseLocalModpack' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","selectionRef":"7cc6a8e9-e662-477a-b58a-000000000001","instance":"Example Pack"}`
- `{"state":"failed","reason":"fileNotSelected"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"chooseLocalModpack","operationRef":"current-operation"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"cancelled"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","cancelled","unavailable","busy"]},"reason":{"type":"string"},"selectionRef":{"type":"string","minLength":1},"instance":{"type":"string"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["selectionRef","instance"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"chooseLocalModpack"}},"required":["operationRef","method"]}}]}
```

### prepareLocalModpack

查看或修改本次选择的整合包安装名。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'prepareLocalModpack' --args '{"arg1":"7cc6a8e9-e662-477a-b58a-000000000001","arg2":"Example Pack"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"系统选择文件后的标识","maxLength":16384},"arg2":{"type":["string"],"description":"新的目标安装名","maxLength":16384}},"required":["arg1"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `instance` 时，该值等于原请求的 `arg2`（instance）。

当请求参数为 `{"selectionRef":"7cc6a8e9-e662-477a-b58a-000000000001","instance":"Example Pack"}` 时：
- `{"state":"ready","planRef":"7cc6a8e9-e662-477a-b58a-000000000002","instance":"Example Pack"}`
- `{"state":"failed","reason":"fileSelectionChanged"}`
- `{"state":"needsUser","reason":"resourcePageUnavailable"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","unavailable","busy"]},"reason":{"type":"string"},"planRef":{"type":"string","minLength":1},"instance":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["planRef","instance"]}}]}
```

### installLocalModpack

将已选择、已命名的本地整合包按原计划入队。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'installLocalModpack' --args '{"arg1":"7cc6a8e9-e662-477a-b58a-000000000001","arg2":"7cc6a8e9-e662-477a-b58a-000000000002"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"系统选择文件后的标识","maxLength":16384},"arg2":{"type":"string","description":"原计划确认标识","maxLength":16384}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `operationRef` 时，该值等于原请求的 `arg2`（planRef）。

当请求参数为 `{"selectionRef":"7cc6a8e9-e662-477a-b58a-000000000001","planRef":"7cc6a8e9-e662-477a-b58a-000000000002"}` 时：
- `{"state":"accepted","operationRef":"7cc6a8e9-e662-477a-b58a-000000000002"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"resourcePageUnavailable"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["accepted","failed","needsUser","unknown","unavailable","busy"]},"reason":{"type":"string"},"operationRef":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"accepted"}}},"then":{"required":["operationRef"]}}]}
```

### listInstalledResources

查询选定实例中的已安装资源、更新及完整性，支持按词筛选。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'listInstalledResources' --args '{"arg1":"instance","arg2":"mod"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"已选择的本地实例名称","maxLength":16384},"arg2":{"type":"string","description":"资源类别","maxLength":16384,"enum":["mod","shader","resourcepack","datapack"]},"arg3":{"type":["string"],"description":"查询词","maxLength":16384}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]}}
```

执行返回值

- `{"state":"ready","folder":"02a38130-7fd7-4cf4-b09f-87f6cebd0681","shared":false,"entries":[]}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"resourcePanelChanged"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","initializing","unavailable","busy"]},"reason":{"type":"string"},"folder":{"type":"string"},"shared":{"type":"boolean"},"entries":{"type":"array","items":{"type":"object","properties":{"ref":{"type":"string"}},"required":["ref"]}}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["folder","shared","entries"]}}]}
```

### refreshInstalledResources

刷新指定实例已安装资源的真实扫描。 该方法首先返回 accepted，完成后用 listInstalledResources 查看重扫结果。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'refreshInstalledResources' --args '{"arg1":"instance","arg2":"mod"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"已选择的本地实例名称","maxLength":16384},"arg2":{"type":"string","description":"资源类别","maxLength":16384,"enum":["mod","shader","resourcepack","datapack"]}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

- `{"state":"accepted"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"resourcePanelChanged"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["accepted","failed","needsUser","unknown","unavailable","busy"]},"reason":{"type":"string"}},"additionalProperties":true}
```

### importInstalledResources

通过系统选择器批量导入本地资源。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'importInstalledResources' --args '{"arg1":"instance","arg2":"mod","arg3":"folder"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"已选择的本地实例名称","maxLength":16384},"arg2":{"type":"string","description":"资源类别","maxLength":16384,"enum":["mod","shader","resourcepack","datapack"]},"arg3":{"type":"string","description":"原已安装资源查询返回的目录标识","maxLength":16384}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]}}
```

执行返回值

- `{"state":"ready","imported":["example.jar"],"failedCount":0}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"importInstalledResources","operationRef":"current-operation"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"cancelled"}`
- `{"state":"partial","imported":["example.jar"],"failedCount":1,"reason":"fileRejected"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"imported":["example.jar"],"failedCount":0,"state":"ready"}`
- `{"imported":["example.jar"],"failedCount":1,"state":"partial","reason":"fileRejected"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","cancelled","partial","initializing","unavailable","busy"]},"reason":{"type":"string"},"imported":{"type":"array","items":{"type":"string"}},"failedCount":{"type":"integer"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["imported","failedCount"]}},{"if":{"properties":{"state":{"const":"partial"}}},"then":{"required":["imported","failedCount"]}},{"if":{"required":["state"],"properties":{"state":{"const":"ready"}}},"then":{"required":["imported","failedCount"],"properties":{"failedCount":{"const":0}}}},{"if":{"required":["state"],"properties":{"state":{"const":"partial"}}},"then":{"required":["imported","failedCount"],"properties":{"imported":{"minItems":1},"failedCount":{"minimum":1}}}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"importInstalledResources"}},"required":["operationRef","method"]}}]}
```

### verifyInstalledMods

执行已安装模组的完整性校验。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'verifyInstalledMods' --args '{"arg1":"instance","arg2":"mod"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"已选择的本地实例名称","maxLength":16384},"arg2":{"type":"string","description":"资源类别","maxLength":16384,"enum":["mod","shader","resourcepack","datapack"]}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

- `{"state":"ready","corrupt":0,"files":0}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"resourcePanelChanged"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","initializing","unavailable","busy"]},"reason":{"type":"string"},"corrupt":{"type":"integer"},"files":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["corrupt","files"]}}]}
```

### setInstalledResourceEnabled

启用或禁用选定的资源。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'setInstalledResourceEnabled' --args '{"arg1":"instance","arg2":"mod","arg3":"folder","arg4":"ref","arg5":true}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"已选择的本地实例名称","maxLength":16384},"arg2":{"type":"string","description":"资源类别","maxLength":16384,"enum":["mod","shader","resourcepack","datapack"]},"arg3":{"type":"string","description":"原查询返回的目录标识","maxLength":16384},"arg4":{"type":"string","description":"原查询返回的行标识","maxLength":16384},"arg5":{"type":"boolean","description":"启用目标状态"}},"required":["arg1","arg2","arg3","arg4","arg5"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"],"arg5":["arg1","arg2","arg3","arg4"]}}
```

执行返回值

返回 `enabled` 时，该值等于原请求的 `arg5`（enabled）。

当请求参数为 `{"instance":"instance","kind":"mod","folder":"folder","ref":"ref","enabled":true}` 时：
- `{"state":"ready","enabled":true}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"setInstalledResourceEnabled","operationRef":"current-operation"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"cancelled"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","cancelled","initializing","unavailable","busy"]},"reason":{"type":"string"},"enabled":{"type":"boolean"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["enabled"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"setInstalledResourceEnabled"}},"required":["operationRef","method"]}}]}
```

### checkInstalledModUpdate

检查该已安装模组的可用更新。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'checkInstalledModUpdate' --args '{"arg1":"instance","arg2":"mod","arg3":"folder","arg4":"ref"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"已选择的本地实例名称","maxLength":16384},"arg2":{"type":"string","description":"资源类别","maxLength":16384,"enum":["mod","shader","resourcepack","datapack"]},"arg3":{"type":"string","description":"原查询返回的目录标识","maxLength":16384},"arg4":{"type":"string","description":"原查询返回的行标识","maxLength":16384}},"required":["arg1","arg2","arg3","arg4"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"]}}
```

执行返回值

- `{"state":"ready","updateState":"latest","version":""}`
- `{"state":"accepted","reason":"alreadyChecking"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"resourcePanelChanged"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","accepted","failed","needsUser","unknown","initializing","unavailable","busy"]},"reason":{"type":"string"},"updateState":{"type":"string"},"version":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["updateState","version"]}}]}
```

### ignoreInstalledModUpdate

忽略当前模组此版本更新。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'ignoreInstalledModUpdate' --args '{"arg1":"instance","arg2":"mod","arg3":"folder","arg4":"ref"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"已选择的本地实例名称","maxLength":16384},"arg2":{"type":"string","description":"资源类别","maxLength":16384,"enum":["mod","shader","resourcepack","datapack"]},"arg3":{"type":"string","description":"原查询返回的目录标识","maxLength":16384},"arg4":{"type":"string","description":"原查询返回的行标识","maxLength":16384}},"required":["arg1","arg2","arg3","arg4"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"]}}
```

执行返回值

- `{"state":"ready","updateState":"ignored"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"resourcePanelChanged"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","initializing","unavailable","busy"]},"reason":{"type":"string"},"updateState":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["updateState"]}}]}
```

### requestInstalledResourceDelete

打开确认后删除指定已安装资源。 ready 表示已核实原目标消失；随后用 listInstalledResources 读取该目录。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'requestInstalledResourceDelete' --args '{"arg1":"instance","arg2":"mod","arg3":"folder","arg4":"ref"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"已选择的本地实例名称","maxLength":16384},"arg2":{"type":"string","description":"资源类别","maxLength":16384,"enum":["mod","shader","resourcepack","datapack"]},"arg3":{"type":"string","description":"原查询返回的目录标识","maxLength":16384},"arg4":{"type":"string","description":"原查询返回的行标识","maxLength":16384}},"required":["arg1","arg2","arg3","arg4"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"]}}
```

执行返回值

- `{"state":"ready"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"requestInstalledResourceDelete","operationRef":"current-operation"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"cancelled"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","cancelled","initializing","unavailable","busy"]},"reason":{"type":"string"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"requestInstalledResourceDelete"}},"required":["operationRef","method"]}}]}
```
