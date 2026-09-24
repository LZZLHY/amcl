"""执行生产失败纯核心及实际 TLS/clear/get/record，核验 wire 与同步入口接线。

生产快照源码从 mc_launcher.cpp 按声明边界提取，不在夹具复制实现。动态测试替换的
仅是进程身份、活动图形计划和 JVM 状态；NAPI 参数校验/页面调用顺序另作静态接线
断言，不能把这些断言写成在 HarmonyOS NAPI 上执行过的集成测试。
"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import json
import os
import re
import subprocess
import tempfile
from lib.host_cpp import compile_cpp

root = Path(__file__).resolve().parent.parent
native_source = (root / 'entry/src/main/cpp/jvm/mc_launcher.cpp').read_text(encoding='utf-8')
napi_source = (root / 'entry/src/main/cpp/napi/napi_mc.cpp').read_text(encoding='utf-8')
page_source = (root / 'entry/src/main/ets/pages/McGamePage.ets').read_text(encoding='utf-8')


def actual_function(source, name):
    """按现有顶层函数闭括号截取；只用于接线量具，不自行生成或改写被测函数。"""
    match = re.search(r'(?m)^[^\n]*\b' + re.escape(name) + r'\([^;]*?\{[\s\S]*?\n\}', source)
    assert match is not None, 'missing production function: ' + name
    return match.group(0)


def verify_wiring():
    """检查真实入口的清空时机、同步取值以及每个已记录失败与紧随返回码的一致性。"""
    for name in ['McLaunchWithProfile', 'McLaunchWithProfileV2']:
        body = actual_function(napi_source, name)
        assert body.index('mcClearGraphicsLaunchFailure();') < body.index('napi_get_cb_info('), name
    getter = actual_function(napi_source, 'McGetGraphicsLaunchFailure')
    assert 'WrapStringResult(env, mcGetGraphicsLaunchFailure())' in getter
    assert 'NAPI_FUNC("mcGetGraphicsLaunchFailure", McGetGraphicsLaunchFailure)' in napi_source

    launch = actual_function(native_source, 'launchWithProfileImpl')
    assert launch.index('mcClearGraphicsLaunchFailure();') < launch.index('if ('), 'clear before all native exits'
    records = list(re.finditer(r'\brecordGraphicsLaunchFailure\((-\d+),', launch))
    assert records, 'record/return positive control'
    for index, record in enumerate(records):
        # 只认可该 record 后的第一个 return；中途出现另一 record 说明解析边界不再可靠。
        returned = re.search(r'\breturn\s+(-\d+)\s*;', launch[record.end():])
        assert returned is not None, 'record without a literal failure return'
        assert int(record.group(1)) == int(returned.group(1)), 'typed rc differs from actual return'
        if index + 1 < len(records):
            assert record.end() + returned.end() < records[index + 1].start(), 'record pair has no own return'

    call_at = page_source.index('let rc = testNapi.mcLaunchWithProfileV2(')
    read_at = page_source.index('parseGraphicsLaunchFailure(testNapi.mcGetGraphicsLaunchFailure(), rc)', call_at)
    # 去注释后检查真正的语句，文档中的 await 一词不能形成假阳性。
    sequence = re.sub(r'/\*[\s\S]*?\*/|//[^\n]*', '', page_source[call_at:read_at])
    assert not re.search(r'\bawait\b|\bsetTimeout\s*\(|\.then\s*\(', sequence), 'snapshot read crosses async boundary'
    declaration = (root / 'entry/src/main/cpp/types/libentry/index.d.ts').read_text(encoding='utf-8')
    kept = (root / 'entry/obfuscation-rules.txt').read_text(encoding='utf-8').splitlines()
    assert 'export const mcGetGraphicsLaunchFailure: () => string;' in declaration
    assert 'mcGetGraphicsLaunchFailure: typeof mcGetGraphicsLaunchFailure;' in declaration
    assert 'mcGetGraphicsLaunchFailure' in kept
    return len(records)


def require_wire(wire, rc, stage, code, profile, restart):
    """逐字段严格核验生产 getter 输出；schema 和 rc 都必须来自这次实际记录。"""
    assert wire == {'schemaVersion': 1, 'returnCode': rc, 'stage': stage, 'code': code,
                     'profile': profile, 'restartRequired': restart, 'diagnosticInjected': False}, wire


record_count = verify_wiring()
with workspace_temporary_directory(prefix='amcl-graphics-failure-') as directory:
    binary = Path(directory) / ('failure.exe' if os.name == 'nt' else 'failure')
    compile_cpp(root / 'entry/src/main/cpp/tests/host/graphics_launch_failure_test.cpp', binary)
    output = subprocess.check_output([str(binary)], timeout=20).decode('utf-8')
    result = json.loads(output)
    assert result == {'schemaVersion': 1, 'returnCode': -5, 'stage': 'plan',
                      'code': 'quote"\\\n\r\t\x01', 'profile': '坏计划', 'restartRequired': False, 'diagnosticInjected': False}

    # 提取声明不要求它已经使用 thread_local；若被误改为全局，动态两线程反例必须失败。
    declaration = re.search(r'(?m)^static[^\n]*\bg_graphicsLaunchFailure\s*;', native_source)
    assert declaration is not None, 'production failure storage boundary missing'
    stop = native_source.index('static std::atomic<bool> g_mcRunning', declaration.start())
    production = native_source[declaration.start():stop]
    for name in ['mcClearGraphicsLaunchFailure', 'mcGetGraphicsLaunchFailure', 'recordGraphicsLaunchFailure']:
        actual_function(production, name)
    template = (root / 'entry/src/main/cpp/tests/host/graphics_launch_failure_snapshot.cpp.in').read_text(encoding='utf-8')
    marker = '@AMCL_PRODUCTION_FAILURE_SNAPSHOT@'
    assert template.count(marker) == 1
    snapshot_source = Path(directory) / 'snapshot.cpp'
    snapshot_source.write_text(template.replace(marker, production), encoding='utf-8')
    snapshot_binary = Path(directory) / ('snapshot.exe' if os.name == 'nt' else 'snapshot')
    compile_cpp(snapshot_source, snapshot_binary, includes=[root / 'entry/src/main/cpp/jvm'])
    lines = subprocess.check_output([str(snapshot_binary)], timeout=20).decode('utf-8').splitlines()
    snapshots = {}
    for line in lines:
        label, wire = line.split('\t', 1)
        assert label not in snapshots, 'duplicate snapshot case: ' + label
        snapshots[label] = json.loads(wire)
    for label in ['cold', 'clear', 'next-attempt', 'changed-pid', 'changed-pid-cleared', 'thread-b-cold']:
        assert snapshots[label] == {}, (label, snapshots[label])
    for rc in [-1, -2, -5, -6, -7]:
        require_wire(snapshots['rc' + str(rc)], rc, 'runtime', 'rc-probe', 'nativegl', False)
    for facts in range(8):
        require_wire(snapshots['state' + str(facts)], -5, 'bootstrap', 'state-probe',
                     'mobileglues' if facts & 1 else '', facts != 0)
    require_wire(snapshots['current-attempt'], -5, 'plan', 'current-attempt', 'mobileglues', False)
    require_wire(snapshots['changed-pid-recorded'], -6, 'preference', 'new-process', 'mobilegl', False)
    require_wire(snapshots['thread-a'], -5, 'plan', 'thread-a', 'nativegl', False)
    require_wire(snapshots['thread-b'], -7, 'runtime', 'thread-b', 'mobilegl', True)
    assert snapshots['main-after-threads'] == snapshots['changed-pid-recorded'], 'workers overwrite main snapshot'
    assert len(snapshots) == 24, 'all actual storage scenarios must execute'
print('PASS graphics failure: actual production TLS/clear/get/record, 24 snapshots, 2-thread isolation, PID, schema/rc')
print(f'PASS graphics failure wiring: {record_count} production record/return pairs, NAPI early-clear/export and synchronous page read')
