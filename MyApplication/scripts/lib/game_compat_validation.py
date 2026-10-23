"""宿主运行器和最终交付门共享的权威输入/输出集合，拒绝旧收据缩减验证范围。"""
from pathlib import Path
import hashlib
import json
import os
import zipfile
from lib.game_compat_inputs import ROOT, LOCK, LWJGL_LOCK, VENDORED_LOCKS, classpath_receipt, lwjgl_inputs, vendored_classpath
from lib.game_compat_scheduling_view import DIRECTORY as VIEW_DIRECTORY, VIEW, validate_runtime_classpath


def sha(path):
    """收据绑定实取字节；不从收据给出的摘要推测当前源码。"""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def fixture_inputs():
    """核对当前固定裁剪夹具的完整class集合与原件摘要，返回JSON/JAR实际路径。"""
    directory = ROOT / "prebuilt/runtime-compat/test-fixtures"
    results = []
    for base in ("create-fly-staging", "create-fly-level"):
        manifest = directory / (base + ".json")
        values = json.loads(manifest.read_text(encoding="utf-8"))
        entries = {item["path"]: item["sha256"] for item in values.get("classes", [])}
        if "entry" in values:
            entries[values["entry"]] = values["entrySha256"]
        artifact = directory / (base + ".jar")
        with zipfile.ZipFile(artifact) as jar:
            classes = [name for name in jar.namelist() if name.endswith(".class")]
            if len(classes) != len(set(classes)) or set(classes) != entries.keys():
                raise RuntimeError("Unpinned test fixture classes: " + base)
            for name, expected in entries.items():
                if hashlib.sha256(jar.read(name)).hexdigest() != expected:
                    raise RuntimeError("Changed frozen test fixture class: " + name)
        results.extend((manifest, artifact))
    return results


def source_snapshot():
    """每次重新枚举当前生产/测试源码和整个fixture目录；新增/删除文件同样使旧收据失效。"""
    runtime = ROOT / "prebuilt/runtime-compat"
    files = [ROOT / relative for relative in (
        "scripts/test-game-compat.py", "scripts/test-game-compat-receipt.py", "scripts/lib/game_compat_inputs.py",
        "scripts/lib/build_dependencies.py",
        "scripts/lib/game_compat_validation.py", "scripts/lib/game_compat_scheduling_view.py", "scripts/lib/game_compat_sessions.py", "scripts/lib/owned_process.py", "scripts/build-game-compat.py",
        "scripts/build-create-thread-device-probe.py",
        "scripts/check-game-runtime-compat.py", "scripts/prepare-game-compat-inputs.py")]
    files.extend([LOCK, LWJGL_LOCK, *VENDORED_LOCKS, runtime / "artifact.json"])
    for directory, pattern in (("src", "*.java"), ("test", "*.java"), ("test-threading", "*.java"), ("resources", "*"), ("test-fixtures", "*")):
        files.extend(path for path in sorted((runtime / directory).rglob(pattern)) if path.is_file())
    if len(files) != len(set(files)):
        raise RuntimeError("Duplicate authoritative host source input")
    return [{"path": path.relative_to(ROOT).as_posix(), "sha256": sha(path)} for path in files]


def capture_host_inputs(prepared):
    """从当前来源锁构造完整有序集合；外置cache只记录相对身份，可换机器/目录复核。"""
    common = [ROOT / "entry/src/main/resources/rawfile/amcl-fabric-compat.jar", *vendored_classpath()]
    return {"sources": source_snapshot(),
        "classpath": classpath_receipt([*common, *prepared["classpath"]], prepared["directory"]),
        "extraInputs": classpath_receipt([*prepared["paths"].values(), *fixture_inputs(),
            *lwjgl_inputs(("lwjgl.jar", "lwjgl-opengl.jar", "lwjgl-tinyfd.jar"))], prepared["directory"])}


def validate_identity_sections(receipt, current):
    """精确比较权威当前集合、顺序和字节，不遍历收据声明的任意路径来反向猜范围。"""
    for name in ("sources", "classpath", "extraInputs"):
        actual = receipt.get(name)
        expected = current[name]
        if not isinstance(actual, list) or not actual or any(not isinstance(item, dict) for item in actual):
            raise RuntimeError("Missing host identity section: " + name)
        paths = [item.get("path") for item in actual]
        if any(not isinstance(path, str) for path in paths) or len(paths) != len(set(paths)) or actual != expected:
            raise RuntimeError("Host current input set/order/bytes changed: " + name)


