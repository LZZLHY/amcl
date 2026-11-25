# 首页、实例清单与版本设置

### listInstances

读取已安装实例、残留目录和当前选择。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'listInstances' --args '{}')
```

```json
{"type":"object","properties":{"arg1":{"type":["string"],"description":"列表筛选，省略为全部。","maxLength":16384,"enum":["all","vanilla","fabric","forge","neoforge","quilt",""]}},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","instances":["Fabric 1.21"],"orphans":[],"selected":"Fabric 1.21"}`
- `{"state":"failed","reason":"inventoryUnavailable"}`
- `{"state":"needsUser","reason":"LAUNCHER_NOT_INTERACTIVE"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","initializing","unavailable","busy","unknown"]},"reason":{"type":"string"},"instances":{"type":"array","items":{"type":"string"}},"orphans":{"type":"array","items":{"type":"string"}},"selected":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["instances","orphans","selected"]}}]}
```

### getLauncherHome

读取首页的实例、账号类型、JDK、模组数、最近活动和运行配置。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getLauncherHome' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","selected":"Fabric 1.21.1","accountType":"离线账户","jdk":"21","memoryMiB":2048,"instanceCount":1,"installedModCount":0,"recentActivities":[],"lastPlayedAt":0,"storeAction":"","jdkReady":true,"isolation":false}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"LAUNCHER_NOT_INTERACTIVE"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","initializing","unavailable","busy","unknown"]},"reason":{"type":"string"},"selected":{"type":"string"},"accountType":{"type":"string"},"jdk":{"type":"string"},"memoryMiB":{"type":"integer"},"instanceCount":{"type":"integer"},"installedModCount":{"type":"integer"},"recentActivities":{"type":"array","items":{"type":"object"}},"lastPlayedAt":{"type":"integer"},"storeAction":{"type":"string"},"jdkReady":{"type":"boolean"},"isolation":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["selected","accountType","jdk","memoryMiB","instanceCount","installedModCount","recentActivities","lastPlayedAt","storeAction","jdkReady","isolation"]}}]}
```

### openLauncherSection

打开已命名的启动器业务界面。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'openLauncherSection' --args '{"arg1":"settings"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"目标页面","maxLength":16384,"enum":["home","accounts","versions","installedMods","download","settings","tasks","history","messages","network","mod","shader","resourcepack","modpack"]}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `section` 时，该值等于原请求的 `arg1`（section）。

当请求参数为 `{"section":"settings"}` 时：
- `{"state":"ready","section":"settings"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"LAUNCHER_NOT_INTERACTIVE"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","initializing","unavailable","busy","unknown"]},"reason":{"type":"string"},"section":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["section"]}}]}
```

### performStoreManagerAction

按商店首页已显示的管理行动处理。检查中、会话退出或路由失败时不报告受理；选择和修复菜单可通过原交接引用回读用户取消或实际派发结果。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'performStoreManagerAction' --args '{"arg1":"download"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'performStoreManagerAction' --args '{"arg1":"checking"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"getLauncherHome 返回的当前管理行动","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `action` 时，该值等于原请求的 `arg1`（action）。

当请求参数为 `{"action":"download"}` 时：
- `{"state":"accepted","action":"download"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"cancelled"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"performStoreManagerAction","operationRef":"current-operation"}`
- `{"state":"needsUser","reason":"LAUNCHER_NOT_INTERACTIVE"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"busy","reason":"anotherRequest"}`
请求参数为 `{"action":"checking"}` 时不会返回 `{"state":"accepted"}`。


```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["accepted","failed","cancelled","needsUser","initializing","unavailable","unknown","busy"]},"reason":{"type":"string"},"action":{"type":"string"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"accepted"}}},"then":{"required":["action"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"performStoreManagerAction"}},"required":["operationRef","method"]}}]}
```

### getLauncherTasks

查看当前产品队列中的活动、终态、控制资格和字节进度。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getLauncherTasks' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","tasks":[]}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"launcherUnavailable"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","initializing","unavailable","busy","unknown"]},"reason":{"type":"string"},"tasks":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"activityId":{"type":"integer"},"phase":{"type":"string"}},"required":["id","activityId","phase"]}}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["tasks"]}}]}
```

