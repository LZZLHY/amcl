# 发布记录、活动证据与分享

### openLatestRelease

用产品的发布链接打开浏览器；更新记录为空时进入应用发行列表，遵守当前渠道的外链限制。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'openLatestRelease' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"initializing"}`
- `{"state":"needsUser","surface":"browser"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["initializing","needsUser","unavailable","busy","unknown","failed"]},"reason":{"type":"string"},"surface":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["surface"]}}]}
```

### readLocalPolicy

分段读取当前渠道随包的隐私政策、日志分享说明或第三方许可。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readLocalPolicy' --args '{"arg1":"privacy","arg2":8436}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"随包文档类别","maxLength":16384,"enum":["privacy","logshare","license"]},"arg2":{"anyOf":[{"type":"integer"},{"const":""}],"description":"起始字符位置"}},"required":["arg1"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

- `{"state":"ready","title":"隐私政策","length":8436,"text":""}`
- `{"state":"initializing"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","initializing","failed","unavailable","busy","unknown"]},"reason":{"type":"string"},"title":{"type":"string"},"text":{"type":"string"},"length":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["title","length","text"]}}]}
```

### readSharedLogs

按页读取分享状态和可撤回性，不返回令牌。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readSharedLogs' --args '{}')
```

```json
{"type":"object","properties":{"arg1":{"anyOf":[{"type":"integer"},{"const":""}],"description":"从零开始的列表位置"}},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"ready","records":[],"total":0}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["busy","failed","ready","unavailable","unknown"]},"reason":{"type":"string"},"total":{"type":"integer"},"records":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"activityId":{"type":"integer"},"createdAt":{"type":"integer"},"revocable":{"type":"boolean"},"status":{"type":"string"},"retention":{"type":"string"}},"required":["id","activityId","createdAt","revocable","status","retention"]}}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["records","total"]}}]}
```

### viewSharedLog

打开原分享选项，查看文件快照、复制链接或转到允许的网页。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'viewSharedLog' --args '{"arg1":"shareId","arg2":1}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"readSharedLogs 返回的分享号","maxLength":16384},"arg2":{"type":"integer","description":"与该条分享匹配的时间戳"}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

- `{"state":"failed","reason":"shareChanged"}`
- `{"state":"needsUser","surface":"shareOptions"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["failed","needsUser","unavailable","busy","unknown"]},"reason":{"type":"string"},"surface":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["surface"]}}]}
```

### requestRevokeSharedLog

请求撤回指定在线分享，由用户完成产品确认。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'requestRevokeSharedLog' --args '{"arg1":"shareId","arg2":1}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"readSharedLogs 返回的分享号","maxLength":16384},"arg2":{"type":"integer","description":"与该条分享匹配的时间戳"}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

- `{"state":"failed","reason":"shareChanged"}`
- `{"state":"needsUser","surface":"revokeShare"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["failed","needsUser","unavailable","busy","unknown"]},"reason":{"type":"string"},"surface":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["surface"]}}]}
```

### readActivity

查询指定活动的状态、保留状态、来源文件、缺失及分享回执。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readActivity' --args '{"arg1":42}')
```

```json
{"type":"object","properties":{"arg1":{"type":"integer","description":"原产品账本中的活动号"}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `activityId` 时，该值等于原请求的 `arg1`（activityId）。

当请求参数为 `{"activityId":42}` 时：
- `{"state":"ready","activityId":42,"files":[],"localFindings":0,"pinned":false,"publicShareId":"","authorReceipt":""}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","unavailable","failed","busy","unknown"]},"reason":{"type":"string"},"activityId":{"type":"integer"},"category":{"type":"string"},"outcome":{"type":"integer"},"pinned":{"type":"boolean"},"duration":{"type":"string"},"files":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"role":{"type":"string"},"capture":{"type":"string"},"bytes":{"type":"integer"}},"required":["id","role","capture","bytes"]}},"localFindings":{"type":"integer"},"integrity":{"type":"string"},"publicShareId":{"type":"string"},"authorReceipt":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["activityId","files","localFindings","pinned","publicShareId","authorReceipt"]}}]}
```

### readActivityEvents

按已登记活动、文件引用、级别或关键词读取真实阅读器的一页脱敏事件。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readActivityEvents' --args '{"arg1":1}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readActivityEvents' --args '{"arg1":1,"arg2":"","arg3":"","arg4":"","arg5":0}')
```

```json
{"type":"object","properties":{"arg1":{"type":"integer","description":"原产品账本中的活动号"},"arg2":{"type":["string"],"description":"原活动文件引用；留空搜索所有可读来源","maxLength":16384},"arg3":{"type":["string"],"description":"可选的搜索文本","maxLength":16384},"arg4":{"anyOf":[{"type":"integer"},{"const":""}],"description":"0全部、1警告以上、2错误以上"},"arg5":{"anyOf":[{"type":"integer"},{"const":""}],"description":"跳过的记录数"},"arg6":{"anyOf":[{"type":"integer"},{"const":""}],"description":"offset 指向的事件内已返回的显示块数，续页取上次 nextRowOffset"}},"required":["arg1"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"],"arg5":["arg1","arg2","arg3","arg4"],"arg6":["arg1","arg2","arg3","arg4","arg5"]}}
```

执行返回值

返回 `offset` 时，该值等于原请求的 `arg5`（offset）。

当请求参数为 `{"activityId":1,"offset":0}` 时：
- `{"state":"ready","events":[],"matches":0,"offset":0,"hasMore":false,"nextOffset":0,"nextRowOffset":0}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","unknown","busy","unavailable"]},"reason":{"type":"string"},"matches":{"type":"integer"},"offset":{"type":"integer"},"events":{"type":"array","items":{"type":"object","properties":{"fileId":{"type":"string"},"line":{"type":"integer"},"level":{"type":"integer"},"text":{"type":"string"},"eventLine":{"type":"integer"}}}},"hasMore":{"type":"boolean"},"nextOffset":{"type":"integer"},"nextRowOffset":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["events","matches","offset","hasMore","nextOffset","nextRowOffset"]}}]}
```

### setActivityRetention

为指定活动保留或取消保留，重新读取产品确认值。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'setActivityRetention' --args '{"arg1":42,"arg2":true}')
```

```json
{"type":"object","properties":{"arg1":{"type":"integer","description":"原产品账本中的活动号"},"arg2":{"type":"boolean","description":"是否固定保留"}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

当结果为 `{"state":"ready"}` 时，`pinned` 等于原请求 `arg2`（keep）。

当请求参数为 `{"activityId":42,"keep":true}` 时：
- `{"state":"ready","pinned":true}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"failed","reason":"invalidArguments"}`
当请求参数为 `{"activityId":42,"keep":true}` 时：
- `{"pinned":true,"state":"ready"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","unknown","busy","unavailable","failed"]},"reason":{"type":"string"},"pinned":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["pinned"]}},{"if":{"required":["state"],"properties":{"state":{"const":"ready"}}},"then":{"required":["pinned"],"properties":{}}}]}
```

### requestActivityRemoval

在原日志页面请求删除本地活动证据，等待产品确认并核对原活动。 用 getActivityChoiceOutcome 回读本次结果。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'requestActivityRemoval' --args '{"arg1":42}')
```

```json
{"type":"object","properties":{"arg1":{"type":"integer","description":"原产品账本中的活动号"}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `activityId` 时，该值等于原请求的 `arg1`（activityId）。

当请求参数为 `{"activityId":42}` 时：
- `{"state":"needsUser","operationRef":"e78a3bab-46a3-475d-80d1-0df5b31692ff","activityId":42,"operation":"requestActivityRemoval","reason":"evidenceChoice"}`
- `{"state":"busy","reason":"pendingChoices"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
当请求参数为 `{"activityId":42}` 时：
- `{"operationRef":"e78a3bab-46a3-475d-80d1-0df5b31692ff","activityId":42,"operation":"requestActivityRemoval","state":"needsUser","reason":"evidenceChoice"}`
当请求参数为 `{"activityId":42}` 时：
- `{"operationRef":"1aab259c-0932-4109-8776-70b808c03009","operation":"exportActivityEvidence","activityId":42,"state":"busy","reason":"existingChoice"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","busy","unavailable","failed","unknown"]},"reason":{"type":"string"},"operationRef":{"type":"string","minLength":1},"activityId":{"type":"integer"},"operation":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["operationRef","activityId","operation"]}},{"if":{"required":["state","reason"],"properties":{"state":{"const":"needsUser"},"reason":{"const":"evidenceChoice"}}},"then":{"required":["operationRef","operation","activityId"],"properties":{}}},{"if":{"required":["state","reason"],"properties":{"state":{"const":"busy"},"reason":{"const":"existingChoice"}}},"then":{"required":["operationRef","operation","activityId"],"properties":{}}}]}
```

### exportActivityEvidence

通过系统保存面板导出指定活动的脱敏 ZIP，区分已保存、取消和错误。 用 getActivityChoiceOutcome 回读本次结果。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'exportActivityEvidence' --args '{"arg1":42}')
```

```json
{"type":"object","properties":{"arg1":{"type":"integer","description":"原产品账本中的活动号"}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `activityId` 时，该值等于原请求的 `arg1`（activityId）。

当请求参数为 `{"activityId":42}` 时：
- `{"state":"needsUser","operationRef":"1aab259c-0932-4109-8776-70b808c03009","activityId":42,"operation":"exportActivityEvidence","reason":"evidenceChoice"}`
- `{"state":"busy","reason":"pendingChoices"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
当请求参数为 `{"activityId":42}` 时：
- `{"operationRef":"1aab259c-0932-4109-8776-70b808c03009","activityId":42,"operation":"exportActivityEvidence","state":"needsUser","reason":"evidenceChoice"}`
当请求参数为 `{"activityId":42}` 时：
- `{"operationRef":"1aab259c-0932-4109-8776-70b808c03009","operation":"exportActivityEvidence","activityId":42,"state":"busy","reason":"existingChoice"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","busy","unavailable","failed","unknown"]},"reason":{"type":"string"},"operationRef":{"type":"string","minLength":1},"activityId":{"type":"integer"},"operation":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["operationRef","activityId","operation"]}},{"if":{"required":["state","reason"],"properties":{"state":{"const":"needsUser"},"reason":{"const":"evidenceChoice"}}},"then":{"required":["operationRef","operation","activityId"],"properties":{}}},{"if":{"required":["state","reason"],"properties":{"state":{"const":"busy"},"reason":{"const":"existingChoice"}}},"then":{"required":["operationRef","operation","activityId"],"properties":{}}}]}
```

### reviewActivityShare

在设备上预览要发送的文件和目标，取得玩家的实际决定；用 readActivity 查询接收结果。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'reviewActivityShare' --args '{"arg1":42,"arg2":"logshare"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"integer","description":"原产品账本中的活动号"},"arg2":{"type":"string","description":"公开分享或允许渠道的作者反馈","maxLength":16384,"enum":["logshare","author"]}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `activityId` 时，该值等于原请求的 `arg1`（activityId）。

当请求参数为 `{"activityId":42,"destination":"logshare"}` 时：
- `{"state":"needsUser","surface":"sharePreview","activityId":42,"operationRef":"share-1"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`
当请求参数为 `{"activityId":42,"destination":"logshare"}` 时：
- `{"surface":"sharePreview","activityId":42,"operationRef":"share-1","state":"needsUser"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","unavailable","busy","unknown","failed"]},"reason":{"type":"string"},"surface":{"type":"string"},"activityId":{"type":"integer"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["surface","activityId","operationRef"]}},{"if":{"required":["state","surface"],"properties":{"state":{"const":"needsUser"},"surface":{"const":"sharePreview"}}},"then":{"required":["activityId","operationRef"],"properties":{}}}]}
```

### readHistoricalAnalysis

检查本地是否保留旧分析报告，存在时打开真实报告阅读页。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readHistoricalAnalysis' --args '{"arg1":1}')
```

```json
{"type":"object","properties":{"arg1":{"type":"integer","description":"原产品账本中的活动号"}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","available":false}`
- `{"state":"needsUser","available":true,"surface":"historicalReport","identifiedSource":true,"completedAt":1795456400000}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"available":{"type":"boolean"},"completedAt":{"type":"integer"},"surface":{"type":"string"},"identifiedSource":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["available"]}},{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["available","surface","identifiedSource","completedAt"]}}]}
```
