# 账号、登录与离线外观

### listPlayerAccounts

查看本机账号类型、当前选用和匿名操作引用

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'listPlayerAccounts' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","accounts":[{"accountRef":"605bb432-b416-401f-bec0-59879e326786","type":"mojang","selected":true}],"removalState":"idle","removalRef":""}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"accounts":{"type":"array","description":"当次面板的匿名账号","items":{"type":"object","description":"账号","properties":{"accountRef":{"type":"string","description":"业务标识或保存的文字"},"type":{"type":"string","description":"业务标识或保存的文字"},"selected":{"type":"boolean","description":"真实状态标志"}},"additionalProperties":false,"required":["accountRef","type","selected"]}},"removalRef":{"type":"string"},"removalState":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["accounts"]}}]}
```

### closePlayerAccounts

关闭当前账号管理面板

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'closePlayerAccounts' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","closed":false}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"closed":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["closed"]}}]}
```

### selectPlayerAccount

选用指定账号并回读持久选择 ready 表示已回读同一账号为选中项；通过 listPlayerAccounts 查看实际选择。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'selectPlayerAccount' --args '{"arg1":"accountRef"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"最近一次账号列表的匿名引用","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","unavailable","unknown","failed"]},"reason":{"type":"string"}},"additionalProperties":true}
```

### checkPlayerAccount

检查指定账号本地凭据状态

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'checkPlayerAccount' --args '{"arg1":"accountRef"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"最近一次账号列表的匿名引用","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","type":"type","credential":"credential"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"type":{"type":"string","description":"业务标识或保存的文字"},"credential":{"type":"string","description":"业务标识或保存的文字"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["type","credential"]}}]}
```

### showPlayerProfile

在应用内显示当前账号完整个人资料

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'showPlayerProfile' --args '{"arg1":"accountRef"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"最近一次账号列表的匿名引用","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"needsUser"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"}},"additionalProperties":true}
```

### addOfflinePlayer

从真实账号表单添加并选择离线玩家

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'addOfflinePlayer' --args '{"arg1":"playerName"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"玩家名，最长16个字符；空值遵循表单默认规则","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","accountRef":"accountRef","loginRef":"loginRef"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"loginRef":{"type":"string","description":"业务标识或保存的文字","minLength":1},"accountRef":{"type":"string","description":"业务标识或保存的文字"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["accountRef","loginRef"]}}]}
```

### beginPlayerLogin

打开指定的登录表单，由玩家授权或选择角色

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'beginPlayerLogin' --args '{"arg1":"authlib"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"认证提供方","maxLength":16384,"enum":["microsoft","authlib"]}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"needsUser","loginRef":"728bc987-e374-4de4-858f-6b77739538fb"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"loginRef":{"type":"string","description":"业务标识或保存的文字","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["loginRef"]}}]}
```

### readPlayerLogin

读取先前发起的登录结果或等待状态

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readPlayerLogin' --args '{"arg1":"728bc987-e374-4de4-858f-6b77739538fb"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"本账号面板签发的登录操作号","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `loginRef` 时，该值等于原请求的 `arg1`（loginRef）。

当请求参数为 `{"loginRef":"728bc987-e374-4de4-858f-6b77739538fb"}` 时：
- `{"state":"ready","loginRef":"728bc987-e374-4de4-858f-6b77739538fb","phase":"ready","accountRef":"605bb432-b416-401f-bec0-59879e326786"}`
当请求参数为 `{"loginRef":"728bc987-e374-4de4-858f-6b77739538fb"}` 时：
- `{"state":"needsUser","loginRef":"728bc987-e374-4de4-858f-6b77739538fb","phase":"opening"}`
当请求参数为 `{"loginRef":"728bc987-e374-4de4-858f-6b77739538fb"}` 时：
- `{"state":"cancelled","loginRef":"728bc987-e374-4de4-858f-6b77739538fb","phase":"cancelled"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","needsUser","cancelled","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"loginRef":{"type":"string","description":"业务标识或保存的文字"},"accountRef":{"type":"string","description":"业务标识或保存的文字"},"phase":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["loginRef","phase"]}},{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["loginRef","phase"]}},{"if":{"properties":{"state":{"const":"cancelled"}}},"then":{"required":["loginRef","phase"]}}]}
```

### refreshPlayerCredentials

刷新并保存当前在线账号的登录凭据

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'refreshPlayerCredentials' --args '{"arg1":"accountRef"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"最近一次账号列表的匿名引用","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","unavailable","unknown","failed"]},"reason":{"type":"string"}},"additionalProperties":true}
```

### requestRemovePlayer

在产品对话框确认移除本机账号，查看更新后的账号列表

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'requestRemovePlayer' --args '{"arg1":"605bb432-b416-401f-bec0-59879e326786"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"最近一次账号列表的匿名引用","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `accountRef` 时，该值等于原请求的 `arg1`（accountRef）。

当请求参数为 `{"accountRef":"605bb432-b416-401f-bec0-59879e326786"}` 时：
- `{"state":"needsUser","accountRef":"605bb432-b416-401f-bec0-59879e326786"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"accountRef":{"type":"string","description":"业务标识或保存的文字"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["accountRef"]}}]}
```

### openPlayerAppearance

查看本机已选账号外观摘要并打开对应的外观详情

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'openPlayerAppearance' --args '{"arg1":"accountRef"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"最近一次账号列表的匿名引用","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"needsUser","hasSkin":false,"hasCape":false,"model":"model"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"hasSkin":{"type":"boolean","description":"真实状态标志"},"hasCape":{"type":"boolean","description":"真实状态标志"},"model":{"type":"string","description":"业务标识或保存的文字"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["hasSkin","hasCape","model"]}}]}
```

### readOfflineAppearance

在已打开的离线外观面板读取库条目与当前草稿；不返回 PNG 路径

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readOfflineAppearance' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","editorRef":"editorRef","revision":1,"playerName":"playerName"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"editorRef":{"type":"string","description":"业务标识或保存的文字","minLength":1},"revision":{"type":"integer","description":"产品读取的计数、修订或位置"},"skin":{"type":"string","description":"业务标识或保存的文字"},"cape":{"type":"string","description":"业务标识或保存的文字"},"model":{"type":"string","description":"业务标识或保存的文字"},"assets":{"type":"array","description":"可选素材","items":{"type":"object","description":"素材","properties":{"id":{"type":"string","description":"业务标识或保存的文字"},"kind":{"type":"string","description":"业务标识或保存的文字"},"width":{"type":"integer","description":"产品读取的计数、修订或位置"},"height":{"type":"integer","description":"产品读取的计数、修订或位置"},"used":{"type":"boolean","description":"真实状态标志"}},"additionalProperties":false,"required":["id","kind","width","height","used"]}},"playerName":{"type":"string"},"storedName":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["editorRef","revision","playerName"]}}]}
```
