"""比较两版真实 Java 绑定的全部字段/方法描述符，分离调试字节与实际 JNI ABI。

使用 JDK 自带 javap 读取完整私有签名；不加载类、不调用初始化器、不修改绑定。
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile


def main():
    """输出两份原始签名证据和比较回执；任何签名差异都必须由调用者审查。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--javap', type=Path, required=True)
    args = parser.parse_args()
    signatures = {}
    for version in ('5.7.3', '6.0.0'):
        jar = args.root / version / 'original-sherpa-bindings.jar'
        with zipfile.ZipFile(jar) as archive:
            classes = sorted(name[:-6].replace('/', '.') for name in archive.namelist() if name.endswith('.class'))
        result = subprocess.run([str(args.javap), '-p', '-s', '-classpath', str(jar), *classes],
                                check=True, stdout=subprocess.PIPE, text=True, encoding='utf-8')
        signatures[version] = result.stdout.replace('\r\n', '\n')
        (args.root / (version + '-all-abi.txt')).write_text(signatures[version], encoding='utf-8', newline='\n')
    report = {'schemaVersion': 1, 'allFieldsAndMethodsIdentical': signatures['5.7.3'] == signatures['6.0.0'],
              'signatureSha256': {v: hashlib.sha256(s.encode()).hexdigest() for v, s in signatures.items()}}
    (args.root / 'abi-comparison.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8', newline='\n')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
