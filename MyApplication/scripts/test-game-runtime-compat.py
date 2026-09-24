from pathlib import Path
import json
from classfile_api import jar_api, resolve_member

root = Path(__file__).resolve().parent.parent
api = jar_api(sorted((root / 'prebuilt/lwjgl3/jars').glob('*.jar')))
refs = json.loads((root / 'prebuilt/runtime-compat/mc-1.21.11-lwjgl-api.json').read_text())['references']
assert all(resolve_member(api, ref) for ref in refs)
for owner, name in [('org/lwjgl/stb/STBImageResize', 'nstbir_resize_uint8'),
                    ('org/lwjgl/util/tinyfd/TinyFileDialogs', 'tinyfd_messageBox')]:
    target = next(ref for ref in refs if ref['owner'] == owner and ref['name'] == name)
    candidate = dict(api); node = dict(api[owner]); candidate[owner] = node
    original = node['methods']
    node['methods'] = [m for m in original if not (m['name'] == name and m['descriptor'] == target['descriptor'])]
    assert not resolve_member(candidate, target), 'Missing method must fail'
    node['methods'] = [dict(m, access=m['access'] & ~1) if m['name'] == name and m['descriptor'] == target['descriptor'] else m for m in original]
    assert not resolve_member(candidate, target), 'Private method must not satisfy public API'
    node['methods'] = [dict(m, descriptor=m['descriptor'][:-1] + 'J') if m['name'] == name and m['descriptor'] == target['descriptor'] else m for m in original]
    assert not resolve_member(candidate, target), 'Return descriptor mismatch must fail'
print('[runtime-compat-tests] PASS all frozen consumers; absent/private/wrong-return STB and TinyFD negative controls')
