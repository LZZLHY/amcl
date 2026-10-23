"""准备、验证兼容层的编译期输入；游戏和模组只保存在仓外，不进入正式 JAR。

固定 metadata 的 SHA256 同时锁住其 library URL、长度和 SHA1。独立克隆可先显式
执行 prepare-game-compat-inputs.py --download；构建和门禁不隐式下载或信任本机路径。
"""
from pathlib import Path
import hashlib
import json
import os
import re
import shutil
import subprocess
import urllib.request
import zipfile
from lib.workspace_paths import external_output_path, workspace_path
from lib.build_dependencies import dependency_path

ROOT = Path(__file__).resolve().parents[2]
LOCK = ROOT / "prebuilt/runtime-compat/threading-inputs.json"
VENDORED_LOCKS = (ROOT / "scripts/lwjgl-stack-backfill/lib/sources.json",
                  ROOT / "prebuilt/runtime-compat/lib/sources.json")
LWJGL_LOCK = ROOT / "prebuilt/lwjgl3/modern-slot.manifest.json"


def digest(data, algorithm="sha256"):
    """对实际字节计算摘要；元数据 SHA1 只用于核实 Mojang 固定依赖记录。"""
    return hashlib.new(algorithm, data).hexdigest()


def input_directory(value=None):
    """显参、专用环境、本机共用配置依次选择；均须仓外，无配置才沿用原默认。"""
    supplied = value or os.environ.get("AMCL_GAME_COMPAT_INPUTS") or dependency_path("gameCompatInputs")
    return external_output_path(supplied) if supplied else workspace_path("build", "game-compat-inputs")


def verified_file(directory, entry, download=False, algorithm="sha256"):
    """先验已有文件再使用；有坏缓存时失败关闭，不自动覆盖可能的调查证据。"""
    relative = Path(entry["file"])
    if relative.is_absolute() or ".." in relative.parts:
        raise RuntimeError("Invalid compile-only input path")
    target = directory / relative
    if not target.is_file():
        if not download:
            raise RuntimeError("Missing compile-only input: " + str(target)
                               + "; run prepare-game-compat-inputs.py --download --output <external-directory>")
        target.parent.mkdir(parents=True, exist_ok=True)
        # 下载中间文件同样外置；先核实后原子改名，避免中断留下可误读的半包。
        temporary = target.with_name(target.name + ".download-" + str(os.getpid()))
        try:
            with urllib.request.urlopen(entry["url"], timeout=90) as source, temporary.open("xb") as output:
                shutil.copyfileobj(source, output)
            data = temporary.read_bytes()
            if len(data) != entry["size"] or digest(data, algorithm) != entry[algorithm]:
                raise RuntimeError("Downloaded input identity mismatch: " + entry["file"])
            temporary.replace(target)
        finally:
            if temporary.exists():
                temporary.unlink()
    data = target.read_bytes()
    if len(data) != entry["size"] or digest(data, algorithm) != entry[algorithm]:
        raise RuntimeError("Unverified compile-only input: " + str(target))
    return target


def prepare(directory=None, download=False, include_create=False):
    """返回经过摘要核实的编译 classpath 和可选测试模组；不写工程原始文件。"""
    directory = input_directory(directory)
    lock = json.loads(LOCK.read_text(encoding="utf-8"))
    if lock.get("schema") != 1 or lock.get("minecraft") != "26.2":
        raise RuntimeError("Unsupported game compatibility input schema")
    required = {"metadata", "client", "loader"}
    if include_create:
        required.update(("create-old", "create-new"))
    paths = {entry["id"]: verified_file(directory, entry, download)
             for entry in lock["files"] if entry["id"] in required}
    if paths.keys() != required:
        raise RuntimeError("Incomplete compile-only lock")
    metadata = json.loads(paths["metadata"].read_text(encoding="utf-8"))
    if metadata["id"] != "26.2" or metadata["javaVersion"]["majorVersion"] != 25:
        raise RuntimeError("Wrong pinned Minecraft metadata")
    libraries = []
    # native classifier 与 macOS-only ObjC 桥不参与 Java ABI；其余固定普通 JAR 提供
    # javac 和真实 PacketProcessor 的传递类型。这里不依据本机 Minecraft 安装猜路径。
    for library in metadata["libraries"]:
        coordinate = library["name"].split(":")
        if len(coordinate) != 3 or coordinate[:2] == ["ca.weblite", "java-objc-bridge"]:
            continue
        artifact = library.get("downloads", {}).get("artifact")
        if not artifact:
            continue
        entry = dict(artifact, file="libraries/" + artifact["path"])
        libraries.append(verified_file(directory, entry, download, "sha1"))
    return {"directory": directory, "paths": paths, "libraries": libraries,
            "classpath": [paths["client"], paths["loader"], *libraries], "lock": lock}


