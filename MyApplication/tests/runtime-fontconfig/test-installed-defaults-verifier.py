"""以宿主边界夹具的实物为正例，再篡改单项（保留顶层passed）验证独立细项门禁。"""
import argparse
import copy
import hashlib
import importlib.util
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--host-output', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
spec = importlib.util.spec_from_file_location('font_default_verifier', Path(__file__).with_name('verify-installed-defaults.py'))
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
raw = (args.host_output / 'cases/good/report/font-defaults-report.json').read_bytes()
good = json.loads(raw)
fc = hashlib.sha256((args.host_output / 'libfontconfig.so').read_bytes()).hexdigest()
ft = hashlib.sha256((args.host_output / 'libfreetype.so').read_bytes()).hexdigest()
root = '/output/font-installed-boundaries/cases/good/runtime'
assert module.verify(good, '17', root, fc, ft)['defaultCacheQualified']
cases = [('wrong FC', lambda r: r['observation']['fontconfigFile'].update(sha256='0' * 64)),
         ('wrong FT origin', lambda r: r['observation'].update(freeTypeOrigin='/system/other/libfreetype.so')),
         ('writable cwd', lambda r: r['observation'].update(readOnlyCwd=False)),
         ('cache file changed', lambda r: r['observation']['cacheAfterWarm'].update(sha256='0' * 64)),
         ('wrong cache path', lambda r: r['observation'].update(cacheFile='/other/cache')),
         ('no cache read proof', lambda r: r['observation'].update(warmUsedLoadOnlyApi=False)),
         ('no cache bytes', lambda r: r['observation']['cacheAfterCold'].update(bytes=0)),
         ('no cached fonts', lambda r: r['observation'].update(cachedFontCount=0)),
         ('slot changed', lambda r: r['observation'].update(runtimeAfterSha256='0' * 64)),
         ('no slot inventory', lambda r: r['observation'].update(runtimeFileCount=0)),
         ('missing Chinese glyph', lambda r: r['observation']['matches'][1].update(covered=False)),
         ('missing match', lambda r: r['observation']['matches'].pop()),
         ('environment leaked', lambda r: r.update(environmentRestored=False)),
         ('NCP overclaim', lambda r: r.update(freshExecQualified=True))]
for label, mutate in cases:
    candidate = copy.deepcopy(good); mutate(candidate)
    result = module.verify(candidate, '17', root, fc, ft)
    assert not result['defaultCacheQualified'] and result['problems'], label
try:
    json.loads('{"passed":false,"passed":true}', object_pairs_hook=module.strict_object)
except ValueError:
    pass
else:
    raise AssertionError('duplicate JSON field accepted')
result = {'passed': True, 'positive': 1, 'negative': len(cases) + 1,
          'hostReportSha256': hashlib.sha256(raw).hexdigest(), 'expectedFixtureFcSha256': fc,
          'expectedFixtureFtSha256': ft, 'scope': 'verifier unit cases over explicitly synthetic host-font fixture; no device/font functionality qualification'}
with args.output.open('x', encoding='utf-8') as output:
    output.write(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
print('PASS installed report verifier:', result['positive'], 'positive;', result['negative'], 'negative')
