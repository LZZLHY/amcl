"""用已知宿主合成一秒报告验证固定边界；不产生或伪造目标录音资格。"""
import argparse
import copy
from datetime import datetime
import importlib.util
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--host-report', type=Path, required=True)
parser.add_argument('--report', type=Path, required=True)
args = parser.parse_args()
spec = importlib.util.spec_from_file_location('startup_verify', Path(__file__).with_name('verify-capture-startup.py'))
helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
original = json.loads(args.host_report.read_text())
assert helper.check_report(original)['signalQualified'] is False
mutations = {
    'old-layout-protocol': lambda value: value.update(protocol='AMCL_CAPTURE_LAYOUT_V1'),
    'old-9600-prefix': lambda value: value['requested'].update(prefixFrames=9600),
    'two-streams': lambda value: value['cases'].append(copy.deepcopy(value['cases'][0])),
    'missing-first-window': lambda value: value['cases'][0]['windows'].pop(0),
    'wrong-energy': lambda value: value['cases'][0]['windows'][0].update(rms=1),
    'actual-normal': lambda value: value['cases'][0]['snapshots'][1].update(fastStatus=0),
    'stop-error': lambda value: next(row for row in value['cases'][0]['calls'] if row['api'] == 'Stop').update(result=-1),
    'not-quiescent': lambda value: value['cases'][0].update(quiescent=False),
    'false-quality-pass': lambda value: value.update(signalQualified=True),
}
cases = []
for name, mutate in mutations.items():
    value = copy.deepcopy(original); mutate(value)
    try:
        helper.check_report(value)
    except ValueError:
        cases.append({'name': name, 'rejected': True})
    else:
        raise AssertionError(name)
# 全零也是有效观测，不能偷加“像声音”的主观阈值；依然没有信号质量资格。
zero = copy.deepcopy(original)
zero['cases'][0]['s16le'].update(peak=0, rms=0)
for window in zero['cases'][0]['windows']:
    window.update(peak=0, rms=0)
assert helper.check_report(zero)['signalQualified'] is False
cases.append({'name': 'zero-amplitude-no-quality-claim', 'acceptedObservationOnly': True})
with args.report.open('x', encoding='utf-8') as output:
    json.dump({'at': datetime.now().astimezone().isoformat(), 'hostOnly': True, 'cases': cases, 'passed': True}, output, indent=2)
    output.write('\n')
print('PASS fixed startup verifier: nine rejection boundaries + zero amplitude observation; no signal quality claim')
