# 实例文件、目录与资源目标

### enterInstanceFolder

进入所选的下一层目录。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'enterInstanceFolder' --args '{"arg1":"instance","arg2":"folder","arg3":"ref"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原实例名称","maxLength":16384},"arg2":{"type":"string","description":"本次目录查询返回的引用","maxLength":16384},"arg3":{"type":"string","description":"本次目录查询返回的行引用","maxLength":16384}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]}}
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

### importInstanceFiles

由系统选择文件后导入目录。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'importInstanceFiles' --args '{"arg1":"instance","arg2":"folder"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原实例名称","maxLength":16384},"arg2":{"type":"string","description":"本次目录查询返回的引用","maxLength":16384}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

- `{"state":"ready","imported":["options-copy.txt"],"failedCount":0}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"importInstanceFiles","operationRef":"current-operation"}`
- `{"state":"partial","imported":["options-copy.txt"],"failedCount":1,"reason":"fileRejected"}`
- `{"state":"cancelled"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"imported":["options-copy.txt"],"failedCount":0,"state":"ready"}`
- `{"imported":["options-copy.txt"],"failedCount":1,"state":"partial","reason":"fileRejected"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","partial","cancelled","unavailable","busy","unknown"]},"reason":{"type":"string"},"imported":{"type":"array","items":{"type":"string"}},"failedCount":{"type":"integer"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["imported","failedCount"]}},{"if":{"properties":{"state":{"const":"partial"}}},"then":{"required":["imported","failedCount"]}},{"if":{"required":["state"],"properties":{"state":{"const":"ready"}}},"then":{"required":["imported","failedCount"],"properties":{"failedCount":{"const":0}}}},{"if":{"required":["state"],"properties":{"state":{"const":"partial"}}},"then":{"required":["imported","failedCount"],"properties":{"imported":{"minItems":1},"failedCount":{"minimum":1}}}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"importInstanceFiles"}},"required":["operationRef","method"]}}]}
```

### exportInstanceFile

