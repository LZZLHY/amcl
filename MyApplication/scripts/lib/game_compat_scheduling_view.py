"""仅为宿主调度端点派生无签名 Minecraft 视图，保留全部原件 class 字节。

真实官方 client JAR 使用 Mojang 签名，不能和同包的 unsigned 测试端点放进同一
普通应用加载器；这里仅在独立宿主 suite 内建立共同 unsigned 测试域。原件只读，
真实 Mixin/JVM47、Knot、设备与生产制品继续使用原件，不关闭 JVM 的 signer 检查。
"""
from pathlib import Path
import hashlib
import json
import re
import zipfile
from lib.game_compat_inputs import ROOT
from lib.workspace_paths import external_output_path

DIRECTORY = "scheduling-minecraft"
VIEW = "minecraft-26.2-host-scheduling.jar"
RECEIPT = "view-receipt.json"
REMOVED = {"META-INF/MANIFEST.MF", "META-INF/MOJANGCS.SF", "META-INF/MOJANGCS.RSA"}


def _sha(data):
    """所有来源/索引/产物身份统一取实字节SHA256，不从名称推断签名状态。"""
    return hashlib.sha256(data).hexdigest()


def _view_path(output):
    """派生物固定在本轮外置输出内；任何逃逸链接都不能成为 classpath 来源。"""
    output = external_output_path(output)
    path = output / DIRECTORY / VIEW
    if output not in path.resolve().parents:
        raise RuntimeError("Scheduling view escaped host session")
    return path


def _endpoint_families():
    """枚举实际全部端点包族，不只记录最先触发Bundle异常的一个包。"""
    directory = ROOT / "prebuilt/runtime-compat/test-threading/endpoints"
    packages = {}
    for path in sorted(directory.rglob("*.java")):
        match = re.search(r"^package\s+([a-zA-Z0-9_.]+);", path.read_text(encoding="utf-8"), re.M)
        if not match:
            raise RuntimeError("Endpoint package declaration missing: " + str(path))
        package = match.group(1)
        packages.setdefault(package, []).append(path.relative_to(directory).with_suffix(".class").as_posix())
    return packages


def _source_entries(source):
    """原件必须恰有已核签名边界，且没有依赖manifest才解释正确的MR或密封主属性。"""
    entries = [item.filename for item in source.infolist() if not item.is_dir()]
    if len(entries) != len(set(entries)):
        raise RuntimeError("Duplicate entry in fixed Minecraft source")
    signatures = {name for name in entries if name.upper() == "META-INF/MANIFEST.MF"
        or (name.upper().startswith("META-INF/") and (name.upper().endswith((".SF", ".RSA", ".DSA", ".EC"))
                                                      or name.upper().split("/")[-1].startswith("SIG-")))}
    if signatures != REMOVED:
        raise RuntimeError("Unexpected Minecraft signature metadata inventory")
    manifest = source.read("META-INF/MANIFEST.MF").replace(b"\r\n", b"\n").lower()
    main = manifest.split(b"\n\n", 1)[0]
    if b"multi-release:" in main or re.search(rb"(?m)^sealed:", manifest) or any(name.startswith("META-INF/versions/") for name in entries):
        raise RuntimeError("Scheduling view recipe does not support MR/sealed client JAR")
    return entries


