"""实际编译生产 writer，分别核验宿主/游戏进程的刷新、硬退出与延迟封账。

只使用独立临时目录。普通写入与读取实时文件，不用日志 stub 冒充持久化；
不会覆盖历史审查结果，输出失败断言或 JSON 供本轮证据留档。
"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import json
import os
import subprocess
import tempfile
from lib.host_cpp import compile_cpp

root = Path(__file__).resolve().parent.parent
source = root / 'entry/src/main/cpp/tests/host/native_log_durability_test.cpp'
results = {}
with workspace_temporary_directory(prefix='amcl-log-durability-') as directory:
    work = Path(directory)
    binary = work / ('probe.exe' if os.name == 'nt' else 'probe')
    compile_cpp(source, binary, [source.parent / 'logging_stubs'], ['AMCL_DIAGNOSTICS_MASK=0'])
    for owner in ['host', 'game']:
        for mode in ['normal', 'hard-exit', 'close-before-flush']:
            key = owner + '/' + mode
            case = work / owner / mode
            run = subprocess.run([str(binary), case.as_posix(), mode + ('-game' if owner == 'game' else '')],
                                 capture_output=True, text=True, check=True, timeout=20)
            if mode == 'hard-exit':
                file = case / ('logs/ledger/1789050000000/launcher/launcher-' + owner + '.log')
                result = {'ledgerContains': 'SCOPED_RENDER_FAILURE' in file.read_text(encoding='utf-8')}
            else:
                result = json.loads(run.stdout)
            if mode == 'normal':
                assert result['globalAfterFlush'] and result['ledgerAfterFlush'] and result['ledgerAfterClose']
                assert result['unscopedInGlobal'] and not result['unscopedInLedger']
            else:
                assert result['ledgerContains']
            results[key] = result
print(json.dumps(results, indent=2))
print('PASS host/game production writer: ledger flush, abrupt exit after flush, deferred close')