通过系统保存文件或打包导出当前目录项。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'exportInstanceFile' --args '{"arg1":"instance","arg2":"folder","arg3":"ref"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原实例名称","maxLength":16384},"arg2":{"type":"string","description":"本次目录查询返回的引用","maxLength":16384},"arg3":{"type":"string","description":"本次目录查询返回的行引用","maxLength":16384}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]}}
```

执行返回值

- `{"state":"ready","exported":"options.txt"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"exportInstanceFile","operationRef":"current-operation"}`
- `{"state":"cancelled"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","cancelled","unavailable","busy","unknown"]},"reason":{"type":"string"},"exported":{"type":"string"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["exported"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"exportInstanceFile"}},"required":["operationRef","method"]}}]}
```

### requestInstanceFileDeletion

在原面板确认删除指定文件或目录。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'requestInstanceFileDeletion' --args '{"arg1":"instance","arg2":"folder","arg3":"ref"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原实例名称","maxLength":16384},"arg2":{"type":"string","description":"本次目录查询返回的引用","maxLength":16384},"arg3":{"type":"string","description":"本次目录查询返回的行引用","maxLength":16384}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]}}
```

执行返回值

- `{"state":"ready","removed":"options-old.txt","shared":false}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"requestInstanceFileDeletion","operationRef":"current-operation"}`
- `{"state":"cancelled"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","cancelled","unavailable","busy","unknown"]},"reason":{"type":"string"},"removed":{"type":"string"},"shared":{"type":"boolean"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["removed","shared"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"requestInstanceFileDeletion"}},"required":["operationRef","method"]}}]}
```

### requestInstanceFileRename

确认影响范围及目标身份后由文件管理器改名并回读。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'requestInstanceFileRename' --args '{"arg1":"instance","arg2":"folder","arg3":"ref","arg4":"options-copy.txt"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原实例名称","maxLength":16384},"arg2":{"type":"string","description":"本次目录查询返回的引用","maxLength":16384},"arg3":{"type":"string","description":"本次目录查询返回的行引用","maxLength":16384},"arg4":{"type":"string","description":"新的纯名称","maxLength":16384}},"required":["arg1","arg2","arg3","arg4"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"]}}
```

执行返回值

返回 `renamed` 时，该值等于原请求的 `arg4`（newName）。

当请求参数为 `{"instance":"instance","folder":"folder","ref":"ref","newName":"options-copy.txt"}` 时：
- `{"state":"ready","renamed":"options-copy.txt","shared":false}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"requestInstanceFileRename","operationRef":"current-operation"}`
- `{"state":"cancelled"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","cancelled","unavailable","busy","unknown"]},"reason":{"type":"string"},"renamed":{"type":"string"},"shared":{"type":"boolean"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["renamed","shared"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"requestInstanceFileRename"}},"required":["operationRef","method"]}}]}
```

### searchResources

从实际在线资源页按类别、关键字和筛选条件搜索。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'searchResources' --args '{"arg1":"mod"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"在线资源类别","maxLength":16384,"enum":["mod","shader","resourcepack","modpack"]},"arg2":{"type":["string"],"description":"关键字，空值浏览全部","maxLength":16384},"arg3":{"type":["string"],"description":"加载器","maxLength":16384,"enum":["fabric","forge","neoforge","quilt",""]},"arg4":{"type":["string"],"description":"游戏版本","maxLength":16384},"arg5":{"type":["string"],"description":"排序","maxLength":16384,"enum":["relevance","downloads","newest","updated",""]}},"required":["arg1"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"],"arg5":["arg1","arg2","arg3","arg4"]}}
```

执行返回值

- `{"state":"ready","searchRef":"02a38130-7fd7-4cf4-b09f-87f6cebd0681","projects":[{"project":"example-project","source":"modrinth","title":"示例模组"}],"total":1,"hasMore":false}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"resourcePageUnavailable"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","unavailable","busy"]},"reason":{"type":"string"},"searchRef":{"type":"string","minLength":1},"projects":{"type":"array","items":{"type":"object","properties":{"project":{"type":"string"},"source":{"type":"string"}},"required":["project","source"]}},"total":{"type":"integer"},"hasMore":{"type":"boolean"},"loader":{"type":"string"},"gameVersion":{"type":"string"},"sort":{"type":"string"},"httpStatus":{"type":"integer"},"errorKind":{"type":"string"},"sourceError":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["searchRef","projects","total","hasMore"]}}]}
```

### nextResourcePage

取得原资源搜索的下一页。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'nextResourcePage' --args '{"arg1":"02a38130-7fd7-4cf4-b09f-87f6cebd0681"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"本次搜索的标识","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `searchRef` 时，该值等于原请求的 `arg1`（searchRef）。

当请求参数为 `{"searchRef":"02a38130-7fd7-4cf4-b09f-87f6cebd0681"}` 时：
- `{"state":"ready","searchRef":"02a38130-7fd7-4cf4-b09f-87f6cebd0681","projects":[],"total":0,"hasMore":false,"sort":"downloads","loader":"","gameVersion":"","httpStatus":0,"errorKind":"","sourceError":""}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"resourcePageUnavailable"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","unavailable","busy"]},"reason":{"type":"string"},"searchRef":{"type":"string","minLength":1},"projects":{"type":"array","items":{"type":"object","properties":{"project":{"type":"string"},"source":{"type":"string"}},"required":["project","source"]}},"total":{"type":"integer"},"hasMore":{"type":"boolean"},"loader":{"type":"string"},"gameVersion":{"type":"string"},"sort":{"type":"string"},"httpStatus":{"type":"integer"},"errorKind":{"type":"string"},"sourceError":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["searchRef","projects","total","hasMore"]}}]}
```

### getResourceVersions

读取原项目的介绍及实际可选版本。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getResourceVersions' --args '{"arg1":"02a38130-7fd7-4cf4-b09f-87f6cebd0681","arg2":"example-project","arg3":"modrinth"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getResourceVersions' --args '{"arg1":"02a38130-7fd7-4cf4-b09f-87f6cebd0681","arg2":"example-project","arg3":"modrinth","arg4":0}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"本次搜索的标识","maxLength":16384},"arg2":{"type":"string","description":"实际结果中的项目 ID","maxLength":16384},"arg3":{"type":"string","description":"实际项目来源","maxLength":16384},"arg4":{"anyOf":[{"type":"integer"},{"const":""}],"description":"分页起点"}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"]}}
```

执行返回值

返回 `project` 时，该值等于原请求的 `arg2`（project）。

返回 `source` 时，该值等于原请求的 `arg3`（source）。

返回 `offset` 时，该值等于原请求的 `arg4`（offset）。

当请求参数为 `{"searchRef":"02a38130-7fd7-4cf4-b09f-87f6cebd0681","project":"example-project","source":"modrinth","offset":0}` 时：
- `{"state":"ready","source":"modrinth","project":"example-project","versions":[{"id":"example-file","name":"1.0","loaders":["fabric"],"games":["1.21.1"],"files":[{"name":"example.jar","bytes":32768,"primary":true}]}],"offset":0,"total":1}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"resourcePageUnavailable"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","unavailable","busy"]},"reason":{"type":"string"},"source":{"type":"string"},"project":{"type":"string"},"versions":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"}},"required":["id","name"]}},"offset":{"type":"integer"},"total":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["source","project","versions","offset","total"]}}]}
```

### prepareResourceInstall

为该来源、项目和版本选择真实主文件并列出依赖。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'prepareResourceInstall' --args '{"arg1":"02a38130-7fd7-4cf4-b09f-87f6cebd0681","arg2":"example-project","arg3":"modrinth","arg4":"example-file"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"本次搜索的标识","maxLength":16384},"arg2":{"type":"string","description":"实际结果中的项目 ID","maxLength":16384},"arg3":{"type":"string","description":"实际项目来源","maxLength":16384},"arg4":{"type":"string","description":"实际资源版本 ID","maxLength":16384},"arg5":{"type":["string"],"description":"整合包的目标名称","maxLength":16384}},"required":["arg1","arg2","arg3","arg4"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"],"arg5":["arg1","arg2","arg3","arg4"]}}
```

