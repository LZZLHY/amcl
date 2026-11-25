"""核对私有分配器的 CPU、装载边界和 LWJGL C ABI，避免把宿主或系统 malloc 混入交付。"""
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

out = Path(sys.argv[1])
sdk = Path(sys.argv[2])
suffix = sys.argv[3]
archive = Path(sys.argv[4])
report = (out / "elf.txt").read_text(encoding="utf-8")
expected = set(re.findall(r"\b(je_\w+);", Path(__file__).with_name("exports.map").read_text()))
symbols = {}
external_bindings = set()
for row in report.splitlines():
    fields = row.split()
    if len(fields) == 8 and fields[0][:-1].isdigit() and fields[4] in {"GLOBAL", "WEAK"} and fields[6] != "UND":
        symbols[fields[7]] = fields[3]
        # LWJGL 把 je_malloc_message 当作一个回调指针槽读取；AArch64 需要完整的 8 字节对象。
        if fields[7] == "je_malloc_message" and int(fields[2]) != 8:
            sys.exit("je_malloc_message 的导出对象必须是 8 字节")
    # 检查最终 ELF 的所有命名动态重定位，数据 GOT 和函数 PLT 均须就地绑定自己的导出。
    if len(fields) >= 5 and fields[2].startswith("R_AARCH64_"):
        name = fields[4].split("@", 1)[0]
        if name in expected:
            external_bindings.add(name)

if external_bindings:
    sys.exit(f"本库导出仍有可抢占的动态重定位：{', '.join(sorted(external_bindings))}")
if set(symbols) != expected or len(expected) != 21:
    sys.exit(f"导出集合不符，缺失 {expected - symbols.keys()}，多出 {symbols.keys() - expected}")
for name, kind in symbols.items():
    if kind != ("OBJECT" if name == "je_malloc_message" else "FUNC"):
        sys.exit(f"{name} 类型异常：{kind}")
if not re.search(r"Machine:\s+AArch64\b", report) or not re.search(r"Type:\s+DYN\b", report):
    sys.exit("产物不是 AArch64 DSO")
if re.findall(r"\(SONAME\).*?\[(.*?)\]", report) != ["libamcl_lwjgl_jemalloc.so"]:
    sys.exit("私有 SONAME 不符")
if set(re.findall(r"\(NEEDED\).*?\[(.*?)\]", report)) != {"libc.so"}:
    sys.exit("运行依赖与 OHOS libc 契约不符")
loads = re.findall(r"^\s*LOAD\s+.*?\s(0x[0-9a-fA-F]+)\s*$", report, re.MULTILINE)
if not loads or any(int(value, 16) < 65536 for value in loads):
    sys.exit("ELF LOAD 段不支持 64 KiB 对齐")
if "R_AARCH64_TLSDESC" not in report or re.search(r"STATIC_TLS|R_AARCH64_TLS_TPREL|GLIBC_", report):
    sys.exit("动态 ELF TLS 或 libc ABI 不符合目标")
if re.search(r"\bUND\s+(?:malloc|calloc|realloc|free|sbrk)\s*$", report, re.MULTILINE):
    sys.exit("产物会进入系统分配器或程序 break")


def sha(path):
    """以真实字节锁定参与者，区分上游版本名、SDK 与已剥离的交付 ELF。"""
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1048576), b""):
            digest.update(block)
    return digest.hexdigest()


soname = "libamcl_lwjgl_jemalloc.so"
library = out / soname
toolchain = sdk / "llvm/bin"
metadata = json.loads((sdk / "oh-uni-package.json").read_text(encoding="utf-8"))
# 同一链接产物同时产生发布库和保留私有符号的 ABI 审查输入。重做完全相同的 strip，
# 比对实际交付字节，防止从其他构建目录误取一个同名未剥离文件。
linked = Path("jemalloc-5.3.1/lib/libjemalloc.so.2")
stripped = subprocess.check_output([str(toolchain.resolve() / ("llvm-strip" + suffix)),
                                    "--strip-all", "-o", "-", str(linked)], cwd=out)
if stripped != library.read_bytes():
    sys.exit("未剥离 ELF 与交付库不属于同一链接产物")
symbol_file = out / "symbols" / soname
symbol_file.parent.mkdir(exist_ok=True)
shutil.copyfile(out / linked, symbol_file)
receipt = {
    "source": "https://github.com/jemalloc/jemalloc/releases/download/5.3.1/jemalloc-5.3.1.tar.bz2",
    "commit": "81034ce1f1373e37dc865038e1bc8eeecf559ce8",
    "sourceSha256": sha(archive),
    "license": "COPYING",
    "licenseSha256": sha(Path(__file__).with_name("COPYING")),
    "recipe": "prebuilt/jemalloc/build-ohos.sh",
    "apiVersion": metadata["apiVersion"],
    "sdkVersion": metadata["version"],
    "compiler": (out / "compiler.txt").read_text().splitlines()[0],
    "toolSha256": {name: sha(toolchain / (name + suffix)) for name in ("clang", "ld.lld", "llvm-strip", "llvm-readelf")},
    "libcStubSha256": sha(sdk / "sysroot/usr/lib/aarch64-linux-ohos/libc.so"),
    "unstripped": {"path": "symbols/" + soname, "size": symbol_file.stat().st_size, "sha256": sha(symbol_file)},
    "elf": {
        "soname": soname, "needed": ["libc.so"], "machine": "AArch64", "tls": "TLSDESC",
        "loadAlignment": sorted({int(value, 16) for value in loads}), "exports": dict(sorted(symbols.items())),
        "ownExportNamedDynamicRelocations": sorted(external_bindings), "mallocMessageSize": 8,
        "size": library.stat().st_size, "sha256": sha(library)
    }
}
(out / "build-provenance.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
