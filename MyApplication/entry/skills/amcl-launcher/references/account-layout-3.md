# 布局导入导出和工作台

### importControlLayout

通过系统文档选择器和真实兼容性确认导入布局

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'importControlLayout' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","id":"id","name":"name","revision":1}`
- `{"state":"cancelled"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"importControlLayout","operationRef":"current-operation"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","cancelled","needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"name":{"type":"string","description":"业务标识或保存的文字"},"id":{"type":"string","description":"业务标识或保存的文字"},"revision":{"type":"integer","description":"产品读取的计数、修订或位置"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["id","name","revision"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"importControlLayout"}},"required":["operationRef","method"]}}]}
```

### useControlLayout

使用指定 ID 和修订的完整操控方案 ready 表示已核对当前活动布局 ID；可用 listControlLayouts 查看该布局。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'useControlLayout' --args '{"arg1":"name","arg2":"layoutId","arg3":1}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"方案名称","maxLength":16384},"arg2":{"type":"string","description":"目录返回的方案 ID","maxLength":16384},"arg3":{"type":"integer","description":"目录返回的修订"}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]}}
```

执行返回值

- `{"state":"ready"}`
- `{"state":"needsUser"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"}},"additionalProperties":true}
```

### copyControlLayout

复制已核实的原布局，返回独立的新 ID、修订 1 和实际名称。目标名在 trim 后无冲突时保留，重名时依次分配「 副本」「 副本 2」等后缀（完整名称最多 256 UTF-8 字节）。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'copyControlLayout' --args '{"arg1":"原布局","arg2":"layout-original","arg3":3,"arg4":" 我的布局 "}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'copyControlLayout' --args '{"arg1":"原布局","arg2":"layout-original","arg3":3,"arg4":" 原布局 "}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"方案名称","maxLength":16384},"arg2":{"type":"string","description":"目录返回的方案 ID","maxLength":16384},"arg3":{"type":"integer","description":"目录返回的修订"},"arg4":{"type":"string","description":"期望新名称，一至四十字","maxLength":16384}},"required":["arg1","arg2","arg3","arg4"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"]}}
```

执行返回值

- `{"state":"ready","id":"copied-layout","name":"我的布局","revision":1}`
- `{"state":"needsUser"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`
当请求参数为 `{"name":"原布局","layoutId":"layout-original","revision":3,"newName":" 原布局 "}` 时：
- `{"id":"new-copy-layout","name":"原布局 副本 2","revision":1,"state":"ready"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"name":{"type":"string","description":"业务标识或保存的文字"},"id":{"type":"string","description":"业务标识或保存的文字","minLength":1},"revision":{"type":"integer","description":"产品读取的计数、修订或位置","const":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["id","name","revision"]}}]}
```

### renameControlLayout

重命名已存在的非预设方案

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'renameControlLayout' --args '{"arg1":"原布局","arg2":"layout-original","arg3":3,"arg4":" 我的布局 "}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"方案名称","maxLength":16384},"arg2":{"type":"string","description":"目录返回的方案 ID","maxLength":16384},"arg3":{"type":"integer","description":"目录返回的修订"},"arg4":{"type":"string","description":"新名称，一至四十字","maxLength":16384}},"required":["arg1","arg2","arg3","arg4"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"]}}
```

执行返回值

返回 `id` 时，该值等于原请求的 `arg2`（layoutId）。

返回 `name` 时取原请求 `arg4`（newName）去除首尾空白后的值。

当请求参数为 `{"name":"原布局","layoutId":"layout-original","revision":3,"newName":" 我的布局 "}` 时：
- `{"state":"ready","id":"layout-original","name":"我的布局","revision":4}`
- `{"state":"needsUser"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"name":{"type":"string","description":"业务标识或保存的文字"},"id":{"type":"string","description":"业务标识或保存的文字"},"revision":{"type":"integer","description":"产品读取的计数、修订或位置"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["id","name","revision"]}}]}
```

### requestRemoveControlLayout

在应用请求二次确认删除指定自建方案

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'requestRemoveControlLayout' --args '{"arg1":"name","arg2":"layoutId","arg3":1}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"方案名称","maxLength":16384},"arg2":{"type":"string","description":"目录返回的方案 ID","maxLength":16384},"arg3":{"type":"integer","description":"目录返回的修订"}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]}}
```

