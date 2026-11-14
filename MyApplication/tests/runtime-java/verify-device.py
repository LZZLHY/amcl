"""验收一份实际设备Java夹具回收件；绑定HAP/JAR/完整ZIP、真实退出和CheckJNI。

该工具只授予所列夹具资格，不代表CLI、游戏、音频、性能或其他设备已通过。
旧日志缺失、JNI警告、超时、回调与Java收据不一致都拒绝；不修改原始材料。
"""
import argparse
import hashlib
import importlib.util
import json
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True


def digest(path):
    """流式核对完整归档，避免将大JDK包一次性载入内存。"""
    value = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def verify(directory, hap_sha, jar_sha):
    """expected SHA来自构建/部署收据；不从待验报告自己的成功字段推导预期身份。"""
    directory = Path(directory)
    read = lambda path: json.loads(path.read_text(encoding="utf-8-sig"))
    transfer = read(directory / "transfer.json")
    if transfer.get("profile") == "native-temp-vms":
        raise ValueError("native-temp-vms is a two-VM protocol; use tests/runtime-native-temp/verify-vm-pair.py")
    if transfer.get("profile") == "native-temp":
        raise ValueError("native-temp is native-only; use tests/runtime-native-temp/verify-device.py, not Java qualification")
    parent = read(directory / "parent-result.json")
    major = transfer["major"]
    run = directory / ("run-" + major)
    native = read(run / "result.json")
    problems = []
    shared_observation = None
    startup_observation = None
    channels_observation = None
    if native.get("profile") == "sound-capture-startup":
        # 一秒前缀是单独授权的固定Native观察；不能以基础Java返回0或旧音频profile代证。
        try:
            helper = Path(__file__).resolve().parents[1] / 'java-sound/verify-capture-startup.py'
            spec = importlib.util.spec_from_file_location('capture_startup_verify', helper)
            module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
            startup_observation = module.validate_run(run, native)
        except (ValueError, KeyError, OSError, TypeError) as error:
            problems.append("capture startup observation failed: " + str(error))
    if (transfer.get("profile") == "sound-capture-startup") != (native.get("profile") == "sound-capture-startup"):
        problems.append("capture startup requested profile does not match native receipt")
    if native.get("profile") == "sound-capture-channels":
        # 新双流各200ms对照必须走自己的严格报告门；不能借一秒或普通Java返回0代证。
        try:
            helper = Path(__file__).resolve().parents[1] / 'java-sound/verify-capture-channels.py'
            spec = importlib.util.spec_from_file_location('capture_channels_verify', helper)
            module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
            channels_observation = module.validate_run(run, native)
        except (ValueError, KeyError, OSError, TypeError) as error:
            problems.append("capture channels observation failed: " + str(error))
    if (transfer.get("profile") == "sound-capture-channels") != (native.get("profile") == "sound-capture-channels"):
        problems.append("capture channels requested profile does not match native receipt")
    if not transfer.get("parentReportReceived") or not parent.get("transportOk"):
        problems.append("parent transport incomplete")
    if transfer.get("hapSha256") != hap_sha or native.get("fixtureSha256") != jar_sha or digest(run / "qualification.jar") != jar_sha:
        problems.append("HAP or actual JAR identity mismatch")
    if native.get("archiveSha256") != transfer.get("archiveSha256") or digest(transfer["candidate"]) != transfer.get("archiveSha256"):
        problems.append("complete candidate archive identity mismatch")
    if native.get("major") != major or not native.get("passed") or not native.get("completionProof") or any(
            native.get(key) != 0 for key in ("initResult", "mainResult", "destroyResult")):
        problems.append("Java installation/VM lifecycle failed")
    stages = []
    for line in parent.get("text", "").splitlines():
        try:
            item = json.loads(line)
            if isinstance(item, dict): stages.append(item)
        except ValueError:
            pass
    started = [item for item in stages if item.get("stage") == "native-child-start"]
    ended = [item for item in stages if item.get("stage") == "native-child-exit"]
    # shared只走独立严格模式，不制造NCP退出事件来满足上面的旧子进程资格。
    shared = transfer.get("executionMode") == "shared-tool" or native.get("executionMode") == "shared-tool" or \
        str(transfer.get("profile", "")).startswith("shared-")
    if shared:
        helper = Path(__file__).with_name("shared_evidence.py")
        spec = importlib.util.spec_from_file_location("shared_evidence_verify", helper)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        shared_observation = module.verify_shared(directory, transfer, parent, native, problems)
    elif (len(started) != 1 or len(ended) != 1 or started[0].get("result") != 0 or
            started[0].get("pid") != native.get("pid") or not ended[0].get("observed") or
            ended[0].get("signal") != 0 or ended[0].get("timedOut") is not False):
        problems.append("actual child identity/exit/deadline mismatch")
    # callback=0只作为组合条件；worker/hook三个真实文件还必须具有同一major token。
    token = "AMCL-JAVA-QUALIFICATION:1:" + major + "\n"
    for name in ("fixture-pass.txt", "non-daemon.txt", "shutdown-hook.txt"):
        if not (run / name).is_file() or (run / name).read_text(encoding="utf-8") != token:
            problems.append("missing completion proof: " + name)
    log = (run / "stdout.log").read_text(encoding="utf-8", errors="strict")
    warnings = [line for line in log.splitlines() if "WARNING in native method" in line or
                "FATAL ERROR in native method" in line]
    if warnings: problems.append("CheckJNI diagnostics present")
    compiled = [line for line in log.splitlines() if re.search(r"\b4\s+RuntimeQualification::hotLoop", line)]
    if not compiled: problems.append("fixture hotLoop tier4 was not observed")
    results = {}
    if (run / "fixture-results.txt").exists():
        results = dict(line.split("=", 1) for line in (run / "fixture-results.txt").read_text(encoding="utf-8").splitlines())
    # 新夹具额外证明原main线程已经结束。旧绑定JAR保留原资格范围，不能追认此新增条件。
    join_required = results.get("mainThreadJoinRequired") == "true"
    join_path = run / "main-thread-ended.txt"
    main_join = join_required and join_path.is_file() and join_path.read_text(encoding="utf-8") == token
    if (join_required or shared) and not main_join:
        problems.append("original Java main join/isAlive completion proof missing")
    if (results.get("logicalFontFacesChecked") != "20" or results.get("fontFallbackMissingGlyphs") != "0" or
            int(results.get("fontFallbackGlyphComparisons", "0")) <= 0 or results.get("pngRoundtripPixels") != "17920"):
        problems.append("expanded font/ImageIO proof incomplete")
    result = {"fixtureQualified": not problems, "problems": problems, "major": major,
            "pid": native.get("pid"), "hapSha256": hap_sha, "jarSha256": jar_sha,
            "mainThreadJoinQualified": main_join,
            "archiveSha256": transfer.get("archiveSha256"), "checkJniDiagnostics": warnings,
            "tier4Evidence": compiled, "fontComparisons": results.get("fontFallbackGlyphComparisons"),
            "scope": "Java fixture only; permission/CF/CLI/game/performance/device matrix require separate evidence"}
    if shared_observation is not None:
        result["sharedObservation"] = shared_observation
    if startup_observation is not None:
        result["captureStartupObservation"] = startup_observation
    if channels_observation is not None:
        result["captureChannelsObservation"] = channels_observation
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--expected-hap-sha256", required=True)
    parser.add_argument("--expected-jar-sha256", required=True)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    result = verify(args.evidence, args.expected_hap_sha256, args.expected_jar_sha256)
    with args.report.open("x", encoding="utf-8") as output:
        json.dump(result, output, ensure_ascii=False, indent=2)
    print(json.dumps({"fixtureQualified": result["fixtureQualified"], "problems": result["problems"]}))
    raise SystemExit(0 if result["fixtureQualified"] else 1)
