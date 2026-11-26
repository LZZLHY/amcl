# 更新安装包选择结果

### readUpdatePackageSelection

按原引用从任意启动器页面查询本地 HAP 是否已转交更新流程，重启后可查最近终态。读取不会再次打开选择器或发起安装。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'readUpdatePackageSelection' --args '{"arg1":"picker-1"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"openUpdateSource(localPackage) 返回的本次选择引用","maxLength":16384}},"required":["arg1"],"additionalProperties":false}
```

执行返回值

- `{"state":"waiting"}`
- `{"state":"accepted","target":"v1.0.8:1000912:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}`
- `{"state":"cancelled"}`
- `{"state":"failed","reason":"selectionExpired"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["waiting","accepted","cancelled","failed","busy","unavailable","unknown"]},"reason":{"type":"string"},"target":{"type":"string","minLength":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"accepted"}}},"then":{"required":["target"]}}]}
```
