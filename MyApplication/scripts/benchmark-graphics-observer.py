"""独立进程交错测量生产CPU观测回调on/off/cost；无真实GPU，结果不转换为游戏帧率提升。"""
from pathlib import Path
import argparse
import json
import os
import platform
import statistics
import subprocess
import sys
import tempfile
root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--out', required=True)
args = parser.parse_args()
if os.name == 'nt':
    translate = lambda p: subprocess.check_output(['wsl', '-d', 'Ubuntu', '--exec', 'wslpath', '-a', Path(p).resolve().as_posix()], text=True).strip()
    subprocess.run(['wsl', '-d', 'Ubuntu', '--exec', 'python3', translate(__file__), '--out', translate(args.out)], check=True, timeout=150)
    sys.exit(0)
with tempfile.TemporaryDirectory(prefix='amcl-observer-cost-') as temp:
    binary = str(Path(temp)/'benchmark')
    subprocess.run(['g++', '-O2', '-std=c++17', '-pthread', '-I'+str(root/'prebuilt/khronos-egl-headers'),
        str(root/'entry/src/main/cpp/tests/host/graphics_observation_abi_test.cpp'), '-o', binary], check=True, timeout=90)
    runs = []
    for repeat in range(7):
        for mode in (['off', 'on', 'cost'] if repeat % 2 == 0 else ['cost', 'on', 'off']):
            run = json.loads(subprocess.check_output([binary, mode], text=True, timeout=15))
            assert run['snapshot']['presentCount'] == run['iterations']
            assert run['snapshot']['samplesEnabled'] == (mode != 'off')
            assert run['snapshot']['observerCostEnabled'] == (mode == 'cost')
            runs.append(run)
    medians = {mode: statistics.median(r['elapsedNs']/r['iterations'] for r in runs if r['mode'] == mode) for mode in ['off', 'on', 'cost']}
    report = {'schemaVersion': 1, 'scope': 'host CPU production ABI callbacks; window identity boundary stub; not device/GPU/FPS evidence',
        'host': platform.platform(), 'compiler': subprocess.check_output(['g++', '--version'], text=True).splitlines()[0],
        'optimization': '-O2', 'rounds': 7, 'medianNsPerSwapAndPresent': medians, 'runs': runs}
    out = Path(args.out); out.parent.mkdir(parents=True, exist_ok=True); out.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print('Observer CPU benchmark PASS:', json.dumps(medians), '; host-only scope; report=', out)
