# 存储、通知、技术支持及备份

### readActivityStorage

通过生产活动账本读取已用字节数、各组数量与提醒阈值，不能读取时报告缺口。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readActivityStorage' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","bytes":0,"issueCount":0,"groups":[],"alertKnown":true,"alertBytes":0}`
- `{"state":"partial","bytes":0,"issueCount":1,"groups":[],"alertKnown":false,"reason":"thresholdUnconfirmed"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"bytes":0,"issueCount":0,"groups":[],"alertKnown":true,"alertBytes":0,"state":"ready"}`
- `{"bytes":0,"issueCount":1,"groups":[],"alertKnown":false,"state":"partial","reason":"thresholdUnconfirmed"}`
- `{"bytes":-1,"issueCount":1,"groups":[{"title":"示例实例","bytes":-1,"count":1}],"alertKnown":true,"alertBytes":0,"state":"partial"}`
- `{"bytes":0,"issueCount":1,"groups":[],"alertKnown":false,"reason":"thresholdUnconfirmed","state":"partial"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","partial","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"bytes":{"type":"integer","minimum":-1},"alertBytes":{"type":"integer"},"issueCount":{"type":"integer","minimum":0},"groups":{"type":"array","items":{"type":"object","properties":{"title":{"type":"string"},"bytes":{"type":"integer","minimum":-1},"count":{"type":"integer","minimum":0}},"required":["title","bytes","count"]}},"alertKnown":{"type":"boolean","description":"提醒阈值是否可证；未知时不返回 alertBytes。"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["bytes","issueCount","groups","alertKnown","alertBytes"]}},{"if":{"properties":{"state":{"const":"partial"}}},"then":{"required":["bytes","issueCount","groups","alertKnown"]}},{"if":{"required":["state"],"properties":{"state":{"const":"ready"}}},"then":{"required":["bytes","groups","issueCount","alertKnown","alertBytes"],"properties":{"bytes":{"minimum":0},"alertBytes":{"minimum":0},"groups":{"items":{"properties":{"bytes":{"minimum":0}}}},"issueCount":{"const":0},"alertKnown":{"const":true}}}},{"if":{"required":["state"],"properties":{"state":{"const":"partial"}}},"then":{"required":["issueCount"],"properties":{"issueCount":{"minimum":1}}}},{"if":{"required":["state","alertKnown"],"properties":{"state":{"const":"partial"},"alertKnown":{"const":true}}},"then":{"required":["alertBytes"],"properties":{}}},{"if":{"required":["state","alertKnown"],"properties":{"state":{"const":"partial"},"alertKnown":{"const":false}}},"then":{"required":["reason"],"properties":{"reason":{"const":"thresholdUnconfirmed"}}}}]}
```

### setActivityAlert

调整账本空间提醒，不会删除任何活动。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'setActivityAlert' --args '{"arg1":256}')
```

```json
{"type":"object","properties":{"arg1":{"type":"integer","description":"0关闭，单位 MiB","enum":[0,256,512,1024,2048]}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","alertBytes":268435456}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","unknown","busy","unavailable","failed"]},"reason":{"type":"string"},"alertBytes":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["alertBytes"]}}]}
```

### readHomeNotification

读取首页正在显示的消息引用、角标及提示可见性。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readHomeNotification' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","visible":false,"messageId":"","unread":0}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"messageId":{"type":"string"},"visible":{"type":"boolean"},"unread":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["visible","messageId","unread"]}}]}
```

### actOnHomeNotification

打开或略过当前可见的指定消息；打开沿用原入口，标记已读并回到相应活动。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'actOnHomeNotification' --args '{"arg1":"messageId","arg2":"open"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"readHomeNotification 返回的原消息号","maxLength":16384},"arg2":{"type":"string","description":"对原消息的操作","maxLength":16384,"enum":["open","dismiss"]}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

- `{"state":"ready","visible":false,"messageId":"","unread":0}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"messageId":{"type":"string"},"visible":{"type":"boolean"},"unread":{"type":"integer"},"read":{"type":"boolean"},"destinationReached":{"type":"boolean"}},"additionalProperties":true}
```

### readSupportPage

读取当前帮助、反馈或支持页面的加载、图片选择及保存到相册的结果。网站未给启动器的收据保持未知。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readSupportPage' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","title":"反馈","photoSelection":"idle","selectedImages":0,"album":"","remoteReceipt":"notProvidedByPage"}`
- `{"state":"failed","reason":"invalidArguments","title":"反馈","photoSelection":"idle","selectedImages":0,"album":"","remoteReceipt":"notProvidedByPage"}`
- `{"state":"initializing","title":"反馈","photoSelection":"idle","selectedImages":0,"album":"","remoteReceipt":"notProvidedByPage"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","initializing","busy","unavailable","unknown"]},"reason":{"type":"string"},"title":{"type":"string"},"photoSelection":{"type":"string"},"selectedImages":{"type":"integer"},"album":{"type":"string"},"remoteReceipt":{"type":"string","const":"notProvidedByPage"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["title","photoSelection","selectedImages","album","remoteReceipt"]}},{"if":{"properties":{"state":{"const":"initializing"}}},"then":{"required":["title","photoSelection","selectedImages","album","remoteReceipt"]}}]}
```

