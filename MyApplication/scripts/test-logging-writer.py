"""执行真实生产 writer 的并发/完整性回归。Windows 自动定位 MSVC。"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory, workspace_path
from pathlib import Path
import json
import os
import subprocess
import tempfile
import shutil

from lib.host_cpp import compile_cpp

repo = Path(__file__).resolve().parents[1]
source = repo / 'entry/src/main/cpp/tests/host/logging_writer_test.cpp'
with workspace_temporary_directory(prefix='amcl-logging-writer-') as temporary:
    out = Path(temporary)
    exe = out / ('writer.exe' if os.name == 'nt' else 'writer')
    compile_cpp(source, exe, [source.parent / 'logging_stubs'], ['AMCL_DIAGNOSTICS_MASK=0'])
    results = []
    for mode in ['utc-time', 'reservation', 'wrap', 'prepublished-wakeup', 'idle-wakeup',
                 'producer-disk-isolation', 'begin-disk-isolation', 'scope-generation', 'scope-counters', 'fork-scope-reset',
                 'normal-exit', 'normal-exit-reinit',
                 'retention', 'flush', 'close', 'failed-open', 'global-recovery', 'long-message-budget', 'routing', 'external-sink']:
        run = subprocess.run([str(exe), str(out / mode).replace('\\', '/'), mode], capture_output=True, text=True, timeout=20)
        valid = run.returncode == 0
        if mode in ('normal-exit', 'normal-exit-reinit') and valid:
            # 必须在子进程正常退出后读真实文件，不能用退出前的PASS或旧全局日志推定scope已封存。
            case = out / mode
            valid = 'LAST_PENDING_PROCESS_LINE' in (case / 'amcl_launcher.log').read_text(encoding='utf-8') \
                and 'LAST_PENDING_PROCESS_LINE' in (case / 'ledger/launcher/launcher-host.log').read_text(encoding='utf-8') \
                and json.loads((case / 'ledger/capture-host.json').read_text(encoding='utf-8'))['sealed'] is True
        results.append({'case': mode, 'passed': valid, 'exitCode': run.returncode, 'output': run.stdout + run.stderr})

    # 编译真实生产函数的两个单点变异：撤回hook必须命中显式退出断言；注册失败不能创建thread。
    # 只替换平台注册表达式，call_once、初始化、drain、join和原验收均执行真实实现。
    implementation = repo / 'entry/src/main/cpp/utils/amcl_log.cpp'
    implementation_text = implementation.read_text(encoding='utf-8')
    harness_text = source.read_text(encoding='utf-8')
    registration = 'std::atexit(amclLogShutdown)'
    inclusion = '#include "../../utils/amcl_log.cpp"'
    if implementation_text.count(registration) != 1 or harness_text.count(inclusion) != 1:
        raise RuntimeError('Process exit hook withdrawal anchor must be unique')
    for name, expression, mode in [('exit-hook-withdrawal', '0', 'normal-exit'),
                                    ('exit-registration-failure', '1', 'exit-registration-failure')]:
        production = out / (name + '-production.cpp')
        production.write_text(implementation_text.replace(registration, expression), encoding='utf-8')
        harness = out / (name + '-test.cpp')
        harness.write_text(harness_text.replace(inclusion, '#include "' + production.as_posix() + '"'), encoding='utf-8')
        # Linux可执行文件无.exe后缀，仍须与同名场景数据目录分开，才能真正命中退出反控。
        binary = out / (name + '-bin' + ('.exe' if os.name == 'nt' else ''))
        compile_cpp(harness, binary, [source.parent / 'logging_stubs', source.parent, implementation.parent], ['AMCL_DIAGNOSTICS_MASK=0'])
        run = subprocess.run([str(binary), (out / name).as_posix(), mode], capture_output=True, text=True, timeout=20)
        valid = run.returncode == 2 and 'EXIT_HOOK_ASSERT: writer not retired' in run.stderr \
            if name == 'exit-hook-withdrawal' else run.returncode == 0
        results.append({'case': name, 'passed': valid, 'exitCode': run.returncode, 'binary': binary.name,
                        'output': run.stdout + run.stderr})
    print(json.dumps(results, ensure_ascii=False, indent=2))
    # 成功仅保留调用者保存的小型JSON收据。失败先复制实际失败场景与本轮二进制，
    # 再让context回收可再生的其余夹具，避免失败原件随临时目录退出而一起消失。
    failed = [result for result in results if not result['passed']]
    if failed:
        preserved = workspace_path('run', 'logging-writer-failure')
        preserved.mkdir(parents=True, exist_ok=False)
        shutil.copy2(exe, preserved / exe.name)
        for result in failed:
            if result.get('binary'):
                shutil.copy2(out / result['binary'], preserved / result['binary'])
            case = out / result['case']
            if case.is_dir():
                shutil.copytree(case, preserved / result['case'])
        (preserved / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding='utf-8')
        print('FAILED writer evidence preserved at ' + str(preserved))
    raise SystemExit(1 if failed else 0)
