"""构建仅供隔离真机实例安装的 Create QA 模组；绝不写入正式 rawfile 或 HAP。

必须在完整代码静态复核关闭后由任务负责人显式调用。本脚本只构建外置 JAR、
启用配置样本和来源收据，不安装、启动、操作设备或修改 Minecraft 原实例。
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import zipfile

from lib.game_compat_inputs import LOCK, jdk_tool, prepare
from lib.game_compat_sessions import new_compat_session

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "prebuilt/runtime-compat/device-test"


def sha(data):
    """记录实际输入/输出字节身份；不以文件名或显示版本替代固定输入核验。"""
    return hashlib.sha256(data).hexdigest()


def build(output=None, inputs=None):
    """在全新仓外目录编译 test-only 源；compile-only 的所有第三方 class 禁止入包。"""
    directory = new_compat_session("create-thread-device-probe", output)
    classes = directory / "classes"
    classes.mkdir()
    fixed = prepare(inputs, include_create=True)
    mixin_lock = ROOT / "prebuilt/runtime-compat/lib/sources.json"
    pinned = json.loads(mixin_lock.read_text(encoding="utf-8"))
    mixin = next(item for item in pinned["files"] if item["file"].startswith("sponge-mixin-"))
    mixin_jar = mixin_lock.parent / mixin["file"]
    data = mixin_jar.read_bytes()
    if len(data) != mixin["size"] or sha(data) != mixin["sha256"]:
        raise RuntimeError("Unpinned probe compile-only Mixin dependency")
    sources = sorted((SOURCE / "src").rglob("*.java"))
    # 与生产变换使用同一份 MC/Loader/旧 Create 身份；不从设备路径推断编译 ABI。
    classpath = [*fixed["classpath"], fixed["paths"]["create-old"], mixin_jar]
    compiler = jdk_tool("javac")
    command = [compiler, "--release", "21", "-encoding", "UTF-8", "-proc:none",
               "-cp", os.pathsep.join(map(str, classpath)), "-d", str(classes), *map(str, sources)]
    subprocess.run(command, check=True)
    entries = {}
    for path in sorted(classes.rglob("*.class")):
        name = path.relative_to(classes).as_posix()
        content = path.read_bytes()
        if not name.startswith("com/amcl/compat/probe/") or int.from_bytes(content[6:8], "big") != 65:
            raise RuntimeError("Unexpected device probe class output: " + name)
        entries[name] = content
    if not entries:
        raise RuntimeError("No device probe class outputs")
    for path in sorted((SOURCE / "resources").rglob("*")):
        if path.is_file():
            entries[path.relative_to(SOURCE / "resources").as_posix()] = path.read_bytes()
    artifact = directory / "amcl-create-thread-device-probe.jar"
    with zipfile.ZipFile(artifact, "w") as archive:
        for name, content in sorted(entries.items()):
            info = zipfile.ZipInfo(name, date_time=(2000, 1, 1, 0, 0, 0))
            archive.writestr(info, content, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    # 启用配置在 JAR 外单独交付，部署者须放进新建 QA gameDir/config 后才会执行。
    (directory / "amcl-create-thread-probe.json").write_bytes(
        (SOURCE / "amcl-create-thread-probe.example.json").read_bytes())
    recipe = [Path(__file__), ROOT / "scripts/lib/game_compat_inputs.py", ROOT / "scripts/lib/game_compat_sessions.py", LOCK, mixin_lock,
              *sorted(path for path in SOURCE.rglob("*") if path.is_file())]
    receipt = {"schema": 1, "testOnly": True, "artifact": str(artifact),
               "sha256": sha(artifact.read_bytes()), "javaOutputRelease": 21,
               "javac": subprocess.check_output([compiler, "-version"], text=True).strip(),
               "classes": sorted(name for name in entries if name.endswith(".class")),
               "inputs": [{"path": str(path), "sha256": sha(path.read_bytes())} for path in classpath],
               "recipe": [{"path": path.relative_to(ROOT).as_posix(), "sha256": sha(path.read_bytes())}
                          for path in recipe]}
    (directory / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print("[create-device-probe] " + str(artifact) + " sha256=" + receipt["sha256"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", help="New external QA artifact directory")
    parser.add_argument("--inputs", help="Verified compile-only input cache prepared by existing helper")
    arguments = parser.parse_args()
    build(arguments.output, arguments.inputs)