def _inspect(prepared, output):
    """重新从固定原件和当前view逐entry核对；汇总摘要证明全class而非抽检几个关键类。"""
    source_path = prepared["paths"]["client"]
    source_hash = _sha(source_path.read_bytes())
    expected_source = next(item for item in prepared["lock"]["files"] if item["id"] == "client")
    if source_hash != expected_source["sha256"]:
        raise RuntimeError("Minecraft source changed before scheduling view verification")
    view_path = _view_path(output)
    classes, retained = [], []
    families = _endpoint_families()
    family_classes = {name: [] for name in families}
    with zipfile.ZipFile(source_path) as source, zipfile.ZipFile(view_path) as view:
        original = _source_entries(source)
        expected = sorted(set(original) - REMOVED)
        actual = [item.filename for item in view.infolist() if not item.is_dir()]
        if len(actual) != len(set(actual)) or sorted(actual) != expected:
            raise RuntimeError("Scheduling view entry/signature inventory mismatch")
        for name in expected:
            data = source.read(name)
            if view.read(name) != data:
                raise RuntimeError("Scheduling view changed original entry bytes: " + name)
            identity = {"path": name, "size": len(data), "sha256": _sha(data)}
            retained.append(identity)
            if name.endswith(".class"):
                classes.append(identity)
                package = name.rsplit("/", 1)[0].replace("/", ".")
                if package in family_classes:
                    family_classes[package].append(name)
        removed = [{"path": name, "size": len(source.read(name)), "sha256": _sha(source.read(name))} for name in sorted(REMOVED)]
    if not classes:
        raise RuntimeError("Scheduling view has no original Minecraft classes")
    if _sha(source_path.read_bytes()) != source_hash:
        raise RuntimeError("Minecraft source changed while checking scheduling view")
    return {"schema": 1, "purpose": "host-scheduling-only-unsigned-domain", "sourceSha256": source_hash,
        "recipePath": "scripts/lib/game_compat_scheduling_view.py",
        "recipeSha256": _sha(Path(__file__).read_text(encoding="utf-8").encode("utf-8")),
        "viewPath": "test-output/" + DIRECTORY + "/" + VIEW, "viewSha256": _sha(view_path.read_bytes()),
        "viewSize": view_path.stat().st_size, "removedSignatureMetadata": removed,
        "retainedEntryCount": len(retained), "retainedEntryIndexSha256": _sha(json.dumps(retained, separators=(",", ":"), sort_keys=True).encode()),
        "originalClassCount": len(classes), "originalClassIndexSha256": _sha(json.dumps(classes, separators=(",", ":"), sort_keys=True).encode()),
        "allOriginalClassBytesEqual": True,
        "endpointPackageFamilies": [{"package": package, "unsignedEndpoints": families[package],
            "officialClassCount": len(family_classes[package]), "officialClassNames": family_classes[package]}
            for package in sorted(families)],
        "jvmSignerChecksDisabled": False, "actualKnot": False, "actualWorld": False}


def create_scheduling_view(prepared, output):
    """只写新会话派生目录；有现成文件就失败，避免把旧view当作当前配方产物。"""
    view_path = _view_path(output)
    view_path.parent.mkdir(parents=True, exist_ok=False)
    with zipfile.ZipFile(prepared["paths"]["client"]) as source:
        entries = _source_entries(source)
        with zipfile.ZipFile(view_path, "x") as view:
            for name in sorted(set(entries) - REMOVED):
                info = zipfile.ZipInfo(name, date_time=(2000, 1, 1, 0, 0, 0))
                info.create_system = 3; info.external_attr = 0o600 << 16
                # STORED避免压缩器版本差异；外置临时view不作为正式发布/游戏安装资产。
                view.writestr(info, source.read(name), compress_type=zipfile.ZIP_STORED)
    identity = _inspect(prepared, output)
    (view_path.parent / RECEIPT).write_text(json.dumps(identity, indent=2) + "\n", encoding="utf-8")
    return view_path, identity


def validate_scheduling_view(prepared, output, recorded):
    """最终门再次核原件、view及本地收据，不能只相信顶层记录的view SHA。"""
    current = _inspect(prepared, output)
    receipt_path = _view_path(output).parent / RECEIPT
    if Path(output).resolve() not in receipt_path.resolve().parents:
        raise RuntimeError("Scheduling view receipt escaped host session")
    if recorded != current or json.loads(receipt_path.read_text(encoding="utf-8")) != current:
        raise RuntimeError("Scheduling view source/recipe/bytes/receipt changed")
    return current


def validate_runtime_classpath(paths, prepared, view):
    """调度两suite的MC类只能来自unsigned view；禁止同时残留原件或另一个MC类容器。"""
    official = prepared["paths"]["client"].resolve()
    view = Path(view).resolve()
    normalized = [Path(path).resolve() for path in paths]
    if official in normalized or normalized.count(view) != 1:
        raise RuntimeError("Scheduling classpath must contain one derived view and no signed official client")
    for path in normalized:
        if path == view or path.is_dir():
            continue
        with zipfile.ZipFile(path) as jar:
            if any(name.startswith("net/minecraft/") and name.endswith(".class") for name in jar.namelist()):
                raise RuntimeError("Another Minecraft class container in scheduling classpath: " + str(path))
