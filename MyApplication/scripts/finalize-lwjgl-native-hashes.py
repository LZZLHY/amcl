"""Canonicalize native bytes, bind LWJGL hash resources, optionally update the one slot lock.

No content-changing native packaging step may follow this operation. --check is
read-only for release files and verifies the locked final bytes and resources.
Reusing locked, already stripped natives does not require an OHOS SDK in CI.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parent.parent
JARS = ROOT / "prebuilt/lwjgl3/jars"
NATIVES = ROOT / "entry/libs/arm64-v8a"
MANIFEST = ROOT / "prebuilt/lwjgl3/modern-slot.manifest.json"
MODULES = {"lwjgl": "liblwjgl.so", "lwjgl-opengl": "liblwjgl_opengl.so", "lwjgl-stb": "liblwjgl_stb.so",
           "lwjgl-tinyfd": "liblwjgl_tinyfd.so", "lwjgl-vma": "liblwjgl_vma.so", "lwjgl-spng": "liblwjgl_spng.so"}


def digest(data, algorithm="sha256"): return hashlib.new(algorithm, data).hexdigest()
def record(path): return {"name": path.name, "size": path.stat().st_size, "sha256": digest(path.read_bytes())}


def finalize(check, jar_dir=JARS):
    manifest = json.loads(MANIFEST.read_text())
    locked = {item["name"]: item for item in manifest["natives"]}
    canonical = manifest.get("nativePostprocess") == "llvm-strip --strip-all; no subsequent byte changes"
    for module, native in MODULES.items():
        original = NATIVES / native
        final = original.read_bytes()
        item = locked.get(native, {})
        pinned = canonical and len(final) == item.get("size") and digest(final) == item.get("sha256")
        if not pinned:
            # Downloads only consume verified native inputs; native rebuilds are
            # finalized separately before their new identity can enter the lock.
            if check or jar_dir.resolve() != JARS.resolve():
                raise RuntimeError("Native differs from the locked final artifact: " + native)
            spec = importlib.util.spec_from_file_location("stb_prepare", ROOT / "scripts/lwjgl-stb-compat/prepare.py")
            helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
            sdk = helper.sdk_root()
            strip = sdk / "native/llvm/bin" / ("llvm-strip.exe" if __import__("os").name == "nt" else "llvm-strip")
            cache = ROOT / "diagnostics/runtime-compat-fix/final-native"
            cache.mkdir(parents=True, exist_ok=True)
            temp = cache / native; shutil.copyfile(original, temp)
            subprocess.run([str(strip), "--strip-all", str(temp)], check=True)
            final = temp.read_bytes()
            if final != original.read_bytes(): original.write_bytes(final)
        path = jar_dir / (module + ".jar")
        with zipfile.ZipFile(path) as jar:
            names = jar.namelist()
            if len(names) != len(set(names)): raise RuntimeError("Duplicate ZIP entries: " + str(path))
            prefix = "linux/arm64/org/lwjgl/" + (module.removeprefix("lwjgl-") + "/" if module != "lwjgl" else "")
            key = "META-INF/" + prefix + native + ".sha1"
            if key not in names: raise RuntimeError("Expected upstream fingerprint resource missing: " + key)
            expected = digest(final, "sha1").encode("ascii")
            if jar.read(key).strip() == expected: continue
            if check: raise RuntimeError("Packaged native fingerprint mismatch: " + key)
            entries = [(info, expected if info.filename == key else jar.read(info)) for info in jar.infolist()]
        tmp = path.with_suffix(".hash.tmp")
        with zipfile.ZipFile(tmp, "w") as jar:
            for info, data in entries:
                info.date_time = (2000, 1, 1, 0, 0, 0)
                jar.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
        tmp.replace(path)
    print("[lwjgl-final-native] final native bytes and Java fingerprint resources match")


def update_lock():
    manifest = json.loads(MANIFEST.read_text())
    manifest["jars"] = [record(JARS / item["name"]) for item in manifest["jars"]]
    manifest["natives"] = [record(NATIVES / item["name"]) for item in manifest["natives"]]
    manifest["postprocess"] = ["root-module-info", "complete-module-packages", "stack-api-backfill",
                               "inject-ohos-glfw-bridge", "stb-resize-v1-api", "ohos-final-native-fingerprints", "tinyfd-boolean-api"]
    manifest["nativePostprocess"] = "llvm-strip --strip-all; no subsequent byte changes"
    manifest["stbCompatibilitySourceSha256"] = digest((ROOT / "prebuilt/lwjgl3/compat/stb-v1/sources.json").read_bytes())
    payload = "".join(f"{x['name']}|{x['size']}|{x['sha256']}\n" for x in sorted(manifest["jars"], key=lambda x: x["name"]))
    manifest["manifestEntrySha256"] = digest(payload.encode())
    MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    contract = ROOT / "launch/src/main/ets/LwjglModernSlot.ets"
    text = contract.read_text(encoding="utf-8")
    text = re.sub(r"(LWJGL_MODERN_MANIFEST_SHA256 = ')[0-9a-f]+", r"\g<1>" + manifest["manifestEntrySha256"], text)
    text = re.sub(r"(manifest=)[0-9a-f]{64}", r"\g<1>" + manifest["manifestEntrySha256"], text)
    for item in manifest["jars"]:
        pattern = r"\{ name: '" + re.escape(item["name"]) + r"', size: \d+, sha256: '[0-9a-f]+' \}"
        text, count = re.subn(pattern, "{ name: '%s', size: %d, sha256: '%s' }" % (item["name"], item["size"], item["sha256"]), text)
        if count != 1: raise RuntimeError("Runtime contract entry count: " + item["name"])
    contract.write_text(text, encoding="utf-8")
    lock = ROOT / "deps.lock"; text = lock.read_text(encoding="utf-8")
    for item in manifest["natives"]:
        stem = item["name"].removesuffix(".so")
        for field in ["size", "sha256"]:
            text, count = re.subn(r"(?m)^(" + re.escape(stem + "_" + field) + r"\s*=\s*)\S+", r"\g<1>" + str(item[field]), text)
            if count != 1: raise RuntimeError("Native lock entry count: " + stem)
    lock.write_text(text, encoding="utf-8")
    for item in manifest["jars"]:
        shutil.copyfile(JARS / item["name"], ROOT / "entry/src/main/resources/rawfile/lwjgl" / item["name"])
    print("[lwjgl-final-native] updated modern manifest, runtime contract, deps.lock and rawfile")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--update-lock", action="store_true")
    parser.add_argument("--jar-dir", type=Path, default=JARS,
                        help="Java slot to bind to the locked final native artifacts")
    args = parser.parse_args()
    if args.check and args.update_lock: parser.error("--check cannot update locks")
    if args.update_lock and args.jar_dir.resolve() != JARS.resolve():
        parser.error("--update-lock requires the canonical Java slot")
    finalize(args.check, args.jar_dir.resolve())
    if args.update_lock: update_lock()
