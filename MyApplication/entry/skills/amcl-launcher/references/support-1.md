# 启动、日志、消息与关于

### getLauncherState

查看当前启动器的初始化状态和等待隐私决定情况。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getLauncherState' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","product":"default","privacyPending":false,"initialized":true,"privacyRequired":false,"privacyDecision":"notRequired"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","product":"store","privacyPending":true,"initialized":false,"privacyRequired":true,"privacyDecision":"unknown"}`
- `{"state":"initializing","product":"default","privacyPending":false,"initialized":false,"privacyRequired":false,"privacyDecision":"notRequired"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","initializing","busy","unavailable","unknown"]},"reason":{"type":"string"},"product":{"type":"string"},"privacyPending":{"type":"boolean"},"privacyRequired":{"type":"boolean"},"privacyAgreed":{"type":"boolean"},"initialized":{"type":"boolean"},"privacyDecision":{"type":"string","enum":["notRequired","unknown","agreed","pending"]}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["product","privacyPending","initialized","privacyRequired","privacyDecision"]}},{"if":{"properties":{"state":{"const":"initializing"}}},"then":{"required":["product","privacyPending","initialized","privacyRequired","privacyDecision"]}},{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["product","privacyPending","initialized","privacyRequired","privacyDecision"]}}]}
```

### retryLauncherInitialization

仅在启动器报告初始化失败时重试准备，返回当前真实状态。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'retryLauncherInitialization' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"initializing","product":"default","privacyPending":false,"initialized":false,"privacyRequired":false,"privacyDecision":"notRequired"}`
- `{"state":"ready","product":"default","privacyPending":false,"initialized":true,"privacyRequired":false,"privacyDecision":"notRequired"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","product":"store","privacyPending":true,"initialized":false,"privacyRequired":true,"privacyDecision":"unknown"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["initializing","ready","failed","needsUser","busy","unavailable","unknown"]},"reason":{"type":"string"},"product":{"type":"string"},"privacyPending":{"type":"boolean"},"privacyRequired":{"type":"boolean"},"privacyAgreed":{"type":"boolean"},"initialized":{"type":"boolean"},"privacyDecision":{"type":"string","enum":["notRequired","unknown","agreed","pending"]}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["product","privacyPending","initialized","privacyRequired","privacyDecision"]}},{"if":{"properties":{"state":{"const":"initializing"}}},"then":{"required":["product","privacyPending","initialized","privacyRequired","privacyDecision"]}},{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["product","privacyPending","initialized","privacyRequired","privacyDecision"]}}]}
```

### openLauncherLog

在前台打开启动器运行日志，由用户阅读或复制脱敏诊断。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'openLauncherLog' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"needsUser","surface":"launcherLog"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"surface":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["surface"]}}]}
```

### openRecentGameLog

查找最近游戏活动并打开实际日志；没有可用原件时说明不可用。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'openRecentGameLog' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"needsUser"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","unavailable","busy","unknown","failed"]},"reason":{"type":"string"}},"additionalProperties":true}
```

### openPlayerSupport

打开产品允许的安装教程、JIT 帮助、问题反馈或支持作者页面。选图、网页提交和保存到相册由用户操作。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'openPlayerSupport' --args '{"arg1":"install"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"要打开的产品功能","maxLength":16384,"enum":["install","jit","feedback","sponsor"]}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"needsUser","surface":"pages/FeedbackPage"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","unavailable","busy","unknown","failed"]},"reason":{"type":"string"},"surface":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["surface"]}}]}
```

### readMessages

读取通知列表、未读角标和上一次整批清空决定，不外传私人正文。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readMessages' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","messages":[],"unread":0,"clearDecision":"idle"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"messages":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"kind":{"type":"integer"},"read":{"type":"boolean"},"createdAt":{"type":"integer"}},"required":["id","kind","read","createdAt"]}},"unread":{"type":"integer"},"clearDecision":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["messages","unread","clearDecision"]}}]}
```

### openMessage

在消息中心标记指定消息已读，并执行该消息原有导航。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'openMessage' --args '{"arg1":"messageId"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"readMessages 返回的 id","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","read":true,"destinationReached":true,"notificationGone":true}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"read":{"type":"boolean"},"destinationReached":{"type":"boolean"},"notificationGone":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["read","destinationReached","notificationGone"]}}]}
```

### markAllMessagesRead

将当前消息标记已读，回读剩余未读数。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'markAllMessagesRead' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","unread":0}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"unread":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["unread"]}}]}
```

### requestClearMessages

打开清空消息的产品确认框，由用户确认或取消，通过 readMessages 查询结果。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'requestClearMessages' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"needsUser","decision":"pending"}`
- `{"state":"ready","remaining":0}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"remaining":0,"state":"ready"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","ready","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"decision":{"type":"string"},"remaining":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["remaining"]}},{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["decision"]}},{"if":{"required":["state"],"properties":{"state":{"const":"ready"}}},"then":{"required":["remaining"],"properties":{"remaining":{"const":0}}}}]}
```

### readLauncherAbout

查询当前安装的应用版本、运行准入及公开的作者联系信息。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readLauncherAbout' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","versionName":"1.0.8-pre2","versionCode":1000911}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"versionName":{"type":"string"},"versionCode":{"type":"integer"},"email":{"type":"string"},"group":{"type":"string"},"repository":{"type":"string"},"gameRunAllowed":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["versionName","versionCode"]}}]}
```

### openStoreRunSettings

在商店产品内进入真实的运行准入设置并显示当前值，由用户自行切换。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'openStoreRunSettings' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"needsUser","surface":"AboutPage","gameRunAllowed":false}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","unavailable","busy","unknown","failed"]},"reason":{"type":"string"},"surface":{"type":"string"},"gameRunAllowed":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["surface","gameRunAllowed"]}}]}
```

### readReleaseNotes

读取当前渠道的更新日志，可按已有类别筛选，按版本分页。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readReleaseNotes' --args '{}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readReleaseNotes' --args '{"arg1":"","arg2":0}')
```

```json
{"type":"object","properties":{"arg1":{"type":["string"],"description":"变更类别，空表示全部","maxLength":16384},"arg2":{"anyOf":[{"type":"integer"},{"const":""}],"description":"版本列表从零开始的位置"}},"required":[],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `offset` 时，该值等于原请求的 `arg2`（offset）。

- `{"state":"initializing"}`
当请求参数为 `{"offset":0}` 时：
- `{"state":"ready","source":"随包数据","total":0,"offset":0,"releases":[]}`
- `{"state":"failed","reason":"invalidCategory"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["initializing","ready","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"source":{"type":"string"},"total":{"type":"integer"},"offset":{"type":"integer"},"releases":{"type":"array","items":{"type":"object","properties":{"version":{"type":"string"},"preview":{"type":"boolean"},"entries":{"type":"array","items":{"type":"string"}}},"required":["version","preview","entries"]}}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["source","total","offset","releases"]}}]}
```
