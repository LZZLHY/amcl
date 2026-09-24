from pathlib import Path
import json
import os
import subprocess
import importlib.util
from lib.workspace_paths import workspace_path

ROOT = Path(__file__).resolve().parent.parent
# 真实字节码变换测试独立于源码与设备证据目录，不覆盖历史诊断记录。
BUILD = workspace_path("build", "mixin-test")
BUILD.mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location("jdk_tools", ROOT / "scripts/lwjgl-stb-compat/prepare.py")
helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
jar = ROOT / "entry/src/main/resources/rawfile/amcl-fabric-compat.jar"
cp = os.pathsep.join(map(str, [jar, *sorted((ROOT / "prebuilt/runtime-compat/lib").glob("*.jar")),
                              *sorted((ROOT / "scripts/lwjgl-stack-backfill/lib").glob("*.jar"))]))
sources = sorted((ROOT / "prebuilt/runtime-compat/test").rglob("*.java"))
subprocess.run([helper.jdk("javac"), "-proc:none", "-encoding", "UTF-8", "-cp", cp, "-d", str(BUILD), *map(str, sources)], check=True)
services = BUILD / "META-INF/services"; services.mkdir(parents=True, exist_ok=True)
(services / "org.spongepowered.asm.service.IMixinService").write_text("com.amcl.compat.test.MixinTestService\n")
(services / "org.spongepowered.asm.service.IGlobalPropertyService").write_text("com.amcl.compat.test.TestProperties\n")
result = subprocess.run([helper.jdk("java"), "-cp", os.pathsep.join([str(BUILD), cp]),
                         "com.amcl.compat.test.ResizeMixinTest"], capture_output=True, text=True, encoding="utf-8", errors="replace")
text = result.stdout + result.stderr
(BUILD / "results.txt").write_text(text, encoding="utf-8")
print(text)
if result.returncode: raise SystemExit(result.returncode)

# 真实 26.2 Create Fly 类仅作为字节码输入；冻结夹具不依赖整份游戏或在线模组仓库。
fixture = ROOT / 'prebuilt/runtime-compat/test-fixtures/create-fly-staging.jar'
result = subprocess.run([helper.jdk('java'), '-cp', os.pathsep.join([str(BUILD), cp, str(fixture)]),
    'com.amcl.compat.test.FlywheelMixinTest'], capture_output=True, text=True, encoding='utf-8', errors='replace')
text = result.stdout + result.stderr
(BUILD / 'flywheel-results.txt').write_text(text, encoding='utf-8')
print(text)
if result.returncode: raise SystemExit(result.returncode)
result = subprocess.run([helper.jdk("java"), "-cp", os.pathsep.join([str(BUILD), cp,
    str(ROOT / 'prebuilt/lwjgl3/jars/lwjgl.jar')]), 'com.amcl.compat.test.TinyFdCompatibilityTest',
    str(ROOT / 'prebuilt/lwjgl3/jars/lwjgl-tinyfd.jar')], capture_output=True, text=True, encoding='utf-8', errors='replace')
text = result.stdout + result.stderr
(BUILD / 'tinyfd-results.txt').write_text(text, encoding='utf-8')
print(text)
if result.returncode: raise SystemExit(result.returncode)

# 真实LevelUniforms/UniformWriter字节码同时证明旧越界与新构造容量；不以编译通过替代内存边界验证。
level_fixture = ROOT / 'prebuilt/runtime-compat/test-fixtures/create-fly-level.jar'
result = subprocess.run([helper.jdk('java'), '-cp', os.pathsep.join([str(BUILD), cp, str(level_fixture)]),
    'com.amcl.compat.test.LevelUniformMixinTest'], capture_output=True, text=True, encoding='utf-8', errors='replace')
text = result.stdout + result.stderr
(BUILD / 'level-uniform-results.txt').write_text(text, encoding='utf-8')
print(text)
if result.returncode: raise SystemExit(result.returncode)
