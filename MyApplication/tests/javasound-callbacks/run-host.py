#!/usr/bin/env python3
"""用正常dlopen的实际宿主C源验证typed回调及POD协议；不创建容器，输出显式仓外。
SDK头保持原声明，仅在宿主GCC关闭不可识别的availability注解；目标SDK另独立检查。
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import os
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk-headers", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    tests = Path(__file__).resolve().parent
    root = tests.parents[1]
    native = root / "entry/src/main/cpp/javasound"
    out = args.out.resolve()
    if root == out or root in out.parents:
        raise ValueError("output must be outside source checkout")
    out.mkdir(parents=True, exist_ok=False)
    sources = [native / name for name in ("ohos_daudio_callbacks.c", "ohos_daudio_callbacks.h", "ohos_capture_ring.h", "ohos_playback_timeline.h")]
    sources += [tests / "host_callback_test.c", tests / "wrong_signature.c", Path(__file__)]
    receipt = {"startedAt": datetime.datetime.now().astimezone().isoformat(),
               "inputs": {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
               "commands": [], "targetCfiQualified": False}
    flags = ["-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
             "-fno-omit-frame-pointer", "-fsanitize=address,undefined", "-D__availability__(...)=",
             "-I" + str(args.sdk_headers), "-pthread"]

    def run(command, label, negative=False):
        result = subprocess.run(command, capture_output=True, timeout=30, env={
            **os.environ, "ASAN_OPTIONS": "detect_leaks=1:abort_on_error=1",
            "UBSAN_OPTIONS": "halt_on_error=1:print_stacktrace=1"})
        (out / (label + ".stdout")).write_bytes(result.stdout)
        (out / (label + ".stderr")).write_bytes(result.stderr)
        receipt["commands"].append({"argv": command, "exitCode": result.returncode, "expectedNegative": negative})
        print(result.stdout.decode("utf-8", "replace"), end="", flush=True)
        print(result.stderr.decode("utf-8", "replace"), end="", flush=True)
        if negative:
            if result.returncode == 0 or b"incompatible-pointer-types" not in result.stderr:
                raise RuntimeError("wrong callback signature was not specifically rejected")
        elif result.returncode != 0:
            raise RuntimeError(label + " failed")
    try:
        run(["gcc", "--version"], "compiler")
        run(["gcc", *flags, "-fPIC", "-shared", str(native / "ohos_daudio_callbacks.c"), "-o", str(out / "host-callbacks.so")], "build-dso")
        run(["gcc", *flags, str(tests / "host_callback_test.c"), "-ldl", "-o", str(out / "test")], "build-test")
        run([str(out / "test"), str(out / "host-callbacks.so")], "callbacks")
        run(["gcc", *flags, "-fsyntax-only", str(tests / "wrong_signature.c")], "wrong-signature", True)
        receipt["result"] = "PASS"
    finally:
        receipt["finishedAt"] = datetime.datetime.now().astimezone().isoformat()
        (out / "receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
