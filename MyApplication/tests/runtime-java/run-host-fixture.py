#!/usr/bin/env python3
"""宿主只验证同一 class52 夹具可执行及负例；不替代 OHOS NativeChildProcess/DestroyJavaVM 资格。"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--java", type=Path, required=True)
    parser.add_argument("--jar", type=Path, required=True)
    parser.add_argument("--major", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    positive = root / "normal"
    positive.mkdir()
    log = root / "normal.log"
    command = [str(args.java), "-Xcheck:jni", "-XX:+PrintCompilation", "-Xms64m", "-Xmx256m",
               "-Djava.awt.headless=true", "-cp", str(args.jar), "RuntimeQualification", str(positive),
               args.major, "AMCL 中文 😀"]
    started = time.monotonic()
    with log.open("wb") as output:
        child = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT)
        try:
            while child.poll() is None:
                # CLI 宿主没有 JNI main 返回事件；这里只在夹具同步检查已全部完成后放行
                # worker，用于验证夹具自身。真正 Destroy 顺序由 native 通道单独证明。
                if (positive / "fixture-pass.txt").exists() and not (positive / "destroy-started.txt").exists():
                    (positive / "destroy-started.txt").write_text("host-fixture-only\n", encoding="utf-8")
                if time.monotonic() - started > 60:
                    raise TimeoutError("host Java fixture did not exit in 60 seconds")
                time.sleep(0.02)
            if child.returncode != 0:
                raise RuntimeError(f"host fixture exit={child.returncode}; see {log}")
        finally:
            if child.poll() is None:
                child.kill()
            child.wait()
    token = f"AMCL-JAVA-QUALIFICATION:1:{args.major}\n"
    for name in ("fixture-pass.txt", "main-thread-ended.txt", "non-daemon.txt", "shutdown-hook.txt"):
        if (positive / name).read_text(encoding="utf-8") != token:
            raise RuntimeError(f"invalid completion marker: {name}")
    text = log.read_text(encoding="utf-8", errors="replace")
    compilations = [line for line in text.splitlines() if "RuntimeQualification::hotLoop" in line]
    if not any(re.search(r"\b4\s+RuntimeQualification::hotLoop", line) for line in compilations):
        raise RuntimeError("hotLoop has no observed tier-4 compilation in the raw host log")
    negative = root / "wrong-major"
    negative.mkdir()
    negative_command = command[:-3] + [str(negative), "8" if args.major != "8" else "17", "AMCL 中文 😀"]
    failure = subprocess.run(negative_command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
    (root / "wrong-major.log").write_bytes(failure.stdout)
    if failure.returncode == 0 or b"wrong candidate VM" not in failure.stdout or (negative / "fixture-pass.txt").exists():
        raise RuntimeError("wrong-major negative control did not fail precisely")
    receipt = {"scope": "host Java fixture only; no OHOS VM or JNI Destroy claim", "command": command,
               "java": str(args.java.resolve()), "javaSha256": hashlib.sha256(args.java.read_bytes()).hexdigest(),
               "jarSha256": hashlib.sha256(args.jar.read_bytes()).hexdigest(), "hostMajor": args.major,
               "normalExit": child.returncode, "wrongMajorExit": failure.returncode,
               "tier4Evidence": compilations, "durationSeconds": round(time.monotonic() - started, 3)}
    (root / "receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(receipt, ensure_ascii=False))


if __name__ == "__main__":
    main()
