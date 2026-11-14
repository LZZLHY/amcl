"""编译并执行生产二级组状态机；成功清理亲建夹具，失败保留现场，输出由AMCL_RUN_DIR外置。"""
from pathlib import Path
import subprocess
from lib.host_cpp import compile_cpp
from lib.workspace_paths import temporary_directory

ROOT=Path(__file__).resolve().parents[1]
with temporary_directory(prefix='touch-secondary-groups-') as output:
    binary=Path(output)/'secondary.exe'
    compile_cpp(ROOT/'scripts/fixtures/touch-groups/secondary.cpp',binary,includes=[ROOT/'entry/src/main/cpp/platform'])
    subprocess.run([str(binary)],check=True)
