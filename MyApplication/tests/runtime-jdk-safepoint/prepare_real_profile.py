#!/usr/bin/env python3
"""真实26.2主JAR与独立本地夹具library的QA版本暂存器，不部署、不改产品。

保留已核QA清单的Mojang downloads/clientVersion/javaVersion/依赖事实，主JAR逐
字节使用真正client-26.2.jar。只改变新版本ID、明确入口和程序参数，并追加正常
本地library与诊断JVM参数；不填充小JAR，不写假的Mojang下载身份或安装marker。
"""
from __future__ import annotations
import argparse
import copy
import hashlib
import json
import pathlib
import shutil
import sys

# 保持仓库只含配方源码，Python导入缓存与测试输出不落回项目。
sys.dont_write_bytecode = True
from run_host import MAIN, sha, external_output_path


def main() -> int:
    """所有输出写入全新目录；原QA JSON、主JAR和fixture JAR均只读。"""
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-profile", required=True, type=pathlib.Path)
    parser.add_argument("--client-jar", required=True, type=pathlib.Path)
    parser.add_argument("--fixture-jar", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--id", required=True)
    parser.add_argument("--game-dir", required=True,
                        help="已核实的设备绝对gameDir；JVM模板不支持${game_directory}")
    args = parser.parse_args()
    if not args.id.startswith("26.2-amcl-safepoint-qa-") or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789.-" for c in args.id):
        raise SystemExit("unsafe_version_id")
    # JVM参数模板没有game_directory分支；绝不能让LogFile被未解析变量过滤器丢掉。
    # 明确限定到本轮独立版本目录，拒绝相对路径、模板或命令分隔字符。
    expected_suffix = "/.minecraft/versions/" + args.id
    if (not args.game_dir.startswith("/data/storage/") or not args.game_dir.endswith(expected_suffix)
            or any(ch in args.game_dir for ch in ["$", "{", "}", "\n", "\r", "\t", " ", "..", ";"])):
        raise SystemExit("game_dir_must_be_verified_absolute_isolated_version_path")
    original = json.loads(args.base_profile.read_text(encoding="utf-8"))
    client = args.client_jar.read_bytes()
    fixture = args.fixture_jar.read_bytes()
    expected = original["downloads"]["client"]
    if original.get("clientVersion") != "26.2" or original.get("inheritsFrom") or original.get("jar"):
        raise SystemExit("base_profile_not_the_expected_complete_26.2_profile")
    if expected["size"] != len(client) or expected["sha1"] != hashlib.sha1(client).hexdigest():
        raise SystemExit("real_mojang_client_identity_mismatch")
    fixture_sha = hashlib.sha256(fixture).hexdigest()
    version = "1.0.0-" + fixture_sha[:12]
    coordinate = "com.amcl.qa:safepoint-regression:" + version
    relative = "com/amcl/qa/safepoint-regression/" + version + "/safepoint-regression-" + version + ".jar"
    profile = copy.deepcopy(original)
    profile["id"] = args.id
    profile["mainClass"] = MAIN
    profile["arguments"]["game"] = ["4", "2000", "750"]
    profile["arguments"]["jvm"].extend([
        "-Xms32m", "-Xbatch", "-XX:-TieredCompilation", "-XX:CompileThreshold=100",
        "-XX:+UnlockDiagnosticVMOptions", "-XX:+LogCompilation",
        "-XX:LogFile=" + args.game_dir + "/compilation.xml",
        "-XX:CompileCommand=dontinline," + MAIN.replace(".", "/") + ".hotLoop",
        "-XX:+SafepointTimeout", "-XX:SafepointTimeoutDelay=500",
        "-Xlog:safepoint=debug,vmthread=debug"])
    # 本地library按真实artifact.path/sha1/size索引，不伪造任何远端URL。
    profile["libraries"].append({"name": coordinate, "downloads": {"artifact": {
        "path": relative, "sha1": hashlib.sha1(fixture).hexdigest(), "size": len(fixture)}}})
    output = external_output_path(args.output)
    output.mkdir(parents=True, exist_ok=False)
    version_dir = output / "versions" / args.id
    version_dir.mkdir(parents=True)
    main_target = version_dir / (args.id + ".jar")
    json_target = version_dir / (args.id + ".json")
    library_target = output / "libraries" / relative
    library_target.parent.mkdir(parents=True)
    shutil.copyfile(args.client_jar, main_target)
    shutil.copyfile(args.fixture_jar, library_target)
    json_target.write_text(json.dumps(profile, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    assert profile["downloads"] == original["downloads"]
    assert profile["libraries"][:-1] == original["libraries"]
    receipt = {"schema": 1, "scope": "local-real-client-staging-device-unverified",
               "producer": "prepare_real_profile.py", "versionId": args.id,
               "expectedDeviceGameDir": args.game_dir,
               "expectedDeviceCompilerLog": args.game_dir + "/compilation.xml",
               "baseProfile": str(args.base_profile.resolve()), "baseProfileSha256": sha(args.base_profile),
               "clientJar": str(main_target), "clientJarBytes": len(client), "clientJarSha256": sha(main_target),
               "fixtureLibrary": str(library_target), "fixtureLibrarySha256": sha(library_target),
               "libraryCoordinate": coordinate, "profile": str(json_target), "profileSha256": sha(json_target),
               "staticInstalledSizeCheck": main_target.stat().st_size > 1024 * 1024,
               "mojangDownloadsUnchanged": True, "originalLibrariesPreserved": True,
               "installCommitMarkerCreated": False,
               "scopeLimit": "源码判据静态通过；不代替实际设备重新扫描/预检/C2运行证据"}
    (output / "staging-receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(receipt, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
