"""Check compatibility source wiring, frozen consumer API, and optional final HAP bytes."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import subprocess
import zipfile
import io
from classfile_api import jar_api, parse_class, resolve_member

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


def check(hap=None):
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
    artifact = json.loads((ROOT / "prebuilt/runtime-compat/artifact.json").read_text())
    for entry in artifact["sources"]:
        require(sha((ROOT / entry["path"]).read_text(encoding='utf-8').encode('utf-8')) == entry["sha256"], "Stale Fabric compatibility artifact: " + entry["path"])
    raw = ROOT / "entry/src/main/resources/rawfile"
    require(sha((raw / "amcl-fabric-compat.jar").read_bytes()) == artifact["sha256"], "Fabric compatibility JAR hash mismatch")
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
    args = parser.parse_args()
    if args.collect_client: collect(args.collect_client)
    check(args.hap)
