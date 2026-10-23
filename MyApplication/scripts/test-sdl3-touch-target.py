"""逐字编译SDL触控尾协议与真实GetHostBridge调用者，验证拒绝不会被symbol fallback绕过。

只替换宿主环境、动态链接与SDL原语，生产parser/调用分支/目标发布保持原文。
所有生成源码、二进制与收据外置；移除调用者拒绝分支的反控必须失败。
"""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import os
import re
import subprocess

from lib.host_cpp import compile_cpp
from lib.workspace_paths import external_output_path, workspace_path


ROOT = Path(__file__).resolve().parents[1]


def production_units():
    """沿既有series逐补丁重建；未知正文拒绝，不能把缺失调用者补成模型写的替代函数。"""
    spec = importlib.util.spec_from_file_location(
        "sdl_touch_extract", ROOT / "scripts/generate-desktop-review-tests.py")
    extract = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(extract)
    source = extract.patch_sources()["SDL_openharmonyamcl.c"]
    structure = re.search(
        r"typedef struct\s*\{\s*int attempts;[\s\S]*?\} OPENHARMONY_HostBridge;", source)
    if not structure or extract.UNKNOWN in structure[0]:
        raise ValueError("Complete production bridge declaration is required")
    names = ["OPENHARMONY_ResolveTouchBridge", "OPENHARMONY_ResolveOrderBridge",
             "OPENHARMONY_ResolveBridgeFromEnvironment", "OPENHARMONY_ValidateTouchFallback"]
    functions = [extract.function(source, name) for name in names]
    getter = re.search(r"^static OPENHARMONY_HostBridge \*OPENHARMONY_GetHostBridge\(void\)", source, re.M)
    if not getter:
        raise ValueError("Production GetHostBridge caller missing")
    functions.append(extract.block(source, getter.start()))
    names.append("OPENHARMONY_GetHostBridge")
    for name in ["OPENHARMONY_AMCL_PublishTouchInputTarget", "OPENHARMONY_AMCL_NotifyFramePresented"]:
        functions.append(extract.function(source, name))
        names.append(name)
    return structure[0], "\n\n".join(functions), names


def main():
    """正常代码和撤回调用者保护的反控分别编译；正例PASS与反例FAIL同写可追溯收据。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    output = external_output_path(arguments.output) if arguments.output else workspace_path("run", "sdl-touch-target")
    output.mkdir(parents=True, exist_ok=True)
    declaration, production, names = production_units()
    template = (ROOT / "entry/src/main/cpp/tests/host/sdl_touch_target.cpp.in").read_text(encoding="utf-8")
    unit = template.replace("@BRIDGE_DECL@", declaration).replace("@PRODUCTION@", production)
    path = output / "touch.cpp"
    binary = output / ("touch.exe" if os.name == "nt" else "touch")
    path.write_text(unit, encoding="utf-8", newline="\n")
    compile_cpp(path, binary)
    result = subprocess.run([str(binary)], capture_output=True, text=True, check=True, timeout=30)
    (output / "positive.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    print(result.stdout, end="")
    # 只撤掉真正调用者的failclosed判据，parser依然拒绝，重现“helper通过不等于整条路拒绝”。
    marker = "if (!OPENHARMONY_ValidateTouchFallback(bridge)) {"
    if production.count(marker) != 1:
        raise ValueError("Exactly one caller failclosed guard must be present")
    wrong = unit.replace(marker, "if (false) { /* 反控：让parser拒绝后继续进入symbols。 */", 1)
    wrong_path = output / "touch-negative.cpp"
    wrong_binary = output / ("touch-negative.exe" if os.name == "nt" else "touch-negative")
    wrong_path.write_text(wrong, encoding="utf-8", newline="\n")
    compile_cpp(wrong_path, wrong_binary)
    negative = subprocess.run([str(wrong_binary)], capture_output=True, text=True, timeout=30)
    (output / "negative.log").write_text(negative.stdout + negative.stderr, encoding="utf-8")
    if negative.returncode == 0 or "CHECK line" not in negative.stderr:
        raise AssertionError("Removing the actual caller guard must reproduce fallback bypass")
    receipt = {"functions": names, "production_sha256": hashlib.sha256(production.encode()).hexdigest(),
               "source_sha256": hashlib.sha256(unit.encode()).hexdigest(),
               "positive_exit": result.returncode, "negative_exit": negative.returncode,
               "negative_trigger": "actual caller guard removed; invalid new descriptor reaches fallback"}
    (output / "evidence.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("PASS negative control: removing GetHostBridge guard reproduces symbol fallback bypass")


if __name__ == "__main__":
    main()
