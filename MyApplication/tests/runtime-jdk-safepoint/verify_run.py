#!/usr/bin/env python3
"""只读核回收的独立夹具证据；可供同设备旧/新运行时两轮分别验收。

evidence目录需含stdout.log、compilation.xml和实际运行JAR。运行时so由负责人
从实际使用的JDK槽回收，本工具计算其摘要并记入收据；不猜设备身份或代为部署。
每轮必须用独立原始目录和新的报告路径，不能把宿主正例说成设备通过。
"""
from __future__ import annotations
import argparse
import datetime as dt
import json
import pathlib
import sys

# 工具运行不得在仓库产生__pycache__；回收证据和验证报告均使用显式外部路径。
sys.dont_write_bytecode = True
from run_host import verify, sha, external_output_path


def main() -> int:
    """同一验证器处理宿主或设备原件，label只是调用方备注，不是设备证明。"""
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", type=pathlib.Path, required=True)
    parser.add_argument("--report", type=pathlib.Path, required=True)
    parser.add_argument("--runtime-so", type=pathlib.Path)
    parser.add_argument("--label", required=True)
    parser.add_argument("--rounds", type=int, default=4)
    parser.add_argument("--max-latency-ms", type=int, default=750)
    args = parser.parse_args()
    evidence = args.evidence.resolve()
    result = verify(evidence, args.rounds, args.max_latency_ms)
    record = {"schema": 1, "label": args.label, "time": dt.datetime.now().astimezone().isoformat(),
              "scope": "evidence-verification-not-device-deployment-proof", "passed": result["passed"],
              "stdoutSha256": sha(evidence / "stdout.log"),
              "compilerLogSha256": sha(evidence / "compilation.xml"),
              "runtimeSoSha256": sha(args.runtime_so) if args.runtime_so else None,
              "verification": result}
    with external_output_path(args.report).open("x", encoding="utf-8") as report:
        json.dump(record, report, ensure_ascii=False, indent=2)
        report.write("\n")
    print(json.dumps({"passed": result["passed"], "problems": result["problems"]}, ensure_ascii=False))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
