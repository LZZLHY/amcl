"""编译生产功能探针与边界故障测试；不使用真实GPU，也不将fixture阳性当成设备能力。"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import os
import runpy
import subprocess
import sys
import tempfile
root = Path(__file__).resolve().parent.parent
if os.name == 'nt':
    script = subprocess.check_output(['wsl', '-d', 'Ubuntu', '--exec', 'wslpath', '-a', Path(__file__).resolve().as_posix()], text=True).strip()
    subprocess.run(['wsl', '-d', 'Ubuntu', '--exec', 'python3', script], check=True, timeout=150)
    sys.exit(0)
with workspace_temporary_directory(prefix='amcl-feature-test-') as temp:
    # 将真实 GLFW typed 报告器接在 GLES operation 后，覆盖下层先置 fatal 的调用顺序。
    # 只抽取生产函数，不复制首因判断；外部头文件是本次宿主测试的临时编译输入。
    extract = runpy.run_path(str(root/'scripts/generate-desktop-review-tests.py'))['function']
    report = extract((root/'entry/src/main/cpp/glfw/glfw_egl.cpp').read_text(encoding='utf-8'), 'report')
    report_header = Path(temp)/'typed-report.h'
    report_header.write_text(report, encoding='utf-8')
    for name in ['graphics_features_test', 'graphics_context_resources_test']:
        binary = str(Path(temp) / name)
        definitions = [f'-DAMCL_TYPED_REPORT_TEST_HEADER="{report_header}"'] if name == 'graphics_context_resources_test' else []
        subprocess.run(['g++', '-std=c++17', '-Wall', '-Wextra', '-Werror', '-pthread',
            *definitions, '-I'+str(root/'prebuilt/khronos-egl-headers'), str(root/('entry/src/main/cpp/tests/host/'+name+'.cpp')), '-o', binary], check=True, timeout=90)
        subprocess.run([binary], check=True, timeout=30)
    # 恢复错误的“core 返回后读取 fatal”条件，同一真实 GLES 链必须在首次 lost 上失败。
    core = (root/'entry/src/main/cpp/platform/graphics_egl_context.cpp').read_text(encoding='utf-8')
    guard = 'if (!wasFatal) s.lastFailure = failure;'
    assert core.count(guard) == 1, 'first-cause guard changed; update its negative control explicitly'
    negative = Path(temp)/'old-first-cause.cpp'
    negative.write_text(core.replace(guard, '(void)wasFatal; if (!s.contextLostFatal) s.lastFailure = failure;'), encoding='utf-8')
    binary = str(Path(temp)/'old-first-cause')
    subprocess.run(['g++', '-std=c++17', '-Wall', '-Wextra', '-Werror', '-pthread',
        f'-DAMCL_TYPED_REPORT_TEST_HEADER="{report_header}"', f'-DAMCL_EGL_CONTEXT_TEST_HEADER="{negative}"',
        '-I'+str(root/'entry/src/main/cpp/platform'), '-I'+str(root/'prebuilt/khronos-egl-headers'),
        str(root/'entry/src/main/cpp/tests/host/graphics_context_resources_test.cpp'), '-o', binary], check=True, timeout=90)
    rejected = subprocess.run([binary], capture_output=True, text=True, timeout=30)
    assert rejected.returncode != 0 and 's.lastFailure.driverFailure == 1' in rejected.stderr, rejected
    print('GLES first-cause chain PASS: actual GL4ES/MobileGlues suspend/attach operations through GLFW typed report; old post-core fatal guard rejected')