执行返回值

返回 `id` 时，该值等于原请求的 `arg2`（layoutId）。

- `{"state":"needsUser"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"id":{"type":"string","description":"业务标识或保存的文字"}},"additionalProperties":true}
```

### exportControlLayout

通过系统保存指定最新或兼容布局副本

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'exportControlLayout' --args '{"arg1":"name","arg2":"layoutId","arg3":1}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"方案名称","maxLength":16384},"arg2":{"type":"string","description":"目录返回的方案 ID","maxLength":16384},"arg3":{"type":"integer","description":"目录返回的修订"},"arg4":{"anyOf":[{"type":"boolean"},{"const":""}],"description":"是否导出兼容副本"}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"]}}
```

执行返回值

- `{"state":"ready","saved":false}`
- `{"state":"cancelled"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"exportControlLayout","operationRef":"current-operation"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","cancelled","needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"saved":{"type":"boolean","description":"真实状态标志"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["saved"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"exportControlLayout"}},"required":["operationRef","method"]}}]}
```

### shareControlLayout

将指定布局交给系统分享面板

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'shareControlLayout' --args '{"arg1":"name","arg2":"layoutId","arg3":1}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"方案名称","maxLength":16384},"arg2":{"type":"string","description":"目录返回的方案 ID","maxLength":16384},"arg3":{"type":"integer","description":"目录返回的修订"}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]}}
```

执行返回值

- `{"state":"needsUser","reason":"awaitingUser","method":"shareControlLayout","operationRef":"current-operation"}`
- `{"state":"needsUser","surface":"systemShare"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"surface":{"type":"string"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"needsUser"}},"not":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}}},"then":{"required":["surface"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"shareControlLayout"}},"required":["operationRef","method"]}}]}
```

### openLayoutWorkbench

打开指定布局的几何编辑或手感与输入编辑器

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'openLayoutWorkbench' --args '{"arg1":"name","arg2":"layoutId","arg3":1,"arg4":"geometry"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"方案名称","maxLength":16384},"arg2":{"type":"string","description":"目录返回的方案 ID","maxLength":16384},"arg3":{"type":"integer","description":"目录返回的修订"},"arg4":{"type":"string","description":"编辑分区","maxLength":16384,"enum":["geometry","input"]}},"required":["arg1","arg2","arg3","arg4"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"]}}
```

执行返回值

返回 `name` 时，该值等于原请求的 `arg1`（name）。

- `{"state":"needsUser"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"name":{"type":"string","description":"业务标识或保存的文字"}},"additionalProperties":true}
```

### readControlWorkbench

查询当前布局草稿、按键、组、尺寸，操作后均需回读草稿版本

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readControlWorkbench' --args '{}')
```