### retrySupportPage

在当前支持页面重新加载内容。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'retrySupportPage' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","title":"反馈","photoSelection":"idle","selectedImages":0,"album":"","remoteReceipt":"notProvidedByPage"}`
- `{"state":"failed","reason":"invalidArguments","title":"反馈","photoSelection":"idle","selectedImages":0,"album":"","remoteReceipt":"notProvidedByPage"}`
- `{"state":"initializing","title":"反馈","photoSelection":"idle","selectedImages":0,"album":"","remoteReceipt":"notProvidedByPage"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","initializing","busy","unavailable","unknown"]},"reason":{"type":"string"},"title":{"type":"string"},"photoSelection":{"type":"string"},"selectedImages":{"type":"integer"},"album":{"type":"string"},"remoteReceipt":{"type":"string","const":"notProvidedByPage"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["title","photoSelection","selectedImages","album","remoteReceipt"]}},{"if":{"properties":{"state":{"const":"initializing"}}},"then":{"required":["title","photoSelection","selectedImages","album","remoteReceipt"]}}]}
```

### viewSupportInBrowser

使用当前页面自带的地址进入系统浏览器。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'viewSupportInBrowser' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"needsUser","surface":"browser"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"surface":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["surface"]}}]}
```

### copyActivityEvidence

使用原页面的冻结与脱敏流程，复制本次全部可导出证据到剪贴板。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'copyActivityEvidence' --args '{"arg1":1}')
```

```json
{"type":"object","properties":{"arg1":{"type":"integer","description":"本次产品活动号"}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","failed","unavailable","unknown"]},"reason":{"type":"string"}},"additionalProperties":true}
```

### copyActivityEvent

只复制指定原文件起始行匹配的完整脱敏事件。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'copyActivityEvent' --args '{"arg1":1,"arg2":"fileId","arg3":1}')
```

```json
{"type":"object","properties":{"arg1":{"type":"integer","description":"本次产品活动号"},"arg2":{"type":"string","description":"已读原文件引用","maxLength":16384},"arg3":{"type":"integer","description":"事件起始行号"}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]}}
```

执行返回值

- `{"state":"ready"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","failed","unavailable","unknown"]},"reason":{"type":"string"}},"additionalProperties":true}
```

### readActivityFindings

读取该次活动的真实本地诊断线索，返回原文件及行号、严重度和证据缺口。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readActivityFindings' --args '{"arg1":1}')
```

```json
{"type":"object","properties":{"arg1":{"type":"integer","description":"本次产品活动号"}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","findings":[],"gaps":0}`
- `{"state":"partial","findings":[],"gaps":1}`
- `{"state":"initializing"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"findings":[],"gaps":0,"state":"ready"}`
- `{"findings":[],"gaps":1,"state":"partial"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","partial","initializing","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"findings":{"type":"array","items":{"type":"object","properties":{"fileId":{"type":"string"},"line":{"type":"integer"},"endLine":{"type":"integer"},"level":{"type":"integer"},"count":{"type":"integer"},"title":{"type":"string"}},"required":["fileId","line","endLine","level","count","title"]}},"gaps":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["findings","gaps"]}},{"if":{"properties":{"state":{"const":"partial"}}},"then":{"required":["findings","gaps"]}},{"if":{"required":["state"],"properties":{"state":{"const":"ready"}}},"then":{"required":["findings","gaps"],"properties":{"gaps":{"const":0}}}},{"if":{"required":["state"],"properties":{"state":{"const":"partial"}}},"then":{"required":["findings","gaps"],"properties":{"gaps":{"minimum":1}}}}]}
```

### readLauncherDiagnostics

读取启动器脱敏诊断摘要的可用性和版本；具体内容由用户在应用中阅读。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readLauncherDiagnostics' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","version":"1.0.8-pre2","summaryCharacters":842,"logPanelVisible":false}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"version":{"type":"string"},"summaryCharacters":{"type":"integer"},"logPanelVisible":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["version","summaryCharacters","logPanelVisible"]}}]}
```

### readSystemBackupStatus

查询本机已安装包的系统备份扩展配置以及应用最近实际收到的备份、恢复回调。备份由系统发起，回调不证明系统归档完成或某个世界已恢复。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readSystemBackupStatus' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","allowed":true,"initiator":"system","lastBackupCallback":{"state":"notObserved"},"lastRestoreCallback":{"state":"notObserved"},"systemOutcome":"notReportedByExtension"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","unavailable","unknown","busy","failed"]},"reason":{"type":"string"},"allowed":{"type":"boolean"},"initiator":{"const":"system"},"lastBackupCallback":{"type":"object","properties":{"state":{"enum":["observed","notObserved","unreadable"]},"at":{"type":"integer"}},"required":["state"]},"lastRestoreCallback":{"type":"object","properties":{"state":{"enum":["observed","notObserved","unreadable"]},"at":{"type":"integer"}},"required":["state"]},"systemOutcome":{"const":"notReportedByExtension"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["allowed","initiator","lastBackupCallback","lastRestoreCallback","systemOutcome"]}}]}
```
