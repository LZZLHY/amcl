"""执行现役MobileGL入口与实际原子资格门，GPU执行器仅用确定性暂停边界替换。
同时移除资格判断做反控，证明并发执行会被测试发现；所有变体只写临时文件。
"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import importlib.util
import os
import subprocess
import tempfile
from lib.host_cpp import compile_cpp

root=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('extract',root/'scripts/generate-desktop-review-tests.py')
extract=importlib.util.module_from_spec(spec);spec.loader.exec_module(extract)
driver=(root/'entry/src/main/cpp/platform/mobilegl_capability_driver.cpp').read_text(encoding='utf-8')
entry=extract.block(driver,driver.index('MobileGlProbeReport ProbeMobileGlCapability('))
code=(root/'entry/src/main/cpp/tests/host/graphics_probe_gate.cpp.in').read_text(encoding='utf-8')
code=code.replace('@ROOT@',root.as_posix()).replace('@ENTRY@',entry)
with workspace_temporary_directory(prefix='amcl-probe-gate-') as temporary:
    source=Path(temporary)/'gate.cpp';binary=Path(temporary)/('gate.exe' if os.name=='nt' else 'gate')
    source.write_text(code,encoding='utf-8');compile_cpp(source,binary)
    subprocess.run([str(binary)],check=True,timeout=20)
    gate='if (!lease.entered())'
    if code.count(gate)!=1:raise RuntimeError('gate shape changed; inspect negative control')
    source.write_text(code.replace(gate,'if (false)'),encoding='utf-8');compile_cpp(source,binary)
    bad=subprocess.run([str(binary)],capture_output=True,text=True,timeout=20)
    if bad.returncode==0 or 'mobilegl_probe_busy' not in bad.stderr:raise RuntimeError('missing-gate negative control not detected')
    print('PASS: concurrent provider-entry negative control rejected')
