# 查找设置、外观、内存与存储

### findLauncherSettings

按当前产品和设备的真实设置目录列出功能，可搜索名称、说明和关键词。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'findLauncherSettings' --args '{"arg1":"网络"}')
```

```json
{"type":"object","properties":{"arg1":{"type":["string"],"description":"留空列出全部可见项","maxLength":16384}},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","items":[{"item":"network","title":"网络检测","section":"logs"}],"section":"overview"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"items":{"type":"array","items":{"type":"object","properties":{"item":{"type":"string"},"title":{"type":"string"},"section":{"type":"string"}},"required":["item","section","title"]}},"section":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["items","section"]}}]}
```

### readLauncherSetting

读取当前设置的确认值、有效候选或需要前台操作的原因。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readLauncherSetting' --args '{"arg1":"memory"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readLauncherSetting' --args '{"arg1":"network"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readLauncherSetting' --args '{"arg1":"theme"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前设置目录返回的稳定项标识","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `item` 时，该值等于原请求的 `arg1`（item）。

当请求参数为 `{"item":"memory"}` 时：
- `{"state":"ready","item":"memory","megabytes":2048,"max":4096}`
当请求参数为 `{"item":"network"}` 时：
- `{"state":"needsUser","item":"network"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
当请求参数为 `{"item":"memory"}` 时：
- `{"item":"memory","megabytes":2048,"max":4096,"state":"ready"}`
当请求参数为 `{"item":"theme"}` 时：
- `{"item":"theme","mode":"system","accent":"blue","state":"ready"}`
当请求参数为 `{"item":"memory"}` 时：
- `{"item":"memory","megabytes":2048,"max":4096,"state":"ready"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","needsUser","unknown","failed","busy","unavailable"]},"reason":{"type":"string"},"item":{"type":"string"},"value":{"type":"string"},"choices":{"type":"array","items":{"type":"object","properties":{"value":{"type":"string"},"enabled":{"type":"boolean"},"title":{"type":"string"}}}},"mode":{"type":"string"},"accent":{"type":"string"},"percent":{"type":"integer"},"enabled":{"type":"boolean"},"checked":{"type":"boolean"},"active":{"type":"boolean"},"independent":{"type":"boolean"},"policy":{"type":"string"},"status":{"type":"string"},"navigation":{"type":"string"},"bottomBar":{"type":"boolean"},"titleButtons":{"type":"boolean"},"manualMaterial":{"type":"boolean"},"saving":{"type":"boolean"},"max":{"type":"integer"},"megabytes":{"type":"integer"},"autoCheck":{"type":"boolean"},"checking":{"type":"boolean"},"available":{"type":"boolean"},"publisherEnabled":{"type":"boolean"},"requested":{"type":"boolean"},"hasCustomArguments":{"type":"boolean"},"summary":{"type":"string"},"relay":{"type":"object","properties":{"sessionReady":{"type":"boolean"},"usable":{"type":"boolean"},"tripped":{"type":"boolean"},"connecting":{"type":"boolean"},"hasNativeCounters":{"type":"boolean"},"fallbacks":{"type":"integer"}}},"currentVersion":{"type":"string"},"delivery":{"type":"string","enum":["appMarket","sideload"]},"saveFailed":{"type":"boolean"},"currentCode":{"type":"integer","description":"系统 BMS 实际安装码，仅身份得到确认时返回"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["item"]}},{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["item"]}},{"if":{"required":["state","item"],"properties":{"state":{"const":"ready"},"item":{"const":"memory"}}},"then":{"required":["megabytes","max"],"properties":{}}}]}
```

### openLauncherSetting

定位真实设置项，进入相应的原生编辑、系统授权、剪贴板或帮助流程。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'openLauncherSetting' --args '{"arg1":"jvm"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'openLauncherSetting' --args '{"arg1":"network"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'openLauncherSetting' --args '{"arg1":"storage"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"当前设置目录返回的稳定项标识","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `item` 时，该值等于原请求的 `arg1`（item）。

当请求参数为 `{"item":"network"}` 时：
- `{"state":"needsUser","item":"network"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
当请求参数为 `{"item":"jvm"}` 时：
- `{"item":"jvm","reference":"editor-1","state":"needsUser"}`
当请求参数为 `{"item":"storage"}` 时：
- `{"item":"storage","reference":"editor-1","state":"needsUser"}`
当请求参数为 `{"item":"network"}` 时：
- `{"item":"network","state":"needsUser"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"item":{"type":"string"},"reference":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["item"]}}]}
```

### setLauncherChoice

从当前有效候选中选择全局Java、游戏语言、帧率、下载来源或JDK更新通道。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'setLauncherChoice' --args '{"arg1":"mc-source","arg2":"auto"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"选择项","maxLength":16384,"enum":["java","language","frame-rate","fixed-refresh-rate","mc-source","jdk-source","mod-source","jdk-update"]},"arg2":{"type":"string","description":"readLauncherSetting列出的已启用候选值","maxLength":16384}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `item` 时，该值等于原请求的 `arg1`（item）。

返回 `value` 时，该值等于原请求的 `arg2`（value）。

当请求参数为 `{"item":"mc-source","value":"auto"}` 时：
- `{"state":"ready","item":"mc-source","value":"auto","choices":[{"value":"auto","title":"自动","enabled":true},{"value":"mirror","title":"镜像优先","enabled":true},{"value":"official","title":"源站","enabled":true}]}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","unknown","busy","unavailable"]},"reason":{"type":"string"},"item":{"type":"string"},"value":{"type":"string"},"choices":{"type":"array","items":{"type":"object","properties":{"value":{"type":"string"},"enabled":{"type":"boolean"},"title":{"type":"string"}},"required":["value","title","enabled"]}},"mode":{"type":"string"},"accent":{"type":"string"},"percent":{"type":"integer"},"enabled":{"type":"boolean"},"checked":{"type":"boolean"},"active":{"type":"boolean"},"independent":{"type":"boolean"},"policy":{"type":"string"},"status":{"type":"string"},"navigation":{"type":"string"},"bottomBar":{"type":"boolean"},"titleButtons":{"type":"boolean"},"manualMaterial":{"type":"boolean"},"saving":{"type":"boolean"},"max":{"type":"integer"},"megabytes":{"type":"integer"},"autoCheck":{"type":"boolean"},"checking":{"type":"boolean"},"available":{"type":"boolean"},"publisherEnabled":{"type":"boolean"},"requested":{"type":"boolean"},"hasCustomArguments":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["item","value","choices"]}}]}
```

### setLauncherSwitch

更改启动器的可见布尔设置，版本隔离和独立进程切换须由用户确认。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'setLauncherSwitch' --args '{"arg1":"isolation","arg2":true}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"设置开关","maxLength":16384,"enum":["virtual-memory","game-keep-screen-on","isolation","process","remote-cache","acceleration","jdk-web","jdk-auto"]},"arg2":{"type":"boolean","description":"目标启用状态"}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

- `{"state":"ready","item":"isolation","enabled":true}`
- `{"state":"cancelled","item":"isolation"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"setLauncherSwitch","operationRef":"current-operation"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","cancelled","unknown","failed","needsUser","busy","unavailable"]},"reason":{"type":"string"},"item":{"type":"string"},"value":{"type":"string"},"choices":{"type":"array","items":{"type":"object","properties":{"value":{"type":"string"},"enabled":{"type":"boolean"},"title":{"type":"string"}}}},"mode":{"type":"string"},"accent":{"type":"string"},"percent":{"type":"integer"},"enabled":{"type":"boolean"},"checked":{"type":"boolean"},"active":{"type":"boolean"},"independent":{"type":"boolean"},"policy":{"type":"string"},"status":{"type":"string"},"navigation":{"type":"string"},"bottomBar":{"type":"boolean"},"titleButtons":{"type":"boolean"},"manualMaterial":{"type":"boolean"},"saving":{"type":"boolean"},"max":{"type":"integer"},"megabytes":{"type":"integer"},"autoCheck":{"type":"boolean"},"checking":{"type":"boolean"},"available":{"type":"boolean"},"publisherEnabled":{"type":"boolean"},"requested":{"type":"boolean"},"hasCustomArguments":{"type":"boolean"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["item"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"setLauncherSwitch"}},"required":["operationRef","method"]}}]}
```

### setLauncherAppearance

应用完整主题组合，等待原持久化事务完成。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'setLauncherAppearance' --args '{"arg1":"system","arg2":"blue"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"明暗模式","maxLength":16384,"enum":["system","light","dark"]},"arg2":{"type":"string","description":"强调色","maxLength":16384,"enum":["rose","blue","teal","violet"]}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `mode` 时，该值等于原请求的 `arg1`（mode）。

返回 `accent` 时，该值等于原请求的 `arg2`（accent）。

当请求参数为 `{"mode":"system","accent":"blue"}` 时：
- `{"state":"ready","mode":"system","accent":"blue"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"mode":{"type":"string"},"accent":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["mode","accent"]}}]}
```

### setLauncherSheetHeight

设置手机面板百分比，50至100且取5的整数倍，默认80。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'setLauncherSheetHeight' --args '{"arg1":80}')
```

