"""仅以宿主报告做少量验收器损坏反例，不冒充HAP部署或目标NCP资格。"""
import argparse
import copy
from datetime import datetime
import importlib.util
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--host-report', required=True, type=Path)
parser.add_argument('--report', required=True, type=Path)
args = parser.parse_args()
spec = importlib.util.spec_from_file_location('native_temp_verify', Path(__file__).with_name('verify-device.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
original = json.loads(args.host_report.read_text())
pid, nonce = original['observation']['pid'], original['observation']['nonce']
assert module.verify_observation(original, pid, nonce)['privateRootOsPreconditionsObserved']
cases = []
for name, mutate in (
    ('wrong-pid', lambda report: report['observation'].update(pid=pid + 1)),
    ('false-cross-vm-claim', lambda report: report['observation'].update(crossVmAttachQualified=True)),
    ('deadline-exceeded', lambda report: report['observation'].update(deadlineExceeded=True)),
):
    report = copy.deepcopy(original); mutate(report)
    try:
        module.verify_observation(report, pid, nonce)
    except ValueError:
        cases.append({'name': name, 'rejected': True})
    else:
        raise AssertionError(name)
for name, mutate in (
    ('cleanup-incomplete', lambda root: root.update(cleanupComplete=False)),
    ('peer-pid-mismatch', lambda root: root['peer'].update(pid=pid + 1)),
    ('missing-munmap', lambda root: root['calls'].__setitem__(slice(None), [row for row in root['calls'] if row['operation'] != 'munmap-read'])),
):
    report = copy.deepcopy(original); mutate(report['observation']['sandbox'])
    assert not module.verify_observation(report, pid, nonce)['privateRootOsPreconditionsObserved']
    cases.append({'name': name, 'qualificationDenied': True})
report = copy.deepcopy(original)
report['observation']['sandbox']['rootMetadata']['mode'] = 0o770
assert module.verify_observation(report, pid, nonce)['privateRootOsPreconditionsObserved']
cases.append({'name': 'same-app-parent-mode-0770-not-rejected', 'accepted': True})
receipt = {'at': datetime.now().astimezone().isoformat(), 'hostSyntheticMetadataOnly': True,
           'hostReportSha256': module.digest(args.host_report), 'cases': cases, 'passed': True}
with args.report.open('x', encoding='utf-8') as output:
    json.dump(receipt, output, indent=2)
    output.write('\n')
print('PASS seven verifier boundary checks; no target identity was fabricated')
