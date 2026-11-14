#!/usr/bin/env python3
"""以未修改的上游 jtreg 执行对应 JDK 原测试；平台适配不重写测试断言。

每轮独占工作目录，完整保留 .jtr、原日志、命令和实际源码/工具/运行映像身份。
宿主参考与 OHOS 目标分别记账；不能执行真实 bin/java 的平台明确返回 ENV_BLOCKED，
不会偷偷换成宿主 java、Invocation main 模拟或把无用例视作 PASS。
"""
import argparse
from collections import Counter
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT))
from scripts.lib.host_test_lifecycle import HostTestScope
from scripts.lib.workspace_paths import external_output_path
LOCK = json.loads(Path(__file__).with_name('sources.json').read_text(encoding='utf-8'))


def digest(path):
    """流式绑定实际字节；不把目录名或 major 标签当制品身份。"""
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def git(source, *args):
    return subprocess.check_output(['git', '-C', str(source), *args]).decode('utf-8').strip()


def verify_upstream_tree(source, roots=()):
    """直接核 Git blob 原字节，避免跨 Windows/WSL 的 stat 缓存误报代替源码身份。

    不归一化换行、不更新索引、不接受只在忽略表中隐藏的额外测试。Git blob 摘要
    覆盖原长度和正文；元数据只用于定位，任何真实差异仍然立即拒绝。
    """
    rows = subprocess.check_output(['git', '-C', str(source), 'ls-tree', '-rz', 'HEAD', '--', *roots])
    count = 0
    for row in rows.split(b'\0'):
        if not row: continue
        metadata, name = row.split(b'\t', 1)
        mode, kind, oid = metadata.split()
        path = source / name.decode('utf-8')
        if kind != b'blob' or mode not in (b'100644', b'100755') or path.is_symlink() or not path.is_file():
            raise ValueError('上游测试/工具输入类型不符：' + str(path))
        data = path.read_bytes()
        actual = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest().encode()
        if actual != oid:
            raise ValueError('上游原字节已修改：' + str(path))
        count += 1
    if not count: raise ValueError('上游输入集合为空')
    others = git(source, 'ls-files', '--others', '--exclude-standard', '--', *roots)
    if others: raise ValueError('上游目录包含未登记输入：' + others[:1024])
    if roots:
        ignored = git(source, 'ls-files', '--others', '--ignored', '--exclude-standard', '--', *roots)
        if ignored: raise ValueError('上游测试目录包含被忽略的额外输入：' + ignored[:1024])
    return {'files': count, 'gitTreeSha256': hashlib.sha256(rows).hexdigest()}


def save(path, value):
    """只在本轮运行目录原子发布收据；失败原日志和工作目录继续保留。"""
    temporary = path.with_suffix(path.suffix + '.new')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    os.replace(temporary, path)