```json
{"type":"object","properties":{"arg1":{"type":"integer","description":"手机面板可用高度百分比"}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `percent` 时，该值等于原请求的 `arg1`（percent）。

当请求参数为 `{"percent":80}` 时：
- `{"state":"ready","percent":80}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"percent":{"type":"integer"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["percent"]}}]}
```

### setLauncherLightMaterial

设置沉浸光感的总开关、底部栏/标题按钮模块或导航材质。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'setLauncherLightMaterial' --args '{"arg1":"enabled","arg2":"on"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"光感设置项","maxLength":16384,"enum":["enabled","bottomBar","titleButtons","material"]},"arg2":{"type":"string","description":"开关用on/off；材质用实际支持的枚举","maxLength":16384,"enum":["on","off","adaptive","exquisite","gentle","smooth"]}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

- `{"state":"ready","item":"immersive","enabled":true,"navigation":"adaptive","bottomBar":true,"titleButtons":false}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"item":{"type":"string"},"enabled":{"type":"boolean"},"navigation":{"type":"string"},"bottomBar":{"type":"boolean"},"titleButtons":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["item","enabled","navigation","bottomBar","titleButtons"]}}]}
```

### setLauncherMemory

提交设备支持范围内的 JVM 堆内存 MB；风险值留在原界面确认。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'setLauncherMemory' --args '{"arg1":2048}')
```

