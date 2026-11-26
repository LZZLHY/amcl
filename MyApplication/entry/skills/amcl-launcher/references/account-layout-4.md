# 控件编辑、输入与保存结果

### setWorkbenchGeometry

将草稿控件定位到当前布局视口中的真实位置与显示尺寸

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'setWorkbenchGeometry' --args '{"arg1":"05ce49ef-fa73-4186-870b-293cebbfe27e","arg2":2,"arg3":"jump","arg4":20,"arg5":20,"arg6":64,"arg7":64}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前编辑器签发的草稿引用","maxLength":16384},"arg2":{"type":"integer","description":"当前草稿版本"},"arg3":{"type":"string","description":"草稿控件ID","maxLength":16384},"arg4":{"type":"integer","description":"当前视口的 vp 数值"},"arg5":{"type":"integer","description":"当前视口的 vp 数值"},"arg6":{"type":"integer","description":"当前视口的 vp 数值"},"arg7":{"type":"integer","description":"当前视口的 vp 数值"}},"required":["arg1","arg2","arg3","arg4","arg5","arg6","arg7"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"],"arg5":["arg1","arg2","arg3","arg4"],"arg6":["arg1","arg2","arg3","arg4","arg5"],"arg7":["arg1","arg2","arg3","arg4","arg5","arg6"]}}
```

执行返回值

返回 `draftRef` 时，该值等于原请求的 `arg1`（draftRef）。

当请求参数为 `{"draftRef":"05ce49ef-fa73-4186-870b-293cebbfe27e","draftRevision":2,"controlId":"jump","x":20,"y":20,"width":64,"height":64}` 时：
- `{"state":"draft","draftRef":"05ce49ef-fa73-4186-870b-293cebbfe27e","draftRevision":3}`
- `{"state":"needsUser"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["draft","needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"draftRef":{"type":"string","description":"业务标识或保存的文字"},"draftRevision":{"type":"integer","description":"产品读取的计数、修订或位置"},"name":{"type":"string","description":"业务标识或保存的文字"},"width":{"type":"number","description":"控件当前保存或投影的数值"},"height":{"type":"number","description":"控件当前保存或投影的数值"},"total":{"type":"integer","description":"产品读取的计数、修订或位置"},"activeControl":{"type":"string","description":"业务标识或保存的文字"},"activeGroup":{"type":"string","description":"业务标识或保存的文字"},"groups":{"type":"array","description":"组初始可见性","items":{"type":"object","description":"控件组","properties":{"id":{"type":"string","description":"业务标识或保存的文字"},"name":{"type":"string","description":"业务标识或保存的文字"},"visible":{"type":"boolean","description":"真实状态标志"},"secondary":{"type":"boolean"},"hidePrimary":{"type":"boolean"}},"additionalProperties":false,"required":["id","name","visible"]}},"scalePercent":{"type":"number","description":"控件当前保存或投影的数值"},"opacityPercent":{"type":"number","description":"控件当前保存或投影的数值"},"snap":{"type":"boolean","description":"真实状态标志"},"items":{"type":"array","description":"草稿控件","items":{"type":"object","description":"控件状态","properties":{"id":{"type":"string","description":"业务标识或保存的文字"},"name":{"type":"string","description":"业务标识或保存的文字"},"type":{"type":["integer","string"]},"parent":{"type":"string","description":"业务标识或保存的文字"},"group":{"type":"string","description":"业务标识或保存的文字"},"hidden":{"type":"boolean","description":"真实状态标志"},"locked":{"type":"boolean","description":"真实状态标志"},"x":{"type":"number","description":"控件当前保存或投影的数值"},"y":{"type":"number","description":"控件当前保存或投影的数值"},"width":{"type":"number","description":"控件当前保存或投影的数值"},"height":{"type":"number","description":"控件当前保存或投影的数值"},"scene":{"type":"string","description":"业务标识或保存的文字"},"visibility":{"type":"string","description":"业务标识或保存的文字"},"trigger":{"type":"string","description":"业务标识或保存的文字"},"keys":{"type":"array","description":"组合键","items":{"type":"integer","description":"产品读取的计数、修订或位置"}},"style":{"type":"string","description":"业务标识或保存的文字"},"phases":{"type":"string","description":"业务标识或保存的文字"},"groupActions":{"type":"string","description":"业务标识或保存的文字"},"swipeGroup":{"type":"string","description":"业务标识或保存的文字"},"dragLook":{"type":"boolean","description":"真实状态标志"},"secondaryAction":{"type":"string"}},"additionalProperties":false,"required":["id","name","type","parent","group","hidden","locked","x","y","width","height","scene","visibility","trigger","keys","style","phases","groupActions","swipeGroup","dragLook"]}},"defaultGroup":{"type":"string"},"snapGap":{"type":"number"},"snapStrength":{"type":"number"},"changed":{"type":"boolean","description":"该次动作是否改变了序列化业务草稿"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"draft"}}},"then":{"required":["draftRef","draftRevision"]}}]}
```

### setWorkbenchAppearance

设置控件名称、大小、文字和背景色、边框、透明度，或更改全局缩放及吸附

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'setWorkbenchAppearance' --args '{"arg1":"05ce49ef-fa73-4186-870b-293cebbfe27e","arg2":2,"arg3":"jump","arg4":"name","arg5":"跳跃"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前编辑器签发的草稿引用","maxLength":16384},"arg2":{"type":"integer","description":"当前草稿版本"},"arg3":{"type":"string","description":"草稿控件ID","maxLength":16384},"arg4":{"type":"string","description":"样式字段","maxLength":16384,"enum":["name","scale","opacity","corner","bg","fg","borderColor","backgroundAlpha","borderWidth","globalScale","globalOpacity","snap","snapGap","snapStrength"]},"arg5":{"type":"string","description":"新的合法数值、名称或 #RRGGBB","maxLength":16384}},"required":["arg1","arg2","arg3","arg4","arg5"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"],"arg5":["arg1","arg2","arg3","arg4"]}}
```

执行返回值

返回 `draftRef` 时，该值等于原请求的 `arg1`（draftRef）。

当请求参数为 `{"draftRef":"05ce49ef-fa73-4186-870b-293cebbfe27e","draftRevision":2,"controlId":"jump","field":"name","value":"跳跃"}` 时：
- `{"state":"draft","draftRef":"05ce49ef-fa73-4186-870b-293cebbfe27e","draftRevision":3}`
- `{"state":"needsUser"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["draft","needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"draftRef":{"type":"string","description":"业务标识或保存的文字"},"draftRevision":{"type":"integer","description":"产品读取的计数、修订或位置"},"name":{"type":"string","description":"业务标识或保存的文字"},"width":{"type":"number","description":"控件当前保存或投影的数值"},"height":{"type":"number","description":"控件当前保存或投影的数值"},"total":{"type":"integer","description":"产品读取的计数、修订或位置"},"activeControl":{"type":"string","description":"业务标识或保存的文字"},"activeGroup":{"type":"string","description":"业务标识或保存的文字"},"groups":{"type":"array","description":"组初始可见性","items":{"type":"object","description":"控件组","properties":{"id":{"type":"string","description":"业务标识或保存的文字"},"name":{"type":"string","description":"业务标识或保存的文字"},"visible":{"type":"boolean","description":"真实状态标志"},"secondary":{"type":"boolean"},"hidePrimary":{"type":"boolean"}},"additionalProperties":false,"required":["id","name","visible"]}},"scalePercent":{"type":"number","description":"控件当前保存或投影的数值"},"opacityPercent":{"type":"number","description":"控件当前保存或投影的数值"},"snap":{"type":"boolean","description":"真实状态标志"},"items":{"type":"array","description":"草稿控件","items":{"type":"object","description":"控件状态","properties":{"id":{"type":"string","description":"业务标识或保存的文字"},"name":{"type":"string","description":"业务标识或保存的文字"},"type":{"type":["integer","string"]},"parent":{"type":"string","description":"业务标识或保存的文字"},"group":{"type":"string","description":"业务标识或保存的文字"},"hidden":{"type":"boolean","description":"真实状态标志"},"locked":{"type":"boolean","description":"真实状态标志"},"x":{"type":"number","description":"控件当前保存或投影的数值"},"y":{"type":"number","description":"控件当前保存或投影的数值"},"width":{"type":"number","description":"控件当前保存或投影的数值"},"height":{"type":"number","description":"控件当前保存或投影的数值"},"scene":{"type":"string","description":"业务标识或保存的文字"},"visibility":{"type":"string","description":"业务标识或保存的文字"},"trigger":{"type":"string","description":"业务标识或保存的文字"},"keys":{"type":"array","description":"组合键","items":{"type":"integer","description":"产品读取的计数、修订或位置"}},"style":{"type":"string","description":"业务标识或保存的文字"},"phases":{"type":"string","description":"业务标识或保存的文字"},"groupActions":{"type":"string","description":"业务标识或保存的文字"},"swipeGroup":{"type":"string","description":"业务标识或保存的文字"},"dragLook":{"type":"boolean","description":"真实状态标志"},"secondaryAction":{"type":"string"}},"additionalProperties":false,"required":["id","name","type","parent","group","hidden","locked","x","y","width","height","scene","visibility","trigger","keys","style","phases","groupActions","swipeGroup","dragLook"]}},"defaultGroup":{"type":"string"},"snapGap":{"type":"number"},"snapStrength":{"type":"number"},"changed":{"type":"boolean","description":"该次动作是否改变了序列化业务草稿"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"draft"}}},"then":{"required":["draftRef","draftRevision"]}}]}
```

### setWorkbenchBinding

设置控件键码、触发、场景、滑动或分阶段按键与组显隐动作

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'setWorkbenchBinding' --args '{"arg1":"05ce49ef-fa73-4186-870b-293cebbfe27e","arg2":2,"arg3":"jump","arg4":"scene","arg5":"game"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前编辑器签发的草稿引用","maxLength":16384},"arg2":{"type":"integer","description":"当前草稿版本"},"arg3":{"type":"string","description":"草稿控件ID","maxLength":16384},"arg4":{"type":"string","description":"设置项目","maxLength":16384,"enum":["scene","visibility","swipeGroup","dragLook","trigger","keys","phaseKeys","groupTargets"]},"arg5":{"type":"string","description":"有界选项或逗号分隔的键码/组ID","maxLength":16384},"arg6":{"type":["string"],"description":"阶段","maxLength":16384,"enum":["press","longPress","click","doubleClick",""]},"arg7":{"type":["string"],"description":"组操作","maxLength":16384,"enum":["toggle","show","hide",""]},"arg8":{"anyOf":[{"type":"integer"},{"const":""}],"description":"原动作下标；-1新增"}},"required":["arg1","arg2","arg3","arg4","arg5"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"],"arg5":["arg1","arg2","arg3","arg4"],"arg6":["arg1","arg2","arg3","arg4","arg5"],"arg7":["arg1","arg2","arg3","arg4","arg5","arg6"],"arg8":["arg1","arg2","arg3","arg4","arg5","arg6","arg7"]}}
```

执行返回值

返回 `draftRef` 时，该值等于原请求的 `arg1`（draftRef）。

当请求参数为 `{"draftRef":"05ce49ef-fa73-4186-870b-293cebbfe27e","draftRevision":2,"controlId":"jump","field":"scene","value":"game"}` 时：
- `{"state":"draft","draftRef":"05ce49ef-fa73-4186-870b-293cebbfe27e","draftRevision":3}`
- `{"state":"needsUser"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["draft","needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"draftRef":{"type":"string","description":"业务标识或保存的文字"},"draftRevision":{"type":"integer","description":"产品读取的计数、修订或位置"},"name":{"type":"string","description":"业务标识或保存的文字"},"width":{"type":"number","description":"控件当前保存或投影的数值"},"height":{"type":"number","description":"控件当前保存或投影的数值"},"total":{"type":"integer","description":"产品读取的计数、修订或位置"},"activeControl":{"type":"string","description":"业务标识或保存的文字"},"activeGroup":{"type":"string","description":"业务标识或保存的文字"},"groups":{"type":"array","description":"组初始可见性","items":{"type":"object","description":"控件组","properties":{"id":{"type":"string","description":"业务标识或保存的文字"},"name":{"type":"string","description":"业务标识或保存的文字"},"visible":{"type":"boolean","description":"真实状态标志"},"secondary":{"type":"boolean"},"hidePrimary":{"type":"boolean"}},"additionalProperties":false,"required":["id","name","visible"]}},"scalePercent":{"type":"number","description":"控件当前保存或投影的数值"},"opacityPercent":{"type":"number","description":"控件当前保存或投影的数值"},"snap":{"type":"boolean","description":"真实状态标志"},"items":{"type":"array","description":"草稿控件","items":{"type":"object","description":"控件状态","properties":{"id":{"type":"string","description":"业务标识或保存的文字"},"name":{"type":"string","description":"业务标识或保存的文字"},"type":{"type":["integer","string"]},"parent":{"type":"string","description":"业务标识或保存的文字"},"group":{"type":"string","description":"业务标识或保存的文字"},"hidden":{"type":"boolean","description":"真实状态标志"},"locked":{"type":"boolean","description":"真实状态标志"},"x":{"type":"number","description":"控件当前保存或投影的数值"},"y":{"type":"number","description":"控件当前保存或投影的数值"},"width":{"type":"number","description":"控件当前保存或投影的数值"},"height":{"type":"number","description":"控件当前保存或投影的数值"},"scene":{"type":"string","description":"业务标识或保存的文字"},"visibility":{"type":"string","description":"业务标识或保存的文字"},"trigger":{"type":"string","description":"业务标识或保存的文字"},"keys":{"type":"array","description":"组合键","items":{"type":"integer","description":"产品读取的计数、修订或位置"}},"style":{"type":"string","description":"业务标识或保存的文字"},"phases":{"type":"string","description":"业务标识或保存的文字"},"groupActions":{"type":"string","description":"业务标识或保存的文字"},"swipeGroup":{"type":"string","description":"业务标识或保存的文字"},"dragLook":{"type":"boolean","description":"真实状态标志"},"secondaryAction":{"type":"string"}},"additionalProperties":false,"required":["id","name","type","parent","group","hidden","locked","x","y","width","height","scene","visibility","trigger","keys","style","phases","groupActions","swipeGroup","dragLook"]}},"defaultGroup":{"type":"string"},"snapGap":{"type":"number"},"snapStrength":{"type":"number"},"changed":{"type":"boolean","description":"该次动作是否改变了序列化业务草稿"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"draft"}}},"then":{"required":["draftRef","draftRevision"]}}]}
```

### arrangeWorkbenchSelection

对一组草稿中的控件执行对齐、等间距、复制、锁定和经确认的移除

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'arrangeWorkbenchSelection' --args '{"arg1":"05ce49ef-fa73-4186-870b-293cebbfe27e","arg2":2,"arg3":"jump","arg4":"lock"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前编辑器签发的草稿引用","maxLength":16384},"arg2":{"type":"integer","description":"当前草稿版本"},"arg3":{"type":"string","description":"逗号分隔的顶层控件ID","maxLength":16384},"arg4":{"type":"string","description":"变更类型","maxLength":16384,"enum":["horizontal","vertical","auto","space","duplicate","lock","unlock","anchor","remove","move","style"]},"arg5":{"type":["string"],"description":"网格锚点，如11为中心","maxLength":16384},"arg6":{"anyOf":[{"type":"integer"},{"const":""}],"description":"水平移动 vp"},"arg7":{"anyOf":[{"type":"integer"},{"const":""}],"description":"垂直移动 vp"},"arg8":{"type":["string"],"description":"批量样式字段","maxLength":16384},"arg9":{"type":["string"],"description":"批量样式目标值","maxLength":16384}},"required":["arg1","arg2","arg3","arg4"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"],"arg5":["arg1","arg2","arg3","arg4"],"arg6":["arg1","arg2","arg3","arg4","arg5"],"arg7":["arg1","arg2","arg3","arg4","arg5","arg6"],"arg8":["arg1","arg2","arg3","arg4","arg5","arg6","arg7"],"arg9":["arg1","arg2","arg3","arg4","arg5","arg6","arg7","arg8"]}}
```

执行返回值

返回 `draftRef` 时，该值等于原请求的 `arg1`（draftRef）。

当请求参数为 `{"draftRef":"05ce49ef-fa73-4186-870b-293cebbfe27e","draftRevision":2,"controlIds":"jump","arrangement":"lock"}` 时：
- `{"state":"draft","draftRef":"05ce49ef-fa73-4186-870b-293cebbfe27e","draftRevision":3}`
- `{"state":"needsUser"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["draft","needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"draftRef":{"type":"string","description":"业务标识或保存的文字"},"draftRevision":{"type":"integer","description":"产品读取的计数、修订或位置"},"name":{"type":"string","description":"业务标识或保存的文字"},"width":{"type":"number","description":"控件当前保存或投影的数值"},"height":{"type":"number","description":"控件当前保存或投影的数值"},"total":{"type":"integer","description":"产品读取的计数、修订或位置"},"activeControl":{"type":"string","description":"业务标识或保存的文字"},"activeGroup":{"type":"string","description":"业务标识或保存的文字"},"groups":{"type":"array","description":"组初始可见性","items":{"type":"object","description":"控件组","properties":{"id":{"type":"string","description":"业务标识或保存的文字"},"name":{"type":"string","description":"业务标识或保存的文字"},"visible":{"type":"boolean","description":"真实状态标志"},"secondary":{"type":"boolean"},"hidePrimary":{"type":"boolean"}},"additionalProperties":false,"required":["id","name","visible"]}},"scalePercent":{"type":"number","description":"控件当前保存或投影的数值"},"opacityPercent":{"type":"number","description":"控件当前保存或投影的数值"},"snap":{"type":"boolean","description":"真实状态标志"},"items":{"type":"array","description":"草稿控件","items":{"type":"object","description":"控件状态","properties":{"id":{"type":"string","description":"业务标识或保存的文字"},"name":{"type":"string","description":"业务标识或保存的文字"},"type":{"type":["integer","string"]},"parent":{"type":"string","description":"业务标识或保存的文字"},"group":{"type":"string","description":"业务标识或保存的文字"},"hidden":{"type":"boolean","description":"真实状态标志"},"locked":{"type":"boolean","description":"真实状态标志"},"x":{"type":"number","description":"控件当前保存或投影的数值"},"y":{"type":"number","description":"控件当前保存或投影的数值"},"width":{"type":"number","description":"控件当前保存或投影的数值"},"height":{"type":"number","description":"控件当前保存或投影的数值"},"scene":{"type":"string","description":"业务标识或保存的文字"},"visibility":{"type":"string","description":"业务标识或保存的文字"},"trigger":{"type":"string","description":"业务标识或保存的文字"},"keys":{"type":"array","description":"组合键","items":{"type":"integer","description":"产品读取的计数、修订或位置"}},"style":{"type":"string","description":"业务标识或保存的文字"},"phases":{"type":"string","description":"业务标识或保存的文字"},"groupActions":{"type":"string","description":"业务标识或保存的文字"},"swipeGroup":{"type":"string","description":"业务标识或保存的文字"},"dragLook":{"type":"boolean","description":"真实状态标志"},"secondaryAction":{"type":"string"}},"additionalProperties":false,"required":["id","name","type","parent","group","hidden","locked","x","y","width","height","scene","visibility","trigger","keys","style","phases","groupActions","swipeGroup","dragLook"]}},"defaultGroup":{"type":"string"},"snapGap":{"type":"number"},"snapStrength":{"type":"number"},"changed":{"type":"boolean","description":"该次动作是否改变了序列化业务草稿"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"draft"}}},"then":{"required":["draftRef","draftRevision"]}}]}
```

### editWorkbenchGroup

按当前草稿管理原生组及二级组。新建时提供非空组名。操作已有组前先从 readControlWorkbench 的 groups 取其 ID；重命名、绑定入口和修改入口比例还要提供新值。members 接受控件 ID 列表，空列表将清空成员。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'editWorkbenchGroup' --args '{"arg1":"05ce49ef-fa73-4186-870b-293cebbfe27e","arg2":2,"arg3":"create","arg4":"","arg5":"快捷操作"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'editWorkbenchGroup' --args '{"arg1":"05ce49ef-fa73-4186-870b-293cebbfe27e","arg2":2,"arg3":"remove","arg4":"custom-group"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'editWorkbenchGroup' --args '{"arg1":"05ce49ef-fa73-4186-870b-293cebbfe27e","arg2":2,"arg3":"rename","arg4":"custom-group","arg5":"常用操作"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'editWorkbenchGroup' --args '{"arg1":"05ce49ef-fa73-4186-870b-293cebbfe27e","arg2":2,"arg3":"bindOpener","arg4":"secondary-group","arg5":"jump"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'editWorkbenchGroup' --args '{"arg1":"05ce49ef-fa73-4186-870b-293cebbfe27e","arg2":2,"arg3":"openerRatio","arg4":"secondary-group","arg5":"2:1"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前编辑器签发的草稿引用","maxLength":16384},"arg2":{"type":"integer","description":"当前草稿版本"},"arg3":{"type":"string","description":"组操作","maxLength":16384,"enum":["create","createSecondary","rename","showInitially","hideInitially","raise","lower","duplicate","remove","addReturn","createOpener","bindOpener","unbindOpener","members","openerRatio","hideDuringUse","showDuringUse"]},"arg4":{"type":["string"],"description":"现有组ID，创建时不需要","maxLength":16384},"arg5":{"type":["string"],"description":"新组名、成员ID列表、入口ID或尺寸比例","maxLength":16384}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"],"arg5":["arg1","arg2","arg3","arg4"]},"allOf":[{"if":{"properties":{"arg3":{"const":"create"}},"required":["arg3"]},"then":{"required":["arg5"],"properties":{"arg5":{"type":"string","minLength":1}}}},{"if":{"properties":{"arg3":{"const":"createSecondary"}},"required":["arg3"]},"then":{"required":["arg5"],"properties":{"arg5":{"type":"string","minLength":1}}}},{"if":{"properties":{"arg3":{"const":"rename"}},"required":["arg3"]},"then":{"required":["arg4","arg5"],"properties":{"arg4":{"type":"string","minLength":1},"arg5":{"type":"string","minLength":1}}}},{"if":{"properties":{"arg3":{"const":"showInitially"}},"required":["arg3"]},"then":{"required":["arg4"],"properties":{"arg4":{"type":"string","minLength":1}}}},{"if":{"properties":{"arg3":{"const":"hideInitially"}},"required":["arg3"]},"then":{"required":["arg4"],"properties":{"arg4":{"type":"string","minLength":1}}}},{"if":{"properties":{"arg3":{"const":"raise"}},"required":["arg3"]},"then":{"required":["arg4"],"properties":{"arg4":{"type":"string","minLength":1}}}},{"if":{"properties":{"arg3":{"const":"lower"}},"required":["arg3"]},"then":{"required":["arg4"],"properties":{"arg4":{"type":"string","minLength":1}}}},{"if":{"properties":{"arg3":{"const":"duplicate"}},"required":["arg3"]},"then":{"required":["arg4"],"properties":{"arg4":{"type":"string","minLength":1}}}},{"if":{"properties":{"arg3":{"const":"remove"}},"required":["arg3"]},"then":{"required":["arg4"],"properties":{"arg4":{"type":"string","minLength":1}}}},{"if":{"properties":{"arg3":{"const":"addReturn"}},"required":["arg3"]},"then":{"required":["arg4"],"properties":{"arg4":{"type":"string","minLength":1}}}},{"if":{"properties":{"arg3":{"const":"createOpener"}},"required":["arg3"]},"then":{"required":["arg4"],"properties":{"arg4":{"type":"string","minLength":1}}}},{"if":{"properties":{"arg3":{"const":"bindOpener"}},"required":["arg3"]},"then":{"required":["arg4","arg5"],"properties":{"arg4":{"type":"string","minLength":1},"arg5":{"type":"string","minLength":1}}}},{"if":{"properties":{"arg3":{"const":"unbindOpener"}},"required":["arg3"]},"then":{"required":["arg4"],"properties":{"arg4":{"type":"string","minLength":1}}}},{"if":{"properties":{"arg3":{"const":"members"}},"required":["arg3"]},"then":{"required":["arg4"],"properties":{"arg4":{"type":"string","minLength":1}}}},{"if":{"properties":{"arg3":{"const":"openerRatio"}},"required":["arg3"]},"then":{"required":["arg4","arg5"],"properties":{"arg4":{"type":"string","minLength":1},"arg5":{"type":"string","minLength":1}}}},{"if":{"properties":{"arg3":{"const":"hideDuringUse"}},"required":["arg3"]},"then":{"required":["arg4"],"properties":{"arg4":{"type":"string","minLength":1}}}},{"if":{"properties":{"arg3":{"const":"showDuringUse"}},"required":["arg3"]},"then":{"required":["arg4"],"properties":{"arg4":{"type":"string","minLength":1}}}}]}
```

执行返回值

返回 `draftRef` 时，该值等于原请求的 `arg1`（draftRef）。

返回 `groupId` 时，该值等于原请求的 `arg4`（groupId）。

当请求参数为 `{"draftRef":"05ce49ef-fa73-4186-870b-293cebbfe27e","draftRevision":2,"change":"create","value":"快捷操作"}` 时：
- `{"state":"draft","draftRef":"05ce49ef-fa73-4186-870b-293cebbfe27e","draftRevision":3}`
当请求参数为 `{"draftRef":"05ce49ef-fa73-4186-870b-293cebbfe27e","draftRevision":2,"change":"remove","groupId":"custom-group"}` 时：
- `{"state":"needsUser","surface":"groupRemoval","groupId":"custom-group"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`
当请求参数为 `{"draftRef":"05ce49ef-fa73-4186-870b-293cebbfe27e","draftRevision":2,"change":"remove","groupId":"custom-group"}` 时：
- `{"groupId":"custom-group","state":"needsUser","surface":"groupRemoval"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["draft","needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"draftRef":{"type":"string","description":"业务标识或保存的文字"},"draftRevision":{"type":"integer","description":"产品读取的计数、修订或位置"},"name":{"type":"string","description":"业务标识或保存的文字"},"width":{"type":"number","description":"控件当前保存或投影的数值"},"height":{"type":"number","description":"控件当前保存或投影的数值"},"total":{"type":"integer","description":"产品读取的计数、修订或位置"},"activeControl":{"type":"string","description":"业务标识或保存的文字"},"activeGroup":{"type":"string","description":"业务标识或保存的文字"},"groups":{"type":"array","description":"组初始可见性","items":{"type":"object","description":"控件组","properties":{"id":{"type":"string","description":"业务标识或保存的文字"},"name":{"type":"string","description":"业务标识或保存的文字"},"visible":{"type":"boolean","description":"真实状态标志"},"secondary":{"type":"boolean"},"hidePrimary":{"type":"boolean"}},"additionalProperties":false,"required":["id","name","visible"]}},"scalePercent":{"type":"number","description":"控件当前保存或投影的数值"},"opacityPercent":{"type":"number","description":"控件当前保存或投影的数值"},"snap":{"type":"boolean","description":"真实状态标志"},"items":{"type":"array","description":"草稿控件","items":{"type":"object","description":"控件状态","properties":{"id":{"type":"string","description":"业务标识或保存的文字"},"name":{"type":"string","description":"业务标识或保存的文字"},"type":{"type":["integer","string"]},"parent":{"type":"string","description":"业务标识或保存的文字"},"group":{"type":"string","description":"业务标识或保存的文字"},"hidden":{"type":"boolean","description":"真实状态标志"},"locked":{"type":"boolean","description":"真实状态标志"},"x":{"type":"number","description":"控件当前保存或投影的数值"},"y":{"type":"number","description":"控件当前保存或投影的数值"},"width":{"type":"number","description":"控件当前保存或投影的数值"},"height":{"type":"number","description":"控件当前保存或投影的数值"},"scene":{"type":"string","description":"业务标识或保存的文字"},"visibility":{"type":"string","description":"业务标识或保存的文字"},"trigger":{"type":"string","description":"业务标识或保存的文字"},"keys":{"type":"array","description":"组合键","items":{"type":"integer","description":"产品读取的计数、修订或位置"}},"style":{"type":"string","description":"业务标识或保存的文字"},"phases":{"type":"string","description":"业务标识或保存的文字"},"groupActions":{"type":"string","description":"业务标识或保存的文字"},"swipeGroup":{"type":"string","description":"业务标识或保存的文字"},"dragLook":{"type":"boolean","description":"真实状态标志"},"secondaryAction":{"type":"string"}},"additionalProperties":false,"required":["id","name","type","parent","group","hidden","locked","x","y","width","height","scene","visibility","trigger","keys","style","phases","groupActions","swipeGroup","dragLook"]}},"defaultGroup":{"type":"string"},"snapGap":{"type":"number"},"snapStrength":{"type":"number"},"changed":{"type":"boolean","description":"该次动作是否改变了序列化业务草稿"},"groupId":{"type":"string"},"surface":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"draft"}}},"then":{"required":["draftRef","draftRevision"]}}]}
```

### readInputWorkbench

读取当前方案的触控与视角完整草稿及输入选项

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readInputWorkbench' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"draft","draftRef":"3f5f8109-6ea0-4251-9845-c5d300ec5963","draftRevision":2}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["draft","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"draftRef":{"type":"string","description":"业务标识或保存的文字","minLength":1},"draftRevision":{"type":"integer","description":"产品读取的计数、修订或位置"},"name":{"type":"string","description":"业务标识或保存的文字"},"touch":{"type":"string","description":"业务标识或保存的文字"},"joystickDeadZone":{"type":"number","description":"控件当前保存或投影的数值"},"haptic":{"type":"boolean","description":"真实状态标志"},"source":{"type":"string","description":"业务标识或保存的文字"},"independent":{"type":"boolean","description":"真实状态标志"},"look":{"type":"string","description":"业务标识或保存的文字"},"actions":{"type":"array","description":"触控动作名称","items":{"type":"string","description":"业务标识或保存的文字"}},"changed":{"type":"boolean","description":"该次动作是否改变了序列化业务草稿"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"draft"}}},"then":{"required":["draftRef","draftRevision"]}}]}
```

### finishInputWorkbench

保存、撤销或请求放弃当前输入草稿

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'finishInputWorkbench' --args '{"arg1":"3f5f8109-6ea0-4251-9845-c5d300ec5963","arg2":2,"arg3":"undo"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'finishInputWorkbench' --args '{"arg1":"3f5f8109-6ea0-4251-9845-c5d300ec5963","arg2":2,"arg3":"save"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'finishInputWorkbench' --args '{"arg1":"3f5f8109-6ea0-4251-9845-c5d300ec5963","arg2":2,"arg3":"discard"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前输入编辑器的草稿引用","maxLength":16384},"arg2":{"type":"integer","description":"当前草稿版本"},"arg3":{"type":"string","description":"编辑意图","maxLength":16384,"enum":["save","discard","undo"]}},"required":["arg1","arg2","arg3"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"]}}
```

执行返回值

返回 `draftRef` 时，该值等于原请求的 `arg1`（draftRef）。

当请求参数为 `{"draftRef":"3f5f8109-6ea0-4251-9845-c5d300ec5963","draftRevision":2,"decision":"undo"}` 时：
- `{"state":"draft","draftRef":"3f5f8109-6ea0-4251-9845-c5d300ec5963","draftRevision":3}`
- `{"state":"ready","name":"已保存的布局","layoutId":"saved-profile","revision":2}`
- `{"state":"needsUser"}`
- `{"state":"cancelled"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["draft","ready","needsUser","cancelled","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"draftRef":{"type":"string","description":"业务标识或保存的文字"},"draftRevision":{"type":"integer","description":"产品读取的计数、修订或位置"},"name":{"type":"string","description":"业务标识或保存的文字"},"touch":{"type":"string","description":"业务标识或保存的文字"},"joystickDeadZone":{"type":"number","description":"控件当前保存或投影的数值"},"haptic":{"type":"boolean","description":"真实状态标志"},"source":{"type":"string","description":"业务标识或保存的文字"},"independent":{"type":"boolean","description":"真实状态标志"},"look":{"type":"string","description":"业务标识或保存的文字"},"actions":{"type":"array","description":"触控动作名称","items":{"type":"string","description":"业务标识或保存的文字"}},"layoutId":{"type":"string","description":"业务标识或保存的文字"},"revision":{"type":"integer","description":"产品读取的计数、修订或位置"},"changed":{"type":"boolean","description":"该次动作是否改变了序列化业务草稿"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["name","layoutId","revision"]}},{"if":{"properties":{"state":{"const":"draft"}}},"then":{"required":["draftRef","draftRevision"]}}]}
```

### setTouchOption

调整移动、菜单、快捷栏、陀螺仪或按键动作的草稿设置

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'setTouchOption' --args '{"arg1":"3f5f8109-6ea0-4251-9845-c5d300ec5963","arg2":2,"arg3":"scroll","arg4":"true"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前输入编辑器的草稿引用","maxLength":16384},"arg2":{"type":"integer","description":"当前草稿版本"},"arg3":{"type":"string","description":"触控选项","maxLength":16384,"enum":["scroll","sprint","bindings","swap","drop","gyroX","gyroY","menu","joystick","gyroMode","menuSpeed","menuHold","sprintThreshold","hold","gyroScale","deadZone","action"]},"arg4":{"type":"string","description":"布尔文本、百分比、毫秒、模式或键码；动作支持inherit/unbind","maxLength":16384},"arg5":{"type":["string"],"description":"动作名称，只用于action","maxLength":16384}},"required":["arg1","arg2","arg3","arg4"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"],"arg5":["arg1","arg2","arg3","arg4"]}}
```

执行返回值

返回 `draftRef` 时，该值等于原请求的 `arg1`（draftRef）。

当请求参数为 `{"draftRef":"3f5f8109-6ea0-4251-9845-c5d300ec5963","draftRevision":2,"field":"scroll","value":"true"}` 时：
- `{"state":"draft","draftRef":"3f5f8109-6ea0-4251-9845-c5d300ec5963","draftRevision":3}`
- `{"state":"needsUser"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["draft","needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"draftRef":{"type":"string","description":"业务标识或保存的文字"},"draftRevision":{"type":"integer","description":"产品读取的计数、修订或位置"},"name":{"type":"string","description":"业务标识或保存的文字"},"touch":{"type":"string","description":"业务标识或保存的文字"},"joystickDeadZone":{"type":"number","description":"控件当前保存或投影的数值"},"haptic":{"type":"boolean","description":"真实状态标志"},"source":{"type":"string","description":"业务标识或保存的文字"},"independent":{"type":"boolean","description":"真实状态标志"},"look":{"type":"string","description":"业务标识或保存的文字"},"actions":{"type":"array","description":"触控动作名称","items":{"type":"string","description":"业务标识或保存的文字"}},"changed":{"type":"boolean","description":"该次动作是否改变了序列化业务草稿"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"draft"}}},"then":{"required":["draftRef","draftRevision"]}}]}
```

### setLookOption

按输入来源设置视角、反向、灵敏度、平滑、加速和反馈

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'setLookOption' --args '{"arg1":"3f5f8109-6ea0-4251-9845-c5d300ec5963","arg2":2,"arg3":"touch","arg4":"invertY","arg5":"true"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前输入编辑器的草稿引用","maxLength":16384},"arg2":{"type":"integer","description":"当前草稿版本"},"arg3":{"type":"string","description":"输入来源","maxLength":16384,"enum":["physical","touch","external"]},"arg4":{"type":"string","description":"视角选项","maxLength":16384,"enum":["independent","invertY","haptic","sensitivity","smoothing","acceleration"]},"arg5":{"type":"string","description":"百分比或布尔文本","maxLength":16384}},"required":["arg1","arg2","arg3","arg4","arg5"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"],"arg3":["arg1","arg2"],"arg4":["arg1","arg2","arg3"],"arg5":["arg1","arg2","arg3","arg4"]}}
```

执行返回值

返回 `draftRef` 时，该值等于原请求的 `arg1`（draftRef）。

当请求参数为 `{"draftRef":"3f5f8109-6ea0-4251-9845-c5d300ec5963","draftRevision":2,"source":"touch","field":"invertY","value":"true"}` 时：
- `{"state":"draft","draftRef":"3f5f8109-6ea0-4251-9845-c5d300ec5963","draftRevision":3}`
- `{"state":"needsUser"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["draft","needsUser","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"draftRef":{"type":"string","description":"业务标识或保存的文字"},"draftRevision":{"type":"integer","description":"产品读取的计数、修订或位置"},"name":{"type":"string","description":"业务标识或保存的文字"},"touch":{"type":"string","description":"业务标识或保存的文字"},"joystickDeadZone":{"type":"number","description":"控件当前保存或投影的数值"},"haptic":{"type":"boolean","description":"真实状态标志"},"source":{"type":"string","description":"业务标识或保存的文字"},"independent":{"type":"boolean","description":"真实状态标志"},"look":{"type":"string","description":"业务标识或保存的文字"},"actions":{"type":"array","description":"触控动作名称","items":{"type":"string","description":"业务标识或保存的文字"}},"changed":{"type":"boolean","description":"该次动作是否改变了序列化业务草稿"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"draft"}}},"then":{"required":["draftRef","draftRevision"]}}]}
```

### readWorkbenchOutcome

在返回目录后核对先前布局或输入草稿的人机确认结果；无证据回报未知

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readWorkbenchOutcome' --args '{"arg1":"05ce49ef-fa73-4186-870b-293cebbfe27e"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"先前打开的独立布局或输入草稿引用","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","name":"已保存的布局","layoutId":"saved-profile","revision":2}`
- `{"state":"cancelled"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","cancelled","busy","unavailable","unknown","failed"]},"reason":{"type":"string"},"name":{"type":"string"},"layoutId":{"type":"string"},"revision":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["name","layoutId","revision"]}}]}
```
