#!/usr/bin/env python3
"""仅以固定主类/参数运行 class52 ProcessBuilder 宿主资格，全部实物与收据显式外置。"""
import argparse
from datetime import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, data):
    """任务目录必须全新；后续每份证据也以 x 创建，不覆盖已完成结果。"""
    with path.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(data, stream, ensure_ascii=False, indent=2)
        stream.write('\n')


def execute(command, output, timeout=120):
    """前台等待；若内层 Java/native 卡死，只终止本 runner 实际拥有的进程组/树。"""
    started = time.monotonic()
    with output.open('xb') as log:
        child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                 start_new_session=os.name != 'nt')
        try:
            code = child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            if os.name == 'nt':
                subprocess.run(['taskkill', '/PID', str(child.pid), '/T', '/F'], stdout=log, stderr=log, timeout=10, check=False)
            else:
                os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=10)
            raise RuntimeError('owned fixture exceeded outer deadline; evidence retained: ' + str(output))
    return {'command': command, 'exitCode': code, 'elapsedSeconds': time.monotonic() - started, 'logSha256': sha(output)}


def main():
    # 动态导入验证器不在源码目录生成 __pycache__，所有任务输出都走显式外置根。
    sys.dont_write_bytecode = True
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--javac', type=Path, required=True)
    parser.add_argument('--java', type=Path, action='append', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve(); root.mkdir(parents=True, exist_ok=False)
    source = Path(__file__).with_name('JavaProcessQualification.java')
    verifier_file = source.with_name('verify-java-process.py')
    spec = importlib.util.spec_from_file_location('process_verifier', verifier_file)
    verifier = importlib.util.module_from_spec(spec); spec.loader.exec_module(verifier)
    # 显式冻结本轮实际源码；编译只读取冻结副本，后续源演进不追认到旧字节码。
    frozen = root / source.name; frozen.write_bytes(source.read_bytes())
    classes = root / 'classes'; classes.mkdir()
    javac = args.javac.resolve(strict=True)
    compiled = execute([str(javac), '--release', '8', '-encoding', 'UTF-8', '-g', '-d', str(classes), str(frozen)], root / 'compile.log', 60)
    if compiled['exitCode'] != 0:
        raise RuntimeError('class52 compilation failed; see compile.log')
    inventory = []
    for file in sorted(classes.rglob('*.class')):
        data = file.read_bytes()
        if data[:4] != b'\xca\xfe\xba\xbe' or int.from_bytes(data[6:8], 'big') != 52:
            raise RuntimeError('not class52: ' + str(file))
        inventory.append({'path': file.relative_to(classes).as_posix(), 'sha256': sha(file), 'bytes': len(data), 'classMajor': 52})
    outcomes = []
    for index, executable in enumerate(args.java):
        java = executable.resolve(strict=True)
        version = subprocess.check_output([str(java), '-version'], stderr=subprocess.STDOUT, timeout=15).decode('utf-8', errors='replace')
        match = re.search(r'version "(\d+)(?:\.(\d+))?', version)
        if not match:
            raise RuntimeError('unrecognized actual VM version')
        major = match.group(2) if match.group(1) == '1' else match.group(1)
        if major not in ('8', '17', '21', '25'):
            raise RuntimeError('unsupported qualification VM')
        run = root / ('run-' + major + '-' + str(index)); run.mkdir()
        command = [str(java), '-cp', str(classes), 'JavaProcessQualification', str(run), major]
        outcome = execute(command, root / ('java-' + major + '-' + str(index) + '.log'))
        outcome.update({'major': major, 'java': str(java), 'javaSha256': sha(java), 'javaVersion': version})
        save(root / ('invocation-' + str(index) + '.json'), outcome)
        if outcome['exitCode'] != 0:
            raise RuntimeError('host fixture invocation failed')
        evidence = run / 'java-process'
        observed = [verifier.read_regular(evidence / name, limit) for name, limit in
                    [('result.json', 1024 * 1024), ('complete.json', 4096), ('progress.jsonl', 2 * 1024 * 1024)]]
        try:
            qualified = verifier.verify_documents(evidence, *observed, major, 'windows-host' if os.name == 'nt' else 'unix-host', str(run))
        except Exception as error:
            # 留下验证失败那一刻真正读到的字节，而非出错后重读/重算marker掩盖写后变化。
            failure = root / ('verification-read-failure-' + str(index)); failure.mkdir()
            for name, data in zip(('result.json', 'complete.json', 'progress.jsonl'), observed):
                (failure / name).write_bytes(data)
            save(failure / 'read-receipt.json', {'error': str(error), 'evidenceDirectory': str(evidence),
                 'observedSha256': {name: hashlib.sha256(data).hexdigest() for name, data in
                                    zip(('result.json', 'complete.json', 'progress.jsonl'), observed)}})
            raise
        save(root / ('qualified-' + str(index) + '.json'), qualified)
        # 错 major 与重用旧目录均须拒绝，且不能改变先前完整报告的字节。
        original = sha(run / 'java-process/result.json')
        wrong = root / ('wrong-major-' + str(index)); wrong.mkdir()
        negative = execute(command[:-2] + [str(wrong), '8' if major != '8' else '17'], root / ('wrong-major-' + str(index) + '.log'), 15)
        repeated = execute(command, root / ('repeat-' + str(index) + '.log'), 15)
        if negative['exitCode'] == 0 or (wrong / 'java-process').exists() or repeated['exitCode'] == 0 or sha(run / 'java-process/result.json') != original:
            raise RuntimeError('wrong-major or exclusive-output negative control failed')
        outcome['qualified'] = qualified; outcome['wrongMajor'] = negative; outcome['exclusiveOutput'] = repeated; outcomes.append(outcome)
    receipt = {'schemaVersion': 1, 'recordedAt': datetime.now().astimezone().isoformat(), 'scope': 'host only; no OHOS qualification',
               'sourceSha256': sha(frozen), 'verifierSha256': sha(verifier_file), 'runnerSha256': sha(Path(__file__)),
               'javacSha256': sha(javac), 'compile': compiled, 'classes': inventory, 'runs': outcomes}
    save(root / 'host-receipt.json', receipt)
    print(json.dumps({'receipt': str(root / 'host-receipt.json'), 'sha256': sha(root / 'host-receipt.json'),
                      'passedMajors': [row['major'] for row in outcomes]}, ensure_ascii=False))


if __name__ == '__main__':
    main()
