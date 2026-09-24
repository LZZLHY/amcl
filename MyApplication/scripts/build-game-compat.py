"""Deterministic Fabric compatibility artifact. Mixin is a build-time dependency only."""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import subprocess
import zipfile
from lib.workspace_paths import workspace_path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "prebuilt/runtime-compat"
# Java 兼容 JAR 的编译中间物外置，最终工程交付 JAR 仍使用下方原有目标。
BUILD = workspace_path("build", "fabric-compat")
BUILD.mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location("jdk_tools", ROOT / "scripts/lwjgl-stb-compat/prepare.py")
helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
dependencies = json.loads((SOURCE / "lib/sources.json").read_text())
for item in dependencies["files"]:
    data = (SOURCE / "lib" / item["file"]).read_bytes()
    if len(data) != item["size"] or hashlib.sha256(data).hexdigest() != item["sha256"]:
        raise RuntimeError("Unpinned Mixin dependency")
sources = sorted((SOURCE / "src").rglob("*.java"))
cp = os.pathsep.join(map(str, [*sorted((SOURCE / "lib").glob("*.jar")),
                            *sorted((ROOT / "scripts/lwjgl-stack-backfill/lib").glob("*.jar")),
                            ROOT / 'prebuilt/lwjgl3/jars/lwjgl.jar', ROOT / 'prebuilt/lwjgl3/jars/lwjgl-opengl.jar']))
subprocess.run([helper.jdk("javac"), "--release", "21", "-encoding", "UTF-8", "-proc:none", "-cp", cp,
                "-d", str(BUILD), *map(str, sources)], check=True)
entries = {}
for source in sources:
    relative = source.relative_to(SOURCE / "src").with_suffix(".class")
    entries[relative.as_posix()] = (BUILD / relative).read_bytes()
for source in sorted((SOURCE / "resources").rglob("*")):
    if source.is_file(): entries[source.relative_to(SOURCE / "resources").as_posix()] = source.read_text(encoding="utf-8").encode("utf-8")
artifact = ROOT / "entry/src/main/resources/rawfile/amcl-fabric-compat.jar"
temp = BUILD / "amcl-fabric-compat.jar"
with zipfile.ZipFile(temp, "w") as jar:
    for name, data in sorted(entries.items()):
        info = zipfile.ZipInfo(name, date_time=(2000, 1, 1, 0, 0, 0))
        jar.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
data = temp.read_bytes()
if not artifact.exists() or artifact.read_bytes() != data: artifact.write_bytes(data)
sha = hashlib.sha256(data).hexdigest()
contract = ROOT / "launch/src/main/ets/GameCompatibilityArtifact.ets"
text = "/** 由 build-game-compat.py 生成；运行时按这些字节身份验证实际交付的兼容 JAR。 */\n"
text += "export const GAME_COMPAT_JAR = 'amcl-fabric-compat.jar';\n"
text += f"export const GAME_COMPAT_RUNTIME_JAR = 'amcl-fabric-compat-{sha}.jar';\n"
text += f"export const GAME_COMPAT_SIZE = {len(data)};\nexport const GAME_COMPAT_SHA256 = '{sha}';\n"
if not contract.exists() or contract.read_text(encoding="utf-8") != text: contract.write_text(text, encoding="utf-8")
inputs = [Path(__file__), SOURCE / 'lib/sources.json', *sources, *sorted((SOURCE / 'resources').rglob('*'))]
identity = {'schema': 1, 'sha256': sha, 'size': len(data), 'sources': [
    {'path': path.relative_to(ROOT).as_posix(), 'sha256': hashlib.sha256(path.read_text(encoding='utf-8').encode('utf-8')).hexdigest()}
    for path in inputs if path.is_file()]}
(SOURCE / 'artifact.json').write_text(json.dumps(identity, indent=2) + '\n', encoding='utf-8')
print(f"[game-compat] {len(data)} bytes sha256={sha}")
