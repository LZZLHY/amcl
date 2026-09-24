"""执行真实生产 writer 的并发/完整性回归。Windows 自动定位 MSVC。"""
from pathlib import Path
import json
import os
import subprocess
import tempfile

from lib.host_cpp import compile_cpp

repo = Path(__file__).resolve().parents[1]
source = repo / 'entry/src/main/cpp/tests/host/logging_writer_test.cpp'
with tempfile.TemporaryDirectory(prefix='amcl-logging-writer-') as temporary:
    out = Path(temporary)
    exe = out / ('writer.exe' if os.name == 'nt' else 'writer')
    compile_cpp(source, exe, [source.parent / 'logging_stubs'], ['AMCL_DIAGNOSTICS_MASK=0'])
    results = []
    for mode in ['utc-time', 'reservation', 'wrap', 'prepublished-wakeup', 'retention', 'flush', 'close', 'failed-open', 'global-recovery', 'long-message-budget', 'routing', 'external-sink']:
        run = subprocess.run([str(exe), str(out / mode).replace('\\', '/'), mode], capture_output=True, text=True, timeout=20)
        results.append({'case': mode, 'passed': run.returncode == 0, 'output': run.stdout + run.stderr})
    print(json.dumps(results, ensure_ascii=False, indent=2))
    raise SystemExit(0 if all(result['passed'] for result in results) else 1)
