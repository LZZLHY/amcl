"""独立标准ZIP读取核对完整v7发布后的每个payload文件SHA/大小/mode；不执行目标ELF。"""
import hashlib
import json
import pathlib
import sys
import zipfile

archive, reports = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
expected, actual = {}, {}
metadata = {'.amcl_release_tag', '.amcl-runtime-receipt.json', '.amcl-install-seal'}
with zipfile.ZipFile(archive) as source:
    for entry in source.infolist():
        if entry.is_dir() or entry.filename in metadata:
            continue
        with source.open(entry) as payload:
            digest = hashlib.file_digest(payload, 'sha256').hexdigest()
        mode = 0o755 if (entry.external_attr >> 16) & 0o111 else 0o644
        expected[entry.filename] = [entry.file_size, mode, digest]
for line in (reports / 'installed-v7.tsv').read_text(encoding='utf8').splitlines():
    name, size, mode, sha = line.split('\t')
    assert name not in actual
    if name not in metadata:
        actual[name] = [int(size), int(mode, 8), sha]
assert actual == expected, 'Native实际发布payload与真实v7原ZIP的文件/大小/模式/SHA不同'
result = {'allPayloadsMatch': True, 'payloadFiles': len(expected),
          'payloadBytes': sum(row[0] for row in expected.values()), 'targetElfExecuted': False}
(reports / 'independent-v7-readback.json').write_text(json.dumps(result, indent=2) + '\n')
print('PASS independent complete v7 readback', json.dumps(result), flush=True)
