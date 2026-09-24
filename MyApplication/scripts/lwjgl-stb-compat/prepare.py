"""Build the pinned STB v1 compatibility payload using the existing OHOS SDK.

--native rebuilds the complete STB module, including modern and legacy JNI.
Without it, only Java backfill is performed. No source/tag is fetched implicitly.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
VENDOR = ROOT / "prebuilt/lwjgl3/compat/stb-v1"
MODERN = ROOT / "prebuilt/lwjgl3/lwjgl3_src/modules/lwjgl"
JARS = ROOT / "prebuilt/lwjgl3/jars"
BUILD = ROOT / "diagnostics/runtime-compat-fix/stb-build"


def sha(data): return hashlib.sha256(data).hexdigest()
def run(args):
    print("[stb-compat] " + " ".join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), check=True, cwd=ROOT)


def jdk(tool):
    home = os.environ.get("JAVA_HOME")
    exe = tool + (".exe" if os.name == "nt" else "")
    if home and (Path(home) / "bin" / exe).is_file(): return str(Path(home) / "bin" / exe)
    found = shutil.which(tool)
    if not found: raise RuntimeError("JDK tool missing: " + tool)
    return found


def sdk_root():
    configured = os.environ.get("OHOS_SDK_ROOT")
    if configured: return Path(configured)
    match = re.search(r"^hwsdk\.dir=(.+)$", (ROOT / "local.properties").read_text(), re.M)
    if not match: raise RuntimeError("Set OHOS_SDK_ROOT to the OpenHarmony SDK")
    return Path(match[1].strip().replace("\\\\", "\\"))


def verify_sources():
    sources = json.loads((VENDOR / "sources.json").read_text())
    for entry in sources["files"]:
        data = (VENDOR / entry["file"]).read_bytes()
        if len(data) != entry["size"] or sha(data) != entry["sha256"]:
            raise RuntimeError("Unpinned STB source: " + entry["file"])
    return sources


def prepare_java(check=False, jar_dir=JARS, module="all"):
    BUILD.mkdir(parents=True, exist_ok=True)
    asm = sorted((ROOT / "scripts/lwjgl-stack-backfill/lib").glob("*.jar"))
    cp = os.pathsep.join(map(str, asm))
    run([jdk("javac"), "-cp", cp, "-d", BUILD, Path(__file__).with_name("StbBackfill.java")])
    args = [jdk("java"), "-cp", os.pathsep.join([str(BUILD), cp]), "StbBackfill"]
    if module == "tinyfd":
        args += [jar_dir / "lwjgl-tinyfd.jar", "--tinyfd-only"]
    else:
        text = (VENDOR / "STBImageResize.java").read_text(encoding="utf-8")
        source = BUILD / "STBImageResizeV1.java"
        source.write_text(re.sub(r"\bSTBImageResize\b", "STBImageResizeV1", text), encoding="utf-8")
        # Compile the original wrapper against the actual deployed modern core API.
        run([jdk("javac"), "--release", "8", "-proc:none", "-encoding", "UTF-8", "-cp",
             os.pathsep.join(map(str, [jar_dir / "lwjgl.jar", jar_dir / "lwjgl-stb.jar"])), "-d", BUILD, source])
        args += [jar_dir / "lwjgl-stb.jar", BUILD / "org/lwjgl/stb/STBImageResizeV1.class",
                 VENDOR / "lwjgl-stb-3.3.3.jar"]
        if module == "stb": args.append("--stb-only")
    if check: args.append("--check")
    run(args)


def build_native():
    sdk = sdk_root()
    suffix = ".exe" if os.name == "nt" else ""
    clang = sdk / "native/llvm/bin" / ("clang" + suffix)
    strip = sdk / "native/llvm/bin" / ("llvm-strip" + suffix)
    core = MODERN / "core/src/main/c"
    jni = ROOT / "prebuilt/mod-natives/imgui-java/jni/jni-headers"
    flags = ["--target=aarch64-linux-ohos", "--sysroot=" + str(sdk / "native/sysroot"),
             "-O3", "-fPIC", "-DNDEBUG", "-DLWJGL_LINUX", "-DLWJGL_arm64", "-U_FORTIFY_SOURCE",
             "-D_FORTIFY_SOURCE=0", "-D_GNU_SOURCE", "-D_FILE_OFFSET_BITS=64", "-D__ANDROID_API__=24"]
    for inc in [jni, jni / "linux", core, core / "linux", MODERN / "stb/src/main/c", VENDOR]:
        flags += ["-I", str(inc)]
    source = BUILD / "org_lwjgl_stb_STBImageResizeV1.c"
    source.write_text((VENDOR / "org_lwjgl_stb_STBImageResize.c").read_text().replace(
        "Java_org_lwjgl_stb_STBImageResize_", "Java_org_lwjgl_stb_STBImageResizeV1_"), encoding="utf-8")
    objects = []
    for src in [*sorted((MODERN / "stb/src/generated/c").glob("*.c")), source]:
        obj = BUILD / (src.stem + ".o")
        run([clang, "-c", "-std=gnu11", *flags, src, "-o", obj])
        objects.append(obj)
    exports = BUILD / "exports.ver"
    exports.write_text("{ global: Java_*; JNI_OnLoad; local: *; };\n")
    target = BUILD / "liblwjgl_stb.so"
    run([clang, *flags, "-shared", "-Wl,--no-undefined", "-Wl,-z,noexecstack",
         "-Wl,--version-script=" + str(exports), "-o", target, *objects, "-lm"])
    run([strip, "--strip-all", target])
    provenance = {"schema": 1, "sourceManifestSha256": sha((VENDOR / "sources.json").read_bytes()),
                  "modernCommit": subprocess.check_output(["git", "-C", str(MODERN), "rev-parse", "HEAD"], text=True).strip(),
                  "compiler": subprocess.check_output([str(clang), "--version"], text=True).splitlines()[0],
                  "flags": flags, "strip": "--strip-all", "sha256": sha(target.read_bytes()), "size": target.stat().st_size}
    (BUILD / "native-build.json").write_text(json.dumps(provenance, indent=2) + "\n")
    shutil.copyfile(target, ROOT / "entry/libs/arm64-v8a/liblwjgl_stb.so")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--native", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--jar-dir", type=Path, default=JARS,
                        help="Java slot to prepare, including an unpublished download staging directory")
    parser.add_argument("--module", choices=["all", "stb", "tinyfd"], default="all")
    args = parser.parse_args()
    if args.native and args.check: parser.error("--check cannot rebuild native")
    if args.native and args.jar_dir.resolve() != JARS.resolve():
        parser.error("--native requires the canonical Java slot")
    if args.native and args.module == "tinyfd": parser.error("--native builds the STB module")
    verify_sources()
    prepare_java(args.check, args.jar_dir.resolve(), args.module)
    if args.native:
        build_native()