执行返回值

返回 `project` 时，该值等于原请求的 `arg2`（project）。

返回 `source` 时，该值等于原请求的 `arg3`（source）。

返回 `version` 时，该值等于原请求的 `arg4`（version）。

当请求参数为 `{"searchRef":"02a38130-7fd7-4cf4-b09f-87f6cebd0681","project":"example-project","source":"modrinth","version":"example-file"}` 时：
- `{"state":"ready","planRef":"256d1962-2579-4e41-8eed-4274cae65f67","project":"example-project","source":"modrinth","version":"example-file","target":"Fabric 1.21.1","filename":"example.jar","saveOnly":false,"dependencies":[]}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"resourcePageUnavailable"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","unavailable","busy"]},"reason":{"type":"string"},"planRef":{"type":"string","minLength":1},"dependencies":{"type":"array","items":{"type":"object","properties":{"key":{"type":"string"},"selected":{"type":"boolean"}},"required":["key","selected"]}},"version":{"type":"string"},"target":{"type":"string"},"filename":{"type":"string"},"saveOnly":{"type":"boolean"},"project":{"type":"string"},"source":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["planRef","project","source","version","target","filename","saveOnly","dependencies"]}}]}
```

### selectResourceDependency

更新原安装计划中的可选依赖。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'selectResourceDependency' --args '{"arg1":"searchRef","arg2":"planRef","arg3":"key","arg4":true}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"本次搜索的标识","maxLength":16384},"arg2":{"type":"string","description":"原计划确认标识","maxLength":16384},"arg3":{"type":"string","description":"依赖标识","maxLength":16384},"arg4":{"type":"boolean","description":"是否安装"}},"required":["arg1","arg2","arg3","arg4"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"]}}
```

执行返回值

- `{"state":"ready","planRef":"256d1962-2579-4e41-8eed-4274cae65f67","project":"example-project","source":"modrinth","version":"example-file","target":"Fabric 1.21.1","filename":"example.jar","saveOnly":false,"dependencies":[{"key":"modrinth:optional-mod","kind":"optional","name":"Optional Mod","installed":false,"selected":true}]}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"resourcePageUnavailable"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","unavailable","busy"]},"reason":{"type":"string"},"planRef":{"type":"string","minLength":1},"dependencies":{"type":"array","items":{"type":"object","properties":{"key":{"type":"string"},"selected":{"type":"boolean"}},"required":["key","selected"]}},"version":{"type":"string"},"target":{"type":"string"},"filename":{"type":"string"},"saveOnly":{"type":"boolean"},"project":{"type":"string"},"source":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["planRef","project","source","version","target","filename","saveOnly","dependencies"]}}]}
```

### installResourcePlan

提交一次指定资源安装计划。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'installResourcePlan' --args '{"arg1":"02a38130-7fd7-4cf4-b09f-87f6cebd0681","arg2":"256d1962-2579-4e41-8eed-4274cae65f67"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"本次搜索的标识","maxLength":16384},"arg2":{"type":"string","description":"原计划确认标识","maxLength":16384}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `operationRef` 时，该值等于原请求的 `arg2`（planRef）。

当请求参数为 `{"searchRef":"02a38130-7fd7-4cf4-b09f-87f6cebd0681","planRef":"256d1962-2579-4e41-8eed-4274cae65f67"}` 时：
- `{"state":"accepted","operationRef":"256d1962-2579-4e41-8eed-4274cae65f67"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"installResourcePlan","operationRef":"current-operation"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"cancelled"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["accepted","failed","needsUser","unknown","cancelled","unavailable","busy"]},"reason":{"type":"string"},"operationRef":{"type":"string"},"method":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"accepted"}}},"then":{"required":["operationRef"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"installResourcePlan"}},"required":["operationRef","method"]}}]}
```

### getResourceInstall

使用原计划编号查询资源安装或另存任务，应用重启后仍由原活动及记录核验。 使用原操作返回的 operationRef；如是等待用户时收到的临时引用，应先用 getLauncherHandoff 读取原业务结果。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getResourceInstall' --args '{"arg1":"256d1962-2579-4e41-8eed-4274cae65f67"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"提交回包的操作编号","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `operationRef` 时，该值等于原请求的 `arg1`（operationRef）。

当请求参数为 `{"operationRef":"256d1962-2579-4e41-8eed-4274cae65f67"}` 时：
- `{"state":"ready","operationRef":"256d1962-2579-4e41-8eed-4274cae65f67","taskId":"mod-plan:/sandbox/.minecraft/mods:modrinth:example-project","activityId":1731870000000,"phase":"done"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"initializing"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","unknown","unavailable","initializing","busy"]},"reason":{"type":"string"},"operationRef":{"type":"string"},"taskId":{"type":"string"},"activityId":{"type":"integer"},"phase":{"type":"string"},"completeness":{"type":"string"},"missingCount":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["operationRef","taskId","activityId","phase"]}}]}
```
