# 皮肤披风、角色与布局清单

### importAppearanceImage

为共享素材库选择一张 PNG 并等待系统选择及真实导入结果

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'importAppearanceImage' --args '{"arg1":"editorRef","arg2":1,"arg3":"skin"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"刚读到的当前外观草稿引用","maxLength":16384},"arg2":{"type":"integer","description":"账号外观修订"},"arg3":{"type":"string","description":"纹理类型","maxLength":16384,"enum":["skin","cape"]}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]}}
```

执行返回值

返回 `kind` 时，该值等于原请求的 `arg3`（kind）。

当请求参数为 `{"editorRef":"editorRef","revision":1,"kind":"skin"}` 时：
- `{"state":"ready","assetId":"assetId","kind":"skin"}`
- `{"state":"cancelled"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"importAppearanceImage","operationRef":"current-operation"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","cancelled","needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"assetId":{"type":"string","description":"业务标识或保存的文字"},"kind":{"type":"string","description":"业务标识或保存的文字"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["assetId","kind"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"importAppearanceImage"}},"required":["operationRef","method"]}}]}
```

### requestRemoveAppearanceAsset

由玩家确认从共享库删除未被任何离线账号使用的纹理

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'requestRemoveAppearanceAsset' --args '{"arg1":"editorRef","arg2":1,"arg3":"assetId"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"刚读到的当前外观草稿引用","maxLength":16384},"arg2":{"type":"integer","description":"账号外观修订"},"arg3":{"type":"string","description":"当前共享库条目的引用","maxLength":16384}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]}}
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

### discardOfflineAppearance

放弃当前离线外观草稿并关闭编辑层

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'discardOfflineAppearance' --args '{"arg1":"editorRef","arg2":1}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"刚读到的当前外观草稿引用","maxLength":16384},"arg2":{"type":"integer","description":"账号外观修订"}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

- `{"state":"cancelled"}`
- `{"state":"needsUser"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["cancelled","needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"}},"additionalProperties":true}
```

### saveOfflineAppearance

保存并回读选中离线账号整份外观草稿

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'saveOfflineAppearance' --args '{"arg1":"appearance-1","arg2":1,"arg3":" Alex ","arg4":"","arg5":"","arg6":"CLASSIC"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"刚读到的当前外观草稿引用","maxLength":16384},"arg2":{"type":"integer","description":"账号外观修订"},"arg3":{"type":"string","description":"玩家名","maxLength":16384},"arg4":{"type":"string","description":"库内皮肤引用；空串为默认","maxLength":16384},"arg5":{"type":"string","description":"库内披风引用；空串为无","maxLength":16384},"arg6":{"type":"string","description":"手臂模型","maxLength":16384,"enum":["CLASSIC","SLIM"]}},"required":["arg1","arg2","arg3","arg4","arg5","arg6"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"],"arg5":["arg1","arg2","arg3","arg4"],"arg6":["arg1","arg2","arg3","arg4","arg5"]}}
```

执行返回值

返回 `skin` 时，该值等于原请求的 `arg4`（skin）。

返回 `cape` 时，该值等于原请求的 `arg5`（cape）。

返回 `playerName` 时取原请求 `arg3`（playerName）去除首尾空白后的值。

当请求参数为 `{"editorRef":"appearance-1","revision":1,"playerName":" Alex ","skin":"","cape":"","model":"CLASSIC"}` 时：
- `{"state":"ready","playerName":"Alex","skin":"","cape":"","model":"CLASSIC","revision":2}`
- `{"state":"needsUser"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"playerName":{"type":"string","description":"业务标识或保存的文字"},"skin":{"type":"string","description":"业务标识或保存的文字"},"cape":{"type":"string","description":"业务标识或保存的文字"},"model":{"type":"string","description":"业务标识或保存的文字"},"revision":{"type":"integer","description":"产品读取的计数、修订或位置"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["playerName","skin","cape","model","revision"]}}]}
```

### readPlayerRoles

