"""从已验证原件和 javap 证据生成可审查的 Sherpa 精确绑定允许清单。

这不是宽泛版本范围：每个 profile 必须覆盖完整 class 集合。Java ABI 另外保存，
生产启动检查只需读取紧凑的 class 摘要；元数据不能替代实际 class 字节校验。
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile


def sha(data):
    """清单摘要采用固定 UTF-8/二进制字节，不依赖 Windows 换行转换。"""
    return hashlib.sha256(data).hexdigest()


def write(path, record):
    """固定缩进与尾换行，生成件可以精确比较、纳入版本控制并被运行时消费。"""
    path.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')


def main():
    """只处理已验两版原件；任何完整签名差异会阻止共用 native profile。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--inputs', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    comparison = json.loads((args.evidence / 'binding-comparison.json').read_text())
    abi = json.loads((args.evidence / 'abi-comparison.json').read_text())
    if abi['allFieldsAndMethodsIdentical'] is not True:
        raise ValueError('原 Java API 合同不一致，不能签发共库清单')
    args.output.mkdir(parents=True, exist_ok=True)
    classes = {}
    text = (args.evidence / '5.7.3-all-abi.txt').read_text()
    for chunk in text.split('Compiled from ')[1:]:
        header = chunk.splitlines()[1]
        match = re.search(r'\b(?:class|interface|enum)\s+([\w.$]+)', header)
        if not match:
            raise ValueError('无法识别真实 javap class：' + header)
        members = []
        lines = chunk.splitlines()
        for index, line in enumerate(lines):
            if line.strip().startswith('descriptor:'):
                declaration = lines[index - 1].strip()
                members.append({'declaration': declaration, 'descriptor': line.strip()[12:],
                                'kind': 'native' if ' native ' in (' ' + declaration) else
                                'method' if '(' in declaration else 'field'})
        classes[match.group(1).replace('.', '/') + '.class'] = {'declaration': header, 'members': members}
    if len(classes) != len(comparison['inputs'][0]['classes']):
        raise ValueError('完整 ABI class 数量与原字节集合不符')
    abi_record = {'schemaVersion': 1, 'nativeProfile': 'sherpa-onnx-1.13.3-ohos-cpu',
                  'javapAllSha256': abi['signatureSha256']['5.7.3'], 'classes': classes}
    abi_path = args.output / 'java-abi-contract.json'
    write(abi_path, abi_record)
    profiles = []
    for record in comparison['inputs']:
        version = record['modVersion']
        publication = record['publication']
        container = {'kind': 'self'}
        if version == '6.0.0':
            nested_name = 'META-INF/jarjar/sherpa-onnx-v1.13.3.jar'
            with zipfile.ZipFile(args.inputs / publication['filename']) as archive:
                nested = archive.read(nested_name)
                container = {'kind': 'jarjar', 'entry': nested_name, 'sha256': sha(nested), 'size': len(nested)}
        profiles.append({'id': 'verity-' + version, 'nativeProfile': 'sherpa-onnx-1.13.3-ohos-cpu',
            'source': {'project': 'on1Y0osD', 'publicationId': publication['publicationId'],
                       'version': version, 'sha256': publication['sha256'], 'sha512': publication['sha512'],
                       'url': publication['url'], 'size': publication['size']},
            'container': container, 'classSha256': record['classes']})
    write(args.output / 'verified-bindings.json', {'schemaVersion': 1,
        'nativeProfile': 'sherpa-onnx-1.13.3-ohos-cpu',
        'classPrefix': 'com/k2fsa/sherpa/onnx/', 'classCount': len(classes),
        'abiContract': {'file': abi_path.name, 'sha256': sha(abi_path.read_bytes())},
        'profiles': profiles})


if __name__ == '__main__':
    main()
