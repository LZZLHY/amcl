"""核对真实 Verity 整包并提取原 Java 绑定、宿主库和原模型，不重写模组。

5.7.3 的平铺 fat-JAR 与 6.0.0 的 JarJar 使用同一递归阅读器。每个 class、
模型归档和宿主 DLL 都保留独立摘要；比较的是全部原 class 字节，不靠版本名推断 ABI。
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import zipfile


def digest(data):
    """字节摘要用于把提取件准确绑定回整包发布身份。"""
    return hashlib.sha256(data).hexdigest()


def read_entries(archive, result):
    """只递归 JarJar，遇到重复且不同字节的绑定立即拒绝而不选择任意一份。"""
    for name in archive.namelist():
        if name.startswith('META-INF/jarjar/') and name.endswith('.jar') and 'sherpa' in name:
            read_entries(zipfile.ZipFile(io.BytesIO(archive.read(name))), result)
        elif ((name.startswith('com/k2fsa/sherpa/onnx/') and name.endswith('.class')) or
              name.startswith('sherpa-onnx/native/win-x64/') and name.endswith('.dll') or
              name in ('assets/verity/sherpa-model.zip', 'assets/verity/tts/piper.zip')):
            data = archive.read(name)
            if name in result and result[name] != data:
                raise ValueError('发现冲突绑定：' + name)
            result[name] = data


def main():
    """整包 SHA-512 通过后才解压模型；输出始终为显式仓外目录。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    target = args.output.resolve()
    if any((p / '.git').exists() for p in (target, *target.parents)):
        raise ValueError('提取结果必须位于仓库之外')
    target.mkdir(parents=True, exist_ok=True)
    downloads = json.loads((args.inputs / 'downloads.json').read_text())['inputs']
    records = []
    for version in ('5.7.3', '6.0.0'):
        publication = next(x for x in downloads if x.get('modVersion') == version)
        jar = args.inputs / publication['filename']
        with jar.open('rb') as stream:
            actual = hashlib.file_digest(stream, 'sha512').hexdigest()
        if actual != publication['sha512']:
            raise ValueError('整包摘要不匹配：' + version)
        entries = {}
        with zipfile.ZipFile(jar) as archive:
            read_entries(archive, entries)
        root = target / version
        root.mkdir(exist_ok=True)
        classes = {name: digest(data) for name, data in entries.items() if name.endswith('.class')}
        with zipfile.ZipFile(root / 'original-sherpa-bindings.jar', 'w') as archive:
            for name, data in entries.items():
                if name.endswith('.class'):
                    archive.writestr(name, data)
                elif name.endswith('.dll'):
                    dest = root / 'native' / Path(name).name
                    dest.parent.mkdir(exist_ok=True)
                    dest.write_bytes(data)
                elif name.endswith('.zip'):
                    group = 'tts' if name.endswith('piper.zip') else 'asr'
                    with zipfile.ZipFile(io.BytesIO(data)) as model:
                        model.extractall(root / group)
        records.append({'modVersion': version, 'publication': publication, 'classes': classes,
                        'entries': {name: {'sha256': digest(data), 'size': len(data)} for name, data in entries.items()}})
        print(version + ': ' + str(len(classes)) + ' 个原绑定 class 已验证/提取', flush=True)
    same = records[0]['classes'] == records[1]['classes']
    report = {'schemaVersion': 1, 'javaClassesByteIdentical': same, 'inputs': records}
    (target / 'binding-comparison.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8', newline='\n')
    print('两版原 Java 绑定全字节一致：' + str(same), flush=True)


if __name__ == '__main__':
    main()
