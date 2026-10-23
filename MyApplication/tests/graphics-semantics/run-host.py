#!/usr/bin/env python3
"""在独立软件EGL进程校准共享深度场景，并可验证显式传入的真实MG库。

临时构建、配置、原始日志与判定全部写调用者指定的仓外目录。参考通过只证明
oracle可用；生产结果另列，不借参考或人工负控推断OHOS实际最终载荷通过。
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
from datetime import datetime, timezone, timedelta


def digest(path):
    """读取实际文件内容的摘要，不把文件名或pin当作被测库身份。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def execute(command, log, environment=None, timeout=90):
    """前台等待同一进程；保留完整stdout/stderr和实际exit code，超时不能算负控检出。"""
    try:
        result = subprocess.run(command, env=environment, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as error:
        text = error.stdout or b""
        log.write_text(text.decode(errors="replace") if isinstance(text, bytes) else text,
                       encoding="utf-8")
        raise RuntimeError("test process timed out: " + str(command)) from error
    log.write_text(result.stdout, encoding="utf-8")
    print(result.stdout, end="", flush=True)
    return result.returncode


def validate_evidence(directory, summary, contract, required_functions):
    """独立核对必需用例/实际行数/终止marker/函数身份；不复制深度映射或绘制算法。

    缺报告、截断、空清单或不完整函数身份都不能借exitCode=0/summary的自述PASS。
    返回完整原始条目与缺陷清单，供正例和校准负控用同一完整性判据裁决。
    """
    errors = []
    evidence_path = directory / "evidence.jsonl"
    try:
        evidence = [json.loads(line) for line in evidence_path.read_text().splitlines()]
    except (OSError, json.JSONDecodeError) as error:
        return [], ["evidence missing or not complete JSONL: " + str(error)]
    if not evidence or not all(isinstance(item, dict) for item in evidence):
        return evidence, ["evidence must contain structured checks"]
    terminals = [item for item in evidence if item.get("kind") == contract["terminalKind"]]
    if len(terminals) != 1 or evidence[-1] != terminals[0]:
        errors.append("exactly one terminal must be the final JSONL record")
    checks = [item for item in evidence if "pass" in item]
    if not all(type(item["pass"]) is bool for item in checks):
        errors.append("check verdict must be boolean")
    actual = {"checks": len(checks), "queryChecks": sum(item.get("kind") in contract["queryKinds"] for item in checks),
              "pixelChecks": sum(item.get("kind") == "pixels" for item in checks),
              "failures": sum(item.get("pass") is False for item in checks)}
    if summary.get("completed") is not True or summary.get("evidenceComplete") is not True:
        errors.append("producer did not finish and validate evidence")
    for key, value in actual.items():
        if type(summary.get(key)) is not int or summary[key] != value:
            errors.append("summary count mismatch: " + key)
        if len(terminals) == 1 and (type(terminals[0].get(key)) is not int or terminals[0][key] != value):
            errors.append("terminal count mismatch: " + key)
    for key, value in contract["counts"].items():
        if actual[key] != value:
            errors.append("required count mismatch: " + key)
    if len(terminals) == 1 and terminals[0].get("completed") is not True:
        errors.append("terminal is not complete")
    for case in contract["cases"]:
        for kind in contract["queryKinds"]:
            rows = [item for item in checks if item.get("kind") == kind and item.get("case") == case["id"]]
            if len(rows) != 1:
                errors.append("missing/duplicate query: " + case["id"] + "/" + kind)
            elif any(not isinstance(rows[0].get(field), list) or len(rows[0][field]) !=
                     (2 if field == 'guards' else contract.get('queryComponents', 2))
                     for field in ["actual", "expected", "guards"]):
                errors.append("query does not include both components and guards")
        pixels = [item for item in checks if item.get("kind") == "pixels" and item.get("case") == case["id"]]
        if len(pixels) != case["pixelChecks"]:
            errors.append("missing/duplicate pixel check: " + case["id"])
        for pixel in pixels:
            raw = pixel.get("rgba8x8Hex", "")
            if pixel.get("sampledPixels") != contract["pixelsPerCheck"] or \
                    not isinstance(raw, str) or len(raw) != contract["pixelsPerCheck"] * 8 or \
                    not re.fullmatch("[0-9a-f]+", raw) or \
                    pixel.get("channelTolerance") != contract["channelTolerance"]:
                errors.append("raw pixel evidence incomplete: " + case["id"])
    for required in contract["requiredChecks"]:
        if sum(item.get("kind") == required["kind"] and item.get("case") == required["case"]
               for item in checks) != required["count"]:
            errors.append("missing required resource/error check")
    if contract.get('sceneVersion') == 1:
        # initializer是独立新增协议；只认机器清单给出的16个check、一个metadata与
        # 唯一末尾。额外合法JSON/NOT_RUN、旧快照或缺资源行均不能借summary通过。
        allowed = {(row['kind'], row['case']) for row in contract['requiredChecks']}
        allowed.update((kind, case['id']) for case in contract['cases'] for kind in [*contract['queryKinds'], 'pixels'])
        if any((item.get('kind'), item.get('case')) not in allowed for item in checks):
            errors.append('unknown initializer check')
        metadata = [item for item in evidence if item.get('kind') in contract['metadataKinds']]
        if len(metadata) != 1 or evidence[0] != metadata[0] or type(metadata[0].get('count')) is not int or not 0 <= metadata[0]['count'] <= 32:
            errors.append('initializer metadata incomplete')
        if len(evidence) != len(checks) + len(metadata) + len(terminals):
            errors.append('unknown initializer JSON record')
    try:
        functions = [line.split("\t") for line in (directory / "functions.tsv").read_text().splitlines()]
        names = {row[0] for row in functions if len(row) >= 3 and row[1] not in ["0", "(nil)", "0x0"]
                 and row[2] != "UNKNOWN"}
        if not required_functions.issubset(names):
            errors.append("missing actual required function identity")
    except OSError:
        errors.append("function identity evidence missing")
    try:
        process = (directory / "process.log").read_text()
        marker = (contract.get("hostMarker", "DEPTH_RANGE_RESULT") +
                  " completed=1 checks={checks} queryChecks={queryChecks} pixelChecks={pixelChecks} failures={failures}").format(**actual)
        if process.count(marker) != 1 or "HOST_SETUP_FAILURE" in process:
            errors.append("host completion marker missing or failed")
        if summary.get("stage") == "software-reference" and "renderer=llvmpipe" not in process:
            errors.append("actual software renderer is not llvmpipe")
    except OSError:
        errors.append("host process evidence missing")
    return evidence, errors


def main():
    """冻结编译源/工具和运行环境，先校准正负判据，再记录可选production的独立结果。"""
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--egl-include", type=Path)
    parser.add_argument("--library", type=Path)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--scene", choices=['depth', 'initializer'], default='depth')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    source = Path(__file__).resolve().parent
    contract_name = 'uniform_initializer_cases.json' if args.scene == 'initializer' else 'depth_range_cases.json'
    contract = json.loads((source / contract_name).read_text())
    required_functions = {"gl" + name for name in re.findall(r"\b" + contract['loaderMacro'] + r"\((\w+)\)",
        (source / contract["loaderSource"]).read_text()) if name != "member"} | {"glGetString"}
    if not required_functions or not contract["cases"]:
        raise ValueError("required case/function contract must not be empty")
    output, build = args.output.resolve(), args.build.resolve()
    for path in (output, build):
        if path == root or root in path.parents:
            raise ValueError("outputs must be outside the application repository")
        path.mkdir(parents=True, exist_ok=False)
    if args.repeats < 1 or args.repeats > 10:
        raise ValueError("repeats must be in [1,10]")
    include = (args.egl_include or root / "prebuilt/mobileglues/mg_src/MobileGlues-cpp/include").resolve()
    if not (include / "EGL/egl.h").is_file() or not (include / "MG/init.h").is_file():
        raise ValueError("EGL and MG initialization ABI headers are required")
    executable = build / "depth-range-host"
    compiler = os.environ.get("CXX", "c++")
    command = [compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror", "-O2", "-g",
               "-I" + str(include), str(source / "depth_range_scene.cpp"),
               str(source / "host_runner.cpp"), "-Wl,-l:libEGL.so.1", "-ldl", "-o", str(executable)]
    identity = {
        "schema": "amcl-graphics-semantics-host/v1",
        "startedAt": datetime.now(timezone(timedelta(hours=8))).isoformat(),
        "timeZone": "Asia/Shanghai", "platform": platform.platform(),
        "compileCommand": command,
        "compiler": subprocess.check_output([compiler, "--version"], text=True),
        "repositoryHead": subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip(),
        "sources": {name: digest(source / name) for name in
                    ["depth_range_scene.h", "depth_range_scene.cpp", contract_name, "host_runner.cpp", "run-host.py"]},
        "headers": {name: digest(include / name) for name in ["EGL/egl.h", "MG/init.h"]},
        "bounds": {"fbo": [64, 64], "depthFormat": "DEPTH_COMPONENT16", "pixelRegion": [28, 28, 8, 8],
                   "scene": args.scene, "queryTolerance": 2e-6, "channelTolerance": contract['channelTolerance'], "repeats": args.repeats,
                   "processTimeoutSeconds": 90, "performanceClaim": False},
        "reference": "Mesa desktop OpenGL through software EGL; does not substitute MG/OHOS",
    }
    (output / "identity.json").write_text(json.dumps(identity, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if execute(command, output / "compile.log"):
        return 2
    identity["executableSha256"] = digest(executable)
    identity["elfNotes"] = subprocess.check_output(["readelf", "-n", str(executable)], text=True)
    identity["linkedLibraries"] = subprocess.check_output(["ldd", str(executable)], text=True)
    environment = dict(os.environ, EGL_PLATFORM="surfaceless", LIBGL_ALWAYS_SOFTWARE="1",
                       MESA_LOADER_DRIVER_OVERRIDE="llvmpipe")
    identity["graphicsEnvironment"] = {key: environment[key] for key in
                                       ["EGL_PLATFORM", "LIBGL_ALWAYS_SOFTWARE", "MESA_LOADER_DRIVER_OVERRIDE"]}
    runs = [("reference-" + str(i + 1), [], None) for i in range(args.repeats)]
    controls = ['initializer-stripped'] if args.scene == 'initializer' else ['double-stub', 'depth-disabled', 'short-double-query']
    runs += [("oracle-" + control, ["--control", control], control) for control in controls]
    if args.library:
        library = args.library.resolve(strict=True)
        identity["productionLibrary"] = {"path": str(library), "sha256": digest(library),
            "elfNotes": subprocess.check_output(["readelf", "-n", str(library)], text=True)}
        # MG配置只供这次新进程读取；不修改消费者的既有配置/全局环境。
        configuration = output / "mg-config"
        configuration.mkdir()
        (configuration / "config.json").write_text('{"customGLVersion":46,"fsr1Setting":0,"hideMGEnvLevel":0}\n')
        environment["MG_DIR_PATH"] = str(configuration)
        runs += [("production-" + str(i + 1), ["--library", str(library)], None) for i in range(args.repeats)]
    rows = []
    for name, arguments, control in runs:
        directory = output / name
        directory.mkdir()
        scene_arguments = ['--scene', 'initializer'] if args.scene == 'initializer' else []
        exit_code = execute([str(executable), str(directory), *scene_arguments, *arguments], directory / "process.log", environment)
        summary_path = directory / "summary.json"
        summary = json.loads(summary_path.read_text()) if summary_path.exists() else {"completed": False}
        evidence_path = directory / "evidence.jsonl"
        evidence, integrity_errors = validate_evidence(directory, summary, contract, required_functions)
        failed_kinds = sorted({item["kind"] for item in evidence if item.get("pass") is False})
        mapped_libraries = {}
        mappings_path = directory / "graphics-maps.txt"
        if mappings_path.exists():
            for mapping in mappings_path.read_text().splitlines():
                mapped_name = mapping.split()[-1]
                mapped = Path(mapped_name)
                if mapped.is_absolute() and mapped.is_file() and mapped_name not in mapped_libraries:
                    mapped_libraries[mapped_name] = {"sha256": digest(mapped),
                        "elfNotes": subprocess.check_output(["readelf", "-n", mapped_name], text=True)}
        if control:
            required = {"double-stub": {"float-query", "double-query", "pixels"},
                        "depth-disabled": {"pixels"}, "short-double-query": {"double-query"},
                        "initializer-stripped": {"uniform-query", "pixels"}}[control]
            passed = exit_code == 1 and not integrity_errors and required.issubset(failed_kinds)
            if control == 'initializer-stripped':
                failures = [item for item in evidence if item.get('pass') is False]
                passed = passed and len(failures) == 2 and all(item.get('case') == 'initializer-link-default' for item in failures)
            # GL错误/环境失败会阻止completed，不允许被统计成“成功检出语义缺陷”。
            verdict = "EXPECTED_FAILURE_DETECTED" if passed else "ORACLE_CALIBRATION_FAILED"
        else:
            passed = exit_code == 0 and not integrity_errors and summary.get("failures") == 0
            verdict = "PASS" if passed else "FAIL"
        rows.append({"name": name, "exitCode": exit_code, "verdict": verdict,
                     "passed": passed, "summary": summary, "failedKinds": failed_kinds,
                     "actualMappedGraphicsLibraries": mapped_libraries,
                     "evidenceIntegrityErrors": integrity_errors,
                     "evidence": str(evidence_path), "functionIdentity": str(directory / "functions.tsv")})
    identity["finishedAt"] = datetime.now(timezone(timedelta(hours=8))).isoformat()
    (output / "identity.json").write_text(json.dumps(identity, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (output / "results.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("HOST_SUITE_RESULT runs=" + str(len(rows)) + " passed=" + str(sum(row["passed"] for row in rows)))
    return 0 if all(row["passed"] for row in rows) else 1


if __name__ == "__main__":
    sys.exit(main())