def vendored_classpath():
    """按两份来源清单的声明顺序核实 ASM/Mixin，拒绝额外、缺失或被替换的 JAR。

    目录 glob 仅用于核对是否混入未锁文件，绝不用于构造 classpath。core/tree 在前，
    随后的 Mixin/util/analysis/commons 保持清单顺序，避免宿主目录枚举改变消费实现。
    """
    result = []
    for lock in VENDORED_LOCKS:
        values = json.loads(lock.read_text(encoding="utf-8"))
        names = [item["file"] for item in values["files"]]
        if len(names) != len(set(names)) or any(Path(name).name != name or not name.endswith(".jar") for name in names):
            raise RuntimeError("Invalid vendored compatibility source manifest: " + str(lock))
        if set(names) != {path.name for path in lock.parent.glob("*.jar")}:
            raise RuntimeError("Unpinned or missing JAR in compatibility input directory: " + str(lock.parent))
        result.extend(verified_file(lock.parent, item) for item in values["files"])
    return result


def lwjgl_inputs(names=("lwjgl.jar", "lwjgl-opengl.jar")):
    """按既有正式 modern slot 清单核实明确列出的编译/测试输入，不新增另一份 LWJGL 锁。"""
    manifest = json.loads(LWJGL_LOCK.read_text(encoding="utf-8"))
    entries = {item["name"]: item for item in manifest["jars"]}
    if len(entries) != len(manifest["jars"]):
        raise RuntimeError("Duplicate LWJGL manifest JAR")
    return [verified_file(ROOT / "prebuilt/lwjgl3/jars", dict(entries[name], file=name)) for name in names]


def classpath_receipt(paths, external_root=None):
    """绑定实际顺序、大小和 SHA256，并拒绝被其他 JAR 同名遮蔽的 ASM 类。

    外置输入用 compile-only 相对身份记账，不把本轮 E 盘机器路径固化进可复现制品。
    正式源槽使用仓库相对路径，便于最终制品门再次核实自带编译依赖。
    """
    records, asm_owners = [], {}
    external_root = Path(external_root).resolve() if external_root else None
    for position, candidate in enumerate(paths):
        path = Path(candidate).resolve()
        try:
            identity = path.relative_to(ROOT).as_posix()
        except ValueError:
            if external_root is None or (path != external_root and external_root not in path.parents):
                raise RuntimeError("Classpath input outside declared source/cache: " + str(path))
            identity = "compile-only/" + path.relative_to(external_root).as_posix()
        data = path.read_bytes()
        records.append({"position": position, "path": identity, "size": len(data), "sha256": digest(data)})
        if path.suffix.lower() != ".jar":
            continue
        with zipfile.ZipFile(path) as jar:
            for name in jar.namelist():
                if name.startswith("org/objectweb/asm/") and name.endswith(".class"):
                    if name in asm_owners:
                        raise RuntimeError("Shadowed ASM class on compile/test classpath: " + name
                                           + " in " + asm_owners[name] + " and " + identity)
                    asm_owners[name] = identity
    return records


def jdk_tool(name, minimum=25):
    """优先兼容层专用环境/本机JDK，再回退通用JAVA_HOME/PATH；仍实测编译器版本。

    本机 compatJavaHome 只供兼容层读取 class69，不改 SDK/IDE 的 Java 运行环境。
    因此通用 JAVA_HOME=21 不应覆盖本机明确配置的兼容层 JDK25。
    """
    suffix = ".exe" if os.name == "nt" else ""
    home = os.environ.get("AMCL_COMPAT_JAVA_HOME") or dependency_path("compatJavaHome") or os.environ.get("JAVA_HOME")
    tool = str(Path(home) / "bin" / (name + suffix)) if home else shutil.which(name)
    if not tool or not Path(tool).is_file():
        raise RuntimeError("JDK tool missing: " + name)
    compiler = str(Path(tool).with_name("javac" + suffix))
    probe = subprocess.run([compiler, "-version"], capture_output=True, text=True, check=True, timeout=10)
    version = probe.stdout + probe.stderr
    match = re.search(r"javac\s+(\d+)", version)
    if not match or int(match[1]) < minimum:
        raise RuntimeError("Compatibility input requires JDK " + str(minimum) + "+; actual " + version.strip())
    return tool
