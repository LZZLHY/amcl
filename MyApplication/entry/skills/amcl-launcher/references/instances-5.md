# 模组检查、更新与下载队列

### repairInstalledMod

用户确认后原来源修复损坏的模组。 ready 表示原修复调用正常返回。可重新读取该目录并运行 verifyInstalledMods 确认文件完整性。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'repairInstalledMod' --args '{"arg1":"instance","arg2":"mod","arg3":"folder","arg4":"ref"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"已选择的本地实例名称","maxLength":16384},"arg2":{"type":"string","description":"资源类别","maxLength":16384,"enum":["mod","shader","resourcepack","datapack"]},"arg3":{"type":"string","description":"原查询返回的目录标识","maxLength":16384},"arg4":{"type":"string","description":"原查询返回的行标识","maxLength":16384}},"required":["arg1","arg2","arg3","arg4"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"]}}
```

执行返回值

- `{"state":"ready"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"repairInstalledMod","operationRef":"current-operation"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"cancelled"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","cancelled","initializing","unavailable","busy"]},"reason":{"type":"string"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"repairInstalledMod"}},"required":["operationRef","method"]}}]}
```

### updateInstalledMod

用户确认后更新指定模组至页面给出的版本。 ready 表示更新协调器完成。可用 listInstalledResources 重新取得文件与版本，旧行引用可能已失效。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'updateInstalledMod' --args '{"arg1":"instance","arg2":"mod","arg3":"folder","arg4":"ref"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"已选择的本地实例名称","maxLength":16384},"arg2":{"type":"string","description":"资源类别","maxLength":16384,"enum":["mod","shader","resourcepack","datapack"]},"arg3":{"type":"string","description":"原查询返回的目录标识","maxLength":16384},"arg4":{"type":"string","description":"原查询返回的行标识","maxLength":16384}},"required":["arg1","arg2","arg3","arg4"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"]}}
```

执行返回值

- `{"state":"ready"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"updateInstalledMod","operationRef":"current-operation"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"cancelled"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","cancelled","initializing","unavailable","busy"]},"reason":{"type":"string"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"updateInstalledMod"}},"required":["operationRef","method"]}}]}
```

### listDownloadQueue

按全部、进行中、完成和失败筛选下载任务，读取实际汇总和引用。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'listDownloadQueue' --args '{}')
```

```json
{"type":"object","properties":{"arg1":{"type":["string"],"description":"筛选器","maxLength":16384,"enum":["all","active","done","failed",""]}},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","tasks":[{"ref":"7cc6a8e9-e662-477a-b58a-000000000003","id":"mc:Fabric 1.21.1","activityId":1731870000000,"title":"Fabric 1.21.1","category":"mc","phase":"downloading","queuePosition":0,"bytesDone":0,"bytesTotal":8192,"filesDone":0,"filesTotal":1,"errorKind":"","canPause":true,"canResume":false,"canRetry":false,"canCancel":true,"requiresConfirmation":false},{"ref":"7cc6a8e9-e662-477a-b58a-000000000004","id":"modpack:demo","activityId":1731870000000,"title":"Example Pack","category":"modpack","phase":"paused","queuePosition":0,"bytesDone":0,"bytesTotal":8192,"filesDone":0,"filesTotal":1,"errorKind":"","canPause":false,"canResume":false,"canRetry":false,"canCancel":true,"requiresConfirmation":true}],"activeCount":1,"waitingCount":0,"progress":0}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"queueUnavailable"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","unavailable","busy"]},"reason":{"type":"string"},"tasks":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"ref":{"type":"string"},"activityId":{"type":"integer"}},"required":["id","ref","activityId"]}},"activeCount":{"type":"integer"},"waitingCount":{"type":"integer"},"progress":{"type":"number"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["tasks","activeCount","waitingCount","progress"]}}]}
```

### getDownloadTaskDetail

返回原任务详情，需要时展示分文件进度。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getDownloadTaskDetail' --args '{"arg1":"7cc6a8e9-e662-477a-b58a-000000000003"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"本次任务清单的行引用","maxLength":16384},"arg2":{"anyOf":[{"type":"boolean"},{"const":""}],"description":"是否打开原产品任务详情"}},"required":["arg1"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

- `{"state":"ready","id":"mc:Fabric 1.21.1","activityId":1731870000000,"category":"mc","title":"Fabric 1.21.1","phase":"downloading","stages":[]}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"queueUnavailable"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","unavailable","busy"]},"reason":{"type":"string"},"id":{"type":"string"},"activityId":{"type":"integer"},"stages":{"type":"array","items":{"type":"object"}},"files":{"type":"array","items":{"type":"object"}},"currentFiles":{"type":"array","items":{"type":"string"}},"category":{"type":"string"},"title":{"type":"string"},"phase":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["id","activityId","category","title","phase"]}}]}
```

### controlDownloadTask

对原任务执行允许的控制，取消与移除经用户确认。 外部恢复须回读原任务与已到达的产品页面，不能据此断言导出或更新已重新执行。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'controlDownloadTask' --args '{"arg1":"7cc6a8e9-e662-477a-b58a-000000000003","arg2":"pause"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"本次任务清单的行引用","maxLength":16384},"arg2":{"type":"string","description":"控制类型","maxLength":16384,"enum":["pause","resume","retry","cancel","remove","externalRecovery"]}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `operationRef` 时，该值等于原请求的 `arg1`（ref）。

返回 `action` 时，该值等于原请求的 `arg2`（action）。

- `{"state":"ready"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"controlDownloadTask","operationRef":"current-operation"}`
- `{"state":"cancelled"}`
当请求参数为 `{"ref":"7cc6a8e9-e662-477a-b58a-000000000003","action":"pause"}` 时：
- `{"state":"accepted","operationRef":"7cc6a8e9-e662-477a-b58a-000000000003","taskId":"mc:Fabric 1.21.1","activityId":1731870000000,"outcome":"pending","originalActivityId":1731870000000,"selectedTaskId":"mc:Fabric 1.21.1","action":"pause","started":true,"choiceState":"notApplicable","phase":"paused"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
当请求参数为 `{"ref":"7cc6a8e9-e662-477a-b58a-000000000003","action":"pause"}` 时：
- `{"operationRef":"7cc6a8e9-e662-477a-b58a-000000000003","taskId":"mc:Fabric 1.21.1","activityId":1731870000000,"outcome":"pending","originalActivityId":1731870000000,"selectedTaskId":"mc:Fabric 1.21.1","action":"pause","started":true,"choiceState":"notApplicable","phase":"paused","state":"accepted"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","cancelled","accepted","unknown","unavailable","busy"]},"reason":{"type":"string"},"destinationReached":{"type":"boolean"},"started":{"type":"boolean"},"activityId":{"type":"integer"},"parentActivityId":{"type":"integer"},"action":{"type":"string"},"choiceState":{"type":"string"},"outcome":{"type":"string"},"destination":{"type":"string"},"operationRef":{"type":"string","minLength":1},"taskId":{"type":"string","minLength":1},"phase":{"type":"string"},"originalActivityId":{"type":"integer"},"selectedTaskId":{"type":"string"},"method":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"accepted"}}},"then":{"required":["operationRef","taskId","activityId","outcome","originalActivityId","selectedTaskId","action","started","choiceState","phase"]}},{"if":{"required":["state"],"properties":{"state":{"const":"accepted"}}},"then":{"required":["outcome"],"properties":{"outcome":{"const":"pending"}}}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"controlDownloadTask"}},"required":["operationRef","method"]}}]}
```

### clearFinishedTasks

用户确认后移除查询所对应的已结束任务记录。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'clearFinishedTasks' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","removed":0}`
- `{"state":"failed","reason":"queueChanged"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"clearFinishedTasks","operationRef":"current-operation"}`
- `{"state":"cancelled"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","cancelled","unknown","unavailable","busy"]},"reason":{"type":"string"},"removed":{"type":"integer"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["removed"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"clearFinishedTasks"}},"required":["operationRef","method"]}}]}
```

### getModpackChoices

读取同一整合包任务待选的子包和可选文件。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getModpackChoices' --args '{"arg1":"7cc6a8e9-e662-477a-b58a-000000000004"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"本次任务清单的行引用","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","choiceRef":"7cc6a8e9-e662-477a-b58a-000000000005","packages":[],"files":[{"index":0,"name":"optional-resource.jar","selected":false}],"requiresChoice":true,"canChooseOtherPackage":false}`
- `{"state":"failed","reason":"notModpack"}`
- `{"state":"needsUser","reason":"queueUnavailable"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"choiceRef":"7cc6a8e9-e662-477a-b58a-000000000007","packages":[{"index":0,"name":"客户端 A","selected":false},{"index":1,"name":"客户端 B","selected":false}],"files":[],"requiresChoice":true,"canChooseOtherPackage":true,"state":"ready"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","unavailable","busy"]},"reason":{"type":"string"},"choiceRef":{"type":"string","minLength":1},"packages":{"type":"array","items":{"type":"object","properties":{"index":{"type":"integer"},"name":{"type":"string"},"selected":{"type":"boolean"}},"required":["index","name","selected"]}},"files":{"type":"array","items":{"type":"object","properties":{"index":{"type":"integer"},"name":{"type":"string"},"selected":{"type":"boolean"}},"required":["index","name","selected"]}},"requiresChoice":{"type":"boolean"},"canChooseOtherPackage":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["choiceRef","packages","files","requiresChoice","canChooseOtherPackage"]}},{"if":{"required":["state","canChooseOtherPackage"],"properties":{"state":{"const":"ready"},"canChooseOtherPackage":{"const":true}}},"then":{"required":["packages","files","choiceRef"],"properties":{}}}]}
```

### changeModpackChoice

选子包、选择可选文件或返回重新选择。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'changeModpackChoice' --args '{"arg1":"7cc6a8e9-e662-477a-b58a-000000000004","arg2":"7cc6a8e9-e662-477a-b58a-000000000005","arg3":"optional","arg4":0,"arg5":true}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'changeModpackChoice' --args '{"arg1":"7cc6a8e9-e662-477a-b58a-000000000004","arg2":"7cc6a8e9-e662-477a-b58a-000000000007","arg3":"package","arg4":0}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'changeModpackChoice' --args '{"arg1":"7cc6a8e9-e662-477a-b58a-000000000004","arg2":"7cc6a8e9-e662-477a-b58a-000000000007","arg3":"other"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"本次任务清单的行引用","maxLength":16384},"arg2":{"type":"string","description":"本次待确认选择的标识","maxLength":16384},"arg3":{"type":"string","description":"选择类型","maxLength":16384,"enum":["package","optional","other"]},"arg4":{"anyOf":[{"type":"integer"},{"const":""}],"description":"候选序号"},"arg5":{"anyOf":[{"type":"boolean"},{"const":""}],"description":"是否选择可选文件"}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"],"arg5":["arg1","arg2","arg3","arg4"]},"allOf":[{"if":{"properties":{"arg3":{"const":"package"}},"required":["arg3"]},"then":{"required":["arg4"],"properties":{"arg4":{"type":"integer"}}}},{"if":{"properties":{"arg3":{"const":"optional"}},"required":["arg3"]},"then":{"required":["arg4","arg5"],"properties":{"arg4":{"type":"integer"},"arg5":{"type":"boolean"}}}}]}
```

执行返回值

- `{"state":"ready","choiceRef":"7cc6a8e9-e662-477a-b58a-000000000006","packages":[],"files":[{"index":0,"name":"optional-resource.jar","selected":true}],"requiresChoice":true,"canChooseOtherPackage":false}`
- `{"state":"failed","reason":"choiceChanged"}`
- `{"state":"needsUser","reason":"queueUnavailable"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","unavailable","busy"]},"reason":{"type":"string"},"choiceRef":{"type":"string","minLength":1},"packages":{"type":"array","items":{"type":"object","properties":{"index":{"type":"integer"},"name":{"type":"string"},"selected":{"type":"boolean"}},"required":["index","name","selected"]}},"files":{"type":"array","items":{"type":"object","properties":{"index":{"type":"integer"},"name":{"type":"string"},"selected":{"type":"boolean"}},"required":["index","name","selected"]}},"requiresChoice":{"type":"boolean"},"canChooseOtherPackage":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["choiceRef","packages","files","requiresChoice","canChooseOtherPackage"]}}]}
```

### confirmModpackChoices

确认本轮整合包选项并继续原任务。 重放已受理确认时须使用原任务行及原 choiceRef。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'confirmModpackChoices' --args '{"arg1":"7cc6a8e9-e662-477a-b58a-000000000004","arg2":"7cc6a8e9-e662-477a-b58a-000000000006"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"本次任务清单的行引用","maxLength":16384},"arg2":{"type":"string","description":"本次待确认选择的标识","maxLength":16384}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `operationRef` 时，该值等于原请求的 `arg2`（choiceRef）。

返回 `selectedRef` 时，该值等于原请求的 `arg1`（ref）。

当请求参数为 `{"ref":"7cc6a8e9-e662-477a-b58a-000000000004","choiceRef":"7cc6a8e9-e662-477a-b58a-000000000006"}` 时：
- `{"state":"ready","operationRef":"7cc6a8e9-e662-477a-b58a-000000000006","taskId":"modpack:demo","activityId":1731870000000,"outcome":"returned","originalActivityId":1731870000000,"selectedTaskId":"modpack:demo","action":"confirm","started":true,"choiceState":"committed","phase":"downloading","selectedRef":"7cc6a8e9-e662-477a-b58a-000000000004"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"queueUnavailable"}`
当请求参数为 `{"ref":"7cc6a8e9-e662-477a-b58a-000000000004","choiceRef":"7cc6a8e9-e662-477a-b58a-000000000006"}` 时：
- `{"state":"accepted","operationRef":"7cc6a8e9-e662-477a-b58a-000000000006","taskId":"modpack:demo","activityId":1731870000000,"outcome":"pending","originalActivityId":1731870000000,"selectedTaskId":"modpack:demo","action":"confirm","started":true,"choiceState":"committed","phase":"downloading","selectedRef":"7cc6a8e9-e662-477a-b58a-000000000004"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
当请求参数为 `{"ref":"7cc6a8e9-e662-477a-b58a-000000000004","choiceRef":"7cc6a8e9-e662-477a-b58a-000000000006"}` 时：
- `{"operationRef":"7cc6a8e9-e662-477a-b58a-000000000006","taskId":"modpack:demo","activityId":1731870000000,"outcome":"pending","originalActivityId":1731870000000,"selectedTaskId":"modpack:demo","action":"confirm","started":true,"choiceState":"committed","phase":"downloading","selectedRef":"7cc6a8e9-e662-477a-b58a-000000000004","state":"accepted"}`
当请求参数为 `{"ref":"7cc6a8e9-e662-477a-b58a-000000000004","choiceRef":"7cc6a8e9-e662-477a-b58a-000000000006"}` 时：
- `{"operationRef":"7cc6a8e9-e662-477a-b58a-000000000006","taskId":"modpack:demo","activityId":1731870000000,"outcome":"returned","originalActivityId":1731870000000,"selectedTaskId":"modpack:demo","action":"confirm","started":true,"choiceState":"committed","phase":"downloading","selectedRef":"7cc6a8e9-e662-477a-b58a-000000000004","state":"ready"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","accepted","unknown","unavailable","busy"]},"reason":{"type":"string"},"operationRef":{"type":"string","minLength":1},"selectedTaskId":{"type":"string"},"originalActivityId":{"type":"integer"},"taskId":{"type":"string","minLength":1},"activityId":{"type":"integer"},"action":{"type":"string"},"started":{"type":"boolean"},"choiceState":{"type":"string"},"outcome":{"type":"string"},"phase":{"type":"string"},"selectedRef":{"type":"string","description":"确认受理时的原任务行引用"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"accepted"}}},"then":{"required":["operationRef","taskId","activityId","outcome","originalActivityId","selectedTaskId","action","started","choiceState","phase","selectedRef"]}},{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["operationRef","taskId","activityId","outcome","originalActivityId","selectedTaskId","action","started","choiceState","phase","selectedRef"]}},{"if":{"required":["state"],"properties":{"state":{"const":"accepted"}}},"then":{"required":["outcome"],"properties":{"outcome":{"const":"pending"}}}},{"if":{"required":["state"],"properties":{"state":{"const":"ready"}}},"then":{"required":["outcome"],"properties":{"outcome":{"const":"returned"}}}}]}
```

### listResourceTargets

列出当前资源分类在沙箱、外部存储和另存模式的可选目标。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'listResourceTargets' --args '{"arg1":"mod"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'listResourceTargets' --args '{"arg1":"shader"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'listResourceTargets' --args '{"arg1":"resourcepack"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'listResourceTargets' --args '{"arg1":"modpack"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"资源分类","maxLength":16384,"enum":["mod","shader","resourcepack","modpack"]}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `kind` 时，该值等于原请求的 `arg1`（kind）。

当请求参数为 `{"kind":"mod"}` 时：
- `{"state":"ready","kind":"mod","target":"Fabric 1.21.1","location":"sandbox","external":[],"sandbox":["Fabric 1.21.1"],"customSave":true}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"panelBusy"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
当请求参数为 `{"kind":"mod"}` 时：
- `{"kind":"mod","target":"Fabric 1.21.1","location":"sandbox","external":[],"sandbox":["Fabric 1.21.1"],"customSave":true,"state":"ready"}`
当请求参数为 `{"kind":"shader"}` 时：
- `{"kind":"shader","target":"Fabric 1.21.1","location":"sandbox","external":[],"sandbox":["Fabric 1.21.1"],"customSave":true,"state":"ready"}`
当请求参数为 `{"kind":"resourcepack"}` 时：
- `{"kind":"resourcepack","target":"Fabric 1.21.1","location":"sandbox","external":[],"sandbox":["Fabric 1.21.1"],"customSave":true,"state":"ready"}`
当请求参数为 `{"kind":"modpack"}` 时：
- `{"kind":"modpack","target":"Fabric 1.21.1","location":"sandbox","external":[],"sandbox":["Fabric 1.21.1"],"customSave":false,"state":"ready"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","unknown","unavailable","busy"]},"reason":{"type":"string"},"kind":{"type":"string"},"target":{"type":"string"},"location":{"type":"string"},"external":{"type":"array","items":{"type":"string"}},"sandbox":{"type":"array","items":{"type":"string"}},"customSave":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["kind","target","location","external","sandbox","customSave"]}}]}
```

### selectResourceTarget

选择已列出的存储位置和实例，或选择自定义另存模式。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'selectResourceTarget' --args '{"arg1":"mod","arg2":"sandbox","arg3":"Fabric 1.21.1"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'selectResourceTarget' --args '{"arg1":"mod","arg2":"external","arg3":"Fabric 1.21.1"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'selectResourceTarget' --args '{"arg1":"shader","arg2":"custom"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'selectResourceTarget' --args '{"arg1":"modpack","arg2":"custom"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"资源分类","maxLength":16384,"enum":["mod","shader","resourcepack","modpack"]},"arg2":{"type":"string","description":"目标位置","maxLength":16384,"enum":["sandbox","external","custom"]},"arg3":{"type":["string"],"description":"已有实例","maxLength":16384}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]},"allOf":[{"if":{"properties":{"arg2":{"const":"sandbox"}},"required":["arg2"]},"then":{"required":["arg3"],"properties":{"arg3":{"type":"string","minLength":1}}}},{"if":{"properties":{"arg2":{"const":"external"}},"required":["arg2"]},"then":{"required":["arg3"],"properties":{"arg3":{"type":"string","minLength":1}}}}]}
```

执行返回值

返回 `instance` 时，该值等于原请求的 `arg3`（instance）。

返回 `location` 时，该值等于原请求的 `arg2`（location）。

当请求参数为 `{"kind":"mod","location":"sandbox","instance":"Fabric 1.21.1"}` 时：
- `{"state":"ready","location":"sandbox","instance":"Fabric 1.21.1"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
当请求参数为 `{"kind":"mod","location":"sandbox","instance":"Fabric 1.21.1"}` 时：
- `{"location":"sandbox","instance":"Fabric 1.21.1","state":"ready"}`
当请求参数为 `{"kind":"mod","location":"external","instance":"Fabric 1.21.1"}` 时：
- `{"location":"external","instance":"Fabric 1.21.1","state":"ready"}`
当请求参数为 `{"kind":"shader","location":"custom"}` 时：
- `{"location":"custom","state":"ready"}`
请求参数为 `{"location":"custom","kind":"modpack"}` 时不会返回 `{"state":"ready"}`。


```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","unknown","unavailable","busy"]},"reason":{"type":"string"},"instance":{"type":"string","description":"选择实例位置时返回；自选文件位置仅返回 location。"},"location":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["location"]}}]}
```

### listModpackRecovery

读取继续安装或补齐记录。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'listModpackRecovery' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","records":[]}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"modpackPageRequired"}`
- `{"state":"initializing"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","initializing","unknown","unavailable","busy"]},"reason":{"type":"string"},"records":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"instance":{"type":"string"},"missing":{"type":"integer"}},"required":["id","instance","missing"]}}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["records"]}}]}
```
