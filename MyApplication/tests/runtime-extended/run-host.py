#!/usr/bin/env python3
"""外置构建 class52 扩展资格 JAR，逐个完整宿主 JDK 执行并保留真实进程结果。"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import zipfile


def stamp():
    """直接读取系统带时区时钟，收据不估算历史操作时间。"""
    return datetime.datetime.now().astimezone().isoformat()


def sha(path):
    """对实际文件字节取 SHA，工具显示版本与文件身份分别保留。"""
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def save(path, value):
    """结构化产物只写本次新建的外置运行目录。"""
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--javac", type=Path, required=True)
    parser.add_argument("--java-home", type=Path, action="append", default=[])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=int, default=180)
    parser.add_argument("--launch-mechanism", choices=("default", "FORK"), default="default")
    args = parser.parse_args()
    if args.launch_mechanism == "FORK" and os.name == "nt":
        parser.error("FORK comparison requires a fresh POSIX JVM; Windows does not use that launch mechanism")
    if not 30 <= args.timeout_seconds <= 300:
        parser.error("qualification deadline must be between 30 and 300 seconds")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    inputs = output / "inputs"
    inputs.mkdir()
    source = Path(__file__).with_name("ExtendedRuntimeQualification.java").resolve()
    frozen = inputs / source.name
    shutil.copyfile(source, frozen)
    classes = output / "classes"
    classes.mkdir()
    javac = args.javac.resolve(strict=True)
    javac_version = subprocess.check_output([str(javac), "-version"], stderr=subprocess.STDOUT, text=True).strip()
    command = [str(javac), "--release", "8", "-encoding", "UTF-8", "-g", "-d", str(classes), str(frozen)]
    started = stamp()
    with (output / "compile.log").open("wb") as log:
        built = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, cwd=output)
    if built.returncode:
        save(output / "build-receipt.json", {"startedAt": started, "finishedAt": stamp(), "exitCode": built.returncode,
             "command": command, "javacSha256": sha(javac), "sourceSha256": sha(frozen)})
        raise SystemExit(built.returncode)
    archive = output / "extended-qualification.jar"
    inventory = []
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as jar:
        for file in sorted(classes.rglob("*.class")):
            data = file.read_bytes()
            if data[:4] != b"\xca\xfe\xba\xbe" or int.from_bytes(data[6:8], "big") != 52:
                raise RuntimeError("fixture is not class52: " + str(file))
            name = file.relative_to(classes).as_posix()
            member = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            member.external_attr = 0o100644 << 16
            member.compress_type = zipfile.ZIP_DEFLATED
            jar.writestr(member, data)
            inventory.append({"path": name, "bytes": len(data), "sha256": sha(file), "classMajor": 52})
    save(output / "build-receipt.json", {"startedAt": started, "finishedAt": stamp(), "exitCode": 0,
         "command": command, "javac": str(javac), "javacVersion": javac_version, "javacSha256": sha(javac),
         "sourceSha256": sha(frozen), "jarSha256": sha(archive), "jarBytes": archive.stat().st_size, "classes": inventory})
    rows = []
    for home_arg in args.java_home:
        home = home_arg.resolve(strict=True)
        java = home / "bin" / ("java.exe" if os.name == "nt" else "java")
        version = subprocess.check_output([str(java), "-version"], stderr=subprocess.STDOUT, text=True).strip()
        match = re.search(r'(?:java|openjdk) version "([^\"]+)"', version)
        if not match:
            raise RuntimeError("unrecognized actual Java version: " + version)
        major = match[1].split(".")[1] if match[1].startswith("1.") else re.split(r"[.+-]", match[1])[0]
        if major not in {"8", "17", "21", "25"}:
            raise RuntimeError("unsupported host version: " + major)
        destination = output / ("java-" + major)
        destination.mkdir(exist_ok=False)
        classpath = [str(archive)]
        # 固定8源码的ToolProvider按 java.home/../lib/tools.jar自行载入；JFR也在默认bootpath，
        # 不额外拼classpath掩盖错误的安装布局或java.home。JRE不能冒充完整JDK。
        # 与当前独立目标资格通道相同的堆界限；保留默认正常分层/C2优化。
        command = [str(java), "-Xcheck:jni", "-Xms64m", "-Xmx256m", "-Dfile.encoding=UTF-8"]
        if major != "8":
            # 只给受控 keytool 资格入口导出包，不改变产品或用户公共 JVM 参数。
            command.append("--add-exports=java.base/sun.security.tools.keytool=ALL-UNNAMED")
            command.append("--add-opens=java.base/java.lang=ALL-UNNAMED")
        if args.launch_mechanism == "FORK":
            command.append("-Djdk.lang.Process.launchMechanism=FORK")
        command += ["-cp", os.pathsep.join(classpath), "ExtendedRuntimeQualification", str(destination), major]
        environment = os.environ.copy()
        for name in ("JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS"):
            environment.pop(name, None)
        environment["JAVA_HOME"] = str(home)
        began = stamp()
        timed_out = False
        with (destination / "stdout.log").open("wb") as stdout, (destination / "stderr.log").open("wb") as stderr:
            child = subprocess.Popen(command, cwd=destination, env=environment, stdout=stdout, stderr=stderr)
            try:
                code = child.wait(timeout=args.timeout_seconds)
            except subprocess.TimeoutExpired:
                timed_out = True
                child.kill()
                code = child.wait()
            except BaseException:
                # 用户中断/宿主异常也必须回收本runner拥有的实际进程，不留下孤立JVM。
                child.kill()
                child.wait()
                raise
        result_file = destination / "extended-runtime/result.json"
        result = json.loads(result_file.read_text(encoding="utf-8")) if result_file.is_file() else None
        passed = not timed_out and code == 0 and result is not None and result.get("passed") is True
        row = {"major": major, "home": str(home), "javaVersion": version, "javaSha256": sha(java),
               "toolsJarSha256": sha(home / "lib/tools.jar") if (home / "lib/tools.jar").is_file() else None,
               "command": command, "startedAt": began, "finishedAt": stamp(), "pid": child.pid,
               "actualProcessReturnCode": code, "timedOut": timed_out, "processReaped": True,
               "passed": passed, "fixtureResult": str(result_file) if result else None}
        save(destination / "host-receipt.json", row)
        rows.append(row)
        print(json.dumps({"major": major, "passed": passed, "exitCode": code, "timedOut": timed_out,
                          "receipt": str(destination / "host-receipt.json")}), flush=True)
    untested = sorted({"8", "17", "21", "25"} - {row["major"] for row in rows}, key=int)
    save(output / "host-matrix.json", {"finishedAt": stamp(), "runs": rows, "untestedMajors": untested,
         "allSelectedPassed": all(row["passed"] for row in rows), "fourMajorHostComplete": bool(rows) and not untested,
         "scope": "host only; no OHOS, native-child, CLI exec, external network or release qualification"})
    if any(not row["passed"] for row in rows):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