```json
{"type":"object","properties":{"arg1":{"type":["string"],"description":"按控件标签或ID检索","maxLength":16384},"arg2":{"anyOf":[{"type":"integer"},{"const":""}],"description":"分页起点"}},"required":[],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

- `{"state":"draft","draftRef":"05ce49ef-fa73-4186-870b-293cebbfe27e","draftRevision":2,"activeControl":"jump","groups":[{"id":"custom-group","name":"快捷操作","visible":false,"secondary":false,"hidePrimary":false},{"id":"secondary-group","name":"物品栏","visible":false,"secondary":true,"hidePrimary":false}]}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["draft","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"draftRef":{"type":"string","description":"业务标识或保存的文字","minLength":1},"draftRevision":{"type":"integer","description":"产品读取的计数、修订或位置"},"name":{"type":"string","description":"业务标识或保存的文字"},"width":{"type":"number","description":"控件当前保存或投影的数值"},"height":{"type":"number","description":"控件当前保存或投影的数值"},"total":{"type":"integer","description":"产品读取的计数、修订或位置"},"activeControl":{"type":"string","description":"业务标识或保存的文字"},"activeGroup":{"type":"string","description":"业务标识或保存的文字"},"groups":{"type":"array","description":"组初始可见性","items":{"type":"object","description":"控件组","properties":{"id":{"type":"string","description":"业务标识或保存的文字"},"name":{"type":"string","description":"业务标识或保存的文字"},"visible":{"type":"boolean","description":"真实状态标志"},"secondary":{"type":"boolean"},"hidePrimary":{"type":"boolean"}},"additionalProperties":false,"required":["id","name","visible"]}},"scalePercent":{"type":"number","description":"控件当前保存或投影的数值"},"opacityPercent":{"type":"number","description":"控件当前保存或投影的数值"},"snap":{"type":"boolean","description":"真实状态标志"},"items":{"type":"array","description":"草稿控件","items":{"type":"object","description":"控件状态","properties":{"id":{"type":"string","description":"业务标识或保存的文字"},"name":{"type":"string","description":"业务标识或保存的文字"},"type":{"type":["integer","string"]},"parent":{"type":"string","description":"业务标识或保存的文字"},"group":{"type":"string","description":"业务标识或保存的文字"},"hidden":{"type":"boolean","description":"真实状态标志"},"locked":{"type":"boolean","description":"真实状态标志"},"x":{"type":"number","description":"控件当前保存或投影的数值"},"y":{"type":"number","description":"控件当前保存或投影的数值"},"width":{"type":"number","description":"控件当前保存或投影的数值"},"height":{"type":"number","description":"控件当前保存或投影的数值"},"scene":{"type":"string","description":"业务标识或保存的文字"},"visibility":{"type":"string","description":"业务标识或保存的文字"},"trigger":{"type":"string","description":"业务标识或保存的文字"},"keys":{"type":"array","description":"组合键","items":{"type":"integer","description":"产品读取的计数、修订或位置"}},"style":{"type":"string","description":"业务标识或保存的文字"},"phases":{"type":"string","description":"业务标识或保存的文字"},"groupActions":{"type":"string","description":"业务标识或保存的文字"},"swipeGroup":{"type":"string","description":"业务标识或保存的文字"},"dragLook":{"type":"boolean","description":"真实状态标志"},"secondaryAction":{"type":"string"}},"additionalProperties":false,"required":["id","name","type","parent","group","hidden","locked","x","y","width","height","scene","visibility","trigger","keys","style","phases","groupActions","swipeGroup","dragLook"]}},"defaultGroup":{"type":"string"},"snapGap":{"type":"number"},"snapStrength":{"type":"number"},"changed":{"type":"boolean","description":"该次动作是否改变了序列化业务草稿"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"draft"}}},"then":{"required":["draftRef","draftRevision"]}}]}
```

### finishControlWorkbench

保存、撤销、请求放弃或转到手感设置；未保存冲突时由人决定

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'finishControlWorkbench' --args '{"arg1":"05ce49ef-fa73-4186-870b-293cebbfe27e","arg2":2,"arg3":"undo"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'finishControlWorkbench' --args '{"arg1":"05ce49ef-fa73-4186-870b-293cebbfe27e","arg2":2,"arg3":"save"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'finishControlWorkbench' --args '{"arg1":"05ce49ef-fa73-4186-870b-293cebbfe27e","arg2":2,"arg3":"discard"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前编辑器签发的草稿引用","maxLength":16384},"arg2":{"type":"integer","description":"当前草稿版本"},"arg3":{"type":"string","description":"操作","maxLength":16384,"enum":["undo","save","discard","input"]}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]}}
```

执行返回值

返回 `draftRef` 时，该值等于原请求的 `arg1`（draftRef）。

当请求参数为 `{"draftRef":"05ce49ef-fa73-4186-870b-293cebbfe27e","draftRevision":2,"decision":"undo"}` 时：
- `{"state":"draft","draftRef":"05ce49ef-fa73-4186-870b-293cebbfe27e","draftRevision":3}`
- `{"state":"ready","name":"已保存的布局","layoutId":"saved-profile","revision":2}`
- `{"state":"needsUser"}`
- `{"state":"cancelled"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["draft","ready","needsUser","cancelled","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"draftRef":{"type":"string","description":"业务标识或保存的文字"},"draftRevision":{"type":"integer","description":"产品读取的计数、修订或位置"},"name":{"type":"string","description":"业务标识或保存的文字"},"width":{"type":"number","description":"控件当前保存或投影的数值"},"height":{"type":"number","description":"控件当前保存或投影的数值"},"total":{"type":"integer","description":"产品读取的计数、修订或位置"},"activeControl":{"type":"string","description":"业务标识或保存的文字"},"activeGroup":{"type":"string","description":"业务标识或保存的文字"},"groups":{"type":"array","description":"组初始可见性","items":{"type":"object","description":"控件组","properties":{"id":{"type":"string","description":"业务标识或保存的文字"},"name":{"type":"string","description":"业务标识或保存的文字"},"visible":{"type":"boolean","description":"真实状态标志"},"secondary":{"type":"boolean"},"hidePrimary":{"type":"boolean"}},"additionalProperties":false,"required":["id","name","visible"]}},"scalePercent":{"type":"number","description":"控件当前保存或投影的数值"},"opacityPercent":{"type":"number","description":"控件当前保存或投影的数值"},"snap":{"type":"boolean","description":"真实状态标志"},"items":{"type":"array","description":"草稿控件","items":{"type":"object","description":"控件状态","properties":{"id":{"type":"string","description":"业务标识或保存的文字"},"name":{"type":"string","description":"业务标识或保存的文字"},"type":{"type":["integer","string"]},"parent":{"type":"string","description":"业务标识或保存的文字"},"group":{"type":"string","description":"业务标识或保存的文字"},"hidden":{"type":"boolean","description":"真实状态标志"},"locked":{"type":"boolean","description":"真实状态标志"},"x":{"type":"number","description":"控件当前保存或投影的数值"},"y":{"type":"number","description":"控件当前保存或投影的数值"},"width":{"type":"number","description":"控件当前保存或投影的数值"},"height":{"type":"number","description":"控件当前保存或投影的数值"},"scene":{"type":"string","description":"业务标识或保存的文字"},"visibility":{"type":"string","description":"业务标识或保存的文字"},"trigger":{"type":"string","description":"业务标识或保存的文字"},"keys":{"type":"array","description":"组合键","items":{"type":"integer","description":"产品读取的计数、修订或位置"}},"style":{"type":"string","description":"业务标识或保存的文字"},"phases":{"type":"string","description":"业务标识或保存的文字"},"groupActions":{"type":"string","description":"业务标识或保存的文字"},"swipeGroup":{"type":"string","description":"业务标识或保存的文字"},"dragLook":{"type":"boolean","description":"真实状态标志"},"secondaryAction":{"type":"string"}},"additionalProperties":false,"required":["id","name","type","parent","group","hidden","locked","x","y","width","height","scene","visibility","trigger","keys","style","phases","groupActions","swipeGroup","dragLook"]}},"layoutId":{"type":"string","description":"业务标识或保存的文字"},"revision":{"type":"integer","description":"产品读取的计数、修订或位置"},"defaultGroup":{"type":"string"},"snapGap":{"type":"number"},"snapStrength":{"type":"number"},"changed":{"type":"boolean","description":"该次动作是否改变了序列化业务草稿"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["name","layoutId","revision"]}},{"if":{"properties":{"state":{"const":"draft"}}},"then":{"required":["draftRef","draftRevision"]}}]}
```

### addWorkbenchControl

创建普通组合键、常用按键，或找到/恢复摇杆和物品栏

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'addWorkbenchControl' --args '{"arg1":"05ce49ef-fa73-4186-870b-293cebbfe27e","arg2":2,"arg3":"button"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前编辑器签发的草稿引用","maxLength":16384},"arg2":{"type":"integer","description":"当前草稿版本"},"arg3":{"type":"string","description":"目录项","maxLength":16384,"enum":["button","joystick","hotbar","space","shift","e","esc","f3","f4","f5","tab"]},"arg4":{"type":["string"],"description":"普通按钮的键码，逗号分隔","maxLength":16384}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"]}}
```

执行返回值

返回 `draftRef` 时，该值等于原请求的 `arg1`（draftRef）。

当请求参数为 `{"draftRef":"05ce49ef-fa73-4186-870b-293cebbfe27e","draftRevision":2,"kind":"button"}` 时：
- `{"state":"draft","draftRef":"05ce49ef-fa73-4186-870b-293cebbfe27e","draftRevision":3}`
- `{"state":"needsUser"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["draft","needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"draftRef":{"type":"string","description":"业务标识或保存的文字"},"draftRevision":{"type":"integer","description":"产品读取的计数、修订或位置"},"name":{"type":"string","description":"业务标识或保存的文字"},"width":{"type":"number","description":"控件当前保存或投影的数值"},"height":{"type":"number","description":"控件当前保存或投影的数值"},"total":{"type":"integer","description":"产品读取的计数、修订或位置"},"activeControl":{"type":"string","description":"业务标识或保存的文字"},"activeGroup":{"type":"string","description":"业务标识或保存的文字"},"groups":{"type":"array","description":"组初始可见性","items":{"type":"object","description":"控件组","properties":{"id":{"type":"string","description":"业务标识或保存的文字"},"name":{"type":"string","description":"业务标识或保存的文字"},"visible":{"type":"boolean","description":"真实状态标志"},"secondary":{"type":"boolean"},"hidePrimary":{"type":"boolean"}},"additionalProperties":false,"required":["id","name","visible"]}},"scalePercent":{"type":"number","description":"控件当前保存或投影的数值"},"opacityPercent":{"type":"number","description":"控件当前保存或投影的数值"},"snap":{"type":"boolean","description":"真实状态标志"},"items":{"type":"array","description":"草稿控件","items":{"type":"object","description":"控件状态","properties":{"id":{"type":"string","description":"业务标识或保存的文字"},"name":{"type":"string","description":"业务标识或保存的文字"},"type":{"type":["integer","string"]},"parent":{"type":"string","description":"业务标识或保存的文字"},"group":{"type":"string","description":"业务标识或保存的文字"},"hidden":{"type":"boolean","description":"真实状态标志"},"locked":{"type":"boolean","description":"真实状态标志"},"x":{"type":"number","description":"控件当前保存或投影的数值"},"y":{"type":"number","description":"控件当前保存或投影的数值"},"width":{"type":"number","description":"控件当前保存或投影的数值"},"height":{"type":"number","description":"控件当前保存或投影的数值"},"scene":{"type":"string","description":"业务标识或保存的文字"},"visibility":{"type":"string","description":"业务标识或保存的文字"},"trigger":{"type":"string","description":"业务标识或保存的文字"},"keys":{"type":"array","description":"组合键","items":{"type":"integer","description":"产品读取的计数、修订或位置"}},"style":{"type":"string","description":"业务标识或保存的文字"},"phases":{"type":"string","description":"业务标识或保存的文字"},"groupActions":{"type":"string","description":"业务标识或保存的文字"},"swipeGroup":{"type":"string","description":"业务标识或保存的文字"},"dragLook":{"type":"boolean","description":"真实状态标志"},"secondaryAction":{"type":"string"}},"additionalProperties":false,"required":["id","name","type","parent","group","hidden","locked","x","y","width","height","scene","visibility","trigger","keys","style","phases","groupActions","swipeGroup","dragLook"]}},"defaultGroup":{"type":"string"},"snapGap":{"type":"number"},"snapStrength":{"type":"number"},"changed":{"type":"boolean","description":"该次动作是否改变了序列化业务草稿"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"draft"}}},"then":{"required":["draftRef","draftRevision"]}}]}
```

### editWorkbenchControl

选择、复制、锁定、隐藏或请求删除指定控件

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'editWorkbenchControl' --args '{"arg1":"05ce49ef-fa73-4186-870b-293cebbfe27e","arg2":2,"arg3":"jump","arg4":"lock"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前编辑器签发的草稿引用","maxLength":16384},"arg2":{"type":"integer","description":"当前草稿版本"},"arg3":{"type":"string","description":"草稿控件ID","maxLength":16384},"arg4":{"type":"string","description":"编辑意图","maxLength":16384,"enum":["select","duplicate","lock","unlock","hide","show","remove"]}},"required":["arg1","arg2","arg3","arg4"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"]}}
```

执行返回值

返回 `draftRef` 时，该值等于原请求的 `arg1`（draftRef）。

当请求参数为 `{"draftRef":"05ce49ef-fa73-4186-870b-293cebbfe27e","draftRevision":2,"controlId":"jump","change":"lock"}` 时：
- `{"state":"draft","draftRef":"05ce49ef-fa73-4186-870b-293cebbfe27e","draftRevision":3}`
- `{"state":"needsUser"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["draft","needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"draftRef":{"type":"string","description":"业务标识或保存的文字"},"draftRevision":{"type":"integer","description":"产品读取的计数、修订或位置"},"name":{"type":"string","description":"业务标识或保存的文字"},"width":{"type":"number","description":"控件当前保存或投影的数值"},"height":{"type":"number","description":"控件当前保存或投影的数值"},"total":{"type":"integer","description":"产品读取的计数、修订或位置"},"activeControl":{"type":"string","description":"业务标识或保存的文字"},"activeGroup":{"type":"string","description":"业务标识或保存的文字"},"groups":{"type":"array","description":"组初始可见性","items":{"type":"object","description":"控件组","properties":{"id":{"type":"string","description":"业务标识或保存的文字"},"name":{"type":"string","description":"业务标识或保存的文字"},"visible":{"type":"boolean","description":"真实状态标志"},"secondary":{"type":"boolean"},"hidePrimary":{"type":"boolean"}},"additionalProperties":false,"required":["id","name","visible"]}},"scalePercent":{"type":"number","description":"控件当前保存或投影的数值"},"opacityPercent":{"type":"number","description":"控件当前保存或投影的数值"},"snap":{"type":"boolean","description":"真实状态标志"},"items":{"type":"array","description":"草稿控件","items":{"type":"object","description":"控件状态","properties":{"id":{"type":"string","description":"业务标识或保存的文字"},"name":{"type":"string","description":"业务标识或保存的文字"},"type":{"type":["integer","string"]},"parent":{"type":"string","description":"业务标识或保存的文字"},"group":{"type":"string","description":"业务标识或保存的文字"},"hidden":{"type":"boolean","description":"真实状态标志"},"locked":{"type":"boolean","description":"真实状态标志"},"x":{"type":"number","description":"控件当前保存或投影的数值"},"y":{"type":"number","description":"控件当前保存或投影的数值"},"width":{"type":"number","description":"控件当前保存或投影的数值"},"height":{"type":"number","description":"控件当前保存或投影的数值"},"scene":{"type":"string","description":"业务标识或保存的文字"},"visibility":{"type":"string","description":"业务标识或保存的文字"},"trigger":{"type":"string","description":"业务标识或保存的文字"},"keys":{"type":"array","description":"组合键","items":{"type":"integer","description":"产品读取的计数、修订或位置"}},"style":{"type":"string","description":"业务标识或保存的文字"},"phases":{"type":"string","description":"业务标识或保存的文字"},"groupActions":{"type":"string","description":"业务标识或保存的文字"},"swipeGroup":{"type":"string","description":"业务标识或保存的文字"},"dragLook":{"type":"boolean","description":"真实状态标志"},"secondaryAction":{"type":"string"}},"additionalProperties":false,"required":["id","name","type","parent","group","hidden","locked","x","y","width","height","scene","visibility","trigger","keys","style","phases","groupActions","swipeGroup","dragLook"]}},"defaultGroup":{"type":"string"},"snapGap":{"type":"number"},"snapStrength":{"type":"number"},"changed":{"type":"boolean","description":"该次动作是否改变了序列化业务草稿"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"draft"}}},"then":{"required":["draftRef","draftRevision"]}}]}
```
