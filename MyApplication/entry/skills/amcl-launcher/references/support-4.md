# 分享、用户选择及操作回执

### getActivityShareOutcome

查询原活动及本次预览引用的实际公开分享或作者接收回执，关闭未取得回执时保持未知。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getActivityShareOutcome' --args '{"arg1":42,"arg2":"share-1"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"integer","description":"原活动号"},"arg2":{"type":"string","description":"reviewActivityShare 返回的本次操作引用","maxLength":16384}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

- `{"state":"ready","shareState":"sending","receipt":"","reason":""}`
- `{"state":"unknown","reason":"operationNotFound"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"shareState":"waiting","receipt":"","reason":"","state":"ready"}`
- `{"shareState":"sending","receipt":"","reason":"","state":"ready"}`
- `{"shareState":"shared","receipt":"share-42","reason":"","state":"ready"}`
- `{"shareState":"submittedToAuthor","receipt":"feedback-42","reason":"","state":"ready"}`
- `{"shareState":"cancelled","receipt":"","reason":"","state":"ready"}`
- `{"shareState":"failed","receipt":"","reason":"http","state":"ready"}`
- `{"shareState":"unknown","receipt":"","reason":"unknown-outcome","state":"ready"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","unknown","busy","unavailable","failed"]},"reason":{"type":"string"},"shareState":{"type":"string","enum":["waiting","sending","shared","submittedToAuthor","failed","unknown","cancelled"]},"receipt":{"type":"string"}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["shareState","receipt","reason"]}},{"if":{"required":["state","shareState"],"properties":{"state":{"const":"ready"},"shareState":{"const":"waiting"}}},"then":{"required":["receipt","reason"],"properties":{"receipt":{"const":""},"reason":{"const":""}}}},{"if":{"required":["state","shareState"],"properties":{"state":{"const":"ready"},"shareState":{"const":"sending"}}},"then":{"required":["receipt","reason"],"properties":{"receipt":{"const":""},"reason":{"const":""}}}},{"if":{"required":["state","shareState"],"properties":{"state":{"const":"ready"},"shareState":{"const":"shared"}}},"then":{"required":["receipt","reason"],"properties":{"receipt":{"minLength":1},"reason":{"const":""}}}},{"if":{"required":["state","shareState"],"properties":{"state":{"const":"ready"},"shareState":{"const":"submittedToAuthor"}}},"then":{"required":["receipt","reason"],"properties":{"receipt":{"minLength":1},"reason":{"const":""}}}},{"if":{"required":["state","shareState"],"properties":{"state":{"const":"ready"},"shareState":{"const":"cancelled"}}},"then":{"required":["receipt","reason"],"properties":{"receipt":{"const":""},"reason":{"const":""}}}},{"if":{"required":["state","shareState"],"properties":{"state":{"const":"ready"},"shareState":{"const":"failed"}}},"then":{"required":["receipt","reason"],"properties":{"receipt":{"const":""},"reason":{"minLength":1}}}},{"if":{"required":["state","shareState"],"properties":{"state":{"const":"ready"},"shareState":{"const":"unknown"}}},"then":{"required":["receipt","reason"],"properties":{"receipt":{"const":""},"reason":{"minLength":1}}}}]}
```

### getActivityChoiceOutcome

