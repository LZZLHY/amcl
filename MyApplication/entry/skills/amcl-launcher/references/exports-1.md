# 导出范围、检查计划、保存与任务结果

### getExportPlan

打开或读取原版游戏包导出计划、共享范围、格式、依赖及分层内容树。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getExportPlan' --args '{"arg1":"instance"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原安装清单中的准确实例名","maxLength":16384},"arg2":{"type":["string"],"description":"上一级返回的分组 id，省略表示根","maxLength":16384},"arg3":{"anyOf":[{"type":"integer"},{"const":""}],"description":"条目起始位置"}},"required":["arg1"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]}}
```

执行返回值

返回 `instance` 时，该值等于原请求的 `arg1`（instance）。

当请求参数为 `{"instance":"instance"}` 时：
- `{"state":"ready","instance":"instance","format":"format","nodes":[]}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","initializing","unavailable","unknown","failed"]},"reason":{"type":"string"},"instance":{"type":"string"},"shared":{"type":"boolean"},"format":{"type":"string"},"launcher":{"type":"string"},"supportsPcl":{"type":"boolean"},"nodes":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"kind":{"type":"string"}},"required":["id","kind"]}},"total":{"type":"integer"},"dirty":{"type":"boolean"},"checked":{"type":"boolean"},"issues":{"type":"array","items":{"type":"string"}},"recipient":{"type":"string"},"planSummary":{"type":"array","items":{"type":"string"}}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["instance","format","nodes"]}}]}
```

### configureExport

在原导出器选择完整包、Modrinth 或 CurseForge 格式及适用的接收启动器。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'configureExport' --args '{"arg1":"示例实例","arg2":"full","arg3":"hmcl"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原安装清单中的准确实例名","maxLength":16384},"arg2":{"type":"string","description":"导出格式","maxLength":16384,"enum":["full","modrinth","curseforge"]},"arg3":{"type":"string","description":"接收启动器","maxLength":16384,"enum":["hmcl","pcl"]}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]}}
```

执行返回值

当结果为 `{"state":"ready"}` 时，`format` 等于原请求 `arg2`（format）。

当结果为 `{"state":"ready"}` 时，`launcher` 等于原请求 `arg3`（launcher）。

当请求参数为 `{"instance":"示例实例","format":"full","launcher":"hmcl"}` 时：
- `{"state":"ready","format":"full","launcher":"hmcl"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`
当请求参数为 `{"instance":"示例实例","format":"full","launcher":"hmcl"}` 时：
- `{"format":"full","launcher":"hmcl","state":"ready"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","initializing","unavailable","unknown","failed"]},"reason":{"type":"string"},"format":{"type":"string"},"launcher":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["format","launcher"]}},{"if":{"required":["state"],"properties":{"state":{"const":"ready"}}},"then":{"required":["format","launcher"],"properties":{}}}]}
```

### selectExportContent

按真实盘点的分组或条目选择是否包含目录、文件或世界。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'selectExportContent' --args '{"arg1":"instance","arg2":"node","arg3":true}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原安装清单中的准确实例名","maxLength":16384},"arg2":{"type":"string","description":"getExportPlan 返回的节点 id","maxLength":16384},"arg3":{"type":"boolean","description":"是否纳入导出"}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]}}
```

执行返回值

返回 `node` 时，该值等于原请求的 `arg2`（node）。

当请求参数为 `{"instance":"instance","node":"node","selected":true}` 时：
- `{"state":"ready","node":"node"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","initializing","unavailable","unknown","failed"]},"reason":{"type":"string"},"node":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["node"]}}]}
```

### resetExportContent

将当前格式的内容恢复为产品默认选择。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'resetExportContent' --args '{"arg1":"instance"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原安装清单中的准确实例名","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","selectedCount":1}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","initializing","unavailable","unknown","failed"]},"reason":{"type":"string"},"selectedCount":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["selectedCount"]}}]}
```

### saveExportDraft

将本次导出选择保存到原产品草稿。打开同一实例时按产品规则恢复。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'saveExportDraft' --args '{"arg1":"instance"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原安装清单中的准确实例名","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","initializing","unavailable","unknown","failed"]},"reason":{"type":"string"}},"additionalProperties":true}
```

### discardExportEdits

请求离开，存在未保存修改时由用户在原确认对话框中选择保存、放弃或继续。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'discardExportEdits' --args '{"arg1":"instance"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原安装清单中的准确实例名","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","unsaved":false}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"needsUser","unsaved":true}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","initializing","unavailable","needsUser","unknown","failed"]},"reason":{"type":"string"},"unsaved":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["unsaved"]}},{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["unsaved"]}}]}
```

### retryExport

从导出结果返回配置并放弃旧预览，重试前需要重新核对方案。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'retryExport' --args '{"arg1":"instance"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原安装清单中的准确实例名","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","checked":false}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","initializing","unavailable","unknown","failed"]},"reason":{"type":"string"},"checked":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["checked"]}}]}
```

### checkExportPlan

对当前导出选择运行真实计划检查，返回一次性预览引用与预估。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'checkExportPlan' --args '{"arg1":"示例实例"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原安装清单中的准确实例名","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","plan":"fc769f4f-65bd-4287-984d-124d1056465c","files":8,"bytes":4096,"downloads":1}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"planUnavailable"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","initializing","unavailable","unknown","failed"]},"reason":{"type":"string"},"plan":{"type":"string","minLength":1},"files":{"type":"integer"},"bytes":{"type":"integer"},"downloads":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["plan","files","bytes","downloads"]}}]}
```

### startExport

持本次检查的预览引用，打开系统另存，按原选择生成导出包。可用 getExportTask 核对结果。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'startExport' --args '{"arg1":"示例实例","arg2":"fc769f4f-65bd-4287-984d-124d1056465c"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原安装清单中的准确实例名","maxLength":16384},"arg2":{"type":"string","description":"checkExportPlan 返回的当前预览引用","maxLength":16384}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"needsUser","surface":"savePicker"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"planChanged"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["busy","initializing","unavailable","needsUser","unknown","failed"]},"reason":{"type":"string"},"surface":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["surface"]}}]}
```

### getExportTask

读取导出任务的实际阶段、文件数、最终回读状态、大小及摘要。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getExportTask' --args '{"arg1":"示例实例","arg2":"1795456400000-20156704-92b4-4089-8e65-08acc41d36f8"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getExportTask' --args '{"arg1":"示例实例"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原安装清单中的准确实例名","maxLength":16384},"arg2":{"type":["string"],"description":"已知原任务身份，省略时读取当前导出面板对应任务","maxLength":16384}},"required":["arg1"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `taskId` 时，该值等于原请求的 `arg2`（taskId）。

当请求参数为 `{"instance":"示例实例","taskId":"1795456400000-20156704-92b4-4089-8e65-08acc41d36f8"}` 时：
- `{"state":"ready","taskId":"1795456400000-20156704-92b4-4089-8e65-08acc41d36f8","phase":"准备导出","taskState":"running","verified":false}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"noMatchingTask","picker":"waiting"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"taskId":{"type":"string"},"taskState":{"type":"string"},"phase":{"type":"string"},"verified":{"type":"boolean"},"digest":{"type":"string"},"size":{"type":"integer"},"picker":{"type":"string"},"platform":{"type":"string"},"recipientGuide":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["taskId","phase","taskState","verified"]}}]}
```

### cancelExportTask

请求取消正在执行的指定原任务，然后读取原任务直到自然终态。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'cancelExportTask' --args '{"arg1":"示例实例","arg2":"1795456400000-20156704-92b4-4089-8e65-08acc41d36f8"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原安装清单中的准确实例名","maxLength":16384},"arg2":{"type":"string","description":"当前导出任务身份","maxLength":16384}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `taskId` 时，该值等于原请求的 `arg2`（taskId）。

- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
当请求参数为 `{"instance":"示例实例","taskId":"1795456400000-20156704-92b4-4089-8e65-08acc41d36f8"}` 时：
- `{"state":"accepted","taskId":"1795456400000-20156704-92b4-4089-8e65-08acc41d36f8","taskState":"cancelling"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["busy","unavailable","accepted","unknown","failed"]},"reason":{"type":"string"},"taskId":{"type":"string"},"taskState":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"accepted"}}},"then":{"required":["taskId","taskState"]}}]}
```
