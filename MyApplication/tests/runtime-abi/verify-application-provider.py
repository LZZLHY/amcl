"""验证重建 provider 保留 SDK 的全部可解析导出，并仅增加受控的失败可见 API。"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'docker/scripts'))
from package_runtime import elf_facts

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--original', type=Path, required=True)
parser.add_argument('--candidate', type=Path, required=True)
parser.add_argument('--receipt', type=Path, required=True)
parser.add_argument('--unstripped', type=Path, help='same build debug original retained outside HAP')
args = parser.parse_args()
old_bytes, new_bytes = args.original.read_bytes(), args.candidate.read_bytes()
old, new = elf_facts(old_bytes), elf_facts(new_bytes)
missing = sorted(set(old['resolvableExports']) - set(new['resolvableExports']))
extra = sorted(set(new['resolvableExports']) - set(old['resolvableExports']))
if missing or extra != ['amcl_unwind_register_image', 'amcl_unwind_unregister_image']:
    raise ValueError('ABI export surface changed unexpectedly: ' + repr({'missing': missing, 'extra': extra}))
if old['needed'] != new['needed']:
    raise ValueError('Provider dependency closure changed')
receipt = {'schemaVersion': 1, 'originalSha256': hashlib.sha256(old_bytes).hexdigest(),
           'candidateSha256': hashlib.sha256(new_bytes).hexdigest(), 'missingExports': missing,
           'candidateBytes': len(new_bytes), 'additionalExports': extra,
           'needed': new['needed'], 'qualification': 'export-surface-only'}
if args.unstripped:
    debug = args.unstripped.read_bytes()
    if set(elf_facts(debug)['resolvableExports']) != set(new['resolvableExports']):
        raise ValueError('Stripping changed runtime export surface')
    receipt['unstrippedSha256'] = hashlib.sha256(debug).hexdigest()
args.receipt.write_text(json.dumps(receipt, indent=2) + '\n')
print('PASS application ABI export surface; runtime/loader qualification remains separate')
