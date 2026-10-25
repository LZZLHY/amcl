# Native ILAT 离线解析

`parse-input-latency.py` 复用已独审的严格ILAT1/ILAT2算法，只读取调用者明确绑定的原日志、Source/HAP材料，不采集设备、不运行Native，也不生成性能PASS。

```text
python -B scripts/parse-input-latency.py --manifest /absolute/evidence-manifest.json --out /absolute/new-external-directory
python -B scripts/test-input-latency-parser.py --out /absolute/new-external-test-directory
```

`--out` 必须是全新仓外目录，链接解析后位于任何Git仓库内也拒绝；manifest内相对原件路径以manifest目录为基准。所有日志和source receipt必须声明真实raw SHA256。测试默认沿所属workspace helper外置；维护者执行时按当前存储路由传明确输出路径。

manifest schema为`amcl-native-ilat-manifest/v1`，`evidence`非空，每项包含`path`、`sha256`及`binding`。binding必须明确`capture_id`（原进程生命期）、`layer`（host/device/rule_fixture）、`pid`、`source.identity`及`source.receipt`原件身份、`hap`、`scene`、`clock_domain`、实际`sampling_interval`和`prefix_format`。可选`line_start`/`line_end`按原日志二进制LF行号；PID不从字符串子串、mtime或“当前活动”猜取。

device需要实际原PID/HAP、hilog载体、`CLOCK_MONOTONIC_NS`资格；缺失会如实保留partial，不能用host或rule_fixture补。采样间隔由真实编译证据给出，不把默认8或host1替代当前Native事实。`source.adopted=false`和`evidence_kind=native_formatter_interop`继续保候选/字面量互操作边界。

ILAT1的最后点是其原callback-return合同；ILAT2按ABI分别记录SDL posted receipt-return与L2 poll-view-copy，不合并成callback时间或Java/game ACK。真实成功终态允许缺终点时钟；未知/缺失保持`null`与具名排除理由。uint64身份和时点输出十进制字符串，分位数为整数ns nearest rank `ceil(p*n)`，不乘采样率、不插值。重复原行、同生命期身份冲突及SUM资格冲突均沿原算法去重/隔离。

正常可解析报告状态固定`PARTIAL_NATIVE_OBSERVATIONS`且退出0，表示离线解释成功；原件/SHA/schema绑定错误退出2并在获准新外部目录留下`BINDING_ERROR`。两者都不证明设备、SDK采样起点、游戏tick、touch-to-photon、CPU或能耗。`records.jsonl`与`issues.jsonl`保原身份和排除原因。

正式Source门仅运行纯规则测试，不运行采集器、编译器或设备；人工日志始终标`rule_fixture`，不能追认成实际host/device实验。
