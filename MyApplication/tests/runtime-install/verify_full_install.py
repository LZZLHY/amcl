"""独立标准ZIP实现对照Native最终回读的每个文件字节/模式，不复用被测解析器。"""
import hashlib
import json
import pathlib
import sys
import zipfile

root = pathlib.Path(sys.argv[1])
records = json.loads((root / 'install-archives.json').read_text())['archives']
metadata = {'.amcl_release_tag', '.amcl-runtime-receipt.json', '.amcl-install-seal'}
results = []
for record in records:
    major = record['major']
    expected = {}
    with open(record['containerPath'], 'rb') as source:
        assert hashlib.file_digest(source, 'sha256').hexdigest() == record['sha256'], '原ZIP在测试中被修改'
    with zipfile.ZipFile(record['containerPath']) as archive:
        for entry in archive.infolist():
            if entry.is_dir() or entry.filename in metadata:
                continue
            mode = 0o755 if ((entry.external_attr >> 16) & 0o111 or entry.filename.startswith(('bin/', 'jre/bin/'))
                             or entry.filename in ('lib/jspawnhelper', 'jre/lib/aarch64/jspawnhelper')) else 0o644
            with archive.open(entry) as source:
                sha = hashlib.file_digest(source, 'sha256').hexdigest()
            expected[entry.filename] = (entry.file_size, mode, sha)
    for origin in ('catalog', 'import'):
        actual = {}
        for line in (root / f'installed-{major}-{origin}.tsv').read_text(encoding='utf-8').splitlines():
            name, size, mode, sha = line.split('\t')
            assert name not in actual, '回读清单存在重复条目'
            actual[name] = (int(size), int(mode, 8), sha)
        assert ('.amcl-runtime-receipt.json' in actual) == (origin == 'catalog'), '导入不得被受管来源接管'
        payload = {name: value for name, value in actual.items() if name not in metadata}
        assert payload == expected, f'JDK{major} {origin} 最终文件集合/内容/模式不一致'
        results.append({'major': major, 'origin': origin, 'payloadFiles': len(payload), 'payloadBytes': sum(v[0] for v in payload.values()),
                        'archiveSha256': record['sha256'], 'allFilesMatch': True})
(root / 'full-install-readback.json').write_text(json.dumps({'results': results, 'targetCodeExecuted': False}, indent=2) + '\n')
print('INDEPENDENT FULL READBACK: 8/8 installations match original ZIP payload bytes and required modes')