列出当前第三方已登录账号的可切换匿名角色引用并显示原角色面板

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readPlayerRoles' --args '{"arg1":"605bb432-b416-401f-bec0-59879e326786"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"正在选用的第三方账号的匿名引用","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","roles":[{"roleRef":"76f35f71-20cc-42ef-88a3-027ba245ba56","selected":false},{"roleRef":"d7ee67c3-f122-4654-bfb0-64df3de5cdb7","selected":true}]}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"roles":{"type":"array","description":"角色","items":{"type":"object","description":"当前账号的匿名角色","properties":{"roleRef":{"type":"string","description":"业务标识或保存的文字","minLength":1},"selected":{"type":"boolean","description":"真实状态标志"}},"additionalProperties":false,"required":["roleRef","selected"]}}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["roles"]}}]}
```

### choosePlayerRole

切换指定的已登录皮肤站角色并核对持久化后的当前角色

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'choosePlayerRole' --args '{"arg1":"605bb432-b416-401f-bec0-59879e326786","arg2":"76f35f71-20cc-42ef-88a3-027ba245ba56"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"正在选用的第三方账号的匿名引用","maxLength":16384},"arg2":{"type":"string","description":"readPlayerRoles 返回的角色引用","maxLength":16384}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `roleRef` 时，该值等于原请求的 `arg2`（roleRef）。

当请求参数为 `{"accountRef":"605bb432-b416-401f-bec0-59879e326786","roleRef":"76f35f71-20cc-42ef-88a3-027ba245ba56"}` 时：
- `{"state":"ready","roleRef":"76f35f71-20cc-42ef-88a3-027ba245ba56"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"roleRef":{"type":"string","description":"业务标识或保存的文字","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["roleRef"]}}]}
```

### readPlayerAppearance

从已打开的账号外观页读取当前皮肤型号及拥有的披风，不返回令牌和网络地址

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readPlayerAppearance' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","appearanceRef":"appearanceRef","type":"type","hasSkin":false,"hasCape":false,"capes":[]}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"appearanceRef":{"type":"string","description":"业务标识或保存的文字"},"type":{"type":"string","description":"业务标识或保存的文字"},"hasSkin":{"type":"boolean","description":"真实状态标志"},"model":{"type":"string","description":"业务标识或保存的文字"},"hasCape":{"type":"boolean","description":"真实状态标志"},"capes":{"type":"array","description":"已拥有的披风","items":{"type":"object","description":"披风","properties":{"capeId":{"type":"string","description":"业务标识或保存的文字"},"name":{"type":"string","description":"业务标识或保存的文字"},"active":{"type":"boolean","description":"真实状态标志"}},"additionalProperties":false,"required":["capeId","name","active"]}}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["appearanceRef","type","hasSkin","hasCape","capes"]}}]}
```

### syncPlayerAppearance

同步当前正版账号的资料和披风到设备

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'syncPlayerAppearance' --args '{"arg1":"appearanceRef"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前在线外观详情回读的引用","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
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

### previewPlayerCape

在真实预览层展示所选披风

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'previewPlayerCape' --args '{"arg1":"appearanceRef","arg2":"capeId"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前在线外观详情回读的引用","maxLength":16384},"arg2":{"type":"string","description":"拥有的披风 ID；空串为无披风","maxLength":16384}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

- `{"state":"needsUser","surface":"capePreview"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"surface":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["surface"]}}]}
```

### changePlayerCape

由用户确认穿戴或脱下当前正版账号的披风，并回读远端和本地提交结果

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'changePlayerCape' --args '{"arg1":"appearanceRef","arg2":"capeId"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前在线外观详情回读的引用","maxLength":16384},"arg2":{"type":"string","description":"拥有的披风 ID；空串为无披风","maxLength":16384}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

- `{"state":"ready"}`
- `{"state":"cancelled"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"changePlayerCape","operationRef":"current-operation"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","cancelled","needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"changePlayerCape"}},"required":["operationRef","method"]}}]}
```

### openMinecraftProfileSite

在支持的渠道打开官方资料网站交给用户管理

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'openMinecraftProfileSite' --args '{"arg1":"appearanceRef"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前在线外观详情回读的引用","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
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

### listControlLayouts

读取完整布局目录、预设、活动方案及加载告警

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'listControlLayouts' --args '{}')
```

```json
{"type":"object","properties":{"arg1":{"anyOf":[{"type":"integer"},{"const":""}],"description":"非负分页起点"}},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","items":[],"total":1}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"total":{"type":"integer","description":"产品读取的计数、修订或位置"},"items":{"type":"array","description":"已加载的方案","items":{"type":"object","description":"布局","properties":{"id":{"type":"string","description":"业务标识或保存的文字"},"name":{"type":"string","description":"业务标识或保存的文字"},"revision":{"type":"integer","description":"产品读取的计数、修订或位置"},"preset":{"type":"boolean","description":"真实状态标志"},"active":{"type":"boolean","description":"真实状态标志"},"controls":{"type":"integer","description":"产品读取的计数、修订或位置"}},"additionalProperties":false,"required":["id","name","revision","preset","active","controls"]}},"hasWarnings":{"type":"boolean","description":"真实状态标志"},"deletionState":{"type":"string"},"deletionId":{"type":"string"},"lastImport":{"type":"object","description":"由已授权文件导入返回的本次结果"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["items","total"]}}]}
```
