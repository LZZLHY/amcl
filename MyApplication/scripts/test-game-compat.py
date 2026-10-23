"""分层验证兼容制品：既有规则、真实 Create Mixin、原版调度字节码与旧路径隔离。

宿主端点测试不能替代实际 Fabric/Knot/真机。各项输出单独保存，避免只因 ASM 通过
就宣布游戏行为安全。测试依赖由显式准备脚本锁定，正式 JAR 不带测试端点或游戏类。
"""
from pathlib import Path
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
import signal
import subprocess
import sys
import queue
import re
import threading
import time
from lib.game_compat_inputs import LOCK, jdk_tool, prepare, vendored_classpath
from lib.game_compat_validation import capture_host_inputs, command_classpath, output_snapshot, validate_identity_sections
from lib.game_compat_scheduling_view import create_scheduling_view, validate_runtime_classpath, validate_scheduling_view
from lib.game_compat_sessions import new_compat_session
from lib.owned_process import WindowsJobProcess

ROOT = Path(__file__).resolve().parent.parent

def run(command, log, timeout=120):
    """流式记录且始终有 deadline；超时/中断只终止此函数启动的子进程。

    不能在主线程直接迭代 stdout，否则沉默死锁的测试永远不触发 timeout。读管道线程
    为 daemon，主线程用有界 Queue/轮询负责计时；job/session回收限定5秒，reader限定1秒。
    不按名字杀 Java、不 kill HDC/其他会话，也不让测试非 daemon 线程拖住门禁 JVM。
    """
    with log.open("w", encoding="utf-8") as output:
        started = datetime.now(timezone.utc).isoformat()
        start_clock = time.monotonic()
        if os.name == "nt":
            process = WindowsJobProcess(command, ROOT)
        else:
            process = subprocess.Popen(list(map(str, command)), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       text=True, encoding="utf-8", errors="replace", cwd=ROOT, start_new_session=True)
        observed_children = []
        lines = queue.Queue(maxsize=256)
        stopped = threading.Event()
        completed = object()
        def enqueue(block):
            """主线程超时离开后停止写队列，避免reader因队列满而遗留到后续suite。"""
            while not stopped.is_set():
                try:
                    lines.put(block, timeout=0.1); return
                except queue.Full:
                    continue
        def read_output():
            """限制单块大小；读取线程只传递文本，不访问日志或处理进程生命周期。"""
            try:
                while True:
                    block = process.stdout.readline(65536)
                    if not block:
                        break
                    enqueue(block)
            finally:
                enqueue(completed)
        reader = threading.Thread(target=read_output, name="game-compat-log-reader", daemon=True)
        reader.start()
        deadline = time.monotonic() + timeout
        pending_error = None
        try:
            ended = False
            while not ended:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    output.write("\n[game-compat-tests] deadline exceeded: " + str(timeout) + " seconds\n"); output.flush()
                    raise subprocess.TimeoutExpired(command, timeout)
                try:
                    block = lines.get(timeout=min(0.25, remaining))
                except queue.Empty:
                    continue
                if block is completed:
                    ended = True
                else:
                    print(block, end="", flush=True); output.write(block); output.flush()
                    marker = re.search(r"\[runner-orphan-control\] child-started pid=(\d+)", block)
                    if marker:
                        pid = int(marker.group(1))
                        if os.name == "nt":
                            process.observe_owned_child(pid)
                        elif os.getpgid(pid) != process.pid:
                            raise RuntimeError("Orphan-control child outside suite-owned session")
                        observed_children.append(pid)
            code = process.wait(timeout=max(0.01, deadline - time.monotonic()))
        except BaseException as error:
            pending_error = error
            raise
        finally:
            cleanup_evidence = None
            root_before_cleanup = None
            try:
                root_before_cleanup = process.poll()
                if os.name == "nt":
                    # job从CreateProcess原子创建时即拥有root及后代，不依赖root还活着。
                    cleanup_evidence = process.terminate_owned(timeout=5)
                else:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=5)
                    cleanup_evidence = {"kind": "owned-posix-session", "groupSignalSent": True,
                                        "observedChildren": [{"pid": pid, "ownedSessionBeforeCleanup": True} for pid in observed_children]}
                if isinstance(pending_error, subprocess.TimeoutExpired):
                    pending_error.terminated_pid = process.pid
                    pending_error.terminated_returncode = process.returncode
                    pending_error.root_exit_before_cleanup = root_before_cleanup
                    pending_error.own_tree_cleanup_confirmed = True
                    pending_error.cleanup_evidence = cleanup_evidence
            finally:
                if os.name == "nt":
                    # Terminate/Query失败时仍CloseHandle触发KillOnClose；失败原样上抛，不能记PASS。
                    process.close()
                stopped.set()
                reader.join(timeout=1)
                if not reader.is_alive():
                    process.stdout.close()
                if isinstance(pending_error, subprocess.TimeoutExpired):
                    pending_error.reader_stopped = not reader.is_alive()
            if reader.is_alive():
                raise RuntimeError("Owned suite log reader did not stop within cleanup deadline")
    if code:
        raise subprocess.CalledProcessError(code, command)
    return {"command": list(map(str, command)), "startedUtc": started,
            "elapsedSeconds": round(time.monotonic() - start_clock, 3), "exitCode": code,
            "log": str(log), "logSha256": hashlib.sha256(log.read_bytes()).hexdigest(),
            "ownedProcessId": process.pid, "cleanupEvidence": cleanup_evidence, "readerStopped": True}