### moveInstanceBefore

把指定实例排到另一个实例之前；不指定参照时移到末尾。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'moveInstanceBefore' --args '{"arg1":"instance"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原实例名称","maxLength":16384},"arg2":{"type":["string"],"description":"目标参照实例","maxLength":16384}},"required":["arg1"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

- `{"state":"ready","order":["Fabric 1.21.1","1.20.1"]}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"LAUNCHER_NOT_INTERACTIVE"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","initializing","unavailable","busy","unknown"]},"reason":{"type":"string"},"order":{"type":"array","items":{"type":"string"}}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["order"]}}]}
```

### selectGameInstance

选择已安装游戏实例。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'selectGameInstance' --args '{"arg1":"Fabric 1.21.1"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原实例名称","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `selected` 时，该值等于原请求的 `arg1`（instance）。

当请求参数为 `{"instance":"Fabric 1.21.1"}` 时：
- `{"state":"ready","selected":"Fabric 1.21.1"}`
- `{"state":"failed","reason":"selectionNotSaved"}`
- `{"state":"needsUser","reason":"LAUNCHER_NOT_INTERACTIVE"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","initializing","unavailable","busy","unknown"]},"reason":{"type":"string"},"selected":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["selected"]}}]}
```

### openInstancePanel

在指定实例打开实际详情、文件、世界、导出或设置。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'openInstancePanel' --args '{"arg1":"Fabric 1.21.1","arg2":"saves"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原实例名称","maxLength":16384},"arg2":{"type":"string","description":"版本面板","maxLength":16384,"enum":["detail","saves","files","export","jvm","language","resolution","jdk","mod","shader","resourcepack","datapack"]}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `instance` 时，该值等于原请求的 `arg1`（instance）。

返回 `panel` 时，该值等于原请求的 `arg2`（panel）。

- `{"state":"failed","reason":"invalidArguments"}`
当请求参数为 `{"instance":"Fabric 1.21.1","panel":"saves"}` 时：
- `{"state":"needsUser","instance":"Fabric 1.21.1","panel":"saves"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["failed","needsUser","initializing","unavailable","busy","unknown"]},"reason":{"type":"string"},"instance":{"type":"string"},"panel":{"type":"string"}},"additionalProperties":true}
```

### getInstanceSettings

