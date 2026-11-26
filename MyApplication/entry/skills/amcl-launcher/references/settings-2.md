# 图形、分辨率、日志与设备输入

### selectGraphicsBackend

为指定实例在原设置页选中渲染器草稿，留给用户确认；随后重读。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'selectGraphicsBackend' --args '{"arg1":"1.20.1","arg2":"auto"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'selectGraphicsBackend' --args '{"arg1":"1.20.1","arg2":"nativegl"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"候选列表返回的实例","maxLength":16384},"arg2":{"type":"string","description":"真实可选图形后端的标识","maxLength":16384}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `id` 时，该值等于原请求的 `arg2`（id）。

当请求参数为 `{"version":"1.20.1","id":"auto"}` 时：
- `{"state":"ready","id":"auto"}`
当请求参数为 `{"version":"1.20.1","id":"nativegl"}` 时：
- `{"state":"needsUser","id":"nativegl","reason":"confirmGraphicsChoice"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","needsUser","failed","unknown","busy","unavailable"]},"reason":{"type":"string"},"id":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["id"]}},{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["id","reason"]}}]}
```

### getGlobalResolution

读取启动器全局渲染比例和解析后的有效比例。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getGlobalResolution' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","percent":80,"effective":80}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","unknown","busy","unavailable"]},"reason":{"type":"string"},"percent":{"type":"integer"},"effective":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["percent","effective"]}}]}
```

### setGlobalResolution

设置全局渲染比例，0恢复默认；不改变单实例覆盖。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'setGlobalResolution' --args '{"arg1":80}')
```

```json
{"type":"object","properties":{"arg1":{"type":"integer","description":"0或产品支持的50至100整数百分比"}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `percent` 时，该值等于原请求的 `arg1`（percent）。

当请求参数为 `{"percent":80}` 时：
- `{"state":"ready","percent":80,"effective":80}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","unknown","busy","unavailable"]},"reason":{"type":"string"},"percent":{"type":"integer"},"effective":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["percent","effective"]}}]}
```

### getGameLogRetention

查看实际归档局数、占用、每版本保留量和样本状态。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getGameLogRetention' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","count":5,"bytes":0,"archivedSessions":0,"versionCount":0,"estimatedBytesPerSlot":0,"incomplete":false}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","unknown","busy","unavailable"]},"reason":{"type":"string"},"count":{"type":"integer"},"bytes":{"type":"integer"},"archivedSessions":{"type":"integer"},"versionCount":{"type":"integer"},"estimatedBytesPerSlot":{"type":"number"},"incomplete":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["count","bytes","archivedSessions","versionCount","estimatedBytesPerSlot","incomplete"]}}]}
```

### setGameLogRetention

调整每版本保留局数，清理前展示真实淘汰范围并等待用户决定。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'setGameLogRetention' --args '{"arg1":10}')
```

```json
{"type":"object","properties":{"arg1":{"type":"integer","description":"5至100局"}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `count` 时，该值等于原请求的 `arg1`（count）。

当请求参数为 `{"count":10}` 时：
- `{"state":"ready","count":10,"bytes":0,"archivedSessions":0,"versionCount":0,"estimatedBytesPerSlot":0,"incomplete":false}`
- `{"state":"failed","reason":"changeNotCommitted"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"setGameLogRetention","operationRef":"current-operation"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","unknown","needsUser","busy","unavailable"]},"reason":{"type":"string"},"count":{"type":"integer"},"bytes":{"type":"integer"},"archivedSessions":{"type":"integer"},"versionCount":{"type":"integer"},"estimatedBytesPerSlot":{"type":"number"},"incomplete":{"type":"boolean"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["count","bytes","archivedSessions","versionCount","estimatedBytesPerSlot","incomplete"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"setGameLogRetention"}},"required":["operationRef","method"]}}]}
```

### bluetoothMidiAccess

读取蓝牙MIDI权限或请求前台系统授权；不承诺硬件连通。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'bluetoothMidiAccess' --args '{"arg1":"inspect"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"按当前状态选择的操作","maxLength":16384,"enum":["inspect","request"]}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","permission":0}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"bluetoothMidiAccess","operationRef":"current-operation"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","unknown","needsUser","busy","unavailable"]},"reason":{"type":"string"},"permission":{"type":"integer"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["permission"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"bluetoothMidiAccess"}},"required":["operationRef","method"]}}]}
```

### getModMicrophone

读取模组麦克风应用开关和实际系统授权。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getModMicrophone' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","enabled":false,"permissionGranted":false}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","unknown","busy","unavailable"]},"reason":{"type":"string"},"enabled":{"type":"boolean"},"permissionGranted":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["enabled","permissionGranted"]}}]}
```

### configureModMicrophone

由已有音频所有者保存应用开关，必要时显示真实系统授权。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'configureModMicrophone' --args '{"arg1":true}')
```

```json
{"type":"object","properties":{"arg1":{"type":"boolean","description":"目标应用开关"}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","enabled":false,"permissionGranted":false}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"configureModMicrophone","operationRef":"current-operation"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","unknown","needsUser","busy","unavailable"]},"reason":{"type":"string"},"enabled":{"type":"boolean"},"permissionGranted":{"type":"boolean"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["enabled","permissionGranted"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"configureModMicrophone"}},"required":["operationRef","method"]}}]}
```

### getDesktopInteraction

查询支持设备的交互偏好及是否待重启。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getDesktopInteraction' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","mode":"auto","restartRequired":false}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","unknown","busy","unavailable"]},"reason":{"type":"string"},"mode":{"type":"string"},"restartRequired":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["mode","restartRequired"]}}]}
```

### setDesktopInteraction

选择电脑交互偏好并回读确认结果。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'setDesktopInteraction' --args '{"arg1":"auto"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"交互方式","maxLength":16384,"enum":["auto","touch","desktop"]}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `mode` 时，该值等于原请求的 `arg1`（mode）。

当请求参数为 `{"mode":"auto"}` 时：
- `{"state":"ready","mode":"auto","restartRequired":false}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","unknown","busy","unavailable"]},"reason":{"type":"string"},"mode":{"type":"string"},"restartRequired":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["mode","restartRequired"]}}]}
```

### openLauncherDiagnostic

在产品实际允许的情况下进入指定诊断页，界面内的探针由用户操作。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'openLauncherDiagnostic' --args '{"arg1":"vulkan"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"允许的诊断页面","maxLength":16384,"enum":["tools","gles","vulkan","input","desktop"]}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `tool` 时，该值等于原请求的 `arg1`（tool）。

当请求参数为 `{"tool":"vulkan"}` 时：
- `{"state":"needsUser","tool":"vulkan","reason":"performDiagnosticsInApp"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"tool":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["tool","reason"]}}]}
```

### readDiagnosticObservation

读取当前前台诊断页的摘要，不读取或传出完整控制台日志。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readDiagnosticObservation' --args '{"arg1":"gles"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readDiagnosticObservation' --args '{"arg1":"tools"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前前台诊断页面","maxLength":16384,"enum":["tools","gles","vulkan","input","desktop"]}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `page` 时，该值等于原请求的 `arg1`（tool）。

当请求参数为 `{"tool":"gles"}` 时：
- `{"state":"ready","page":"gles","running":false,"hasOutput":false,"status":""}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"page":{"type":"string"},"tool":{"type":"string"},"running":{"type":"boolean"},"status":{"type":"string"},"hasOutput":{"type":"boolean"},"vulkanAvailable":{"type":"boolean"},"paused":{"type":"boolean"},"events":{"type":"integer"},"verdict":{"type":"string"},"saved":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["page"]}}]}
```