def execute(command, cwd, log, timeout, env=None, echo=True):
    """前台持续输出，独立截止时间；超时时只终止本轮创建的进程组/进程树。

    不经过 shell 拼接参数，不改变全局 TEMP/TMP。输出线程仅搬运字节，不解释命令；
    子进程和转发线程均结束后才允许调用者关闭亲建夹具。
    """
    options = {'start_new_session': True} if os.name != 'nt' else {}
    process = subprocess.Popen(command, cwd=cwd, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, **options)
    captured = bytearray()
    transfer_error = []
    def forward():
        try:
            with log.open('wb') as stream:
                while chunk := process.stdout.read1(65536):
                    stream.write(chunk)
                    if len(captured) < 1024 * 1024:
                        captured.extend(chunk[:1024 * 1024 - len(captured)])
                    if echo:
                        sys.stdout.write(chunk.decode('utf-8', 'replace'))
                        sys.stdout.flush()
        except BaseException as error:
            transfer_error.append(str(error))
    reader = threading.Thread(target=forward, daemon=True)
    reader.start()
    timed_out = False
    try:
        process.wait(timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        timed_out = True
        if os.name == 'nt':
            subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'], check=False)
        else:
            os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    reader.join(timeout=15)
    if reader.is_alive():
        raise RuntimeError('上游测试子孙仍持有输出句柄；现场保留，不能授予成功')
    process.stdout.close()
    if transfer_error:
        raise RuntimeError('测试输出保存失败：' + '; '.join(transfer_error))
    return {'exitCode': process.returncode, 'timedOut': timed_out,
            'log': str(log), 'logSha256': digest(log)}, captured.decode('utf-8', 'replace')


def java_bin(jdk):
    return jdk / 'bin' / ('java.exe' if os.name == 'nt' else 'java')


def probe_runtime(jdk, major, role, work, output):
    """所有上游框架共用真实 JVM 前置观察；不把宿主 Java 或继承开关冒充目标。"""
    env = dict(os.environ)
    hidden = [name for name in ('JAVA_TOOL_OPTIONS', 'JDK_JAVA_OPTIONS', '_JAVA_OPTIONS') if env.get(name)]
    if hidden: raise ValueError('存在未声明的继承 JVM 配置：' + ', '.join(hidden))
    temporary = work / 'tmp'; temporary.mkdir()
    env.update(TMPDIR=str(temporary), TEMP=str(temporary), TMP=str(temporary))
    identity = {'root': str(jdk), 'javaSha256': digest(java_bin(jdk)),
                'releaseSha256': digest(jdk / 'release'), 'release': (jdk / 'release').read_text()}
    for relative in ('lib/server/libjvm.so', 'jre/lib/aarch64/server/libjvm.so', 'bin/server/jvm.dll'):
        if (jdk / relative).is_file(): identity['vm'] = {'path': relative, 'sha256': digest(jdk / relative)}
    result, text = execute([str(java_bin(jdk)), '-XshowSettings:properties', '-version'], work,
                           output / 'runtime-probe.log', 60, env, echo=False)
    if result['exitCode'] or result['timedOut']:
        return identity, result, env, False
    os_name = re.search(r'^\s*os.name\s*=\s*(.+)$', text, re.M)
    version = re.search(r'^\s*java.version\s*=\s*(.+)$', text, re.M)
    identity['osName'] = os_name.group(1).strip() if os_name else None
    identity['version'] = version.group(1).strip() if version else ''
    observed = '8' if identity['version'].startswith('1.8.') else identity['version'].split('.')[0].split('-')[0]
    if observed != major: raise ValueError('实际 JVM 主版本与选择不一致：' + identity['version'])
    if role == 'ohos-target' and identity['osName'] not in ('OHOS', 'HarmonyOS'):
        raise ValueError('OHOS 目标资格不能使用宿主 JVM')
    print('JVM: ' + str(identity['osName']) + ' / ' + identity['version'] + ' / ' + role, flush=True)
    return identity, result, env, True


def harness_identity(home, receipt_path):
    """核全部 jtreg/JTHarness/TestNG/JUnit/AsmTools jar；缺件、替换或额外件均拒绝。"""
    receipt = json.loads(receipt_path.read_text(encoding='utf-8'))
    if receipt['sourceCommit'] != LOCK['jtreg']['commit']:
        raise ValueError('jtreg 来源与锁定 commit 不同')
    actual = {p.relative_to(home).as_posix(): digest(p) for p in sorted((home / 'lib').glob('*.jar'))}
    if actual != receipt['jars'] or 'lib/jtreg.jar' not in actual:
        raise ValueError('jtreg image 库集合/字节与构建收据不同')
    return {'receiptSha256': digest(receipt_path), 'sourceCommit': receipt['sourceCommit'], 'jars': actual}


def collect_results(work, output):
    """保留原 .jtr 与最后执行状态，FAIL/ERROR/NOT_RUN 都不能被退出码 0 覆盖。"""
    results = []
    for path in sorted(work.rglob('*.jtr')):
        content = path.read_text(encoding='utf-8', errors='replace')
        matches = re.findall(r'^execStatus=(.*)$', content, re.M)
        status = matches[-1] if matches else 'Not run. Missing final execStatus'
        category = ('PASS' if status.startswith('Passed.') else 'FAIL' if status.startswith('Failed.')
                    else 'ERROR' if status.startswith('Error.') else 'NOT_RUN')
        relative = path.relative_to(work)
        destination = output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
        results.append({'test': relative.as_posix(), 'state': category, 'status': status,
                        'sha256': digest(destination)})
    return results


def run(args):
    """运行原始套件。默认 tier1；选定范围原样登记，不把部分测试升级成整个 major 资格。"""
    output = external_output_path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    run_dir = Path(tempfile.mkdtemp(prefix=f'jdk{args.major}-{args.role}-', dir=output))
    scope = HostTestScope('work-', parent=run_dir)
    receipt = {'schemaVersion': 1, 'startedAt': datetime.now().astimezone().isoformat(),
               'role': args.role, 'major': args.major, 'state': 'PREPARING',
               'wholeJdkQualified': False, 'runDirectory': str(run_dir)}
    success = False
    try:
        source, jdk, host = args.source.resolve(), args.jdk.resolve(), args.host_jdk.resolve()
        fixed = json.loads((ROOT / 'prebuilt/jdk/build-inputs.json').read_text())['runtimes'][args.major]
        actual_head = git(source, 'rev-parse', 'HEAD')
        if actual_head != fixed['commit']:
            raise ValueError('测试源码不属于该 major 的锁定上游 commit')
        suites = LOCK['suites'][args.major]
        # 不允许修改或加自写同名测试来取得通过。适配产品 patch 可在 src 内，测试保持上游。
        # 公共 test/lib、jtreg-ext/WhiteBox 也是实际输入，不能只核三个套件入口。
        test_roots = ('test',) if args.major != '8' else ('test', *suites.values())
        receipt['originalTests'] = verify_upstream_tree(source, test_roots)
        # 本入口消费原上游测试及公共测试库，不编译 src。实际测试正文已逐 blob 核验；
        # 不再额外扫描整棵产品源码生成无关 diff，运行映像另按实物/构建收据绑定。
        receipt['source'] = {'root': str(source), 'commit': actual_head,
                             'identityScope': 'original upstream test trees and shared test libraries'}
        receipt['harness'] = harness_identity(args.jtreg.resolve(), args.harness_receipt.resolve())
        receipt['runtime'], receipt['probe'], env, usable = probe_runtime(
            jdk, args.major, args.role, scope.directory, run_dir)
        if not usable:
            receipt['state'] = 'ENV_BLOCKED'; return 2
        selections = args.test or [suites[args.suite] + ':tier1']
        targets = []
        for selection in selections:
            path_part, separator, group = selection.partition(':')
            target = (source / path_part).resolve()
            if not target.is_relative_to(source) or not target.exists():
                raise ValueError('上游测试选择不存在或逃逸：' + selection)
            targets.append(str(target) + (':' + group if separator else ''))
        receipt['selection'] = selections
        command = [str(java_bin(host)), '-jar', str(args.jtreg.resolve() / 'lib/jtreg.jar'),
                   '-testjdk:' + str(jdk), '-w:' + str(scope.directory / 'JTwork'),
                   '-r:' + str(run_dir / 'JTreport'), '-' + args.mode,
                   '-conc:' + str(args.jobs), '-verbose:summary', '-xml']
        if args.native_path:
            command.append('-nativepath:' + str(args.native_path.resolve()))
        command.extend('-javaoption:' + option for option in args.vm_option)
        # 原上游 ProblemList 只在调用者显式选择时使用，并独立记录原摘要。
        receipt['excludeLists'] = []
        for exclude in args.exclude_list:
            file = exclude.resolve()
            if not file.is_relative_to(source): raise ValueError('排除表必须是本锁定上游树内文件')
            receipt['excludeLists'].append({'path': str(file), 'sha256': digest(file)})
            command.append('-exclude:' + str(file))
        command.extend(targets)
        receipt['command'] = command
        receipt['vmOptions'] = args.vm_option
        save(run_dir / 'receipt.json', receipt)
        outcome, _ = execute(command, scope.directory, run_dir / 'jtreg.log', args.timeout, env)
        receipt['execution'] = outcome
        receipt['results'] = collect_results(scope.directory / 'JTwork', run_dir / 'results')
        counts = Counter(item['state'] for item in receipt['results'])
        receipt['counts'] = dict(counts)
        success = bool(counts['PASS']) and len(counts) == 1 and outcome['exitCode'] == 0 and not outcome['timedOut']
        receipt['state'] = 'PASS_SELECTED_TESTS' if success else 'FAILED_OR_INCOMPLETE'
        # 明确这是展开后真正执行的测试集合；requires/平台条件未执行项仍由原 JTreport 保留。
        receipt['coverageClaim'] = 'only recorded original upstream test executions; no whole-JDK claim'
        return 0 if success else 1
    except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
        receipt['state'] = 'HARNESS_OR_ENVIRONMENT_ERROR'
        receipt['error'] = str(error)
        return 2
    finally:
        receipt['finishedAt'] = datetime.now().astimezone().isoformat()
        save(run_dir / 'receipt.json', receipt)
        # 原 .jtr、报告、日志已保存在夹具外；只回收成功轮亲建的可再生 classes/tmp。
        receipt['fixturesRemoved'] = scope.close(success=success)
        save(run_dir / 'receipt.json', receipt)
        print('OPENJDK_UPSTREAM_RECEIPT=' + str(run_dir / 'receipt.json'), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--major', choices=LOCK['suites'], required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--jdk', type=Path, required=True)
    parser.add_argument('--host-jdk', type=Path, required=True)
    parser.add_argument('--jtreg', type=Path, required=True)
    parser.add_argument('--harness-receipt', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--role', choices=('ohos-target', 'host-reference'), default='ohos-target')
    parser.add_argument('--suite', choices=('jdk', 'hotspot', 'langtools'), default='jdk')
    parser.add_argument('--test', action='append', help='原上游相对路径或 group，不复制测试正文')
    parser.add_argument('--mode', choices=('agentvm', 'othervm'), default='agentvm')
    parser.add_argument('--jobs', type=int, default=2)
    parser.add_argument('--timeout', type=int, default=7200)
    parser.add_argument('--vm-option', action='append', default=[])
    parser.add_argument('--exclude-list', action='append', type=Path, default=[])
    parser.add_argument('--native-path', type=Path)
    args = parser.parse_args()
    if args.jobs < 1 or args.timeout < 1: parser.error('jobs/timeout 必须为正数')
    return run(args)


if __name__ == '__main__':
    raise SystemExit(main())
