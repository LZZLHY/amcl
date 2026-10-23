"""编译真实日志NAPI封账桥，替换宿主不可用的SDK边界验证线程/失败/资源生命周期。

writer真实关闭与原件耐久另由test-native-log-durability.py验证；本测试不据SDK mock
声称HarmonyOS帧或线程调度已实测。SDK头可显式传入，独立克隆/CI不要求维护者目录。
"""
import os
from pathlib import Path
import argparse
import subprocess
import shutil
from lib.host_cpp import compile_cpp
from lib.workspace_paths import temporary_directory

parser = argparse.ArgumentParser()
parser.add_argument('--sdk-include', default=os.environ.get('AMCL_NAPI_SDK_INCLUDE', ''))
args = parser.parse_args()
if not args.sdk_include:
    raise SystemExit('Pass --sdk-include or AMCL_NAPI_SDK_INCLUDE with the actual NAPI SDK headers')
sdk = Path(args.sdk_include)
if not (sdk / 'napi/native_api.h').is_file():
    raise SystemExit('Actual SDK napi/native_api.h is required')
root = Path(__file__).resolve().parents[1]
source = root / 'entry/src/main/cpp/tests/host/napi_ledger_end_async_test.cpp'
with temporary_directory(prefix='amcl-ledger-napi-') as directory:
    binary = Path(directory) / ('probe.exe' if os.name == 'nt' else 'probe')
    # 只复制实际SDK的NAPI ABI头，保留宿主标准库。把整个ARM sysroot放进MSVC /I
    # 会让SDK的stddef/stdint遮住宿主CRT，错误地要求bits/alltypes.h等目标平台内容。
    headers = Path(directory) / 'sdk-napi-headers'
    for name in ['napi/native_api.h', 'napi/common.h', 'node_api.h', 'node_api_types.h',
                 'js_native_api.h', 'js_native_api_types.h', 'info/application_target_sdk_version.h']:
        destination = headers / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(sdk / name, destination)
    # 显式打开发布配置的断言裁剪宏，验收CHECK仍须执行，且有副作用的NAPI请求不能消失。
    includes = [headers, source.parent / 'logging_stubs', source.parent]
    defines = ['AMCL_DIAGNOSTICS_MASK=0', 'NDEBUG']
    compile_cpp(source, binary, includes, defines)
    subprocess.run([str(binary)], check=True, timeout=20)
    # 只改外置夹具副本中的资源守恒预期；编译必须成功，运行必须命中同一CHECK而非偶发崩溃。
    original = source.read_text(encoding='utf-8')
    anchor = 'CHECK(created == deleted);'
    if original.count(anchor) != 1:
        raise RuntimeError('Native async CHECK withdrawal anchor is not unique')
    negative = Path(directory) / 'ledger_async_negative.cpp'
    negative.write_text(original.replace(anchor, 'CHECK(created != deleted);'), encoding='utf-8')
    negative_binary = Path(directory) / ('negative.exe' if os.name == 'nt' else 'negative')
    compile_cpp(negative, negative_binary, includes, defines)
    failed = subprocess.run([str(negative_binary)], capture_output=True, timeout=20)
    if failed.returncode != 2 or b'LEDGER ASYNC CHECK FAIL' not in failed.stderr or b'created != deleted' not in failed.stderr:
        raise RuntimeError('Optimized-macro negative did not execute the intended resource assertion')
    print('PASS actual NAPI async bridge with release assertion macro and compiled CHECK withdrawal')