```json
{"type":"object","properties":{"arg1":{"type":"integer","description":"512至本机上限，以256为单位"}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","item":"memory","megabytes":2048,"max":4096}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"needsUser","reason":"awaitingUser","method":"setLauncherMemory","operationRef":"current-operation"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","unknown","failed","needsUser","busy","unavailable"]},"reason":{"type":"string"},"item":{"type":"string"},"value":{"type":"string"},"choices":{"type":"array","items":{"type":"object","properties":{"value":{"type":"string"},"enabled":{"type":"boolean"},"title":{"type":"string"}}}},"mode":{"type":"string"},"accent":{"type":"string"},"percent":{"type":"integer"},"enabled":{"type":"boolean"},"checked":{"type":"boolean"},"active":{"type":"boolean"},"independent":{"type":"boolean"},"policy":{"type":"string"},"status":{"type":"string"},"navigation":{"type":"string"},"bottomBar":{"type":"boolean"},"titleButtons":{"type":"boolean"},"manualMaterial":{"type":"boolean"},"saving":{"type":"boolean"},"max":{"type":"integer"},"megabytes":{"type":"integer"},"autoCheck":{"type":"boolean"},"checking":{"type":"boolean"},"available":{"type":"boolean"},"publisherEnabled":{"type":"boolean"},"requested":{"type":"boolean"},"hasCustomArguments":{"type":"boolean"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["item","megabytes","max"]}},{"if":{"required":["reason"],"properties":{"reason":{"const":"awaitingUser"}}},"then":{"properties":{"state":{"const":"needsUser"},"method":{"const":"setLauncherMemory"}},"required":["operationRef","method"]}}]}
```

### scheduleTouchGuide

预约真实游戏中的下次触控教学并读回登记状态。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'scheduleTouchGuide' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","item":"touch-help","requested":true}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","unknown","busy","unavailable"]},"reason":{"type":"string"},"item":{"type":"string"},"requested":{"type":"boolean"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["item","requested"]}}]}
```

### prepareStorageChange

选择真实游戏数据位置，由用户选择复制迁移或仅切换并授予系统权限。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'prepareStorageChange' --args '{"arg1":"sandbox"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'prepareStorageChange' --args '{"arg1":"external"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"所需数据位置","maxLength":16384,"enum":["sandbox","external"]}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

返回 `value` 时，该值等于原请求的 `arg1`（target）。

当请求参数为 `{"target":"sandbox"}` 时：
- `{"state":"ready","item":"storage","value":"sandbox","choices":[{"value":"sandbox","enabled":true,"title":"沙箱目录"}]}`
- `{"state":"needsUser","item":"storage","reference":"editor-1"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"item":"storage","reference":"reference","state":"needsUser"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","needsUser","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"item":{"type":"string"},"reference":{"type":"string"},"value":{"type":"string"},"target":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["item","reference"]}},{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["item","value"]}},{"if":{"required":["state","item"],"properties":{"state":{"const":"needsUser"},"item":{"const":"storage"}}},"then":{"required":["reference"],"properties":{}}}]}
```

### listGraphicsBackends

查看对应实例的真实渲染器候选、已选项和不可用原因。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'listGraphicsBackends' --args '{}')
```

```json
{"type":"object","properties":{},"required":[],"additionalProperties":false}
```

执行返回值

- `{"state":"ready","version":"1.20.1","backends":[{"id":"auto","label":"自动选择","selectable":true,"selected":true,"reason":"auto"},{"id":"mobileglues","label":"MobileGlues","selectable":true,"selected":false,"reason":"admitted"},{"id":"gl4es","label":"gl4es (Holy-GL4ES)","selectable":false,"selected":false,"reason":"artifact-missing"},{"id":"mobilegl","label":"MobileGL (DirectVulkan)","selectable":true,"selected":false,"reason":"admitted"},{"id":"nativegl","label":"HarmonyOS OpenGL","selectable":true,"selected":false,"reason":"admitted"},{"id":"minecraft-vulkan","label":"Minecraft Vulkan","selectable":false,"selected":false,"reason":"artifact-missing"}]}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","failed","unknown","busy","unavailable"]},"reason":{"type":"string"},"version":{"type":"string"},"backends":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"label":{"type":"string"},"selectable":{"type":"boolean"},"selected":{"type":"boolean"},"reason":{"type":"string"}},"required":["id","label","selectable","selected","reason"]}}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["version","backends"]}}]}
```
