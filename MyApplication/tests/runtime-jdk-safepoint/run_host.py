#!/usr/bin/env python3
"""构建仓外独立夹具并验证宿主C2正例；原生进程硬超时防止坏JVM无限挂起。

所有输出必须写入调用方指定的新目录。本程序不连接设备、不修改应用、环境变量
或已有运行时；只终止由本次Popen创建且仍存活的独占Java进程。最终PASS同时要求
实际延时/GC/栈证据及本次LogCompilation中目标方法的真实C2 nmethod，不预填绿值。
"""

from __future__ import annotations
import argparse
import datetime as dt
import hashlib
import json
import pathlib
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

BASE = pathlib.Path(__file__).resolve().parent
MAIN = "com.amcl.qa.safepoint.SafepointRegression"
PREFIX = "AMCL-SP-REGRESSION "


def sha(path: pathlib.Path) -> str:
    """固定读取已存在文件的SHA256，输入不存在即失败，不生成替代证据。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: pathlib.Path, value: object) -> None:
    """只写本次新建会话目录内的结果，不覆盖其他任务材料。"""
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def external_output_path(value: pathlib.Path) -> pathlib.Path:
    """只接受显式仓外绝对输出，解析链接后再检查，避免输出回流源码目录。

    仓库/工作树从最近.git识别；源码包可由工程清单与AGENTS识别；单独复制本
    夹具时退回夹具目录边界。
    本函数不创建、清理或覆盖路径，后续调用方继续执行各自的新建/排他写入契约。
    """
    if not value.is_absolute():
        raise ValueError("输出必须是显式仓外绝对路径")
    output = value.resolve()
    # “仓外”也不能落进另一个Git项目；源码包没有.git时仍按同一工程哨兵拒绝。
    # 只检查路径及其祖先，不扫描无关仓库，更不创建/清理任何目标目录。
    for candidate in (output, *output.parents):
        git_marker = candidate / ".git"
        if (git_marker.exists() or git_marker.is_symlink()
                or ((candidate / "build-profile.json5").is_file()
                    and (candidate / "AGENTS.md").is_file())):
            raise ValueError("输出不能位于任何Git仓库或带工程哨兵的源码包内")
    repository = next((candidate for candidate in BASE.parents
                       if (candidate / ".git").exists()
                       or ((candidate / "build-profile.json5").is_file()
                           and (candidate / "AGENTS.md").is_file())), BASE)
    if output == repository or repository in output.parents:
        raise ValueError("输出不能位于源码仓库或夹具目录内")
    return output


def verify(output: pathlib.Path, rounds: int, max_latency_ms: int) -> dict:
    """核真实事件序列、测量字段和XML编译事实，不只相信程序的passed布尔值。"""
    stdout = (output / "stdout.log").read_text(encoding="utf-8", errors="strict")
    events = [json.loads(line[len(PREFIX):]) for line in stdout.splitlines() if line.startswith(PREFIX)]
    starts = [e for e in events if e.get("event") == "start"]
    cases = [e for e in events if e.get("event") == "case_result"]
    final = [e for e in events if e.get("event") == "execution_result"]
    begins = [e for e in events if e.get("event") == "case_begin"]
    problems = []
    if len(starts) != 1 or len(final) != 1 or len({e["runId"] for e in events}) != 1:
        problems.append("event_run_or_terminal_not_unique")
    if len(starts) != 1 or type(starts[0].get("rounds")) is not int or starts[0]["rounds"] != rounds:
        problems.append("start_rounds_mismatch")
    expected = list(range(1, rounds * 2 + 1))
    if [e["sequence"] for e in cases] != expected or [e["sequence"] for e in begins] != expected:
        problems.append("case_sequence_incomplete")
    if any(type(e.get("sequence")) is not int for e in begins):
        problems.append("case_begin_sequence_type_invalid")
    # 序号和业务类型是两条独立契约；全改成Dump不能冒充已经触发真实GC。
    begin_by_sequence = {e.get("sequence"): e for e in begins}
    for case in cases:
        sequence = case.get("sequence")
        expected_kind = "dump" if type(sequence) is int and sequence % 2 == 1 else "gc"
        begin = begin_by_sequence.get(sequence)
        if (type(sequence) is not int or case.get("kind") != expected_kind
                or begin is None or begin.get("kind") != expected_kind):
            problems.append("case_kind_mismatch:" + str(sequence))
        observed = case["gcBefore"] >= 0 and case["gcAfter"] > case["gcBefore"] if case["kind"] == "gc" else (
            case["hotFrameObserved"] and case["observedThreads"] > 0)
        valid = (case["failure"] is None and case["concurrentSetup"] and case["requestWithinHotWindow"]
                 and case.get("requestRemainingNanos", 0) > max_latency_ms * 2_000_000
                 and observed and 0 <= case["requestLatencyNanos"] <= max_latency_ms * 1_000_000)
        if not valid or case["executionPassed"] is not True:
            problems.append("case_failed:" + str(case["sequence"]))
    if not final or final[0].get("workersStopped") is not True or final[0].get("executionPassed") is not True:
        problems.append("execution_terminal_failed_or_workers_alive")
    if (len(final) != 1 or type(final[0].get("completed")) is not int
            or type(final[0].get("expected")) is not int
            or final[0]["completed"] != rounds * 2 or final[0]["expected"] != rounds * 2):
        problems.append("terminal_case_counts_mismatch")
    compilation = output / "compilation.xml"
    compiled = []
    retirements = []
    try:
        root = ET.parse(compilation).getroot()
        if starts and root.attrib.get("process") != str(starts[0].get("pid")):
            problems.append("compiler_log_process_mismatch")
        for node in root.iter("nmethod"):
            method = node.attrib.get("method", "").replace("/", ".")
            if node.attrib.get("compiler") == "c2" and method == MAIN + " hotLoop (JJ)J":
                compiled.append(dict(node.attrib))
        retirements = [dict(node.attrib) for node in root.iter("make_not_entrant")]
    except (ET.ParseError, FileNotFoundError) as problem:
        problems.append("compiler_log_unusable:" + str(problem))
    # 目标方法必须在第一次测量开始前编译；只找到结束后的编译不能证明测试运行了C2。
    first_begin_ms = min((e["uptimeMillis"] for e in begins), default=-1)
    ready = [item for item in compiled if float(item.get("stamp", "inf")) * 1000 <= first_begin_ms + 1]
    last_case_ms = max((e["uptimeMillis"] for e in cases), default=-1)
    # 不能拿预热时生成、测量前已失效的C2代码冒充有效覆盖；至少一份代码跨完整测量域。
    active = [item for item in ready if not any(
        retirement.get("compile_id") == item.get("compile_id")
        and float(retirement.get("stamp", "inf")) * 1000 <= last_case_ms + 1
        for retirement in retirements)]
    if not ready:
        problems.append("no_c2_hotloop_before_first_case")
    if not active:
        problems.append("no_c2_hotloop_spanning_measurements")
    if starts and (starts[0]["UseCompiler"] != "true" or starts[0]["TieredCompilation"] != "false"
                   or starts[0]["BackgroundCompilation"] != "false"):
        problems.append("actual_compiler_mode_mismatch")
    artifact = output / "amcl-safepoint-regression.jar"
    if not starts or not artifact.is_file() or starts[0].get("jarSha256") != sha(artifact):
        problems.append("executed_jar_identity_mismatch")
    if starts and not starts[0]["javaVersion"].startswith("25"):
        problems.append("not_actual_jdk25")
    return {"passed": not problems, "problems": problems, "events": events,
            "c2Nmethods": compiled, "c2BeforeFirstCase": ready, "c2SpanningMeasurements": active,
            "compilerRetirements": retirements}


def main() -> int:
    """普通宿主入口；硬超时以系统进程为边界，不依赖被测Java线程调度。"""
    parser = argparse.ArgumentParser()
    parser.add_argument("--java-home", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--rounds", type=int, default=4)
    parser.add_argument("--hot-ms", type=int, default=2000)
    parser.add_argument("--max-latency-ms", type=int, default=750)
    args = parser.parse_args()
    output = external_output_path(args.output)
    output.mkdir(parents=True, exist_ok=False)
    classes = output / "classes"
    classes.mkdir()
    suffix = ".exe" if sys.platform == "win32" else ""
    java = args.java_home.resolve() / "bin" / ("java" + suffix)
    javac = args.java_home.resolve() / "bin" / ("javac" + suffix)
    jar_tool = args.java_home.resolve() / "bin" / ("jar" + suffix)
    source = BASE / "src/com/amcl/qa/safepoint/SafepointRegression.java"
    artifact = output / "amcl-safepoint-regression.jar"
    version = subprocess.run([str(java), "-version"], cwd=output,
                             capture_output=True, text=True, timeout=15)
    (output / "java-version.txt").write_text(version.stdout + version.stderr, encoding="utf-8")
    for name, command in [
        ("javac", [str(javac), "--release", "21", "-encoding", "UTF-8", "-d", str(classes), str(source)]),
        ("jar", [str(jar_tool), "--create", "--file", str(artifact), "--main-class", MAIN, "-C", str(classes), "."]),
    ]:
        result = subprocess.run(command, cwd=output, capture_output=True, text=True, timeout=45)
        (output / (name + ".log")).write_text(result.stdout + result.stderr, encoding="utf-8")
        if result.returncode:
            raise SystemExit(name + "失败，保留" + str(output))
    command = [str(java), "-Xmx128m", "-Xms32m", "-Xbatch", "-XX:-TieredCompilation",
               "-XX:CompileThreshold=100", "-XX:+UnlockDiagnosticVMOptions", "-XX:+LogCompilation",
               "-XX:LogFile=" + str(output / "compilation.xml"),
               "-XX:CompileCommand=dontinline," + MAIN.replace(".", "/") + ".hotLoop",
               "-XX:+SafepointTimeout", "-XX:SafepointTimeoutDelay=500",
               "-Xlog:safepoint=debug,vmthread=debug", "-jar", str(artifact),
               str(args.rounds), str(args.hot_ms), str(args.max_latency_ms)]
    write_json(output / "command.json", command)
    budget = max(30, args.rounds * 2 * args.hot_ms / 1000 + 25)
    started = time.monotonic()
    timed_out = False
    with (output / "stdout.log").open("wb") as stdout, (output / "stderr.log").open("wb") as stderr:
        process = subprocess.Popen(command, cwd=output, stdout=stdout, stderr=stderr)
        print(json.dumps({"event": "host_process_started", "pid": process.pid, "hardTimeoutSeconds": budget}), flush=True)
        try:
            code = process.wait(timeout=budget)
        except subprocess.TimeoutExpired:
            # process对象只代表本次创建的独占JVM；不用按名称或猜测PID杀其他应用。
            timed_out = True
            process.kill()
            code = process.wait(timeout=10)
    evidence = verify(output, args.rounds, args.max_latency_ms)
    passed = code == 0 and not timed_out and evidence["passed"]
    receipt = {"schema": 1, "status": "passed-host-c2-only" if passed else "failed",
               "scope": "host-standard-jdk25-no-device-or-application-proof",
               "time": dt.datetime.now().astimezone().isoformat(), "pid": process.pid,
               "exitCode": code, "timedOut": timed_out, "elapsedSeconds": time.monotonic() - started,
               "sourceSha256": sha(source), "jarSha256": sha(artifact), "javaSha256": sha(java),
               "compilerLogSha256": sha(output / "compilation.xml") if (output / "compilation.xml").exists() else None,
               "verification": evidence}
    write_json(output / "receipt.json", receipt)
    print(json.dumps({"status": receipt["status"], "receipt": str(output / "receipt.json"),
                      "problems": evidence["problems"]}, ensure_ascii=False), flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
