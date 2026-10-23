"""检查兼容层来源、冻结消费 API、生产包边界与可选最终 HAP 实际字节。"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import subprocess
import zipfile
import io
import sys
from classfile_api import jar_api, parse_class, resolve_member
from lib.game_compat_inputs import LWJGL_LOCK, VENDORED_LOCKS, classpath_receipt, lwjgl_inputs, prepare, vendored_classpath
from lib.game_compat_validation import capture_host_inputs, output_snapshot, required_suite_logs, validate_identity_sections, validate_output_inventory, validate_suite_classpath
from lib.game_compat_scheduling_view import validate_scheduling_view

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / "prebuilt/runtime-compat/mc-1.21.11-lwjgl-api.json"
FROZEN_API_SHA256 = "53cfc72e9ec943d6d8d349ea4e16dc08ae1ede53920305e064eb46f6302c0cfe"


def sha(data, algo="sha256"): return hashlib.new(algo, data).hexdigest()
def require(condition, text):
    if not condition: raise RuntimeError(text)


def validate_fixture(fixture):
    require(fixture.get('schema') == 1 and fixture.get('minecraft') == '1.21.11'
            and fixture.get('clientSha1') == 'ba2df812c2d12e0219c489c4cd9a5e1f0760f5bd', 'Wrong frozen client identity')
    require(sha(json.dumps(fixture['references'], sort_keys=True, separators=(',', ':')).encode()) == FROZEN_API_SHA256,
            'Frozen consumer references changed; recollect and review against the verified official client')


def collect(client):
    data = Path(client).read_bytes()
    require(sha(data, "sha1") == "ba2df812c2d12e0219c489c4cd9a5e1f0760f5bd", "Unverified Minecraft client")
    refs = {}
    with zipfile.ZipFile(io.BytesIO(data)) as jar:
        for name in jar.namelist():
            if name.endswith(".class"):
                caller = parse_class(jar.read(name))
                for ref in caller["references"]:
                    if ref["owner"].startswith("org/lwjgl/"):
                        if ref['name'] == '<init>' and caller['parent'] == ref['owner']:
                            ref['subclassConstructor'] = True
                        key = tuple(ref.values()); refs[key] = ref
    FIXTURE.write_text(json.dumps({"schema": 1, "minecraft": "1.21.11", "clientSha1": sha(data, "sha1"),
        "references": sorted(refs.values(), key=lambda r: tuple(r.values()))}, indent=2) + "\n", encoding="utf-8")


def check_compat_artifact():
    """逐项绑定源码、配方、固定输入与真正 JAR；compile-only 类型和测试类不得混入。

    该门不下载游戏，也不因本机恰好有缓存就绕过来源。需要真实运行的 Mixin/队列验证
    留给 test-game-compat，产物门只证明交付字节及旧游戏通用类的静态链接边界。
    """
    directory = ROOT / "prebuilt/runtime-compat"
    artifact = json.loads((directory / "artifact.json").read_text(encoding="utf-8"))
    require(artifact.get("schema") == 2 and artifact.get("javaOutputRelease") == 21,
            "Compatibility artifact lacks reviewed compile-only/output contract")
    lock = directory / "threading-inputs.json"
    require(artifact.get("compileOnlyLockSha256") == sha(lock.read_text(encoding="utf-8").encode("utf-8")), "Compatibility compile-only lock mismatch")
    # 与生成器保持完整源码集合；核对解析器自身，不能把本机私有路径写入公开身份。
    source_paths = [ROOT / "scripts/build-game-compat.py", ROOT / "scripts/lib/game_compat_inputs.py", ROOT / "scripts/lib/game_compat_sessions.py",
                    ROOT / "scripts/lib/build_dependencies.py", lock,
                    LWJGL_LOCK, *VENDORED_LOCKS, *sorted((directory / "src").rglob("*.java")),
                    *[path for path in sorted((directory / "resources").rglob("*")) if path.is_file()]]
    expected = {path.relative_to(ROOT).as_posix() for path in source_paths}
    recorded = [item["path"] for item in artifact["sources"]]
    require(len(recorded) == len(set(recorded)) and set(recorded) == expected,
            "Compatibility recipe omitted/duplicated current source inputs")
    for entry in artifact["sources"]:
        require(sha((ROOT / entry["path"]).read_text(encoding="utf-8").encode("utf-8")) == entry["sha256"],
                "Stale Fabric compatibility artifact: " + entry["path"])
    actual_prefix = classpath_receipt([*vendored_classpath(), *lwjgl_inputs()])
    recorded_classpath = artifact.get("compileClasspath", [])
    require(len(recorded_classpath) > len(actual_prefix)
            and recorded_classpath[:len(actual_prefix)] == actual_prefix,
            "Compatibility compile/test dependency bytes or order changed")
    require([entry.get("position") for entry in recorded_classpath] == list(range(len(recorded_classpath)))
            and len({entry["path"] for entry in recorded_classpath}) == len(recorded_classpath),
            "Compatibility classpath receipt missing, duplicated or unordered")
    data = (ROOT / "entry/src/main/resources/rawfile/amcl-fabric-compat.jar").read_bytes()
    require(len(data) == artifact["size"] and sha(data) == artifact["sha256"], "Fabric compatibility JAR identity mismatch")
    constants = (ROOT / "launch/src/main/ets/GameCompatibilityArtifact.ets").read_text(encoding="utf-8")
    require(f"GAME_COMPAT_SIZE = {len(data)};" in constants
            and f"GAME_COMPAT_SHA256 = '{artifact['sha256']}';" in constants
            and f"amcl-fabric-compat-{artifact['sha256']}.jar" in constants, "Compatibility ETS contract differs from artifact")
    with zipfile.ZipFile(io.BytesIO(data)) as jar:
        names = jar.namelist()
        require(len(names) == len(set(names)), "Duplicate compatibility JAR entry")
        resources = {path.relative_to(directory / "resources").as_posix(): path.read_text(encoding="utf-8").encode("utf-8")
                     for path in (directory / "resources").rglob("*") if path.is_file()}
        for name, resource in resources.items():
            require(name in names and jar.read(name) == resource, "Compatibility resource drift: " + name)
        actual_resources = {name for name in names if not name.endswith(".class")}
        require(actual_resources == set(resources), "Unexpected compile-only/source file in production compatibility JAR")
        for name in names:
            if not name.endswith(".class"):
                continue
            require(name.startswith("com/amcl/compat/") and "/test/" not in name,
                    "Compile-only or test class redistributed: " + name)
            parsed = parse_class(jar.read(name))
            require(parsed["major"] == 65, "Compatibility output is not Java21: " + name)
            require(parsed["name"] + ".class" == name, "Compatibility class entry/name mismatch: " + name)
            if name in ("com/amcl/compat/CompatMixinPlugin.class", "com/amcl/compat/CreateFlyThreadingProfile.class"):
                require(not any(ref["owner"].startswith("net/minecraft/")
                                or ref["owner"] == "com/amcl/compat/CreateFlyPacketThreading26"
                                for ref in parsed["references"]), "Common compatibility path links 26.2-only types: " + name)
        for source in (directory / "src").rglob("*.java"):
            name = source.relative_to(directory / "src").with_suffix(".class").as_posix()
            require(name in names, "Compiled compatibility class missing: " + name)
    return artifact


def check_host_receipt(path, artifact, inputs=None):
    """把已完成宿主收据关联到当前 JAR/HAP；不把宿主层扩大成 Knot/世界结果。"""
    path = Path(path).resolve()
    receipt = json.loads(path.read_text(encoding="utf-8"))
    require(receipt.get("schema") == 2 and receipt.get("status") == "passed-host-only",
            "Host validation is incomplete or failed")
    require(receipt.get("artifactSha256") == artifact["sha256"], "Host validation tested another compatibility JAR")
    prepared = prepare(inputs, include_create=True)
    validate_identity_sections(receipt, capture_host_inputs(prepared))
    validate_scheduling_view(prepared, path.parent, receipt.get("schedulingView"))
    require(receipt.get("suites") and receipt.get("outputs"), "Host validation lacks suite/output evidence")
    seen_logs = []
    for suite in receipt["suites"]:
        require(suite.get("exitCode") == 0 or (suite.get("expectedTimeout") is True and suite.get("terminatedExitCode") is not None),
                "Host suite lacks a successful or deliberate-timeout result")
        log = Path(suite["log"]).resolve()
        require(log.parent == path.parent, "Host log is outside this receipt session")
        seen_logs.append(log.name)
        require(sha(log.read_bytes()) == suite["logSha256"], "Host suite log changed: " + str(log))
        if suite.get("classpath"):
            validate_suite_classpath(suite["classpath"], prepared, path.parent)
        else:
            require(log.name == "receipt-contract-results.txt" and "-cp" not in suite.get("command", []),
                    "Java suite lacks consumed classpath proof")
    require(len(seen_logs) == len(set(seen_logs)) and set(seen_logs) == required_suite_logs()
            and {item.name for item in path.parent.glob("*.txt")} == required_suite_logs(),
            "Host suite/log inventory was omitted, duplicated or changed")
    validate_output_inventory(receipt["outputs"], output_snapshot(path.parent))
    print("[runtime-compat] host receipt bound to final artifact=" + artifact["sha256"] + "; actual Knot/world remain separate")


def check(hap=None, host_receipt=None, inputs=None):
    # 所有产品的正常 HAP 交付审核同时检查派生配方、ETS 常量与包内实际资产；
    # 不能只通过完整源槽的摘要就宣称旧加载器实际消费了安全视图。
    view_command = [sys.executable, str(ROOT / 'scripts/build-lwjgl-jdk-views.py')]
    if hap:
        view_command += ['--hap', str(hap)]
    subprocess.run(view_command, check=True)
    jars = ROOT / "prebuilt/lwjgl3/jars"
    api = jar_api(sorted(jars.glob("*.jar")))
    fixture = json.loads(FIXTURE.read_text())
    validate_fixture(fixture)
    missing = [r for r in fixture["references"] if not resolve_member(api, r)]
    require(not missing, "Minecraft LWJGL consumer API missing: " + json.dumps(missing))
    legacy = jar_api([ROOT / "prebuilt/lwjgl3/compat/stb-v1/lwjgl-stb-3.3.3.jar"])["org/lwjgl/stb/STBImageResize"]
    for method in legacy["methods"]:
        if method["access"] & 9 == 9:
            require(resolve_member(api, {"kind": "method", "owner": legacy["name"], "name": method["name"], "descriptor": method["descriptor"]}), "Legacy STB API missing")
    cpp = (ROOT / "entry/src/main/cpp/glfw/glfw_compat.cpp").read_text(encoding="utf-8")
    require(not re.search(r"(?:window|win)->(?:framebufferSizeCb|windowSizeCb)\s*\(", cpp), "Inline GLFW size callback reintroduced")
    require('DispatchSizeNotifications(dispatchWindow' in cpp, "Pending GLFW size delivery not wired")
    callbacks = (ROOT / "entry/src/main/cpp/glfw/glfw_callbacks.cpp").read_text(encoding="utf-8")
    for name in ["glfwSetFramebufferSizeCallback", "glfwSetWindowSizeCallback"]:
        body = callbacks[callbacks.index(name):].split('\n}', 1)[0]
        require(not re.search(r"\bcallback\s*\(", body), "Callback invoked during registration")
    require("GLFW_PLATFORM_LINUX" not in callbacks and "return GLFW_PLATFORM_NULL;" in callbacks, "Incorrect GLFW native platform enum")
    source = (ROOT / "JavaApp/src/com/amcl/launcher/AmclLauncher.java").read_text(encoding="utf-8")
    body = source[source.index('private static PreparedLaunch prepareLaunch'):]
    require(0 <= body.index('AwtRuntime.initialize()') < body.index('ClassLoader.getSystemClassLoader()'), "AWT capability initialized too late")
    artifact = check_compat_artifact()
    if host_receipt:
        check_host_receipt(host_receipt, artifact, inputs)
    raw = ROOT / "entry/src/main/resources/rawfile"
    manifest = json.loads((ROOT / "prebuilt/lwjgl3/modern-slot.manifest.json").read_text())
    require(manifest.get("stbCompatibilitySourceSha256") == sha((ROOT / "prebuilt/lwjgl3/compat/stb-v1/sources.json").read_bytes()), "STB source identity mismatch")
    for item in manifest["natives"]:
        module = item["name"].removeprefix("lib").removesuffix(".so").replace('_', '-')
        native = (ROOT / "entry/libs/arm64-v8a" / item["name"]).read_bytes()
        with zipfile.ZipFile(raw / "lwjgl" / (module + ".jar")) as jar:
            keys = [n for n in jar.namelist() if n.startswith("META-INF/linux/arm64/") and n.endswith('/' + item["name"] + '.sha1')]
            require(len(keys) == 1 and jar.read(keys[0]).decode().strip() == sha(native, 'sha1'), "Wrong OHOS native fingerprint: " + module)
    if hap:
        with zipfile.ZipFile(hap) as package:
            require(sha(package.read('resources/rawfile/amcl-fabric-compat.jar')) == artifact["sha256"], "HAP compatibility JAR differs")
            for item in manifest["jars"]:
                require(sha(package.read('resources/rawfile/lwjgl/' + item['name'])) == item['sha256'], "HAP JAR mismatch: " + item['name'])
            for item in manifest["natives"]:
                require(sha(package.read('libs/arm64-v8a/' + item['name'])) == item['sha256'], "HAP changed final native bytes: " + item['name'])
            with zipfile.ZipFile(io.BytesIO(package.read('resources/rawfile/amcl-launcher.jar'))) as launcher:
                require('com/amcl/launcher/AwtRuntime.class' in launcher.namelist(), "HAP lacks AWT startup capability")
    print(f"[runtime-compat] PASS Minecraft consumer references={len(fixture['references'])}; AWT/GLFW/STB/Fabric/fingerprints" + ("; final HAP" if hap else ""))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--collect-client'); parser.add_argument('--hap')
    parser.add_argument('--host-receipt', help='Completed host-receipt.json to bind to current JAR and optional HAP')
    parser.add_argument('--inputs', help='Verified compile-only cache for host-receipt revalidation; identity is cache-relative')
    args = parser.parse_args()
    if args.collect_client: collect(args.collect_client)
    check(args.hap, args.host_receipt, args.inputs)