def main():
    """每轮使用新的外置目录，避免旧 class、旧日志或旧 Mixin 状态掩盖变换失败。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", help="New external test session")
    parser.add_argument("--inputs", help="Verified compile-only cache prepared with --include-tests")
    parser.add_argument("--java21-home", default=os.environ.get("AMCL_COMPAT_JAVA21_HOME"),
                        help="JDK21 home for actual legacy isolation process; required to close legacy runtime validation")
    parser.add_argument("--process-timeout", type=int, default=120, help="Deadline in seconds for each own compiler/test process")
    args = parser.parse_args()
    build = new_compat_session("game-compat-tests", args.output)
    inputs = prepare(args.inputs, include_create=True)
    jar = ROOT / "entry/src/main/resources/rawfile/amcl-fabric-compat.jar"
    if args.process_timeout < 1 or args.process_timeout > 600:
        raise RuntimeError("--process-timeout must be between 1 and 600 seconds")
    common = [jar, *vendored_classpath()]
    classes = build / "tests"; classes.mkdir()
    cp = os.pathsep.join(map(str, [*common, *inputs["classpath"]]))
    current_identity = capture_host_inputs(inputs)
    actual_classpath = current_identity["classpath"]
    fixed_extra_inputs = current_identity["extraInputs"]
    (build / "classpath-receipt.json").write_text(json.dumps(actual_classpath, indent=2) + "\n", encoding="utf-8")
    initial_sources = current_identity["sources"]
    initial_artifact = hashlib.sha256(jar.read_bytes()).hexdigest()
    receipt = {"schema": 2, "status": "running", "artifactSha256": initial_artifact,
        "inputLockSha256": hashlib.sha256(LOCK.read_text(encoding="utf-8").encode("utf-8")).hexdigest(),
        "sources": initial_sources, "classpath": actual_classpath, "extraInputs": fixed_extra_inputs, "suites": [],
        "tools": {name: subprocess.check_output([jdk_tool(name), "-version"], stderr=subprocess.STDOUT,
                                                 text=True, timeout=10).strip() for name in ("java", "javac")},
        "scope": {"actualFabricDiscovery": False, "actualKnot": False, "actualWorld": False,
                  "originalBundleHandler": False, "bundleEndpoint": True, "syntheticCmeScenario": True}}
    def save_receipt():
        """每个 suite 完成即更新收据；失败阶段也保留已完成证据，绝不写成全量通过。"""
        (build / "host-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    def execute(command, log, timeout=args.process_timeout):
        """给每次真实子进程绑定命令、日志摘要、结果；被测文件身份最终还要复核。"""
        try:
            consumed_classpath = command_classpath(command, inputs, build)
            result = run(command, log, timeout)
        except BaseException as error:
            receipt["status"] = "failed"
            receipt["suites"].append({"command": list(map(str, command)), "error": type(error).__name__,
                "reason": str(error), "log": str(log),
                "logSha256": hashlib.sha256(log.read_bytes()).hexdigest() if log.exists() else None})
            save_receipt(); raise
        if consumed_classpath != command_classpath(command, inputs, build):
            receipt["status"] = "failed-suite-classpath-drift"; save_receipt()
            raise RuntimeError("Suite classpath changed during process: " + str(command))
        result["classpath"] = consumed_classpath
        receipt["suites"].append(result); save_receipt(); return result
    save_receipt()
    execute([sys.executable, "-B", ROOT / "scripts/test-game-compat-receipt.py", "--inputs", inputs["directory"],
             "--output", build / "session-controls"],
            build / "receipt-contract-results.txt")
    sources = sorted((ROOT / "prebuilt/runtime-compat/test").rglob("*.java"))
    execute([jdk_tool("javac"), "--release", "21", "-proc:none", "-encoding", "UTF-8", "-cp", cp,
         "-d", classes, *sources], build / "compile-tests.txt", args.process_timeout)
    services = classes / "META-INF/services"; services.mkdir(parents=True)
    (services / "org.spongepowered.asm.service.IMixinService").write_text("com.amcl.compat.test.MixinTestService\n", encoding="utf-8")
    (services / "org.spongepowered.asm.service.IGlobalPropertyService").write_text("com.amcl.compat.test.TestProperties\n", encoding="utf-8")
    (classes / "amcl-threading-test.mixins.json").write_text(json.dumps({"required": True,
        "minVersion": "0.8.7", "package": "com.amcl.compat.mixin", "compatibilityLevel": "JAVA_21",
        "plugin": "com.amcl.compat.test.ThreadingTestPlugin", "client": [], "injectors": {"defaultRequire": 1}}), encoding="utf-8")
    foreign_configs = []
    for name in ("ForeignHighMixin", "ForeignLowMixin", "ForeignCancelMixin", "ForeignOverwriteMixin", "ForeignUnmatchedMixin"):
        filename = "amcl-" + name + ".mixins.json"
        (classes / filename).write_text(json.dumps({"required": True, "minVersion": "0.8.7",
            "package": "com.amcl.compat.test.foreign", "compatibilityLevel": "JAVA_21", "client": [name],
            "injectors": {"defaultRequire": 1}}), encoding="utf-8")
        foreign_configs.append(filename)
    host = [str(classes), *map(str, common), str(inputs["paths"]["loader"])]
    fixtures = ROOT / "prebuilt/runtime-compat/test-fixtures"
    old_suites = [
        ("ResizeMixinTest", [], [], "resize-results.txt"),
        ("FlywheelMixinTest", [fixtures / "create-fly-staging.jar"], [], "flywheel-results.txt"),
        ("TinyFdCompatibilityTest", [ROOT / "prebuilt/lwjgl3/jars/lwjgl.jar"],
         [ROOT / "prebuilt/lwjgl3/jars/lwjgl-tinyfd.jar"], "tinyfd-results.txt"),
        ("LevelUniformMixinTest", [fixtures / "create-fly-level.jar"], [], "level-uniform-results.txt"),
    ]
    for suite, extra_cp, arguments, log in old_suites:
        execute([jdk_tool("java"), "-cp", os.pathsep.join([*host, *map(str, extra_cp)]),
             "com.amcl.compat.test." + suite, *arguments], build / log, args.process_timeout)
    # 不带 named 游戏 JAR 的隔离加载器始终运行；若明确提供 JDK21，再用真实旧运行时执行，
    # 收据区分二者，缺 JDK21 不能宣称完整旧运行时验收通过。
    legacy_java = jdk_tool("java")
    legacy_runtime = "current-jdk-isolation-only"
    if args.java21_home:
        legacy_java = str(Path(args.java21_home) / "bin" / ("java.exe" if os.name == "nt" else "java"))
        probe = subprocess.run([legacy_java, "-version"], capture_output=True, text=True, check=True, timeout=10)
        import re
        if not re.search(r'version "21(?:[.\"]|$)', probe.stdout + probe.stderr):
            raise RuntimeError("--java21-home must identify JDK21")
        legacy_runtime = "actual-jdk21"
    receipt["tools"]["legacyJava"] = subprocess.check_output([legacy_java, "-version"], stderr=subprocess.STDOUT, text=True, timeout=10).strip()
    execute([legacy_java, "-cp", os.pathsep.join(host), "com.amcl.compat.test.LegacyThreadingIsolationTest",
         *common, inputs["paths"]["loader"]], build / "legacy-isolation-results.txt", args.process_timeout)
    transform_cp = [str(classes), *map(str, common), *map(str, inputs["classpath"]), str(inputs["paths"]["create-old"])]
    execute([jdk_tool("java"), "-cp", os.pathsep.join(transform_cp), "com.amcl.compat.test.CreateThreadingMixinTest",
         inputs["paths"]["create-old"], inputs["paths"]["create-new"], inputs["paths"]["client"],
         build / "transformed"], build / "threading-mixin-results.txt", args.process_timeout)
    for config in foreign_configs:
        execute([jdk_tool("java"), "-cp", os.pathsep.join(transform_cp), "com.amcl.compat.test.ThreadingCombinationTest", config,
                 *(["expect-unmatched"] if "Unmatched" in config else [])],
            build / (config + ".results.txt"), args.process_timeout)
    # 只有受控调度试验子进程把窄端点放在原件游戏之前；Mixin 实物验证明确使用完整官方原件。
    endpoints = build / "scheduling"; endpoints.mkdir()
    native_sources = sorted((ROOT / "prebuilt/runtime-compat/test-threading").rglob("*.java"))
    execute([jdk_tool("javac"), "--release", "21", "-proc:none", "-encoding", "UTF-8", "-cp", cp,
         "-d", endpoints, *native_sources], build / "compile-scheduling.txt", args.process_timeout)
    # 官方签名JAR继续用于上面的47目标实物/普通JVM验证；只有这两个端点suite换成
    # class字节逐项相等的外置unsigned视图，避免真实原类与同包测试端点的signer冲突。
    scheduling_view, view_identity = create_scheduling_view(inputs, build)
    receipt["schedulingView"] = view_identity
    receipt["scope"]["minecraftSignatureDomain"] = "derived-unsigned-scheduling-only"
    save_receipt()
    native_classpath = [endpoints, *common, scheduling_view, inputs["paths"]["loader"], *inputs["libraries"]]
    validate_runtime_classpath(native_classpath, inputs, scheduling_view)
    native_cp = os.pathsep.join(map(str, native_classpath))
    execute([jdk_tool("java"), "-cp", native_cp,
         "com.amcl.compat.test.NativePacketSchedulingTest", inputs["paths"]["client"], scheduling_view], build / "native-scheduling-results.txt", args.process_timeout)
    execute([jdk_tool("java"), "-cp", native_cp,
         "com.amcl.compat.test.ActualHoldPacketTest", inputs["paths"]["create-old"],
         inputs["paths"]["create-new"], build / "transformed", inputs["paths"]["client"], scheduling_view], build / "actual-hold-results.txt", args.process_timeout)
    # runner 负控故意保留 non-daemon 线程；只有确认 marker 已出现并且自己启动的 JVM
    # 已在 deadline 后结束，才把“超时回收路径”记为已验证。不能把启动失败算作负控通过。
    timeout_log = build / "runner-negative-results.txt"
    timeout_command = [jdk_tool("java"), "-cp", os.pathsep.join(host), "com.amcl.compat.test.HangingRunnerControl"]
    try:
        run(timeout_command, timeout_log, timeout=5)
        raise RuntimeError("Runner negative control did not block")
    except subprocess.TimeoutExpired as expected_timeout:
        if ("worker-started non-daemon=true" not in timeout_log.read_text(encoding="utf-8")
            or getattr(expected_timeout, "terminated_returncode", None) is None
            or not getattr(expected_timeout, "own_tree_cleanup_confirmed", False)
            or not getattr(expected_timeout, "reader_stopped", False)):
            receipt["status"] = "failed-runner-timeout-proof"; save_receipt()
            raise RuntimeError("Runner timeout control did not prove own JVM was reclaimed")
        receipt["suites"].append({"command": list(map(str, timeout_command)), "expectedTimeout": True,
            "classpath": command_classpath(timeout_command, inputs, build),
            "ownPid": expected_timeout.terminated_pid, "terminatedExitCode": expected_timeout.terminated_returncode,
            "cleanupEvidence": expected_timeout.cleanup_evidence, "readerStopped": expected_timeout.reader_stopped,
            "log": str(timeout_log), "logSha256": hashlib.sha256(timeout_log.read_bytes()).hexdigest()})
    except BaseException as unexpected_timeout_control:
        receipt["status"] = "failed-runner-negative-control"
        receipt["runnerNegativeError"] = str(unexpected_timeout_control); save_receipt(); raise
    orphan_log = build / "runner-orphan-negative-results.txt"
    orphan_command = [jdk_tool("java"), "-cp", os.pathsep.join(host), "com.amcl.compat.test.OrphanRunnerControl"]
    try:
        run(orphan_command, orphan_log, timeout=10)
        receipt["status"] = "failed-orphan-control"; save_receipt()
        raise RuntimeError("Orphan runner control did not retain inherited stdout")
    except subprocess.TimeoutExpired as orphan_timeout:
        evidence = getattr(orphan_timeout, "cleanup_evidence", None) or {}
        children = evidence.get("observedChildren", [])
        transcript = orphan_log.read_text(encoding="utf-8")
        verified = ("[runner-orphan-control] root-exit pid=" in transcript
            and "[runner-orphan-control] child-started pid=" in transcript
            and getattr(orphan_timeout, "root_exit_before_cleanup", None) == 0
            and getattr(orphan_timeout, "own_tree_cleanup_confirmed", False)
            and getattr(orphan_timeout, "reader_stopped", False) and len(children) == 1)
        if os.name == "nt":
            verified = (verified and evidence.get("activeProcessesAfterCleanup") == 0
                        and bool(children) and children[0].get("processHandleSignaledAfterCleanup") is True)
        if not verified:
            receipt["status"] = "failed-orphan-cleanup-proof"; save_receipt()
            raise RuntimeError("Orphan control did not prove child job ownership, root early exit and bounded tree/reader cleanup")
        receipt["suites"].append({"command": list(map(str, orphan_command)), "expectedTimeout": True,
            "classpath": command_classpath(orphan_command, inputs, build),
            "ownPid": orphan_timeout.terminated_pid, "rootExitBeforeCleanup": 0,
            "terminatedExitCode": orphan_timeout.terminated_returncode, "cleanupEvidence": evidence, "readerStopped": True,
            "log": str(orphan_log), "logSha256": hashlib.sha256(orphan_log.read_bytes()).hexdigest()})
    except BaseException as orphan_error:
        receipt["status"] = "failed-orphan-control"; receipt["runnerOrphanError"] = str(orphan_error); save_receipt(); raise
    try:
        validate_identity_sections(receipt, capture_host_inputs(inputs))
        validate_scheduling_view(inputs, build, receipt.get("schedulingView"))
        if initial_artifact != hashlib.sha256(jar.read_bytes()).hexdigest():
            raise RuntimeError("Compatibility JAR changed during host validation")
    except RuntimeError:
        receipt["status"] = "failed-input-drift"; save_receipt()
        raise RuntimeError("Compatibility JAR, source or classpath changed during host validation")
    receipt["status"] = "passed-host-only"
    receipt["outputs"] = output_snapshot(build)
    save_receipt()
    (build / "validation-scope.json").write_text(json.dumps({"schema": 2,
        "artifactSha256": initial_artifact, "hostReceiptSha256": hashlib.sha256((build / "host-receipt.json").read_bytes()).hexdigest(),
        "legacyRuntime": legacy_runtime, "originalMojangPacketProcessor": True,
        "isolatedAbiEndpoints": True, "actualCreateMixinTargets": 47,
        "plainJvmDefinedResolvedTargets": 47, "classTweakerApplied": False,
        "minecraftSignatureDomain": "derived-unsigned-scheduling-only", "schedulingViewAllClassPayloadEqual": True,
        "originalBundleHandler": False, "bundleEndpoint": True, "syntheticCmeScenario": True,
        "actualFabricDiscovery": False, "actualKnot": False, "actualWorld": False}, indent=2) + "\n", encoding="utf-8")
    print("[game-compat-tests] PASS host layers; actual Knot/device validation remains separate; output=" + str(build))


if __name__ == "__main__":
    main()
