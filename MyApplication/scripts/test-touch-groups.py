"""编译并执行真实组事务头；产物沿工作区外置契约，不在项目内生成可执行文件。"""
from pathlib import Path
import subprocess
from lib.host_cpp import compile_cpp
from lib.workspace_paths import temporary_directory

ROOT = Path(__file__).resolve().parents[1]
with temporary_directory(prefix='touch-groups-') as directory:
    binary = Path(directory) / 'groups.exe'
    compile_cpp(ROOT / 'scripts/fixtures/touch-groups/state.cpp', binary,
                includes=[ROOT / 'entry/src/main/cpp/platform'])
    subprocess.run([str(binary)], check=True)
    # 只撤回生产头的同方案显隐保留条件；负控须编译成功并命中同方案重发布的指定行为失败。
    header=(ROOT / 'entry/src/main/cpp/platform/touch_group_state.h').read_text(encoding='utf-8')
    needle='if (next.profile == definition_.profile) {'
    assert header.count(needle)==1
    (Path(directory)/'touch_group_state.h').write_text(header.replace(needle,'if (false) {'),encoding='utf-8')
    negative=Path(directory)/'groups-withdrawn.exe'
    compile_cpp(ROOT / 'scripts/fixtures/touch-groups/state.cpp',negative,
                includes=[Path(directory),ROOT / 'entry/src/main/cpp/platform'])
    rejected=subprocess.run([str(negative)],capture_output=True,text=True)
    assert rejected.returncode==91 and 'same-profile publication lost group mask' in rejected.stderr
    print('PASS compiled withdrawal: same-profile publication must preserve runtime group mask')
