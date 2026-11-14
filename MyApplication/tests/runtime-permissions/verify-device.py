"""只读核对同一次NCP的真实libc、Java权限API和ZIPFS结果，不凭目录/errno启用豁免。

输入为完整回收的run-major目录；证据必须具有同PID、成功安装/VM生命周期、每根5个
Java请求以及原生3API×5请求。未知/缺失/旧夹具均拒绝，不给未测根签发通过。
"""
import argparse
import hashlib
import json
from pathlib import Path


def verify(directory):
    """由真实报告决定要比较的根；每个case逐项对照对象、完整mode与成功/失败语义。"""
    directory = Path(directory)
    native = json.loads((directory / "permission-report.json").read_text(encoding="utf-8"))
    result = json.loads((directory / "result.json").read_text(encoding="utf-8"))
    log = (directory / "stdout.log").read_text(encoding="utf-8", errors="strict")
    reports = sorted(directory.glob("permission-java-*.jsonl"))
    if not reports:
        return {"passed": False, "problems": ["exclusive structured permission reports missing; stdout is not repaired"],
                "scope": "no qualification from interleaved compiler stdout"}
    structured = "\n".join(path.read_text(encoding="utf-8") for path in reports)
    def rows(prefix):
        # 只读独占报告中的完整行；共享stdout即使插入完整JSON前后也不能充当正式数据源。
        return [json.loads(line[len(prefix):]) for line in structured.splitlines() if line.startswith(prefix)]
    direct = rows("PERM_JAVA_DIRECT ")
    zip_rows = rows("PERM_JAVA ")
    mapping = {"same": "preserve-exact", "toggle-owner-exec": "toggle-owner-execute",
               "owner-only": "tighten-0600", "remove-owner-write": "remove-owner-write", "zero": "mode-zero"}
    problems, roots = [], []
    if native.get("status") != "OBSERVED" or not result.get("passed"):
        problems.append("native observation or VM lifecycle did not pass")
    for label in ("sandbox", "external"):
        group = native.get(label, {})
        if group.get("status") == "NOT-RUN":
            roots.append({"label": label, "status": "NOT-RUN", "reason": group.get("reason")})
            continue
        root = group.get("root")
        if not root or group.get("pid") != result.get("pid"):
            problems.append(label + ": missing root or PID mismatch")
            continue
        java = [item for item in direct if item.get("root") == root]
        operations = group.get("operations", [])
        if len(java) != 5 or {item.get("case") for item in java} != set(mapping) or len(operations) != 15:
            problems.append(label + ": incomplete unique Java/native permission matrix")
            continue
        for item in java:
            case = mapping[item["case"]]
            expected = [operation for operation in operations if operation.get("case") == case]
            if len(expected) != 3 or {entry.get("api") for entry in expected} != {"chmod", "fchmod", "fchmodat"}:
                problems.append(label + ": native API coverage incomplete: " + case)
                continue
            for entry in expected:
                # 本机三种API实测同义时才可交叉比较，不在未知系统上猜JDK provider内部选择。
                consistent = item.get("sameObject") and entry.get("pathStillSameObject") and (
                    item.get("beforeOctal") == entry.get("before", {}).get("modeOctal") and
                    item.get("requestedOctal") == entry.get("requestedOctal") and
                    item.get("afterOctal") == entry.get("after", {}).get("modeOctal") and
                    item.get("success") == (entry.get("result") == 0))
                if not consistent:
                    problems.append(label + ": Java disagrees with " + entry["api"] + ": " + case)
        source = [item for item in zip_rows if item.get("role") == "source" and
                  str(Path(item.get("path", "")).parent.parent).replace("\\", "/") == root]
        after = [item for item in zip_rows if item.get("role") == "after-zipfs" and
                 str(Path(item.get("path", "")).parent.parent).replace("\\", "/") == root]
        if len(source) != 1 or len(after) != 1 or source[0].get("modeOctal") != after[0].get("modeOctal"):
            problems.append(label + ": ZIPFS source/committed mode proof missing")
        payload = [item for item in zip_rows if item.get("root") == root and item.get("zipPayloadBytesVerified") is True]
        if len(payload) != 1:
            problems.append(label + ": ZIPFS complete payload readback missing")
        roots.append({"label": label, "root": root, "status": "OBSERVED", "javaCases": len(java)})
    measured = len([item for item in roots if item["status"] == "OBSERVED"])
    closed = [item for item in zip_rows if "zipfsClosed" in item]
    if measured == 0 or len(closed) != measured or any(not item.get("zipfsClosed") or
            not item.get("originalStillExists") for item in closed):
        problems.append("ZIPFS payload/close proof incomplete")
    if len(reports) != measured:
        problems.append("structured report count differs from observed roots")
    if any("zipfsError" in item for item in zip_rows):
        problems.append("ZIPFS reported failure")
    return {"passed": not problems, "problems": problems, "roots": roots,
            "pid": result.get("pid"), "archiveSha256": result.get("archiveSha256"),
            "fixtureSha256": result.get("fixtureSha256"),
            "structuredReports": {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in reports},
            "evidence": {name: hashlib.sha256((directory / name).read_bytes()).hexdigest()
                         for name in ("permission-report.json", "result.json", "stdout.log")},
            "scope": "same-session observed roots only; no CLI or other-device qualification"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    result = verify(args.run)
    with args.report.open("x", encoding="utf-8") as output:
        json.dump(result, output, ensure_ascii=False, indent=2)
    print(json.dumps({"passed": result["passed"], "problems": result["problems"]}, ensure_ascii=False))
    raise SystemExit(0 if result["passed"] else 1)
