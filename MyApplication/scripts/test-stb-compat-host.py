"""Windows host build of the same modern+legacy translation units, then real JNI tests."""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import subprocess
import shutil
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "diagnostics/runtime-compat-fix/stb-host"
BUILD.mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location("stb_prepare", ROOT / "scripts/lwjgl-stb-compat/prepare.py")
helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
helper.verify_sources()
vswhere = Path(os.environ["ProgramFiles(x86)"]) / "Microsoft Visual Studio/Installer/vswhere.exe"
vs = subprocess.check_output([str(vswhere), "-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"], text=True).strip()
vcvars = Path(vs) / "VC/Auxiliary/Build/vcvars64.bat"
environment = subprocess.check_output(f'call "{vcvars}" >nul 2>&1 && set', shell=True, text=True)
env = {key.upper(): value for key, value in os.environ.items()}
for line in environment.splitlines():
    key, sep, value = line.partition("=")
    if sep and key: env[key.upper()] = value
core = helper.MODERN / "core/src/main/c"
legacy = BUILD / "org_lwjgl_stb_STBImageResizeV1.c"
legacy.write_text((helper.VENDOR / "org_lwjgl_stb_STBImageResize.c").read_text().replace(
    "Java_org_lwjgl_stb_STBImageResize_", "Java_org_lwjgl_stb_STBImageResizeV1_"))
sources = [*sorted((helper.MODERN / "stb/src/generated/c").glob("*.c")), legacy]
jni = ROOT / "prebuilt/mod-natives/imgui-java/jni/jni-headers"
compiler = shutil.which("cl", path=env["PATH"])
if not compiler: raise RuntimeError("MSVC compiler unavailable after vcvars")
flags = [compiler, "/nologo", "/LD", "/TC", "/std:c11", "/O2", "/MD", "/DNDEBUG", "/DLWJGL_WINDOWS", "/DLWJGL_x64", "/D_CRT_SECURE_NO_WARNINGS"]
for inc in [jni, jni / "win32", core, core / "windows", helper.MODERN / "stb/src/main/c", helper.VENDOR]: flags += ["/I" + str(inc)]
result = subprocess.run([*flags, *map(str, sources), "/link", "/OUT:" + str(BUILD / "lwjgl_stb.dll")], cwd=BUILD, env=env,
                        capture_output=True, text=True, encoding="utf-8", errors="replace")
(BUILD / "build.txt").write_text(result.stdout + result.stderr, encoding="utf-8")
if result.returncode: print(result.stdout + result.stderr); raise SystemExit(result.returncode)
native = BUILD / "lwjgl-natives-windows.jar"
if not native.exists():
    native.write_bytes(urllib.request.urlopen("https://repo.maven.apache.org/maven2/org/lwjgl/lwjgl/3.4.2/lwjgl-3.4.2-natives-windows.jar", timeout=30).read())
if hashlib.sha256(native.read_bytes()).hexdigest() != "8e48cf335d308a84d7e782f001a5a89fdc9a30766e82a9056f30300bdff70d01": raise RuntimeError("Host LWJGL native hash mismatch")
hostJar = BUILD / "lwjgl-stb.jar"
with zipfile.ZipFile(helper.JARS / "lwjgl-stb.jar") as source, zipfile.ZipFile(hostJar, "w") as dest:
    for entry in source.infolist():
        data = source.read(entry)
        if entry.filename.endswith("windows/x64/org/lwjgl/stb/lwjgl_stb.dll.sha1"):
            data = hashlib.sha1((BUILD / "lwjgl_stb.dll").read_bytes()).hexdigest().encode("ascii")
        dest.writestr(entry, data)
cp = os.pathsep.join(map(str, [hostJar, helper.JARS / "lwjgl.jar", native, BUILD]))
subprocess.run([helper.jdk("javac"), "-proc:none", "-cp", cp, "-d", str(BUILD),
                str(ROOT / "scripts/lwjgl-stb-compat/StbCompatTest.java")], check=True)
result = subprocess.run([helper.jdk("java"), "-Dorg.lwjgl.librarypath=" + str(BUILD), "-cp", cp, "StbCompatTest"],
                        capture_output=True, text=True, encoding="utf-8", errors="replace")
text = result.stdout + result.stderr
(BUILD / "results.txt").write_text(text, encoding="utf-8")
print(text)
if result.returncode: raise SystemExit(result.returncode)