def _directory_snapshot(path):
    """目录内符号链接不得把验证读取引到本轮输出树之外。"""
    root = path.resolve()
    results = []
    for item in sorted(path.rglob("*")):
        if not item.is_file():
            continue
        resolved = item.resolve()
        if root not in resolved.parents:
            raise RuntimeError("Host output directory contains escaping link")
        results.append({"path": item.relative_to(path).as_posix(), "sha256": sha(item)})
    return results


def command_classpath(command, prepared, output):
    """suite命令内的实际classpath归一成仓库/cache/本轮输出身份，避免固化机器绝对路径。"""
    strings = list(map(str, command))
    if "-cp" not in strings:
        return []
    result = []
    cache, output = prepared["directory"].resolve(), output.resolve()
    for position, value in enumerate(strings[strings.index("-cp") + 1].split(os.pathsep)):
        path = Path(value).resolve()
        if output in path.parents:
            identity = "test-output/" + path.relative_to(output).as_posix()
        elif ROOT in path.parents:
            identity = path.relative_to(ROOT).as_posix()
        elif cache in path.parents:
            identity = "compile-only/" + path.relative_to(cache).as_posix()
        else:
            raise RuntimeError("Suite classpath escapes declared input roots")
        entry = {"position": position, "path": identity}
        if path.is_dir():
            entry["directory"] = _directory_snapshot(path)
        else:
            entry.update(size=path.stat().st_size, sha256=sha(path))
        result.append(entry)
    return result


def validate_suite_classpath(records, prepared, output):
    """只把已审核来源集合里的身份映射到当前文件，不打开收据任意路径。"""
    allowed = [ROOT / "entry/src/main/resources/rawfile/amcl-fabric-compat.jar", *vendored_classpath(),
        *prepared["classpath"], prepared["paths"]["create-old"], prepared["paths"]["create-new"],
        *[path for path in fixture_inputs() if path.suffix == ".jar"],
        *lwjgl_inputs(("lwjgl.jar", "lwjgl-opengl.jar", "lwjgl-tinyfd.jar"))]
    identities = {}
    for path in allowed:
        resolved = path.resolve()
        name = resolved.relative_to(ROOT).as_posix() if ROOT in resolved.parents else "compile-only/" + resolved.relative_to(prepared["directory"].resolve()).as_posix()
        identities[name] = resolved
    identities.update({"test-output/tests": output.resolve() / "tests", "test-output/scheduling": output.resolve() / "scheduling"})
    view_path = output.resolve() / VIEW_DIRECTORY / VIEW
    identities["test-output/" + VIEW_DIRECTORY + "/" + VIEW] = view_path
    if not isinstance(records, list) or not records:
        raise RuntimeError("Missing consumed suite classpath")
    paths = []
    for position, record in enumerate(records):
        if record.get("position") != position or record.get("path") not in identities:
            raise RuntimeError("Suite receipt has unknown/reordered classpath identity")
        paths.append(identities[record["path"]])
    expected = command_classpath(["test", "-cp", os.pathsep.join(map(str, paths))], prepared, output)
    if expected != records:
        raise RuntimeError("Consumed suite classpath bytes changed")
    if any(record["path"] == "test-output/scheduling" for record in records):
        validate_runtime_classpath(paths, prepared, view_path)


def output_snapshot(output):
    """最终变换证据按当前全集枚举；新增/缺失输出不能被收据少列条目绕开。"""
    results = []
    for directory in ("transformed", VIEW_DIRECTORY, "session-controls"):
        results.extend({"path": directory + "/" + item["path"], "sha256": item["sha256"]}
                       for item in _directory_snapshot(output / directory))
    return results


def validate_output_inventory(recorded, current):
    """输出集合与顺序必须严格一致，不能只验证收据仍保留的几个文件。"""
    if not isinstance(recorded, list) or not recorded or recorded != current:
        raise RuntimeError("Host transformed output inventory changed")


def required_suite_logs():
    """当前完整宿主门的固定suite台账；不能通过删除日志与收据条目一起缩减验收。"""
    return {"receipt-contract-results.txt", "compile-tests.txt", "resize-results.txt", "flywheel-results.txt",
        "tinyfd-results.txt", "level-uniform-results.txt", "legacy-isolation-results.txt", "threading-mixin-results.txt",
        "compile-scheduling.txt", "native-scheduling-results.txt", "actual-hold-results.txt",
        "runner-negative-results.txt", "runner-orphan-negative-results.txt",
        *["amcl-" + name + ".mixins.json.results.txt" for name in
          ("ForeignHighMixin", "ForeignLowMixin", "ForeignCancelMixin", "ForeignOverwriteMixin", "ForeignUnmatchedMixin")]}