按原活动及选择引用查询系统导出或应用删除确认的真实结果。重启或记录消失时返回未知，不重新派发。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getActivityChoiceOutcome' --args '{"arg1":42,"arg2":"e78a3bab-46a3-475d-80d1-0df5b31692ff"}')
```

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getActivityChoiceOutcome' --args '{"arg1":42,"arg2":"1aab259c-0932-4109-8776-70b808c03009"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"integer","description":"原活动号"},"arg2":{"type":"string","description":"发起导出或删除时返回的引用","maxLength":16384}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `activityId` 时，该值等于原请求的 `arg1`（activityId）。

返回 `operationRef` 时，该值等于原请求的 `arg2`（operationRef）。

当请求参数为 `{"activityId":42,"operationRef":"1aab259c-0932-4109-8776-70b808c03009"}` 时：
- `{"state":"needsUser","operation":"exportActivityEvidence","activityId":42,"operationRef":"1aab259c-0932-4109-8776-70b808c03009"}`
当请求参数为 `{"activityId":42,"operationRef":"1aab259c-0932-4109-8776-70b808c03009"}` 时：
- `{"state":"ready","operation":"exportActivityEvidence","activityId":42,"operationRef":"1aab259c-0932-4109-8776-70b808c03009","saved":true}`
当请求参数为 `{"activityId":42,"operationRef":"e78a3bab-46a3-475d-80d1-0df5b31692ff"}` 时：
- `{"state":"cancelled","operation":"requestActivityRemoval","activityId":42,"operationRef":"e78a3bab-46a3-475d-80d1-0df5b31692ff","removed":false}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"failed","reason":"invalidArguments"}`
- `{"state":"unknown","reason":"originalChoiceUnavailable"}`
- `{"state":"busy","reason":"anotherRequest"}`
当请求参数为 `{"activityId":42,"operationRef":"e78a3bab-46a3-475d-80d1-0df5b31692ff"}` 时：
- `{"operation":"requestActivityRemoval","activityId":42,"operationRef":"e78a3bab-46a3-475d-80d1-0df5b31692ff","state":"needsUser"}`
当请求参数为 `{"activityId":42,"operationRef":"1aab259c-0932-4109-8776-70b808c03009"}` 时：
- `{"operation":"exportActivityEvidence","activityId":42,"operationRef":"1aab259c-0932-4109-8776-70b808c03009","state":"needsUser"}`
当请求参数为 `{"activityId":42,"operationRef":"e78a3bab-46a3-475d-80d1-0df5b31692ff"}` 时：
- `{"operation":"requestActivityRemoval","activityId":42,"operationRef":"e78a3bab-46a3-475d-80d1-0df5b31692ff","removed":true,"state":"ready"}`
当请求参数为 `{"activityId":42,"operationRef":"1aab259c-0932-4109-8776-70b808c03009"}` 时：
- `{"operation":"exportActivityEvidence","activityId":42,"operationRef":"1aab259c-0932-4109-8776-70b808c03009","saved":true,"state":"ready"}`
当请求参数为 `{"activityId":42,"operationRef":"e78a3bab-46a3-475d-80d1-0df5b31692ff"}` 时：
- `{"operation":"requestActivityRemoval","activityId":42,"operationRef":"e78a3bab-46a3-475d-80d1-0df5b31692ff","removed":false,"state":"cancelled"}`
当请求参数为 `{"activityId":42,"operationRef":"1aab259c-0932-4109-8776-70b808c03009"}` 时：
- `{"operation":"exportActivityEvidence","activityId":42,"operationRef":"1aab259c-0932-4109-8776-70b808c03009","saved":false,"state":"cancelled"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["needsUser","ready","cancelled","unavailable","failed","unknown","busy"]},"reason":{"type":"string"},"operation":{"type":"string","enum":["requestActivityRemoval","exportActivityEvidence"]},"removed":{"type":"boolean"},"saved":{"type":"boolean"},"operationRef":{"type":"string","minLength":1},"activityId":{"type":"integer","minimum":1}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["operation","activityId","operationRef"]}},{"if":{"properties":{"state":{"const":"cancelled"}}},"then":{"required":["operation","activityId","operationRef"]}},{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["operation","activityId","operationRef"]}},{"if":{"required":["state","operation"],"properties":{"state":{"const":"needsUser"},"operation":{"const":"requestActivityRemoval"}}},"then":{"required":["activityId","operationRef"],"properties":{}}},{"if":{"required":["state","operation"],"properties":{"state":{"const":"needsUser"},"operation":{"const":"exportActivityEvidence"}}},"then":{"required":["activityId","operationRef"],"properties":{}}},{"if":{"required":["state","operation"],"properties":{"state":{"const":"ready"},"operation":{"const":"requestActivityRemoval"}}},"then":{"required":["removed"],"properties":{"removed":{"const":true}}}},{"if":{"required":["state","operation"],"properties":{"state":{"const":"ready"},"operation":{"const":"exportActivityEvidence"}}},"then":{"required":["saved"],"properties":{"saved":{"const":true}}}},{"if":{"required":["state","operation"],"properties":{"state":{"const":"cancelled"},"operation":{"const":"requestActivityRemoval"}}},"then":{"required":["removed"],"properties":{"removed":{"const":false}}}},{"if":{"required":["state","operation"],"properties":{"state":{"const":"cancelled"},"operation":{"const":"exportActivityEvidence"}}},"then":{"required":["saved"],"properties":{"saved":{"const":false}}}}]}
```

### getLauncherHandoff

通过原方法名及 operationRef 查询一次已打开的用户确认或系统选择器。等待时返回 needsUser，结束时 outcome 内保留原业务状态和字段；进程更替或记录过期返回 unknown。

执行参数

```text
exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName 'getLauncherHandoff' --args '{"arg1":"chooseLocalModpack","arg2":"8316e628-24b0-44f1-bcb7-60c4d42d6897"}')
```

```json
{"type":"object","properties":{"arg1":{"type":"string","description":"原业务方法名","maxLength":16384},"arg2":{"type":"string","description":"该方法先前以 awaitingUser 返回的引用","maxLength":16384}},"required":["arg1","arg2"],"additionalProperties":false,"dependentRequired":{"arg2":["arg1"]}}
```

执行返回值

返回 `method` 时，该值等于原请求的 `arg1`（method）。

返回 `operationRef` 时，该值等于原请求的 `arg2`（operationRef）。

当请求参数为 `{"method":"chooseLocalModpack","operationRef":"8316e628-24b0-44f1-bcb7-60c4d42d6897"}` 时：
- `{"state":"ready","method":"chooseLocalModpack","operationRef":"8316e628-24b0-44f1-bcb7-60c4d42d6897","outcome":{"state":"cancelled"}}`
当请求参数为 `{"method":"chooseLocalModpack","operationRef":"8316e628-24b0-44f1-bcb7-60c4d42d6897"}` 时：
- `{"state":"needsUser","method":"chooseLocalModpack","operationRef":"8316e628-24b0-44f1-bcb7-60c4d42d6897","reason":"awaitingUser"}`
- `{"state":"unknown","reason":"operationUnconfirmed"}`
- `{"state":"busy","reason":"anotherRequest"}`
- `{"state":"unavailable","reason":"launcherNotReady"}`
- `{"state":"failed","reason":"invalidArguments"}`

```json
{"type":"object","required":["state"],"properties":{"state":{"enum":["ready","needsUser","unknown","busy","unavailable","failed"]},"reason":{"type":"string"},"method":{"type":"string"},"operationRef":{"type":"string","minLength":1},"outcome":{"type":"object","required":["state"],"properties":{"state":{"type":"string"}}}},"additionalProperties":true,"allOf":[{"if":{"properties":{"state":{"const":"ready"}}},"then":{"required":["method","operationRef","outcome"]}},{"if":{"properties":{"state":{"const":"needsUser"}}},"then":{"required":["method","operationRef"]}}]}
```