读取单版本 JDK、语言和分辨率设置。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getInstanceSettings' --args '{"arg1":"Fabric 1.21.1"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原实例名称","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `instance` 时，该值等于原请求的 `arg1`（instance）。

当请求参数为 `{"instance":"Fabric 1.21.1"}` 时：
- `{"state":"ready","instance":"Fabric 1.21.1","jdk":"","resolution":0,"language":"","jdkChoices":["21"],"effectiveJdk":"21","effectiveLanguage":"zh_cn","effectiveResolution":100,"isolated":false,"hasCustomJvmArgs":false,"jvmRevision":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","memoryMiB":2048}`
- `{"state":"failed","reason":"instanceNotInstalled"}`
- `{"state":"needsUser","reason":"LAUNCHER_NOT_INTERACTIVE"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","initializing","unavailable","busy","unknown"]},"reason":{"type":"string"},"instance":{"type":"string"},"jdk":{"type":"string"},"resolution":{"type":"integer"},"language":{"type":"string"},"jdkChoices":{"type":"array","items":{"type":"string"}},"effectiveJdk":{"type":"string"},"effectiveLanguage":{"type":"string"},"effectiveResolution":{"type":"integer"},"isolated":{"type":"boolean"},"hasCustomJvmArgs":{"type":"boolean"},"jvmRevision":{"type":"string"},"memoryMiB":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["instance","jdk","resolution","language","jdkChoices","effectiveJdk","effectiveLanguage","effectiveResolution","isolated","hasCustomJvmArgs","jvmRevision","memoryMiB"]}}]}
```

### setInstanceJdk

设置指定实例的启动 JDK。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'setInstanceJdk' --args '{"arg1":"Fabric 1.21.1","arg2":"21"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原实例名称","maxLength":16384},"arg2":{"type":"string","description":"可选 JDK，或 inherit/auto","maxLength":16384}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `instance` 时，该值等于原请求的 `arg1`（instance）。

返回 `jdk` 时，该值等于原请求的 `arg2`（jdk）。

当请求参数为 `{"instance":"Fabric 1.21.1","jdk":"21"}` 时：
- `{"state":"ready","instance":"Fabric 1.21.1","jdk":"21"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"LAUNCHER_NOT_INTERACTIVE"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","initializing","unavailable","busy","unknown"]},"reason":{"type":"string"},"instance":{"type":"string"},"jdk":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["instance","jdk"]}}]}
```

### setInstanceResolution

保存版本分辨率百分比，0 表示继承。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'setInstanceResolution' --args '{"arg1":"instance","arg2":100}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原实例名称","maxLength":16384},"arg2":{"type":"integer","description":"渲染比例"}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `percent` 时，该值等于原请求的 `arg2`（percent）。

当请求参数为 `{"instance":"instance","percent":100}` 时：
- `{"state":"ready","percent":100}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"LAUNCHER_NOT_INTERACTIVE"}`
- `{"state":"initializing"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","initializing","unavailable","busy","unknown"]},"reason":{"type":"string"},"percent":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["percent"]}}]}
```

### requestInstanceDeletion

显示实例名并由用户确认，随后回报原实例是否实际删除。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'requestInstanceDeletion' --args '{"arg1":"example-instance"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原实例名称","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

结果 `removed` 中的目标必须来自本次请求的 `arg1`（instance）。

结果 `remaining` 中的目标必须来自本次请求的 `arg1`（instance）。

结果 `affected` 中的目标必须来自本次请求的 `arg1`（instance）。

`removed`、`remaining` 合起来每个目标最多出现一次。

返回 `affected` 时，该目标必须在 `remaining` 中。

当请求参数为 `{"instance":"example-instance"}` 时：
- `{"state":"ready","removed":"example-instance"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"requestInstanceDeletion","operationRef":"current-operation"}`
- `{"state":"initializing"}`
- `{"state":"cancelled"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
当请求参数为 `{"instance":"example-instance"}` 时：
- `{"state":"partial","removed":[],"remaining":["example-instance"],"affected":"example-instance","reason":"cleanupIncomplete"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
当请求参数为 `{"instance":"example-instance"}` 时：
- `{"removed":[],"remaining":["example-instance"],"affected":"example-instance","state":"partial","reason":"cleanupIncomplete"}`
当请求参数为 `{"instance":"example-instance"}` 时：
- `{"removed":"example-instance","state":"ready"}`
当请求参数为 `{"instance":"example-instance"}` 时：
- `{"removed":["example-instance"],"remaining":[],"state":"ready"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","needsUser","initializing","cancelled","unavailable","partial","busy","unknown"]},"reason":{"type":"string"},"removed":{"type":["string","array"],"items":{"type":"string"},"description":"有效实例返回删除的实例名；清理残缺目录返回实取名称列表。"},"remaining":{"type":"array","items":{"type":"string"},"description":"未完全清理的残缺实例名称。"},"affected":{"type":"string"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["removed"]}},{"if":{"properties":{"state":{"const":"partial"}}},"then":{"required":["removed","remaining"]}},{"if":{"required":["state"],"properties":{"state":{"const":"partial"}}},"then":{"required":["removed","remaining","affected"],"properties":{"remaining":{"minItems":1,"maxItems":1},"removed":{"type":"array","maxItems":0}}}},{"if":{"required":["state"],"properties":{"state":{"const":"ready"}}},"then":{"required":["removed"],"properties":{"removed":{"minLength":1,"minItems":1}}}},{"if":{"required":["state","removed"],"properties":{"state":{"const":"ready"},"removed":{"type":"array"}}},"then":{"required":["removed","remaining"],"properties":{"removed":{"minItems":1,"maxItems":1},"remaining":{"const":[]}}}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"requestInstanceDeletion"}},"required":["operationRef","method"]}}]}
```
