"""构建可复现 Fabric 兼容制品；游戏/Loader/Mixin 仅作编译输入，永不打包。

26.2 的真实 ABI 为 class69，编译器须为 JDK25+；输出固定 --release21。兼容规则
仍按游戏/模组身份分支，JDK21 的 1.21.11 路径不得提前解析 26.2 专用类型。
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import zipfile
from lib.game_compat_inputs import LOCK, LWJGL_LOCK, VENDORED_LOCKS, classpath_receipt, jdk_tool, lwjgl_inputs, prepare, vendored_classpath
from lib.game_compat_sessions import new_compat_session

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "prebuilt/runtime-compat"

def sha(data):
    """正式制品与配方统一使用 SHA256；路径、时间均不影响内容身份。"""
    return hashlib.sha256(data).hexdigest()


def build(output=None, inputs=None):
    """在新会话目录编译，枚举真实 class 输出（含内部类），然后原位更新正式资产。"""
    directory = new_compat_session("game-compat-build", output)
    classes = directory / "classes"
    classes.mkdir()
    compile_inputs = prepare(inputs)
    sources = sorted((SOURCE / "src").rglob("*.java"))
    classpath = [*vendored_classpath(), *lwjgl_inputs(),
        *compile_inputs["classpath"]]
    compile_receipt = classpath_receipt(classpath, compile_inputs["directory"])
    cp = os.pathsep.join(map(str, classpath))
    subprocess.run([jdk_tool("javac"), "--release", "21", "-encoding", "UTF-8", "-proc:none", "-cp", cp,
                   "-d", str(classes), *map(str, sources)], check=True)
    entries = {}
    for path in sorted(classes.rglob("*.class")):
        name = path.relative_to(classes).as_posix()
        data = path.read_bytes()
        # compile-only 游戏、加载器、Netty/Mixin 类型不能作为自己的 class 输出入包。
        if not name.startswith("com/amcl/compat/") or int.from_bytes(data[6:8], "big") != 65:
            raise RuntimeError("Unexpected compatibility output class: " + name)
        entries[name] = data
    if not entries:
        raise RuntimeError("No compatibility classes compiled")
    for path in sorted((SOURCE / "resources").rglob("*")):
        if path.is_file():
            entries[path.relative_to(SOURCE / "resources").as_posix()] = path.read_text(encoding="utf-8").encode("utf-8")
    artifact = ROOT / "entry/src/main/resources/rawfile/amcl-fabric-compat.jar"
    temporary = directory / "amcl-fabric-compat.jar"
    with zipfile.ZipFile(temporary, "w") as jar:
        for name, data in sorted(entries.items()):
            info = zipfile.ZipInfo(name, date_time=(2000, 1, 1, 0, 0, 0))
            jar.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    data = temporary.read_bytes()
    if not artifact.exists() or artifact.read_bytes() != data:
        artifact.write_bytes(data)
    checksum = sha(data)
    contract = ROOT / "launch/src/main/ets/GameCompatibilityArtifact.ets"
    text = "/** 由 build-game-compat.py 生成；运行时按这些字节身份验证实际交付的兼容 JAR。 */\n"
    text += "export const GAME_COMPAT_JAR = 'amcl-fabric-compat.jar';\n"
    text += f"export const GAME_COMPAT_RUNTIME_JAR = 'amcl-fabric-compat-{checksum}.jar';\n"
    text += f"export const GAME_COMPAT_SIZE = {len(data)};\nexport const GAME_COMPAT_SHA256 = '{checksum}';\n"
    if not contract.exists() or contract.read_text(encoding="utf-8") != text:
        contract.write_text(text, encoding="utf-8")
    # 解析器属于可复现源码；本机私有路径JSON不入公开配方，实际依赖字节仍由classpath收据绑定。
    recipe = [Path(__file__), ROOT / "scripts/lib/game_compat_inputs.py", ROOT / "scripts/lib/game_compat_sessions.py",
              ROOT / "scripts/lib/build_dependencies.py", LOCK, LWJGL_LOCK, *VENDORED_LOCKS,
              *sources, *sorted((SOURCE / "resources").rglob("*"))]
    identity = {"schema": 2, "sha256": checksum, "size": len(data), "javaOutputRelease": 21,
        "compileOnlyLockSha256": sha(LOCK.read_text(encoding="utf-8").encode("utf-8")),
        "compileClasspath": compile_receipt, "sources": [
            {"path": path.relative_to(ROOT).as_posix(), "sha256": sha(path.read_text(encoding="utf-8").encode("utf-8"))}
            for path in recipe if path.is_file()]}
    (SOURCE / "artifact.json").write_text(json.dumps(identity, indent=2) + "\n", encoding="utf-8")
    (directory / "build-receipt.json").write_text(json.dumps({"schema": 1,
        "javac": subprocess.check_output([jdk_tool("javac"), "-version"], text=True).strip(),
        "javaOutputRelease": 21, "compileOnlyLockSha256": identity["compileOnlyLockSha256"],
        "artifactSha256": checksum, "compileClasspath": compile_receipt,
        "classes": sorted(name for name in entries if name.endswith(".class"))}, indent=2) + "\n", encoding="utf-8")
    print(f"[game-compat] {len(data)} bytes sha256={checksum}; receipt={directory / 'build-receipt.json'}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", help="New external build session directory")
    parser.add_argument("--inputs", help="Verified external compile-only cache")
    args = parser.parse_args()
    build(args.output, args.inputs)
