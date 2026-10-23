"""使用真实锁定 ZIP/JDK8 验证准备 CLI；不下载，不用假 Java 或 stub 源。

正例证明已有材料只读取复用；负例在真实 ZIP 副本追加字节，必须由正式 SHA 守卫
拒绝且不覆盖损坏缓存。可选真实 JDK21 反控证明不会把默认工具当 JDK8 使用。
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from lib.workspace_paths import external_output_path

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / 'scripts/prepare-lwjgl2-test-inputs.py'


def run(args, output, label, success=True, expected_error=None):
    """每例都执行真实 CLI 子进程，保留日志，区分工具失败和目标 checksum 拒绝。"""
    result = subprocess.run([sys.executable, '-B', str(CLI), *map(str, args)], cwd=ROOT,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=90)
    (output / (label + '.log')).write_text(result.stdout, encoding='utf-8')
    if success:
        if result.returncode:
            raise AssertionError(label + ': ' + result.stdout)
    elif result.returncode == 0 or expected_error not in result.stdout:
        raise AssertionError(label + ': expected exact material failure: ' + result.stdout)
    return result


def main(options):
    """材料参数必须指真实外置输入；回归输出为新目录，拒绝覆盖已有原始证据。"""
    output = external_output_path(options.out)
    if output.exists():
        raise ValueError('Regression output must be a new directory: ' + str(output))
    output.mkdir(parents=True)
    initial_home, initial_path = os.environ.get('JAVA_HOME'), os.environ.get('PATH')
    shared = ['--jdk8', options.jdk8]
    archive = options.inputs / 'lwjgl-2df01dd.zip'
    before = hashlib.sha256(archive.read_bytes()).hexdigest()
    receipt = output / 'reused.json'
    github = output / 'github-output.txt'
    run([*shared, '--inputs-dir', options.inputs, '--offline', '--receipt', receipt,
         '--github-output', github], output, 'reuse')
    result = json.loads(receipt.read_text(encoding='utf-8'))
    assert result['reused'] is True and result['sourceSha256'] == before
    assert result['jdk8'] == str(options.jdk8.resolve())
    assert github.read_text(encoding='utf-8').splitlines() == [
        'inputs=' + str(options.inputs.resolve()), 'jdk8=' + str(options.jdk8.resolve())]
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == before
    print('PASS locked real ZIP/JDK8 reused offline; exact step paths published')
    receipt_before = receipt.read_bytes()
    run([*shared, '--inputs-dir', options.inputs, '--offline', '--receipt', receipt],
        output, 'existing-receipt', False, 'Preparation receipt must be a new file')
    assert receipt.read_bytes() == receipt_before
    print('PASS existing preparation evidence is preserved')

    bad_inputs = output / 'corrupt-cache'; bad_inputs.mkdir()
    bad = bad_inputs / archive.name
    shutil.copy2(archive, bad)
    with bad.open('ab') as stream:
        stream.write(b'AMCL checksum negative control\n')
    bad_sha = hashlib.sha256(bad.read_bytes()).hexdigest()
    # 不加--offline：坏的已存在缓存也必须直接拒绝，不能悄悄再下载把反例洗掉。
    run([*shared, '--inputs-dir', bad_inputs, '--receipt', output / 'bad-receipt.json'],
        output, 'corrupt', False, 'LWJGL2 source checksum mismatch')
    assert hashlib.sha256(bad.read_bytes()).hexdigest() == bad_sha
    assert not (output / 'bad-receipt.json').exists()
    assert not list(bad_inputs.glob('*.part'))
    print('PASS checksum-corrupt real archive rejected without overwrite/download/output success')

    run([*shared, '--inputs-dir', output / 'missing-cache', '--offline', '--receipt', output / 'missing.json'],
        output, 'missing', False, 'Offline preparation requires locked archive')
    run([*shared, '--inputs-dir', ROOT, '--offline', '--receipt', output / 'inside.json'],
        output, 'inside-repository', False, 'Output must be outside the project')
    print('PASS missing offline archive and in-repository output rejected')
    if options.wrong_jdk:
        run(['--jdk8', options.wrong_jdk, '--inputs-dir', options.inputs, '--offline',
             '--receipt', output / 'wrong-jdk.json'], output, 'jdk21', False, 'require JDK8')
        print('PASS real default JDK21 cannot stand in for required JDK8')
    assert (os.environ.get('JAVA_HOME'), os.environ.get('PATH')) == (initial_home, initial_path)
    (output / 'result.json').write_text(json.dumps({'schema': 1, 'sourceSha256': before,
        'inputs': str(options.inputs.resolve()), 'jdk8': str(options.jdk8.resolve()),
        'realJdk21Negative': bool(options.wrong_jdk), 'globalJavaEnvironmentUnchanged': True}, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', type=Path, required=True)
    parser.add_argument('--jdk8', type=Path, required=True)
    parser.add_argument('--wrong-jdk', type=Path, help='可选真实非8 JDK，用实际工具执行版本负控')
    parser.add_argument('--out', type=Path, required=True)
    main(parser.parse_args())
