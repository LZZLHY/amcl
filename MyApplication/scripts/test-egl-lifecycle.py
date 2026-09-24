"""编译并执行生产 GLES 生命周期和逐字抽取的 GLFW current/TLS/swap 回归。

临时目录仅保存宿主产物；不访问 GPU、设备或 HAP。编译器缺失、生成失败、正例失败
都会阻断调用方。SDL 补丁全量校验由原测试负责，这个入口不声称验证了 SDL。
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
from lib.host_cpp import compile_cpp


root = Path(__file__).resolve().parent.parent
host = root / 'entry/src/main/cpp/tests/host'
suffix = '.exe' if os.name == 'nt' else ''
with tempfile.TemporaryDirectory(prefix='amcl-egl-lifecycle-') as directory:
    output = Path(directory)
    binary = output / ('core' + suffix)
    compile_cpp(host / 'gles_egl_core_test.cpp', binary, includes=[root / 'prebuilt/khronos-egl-headers'])
    subprocess.run([str(binary)], check=True, timeout=30)
    subprocess.run([sys.executable, str(root / 'scripts/generate-desktop-review-tests.py'),
                    '--glfw-context-only', '--out', str(output)], check=True, timeout=30)
    generated = output / 'glfw_context.cpp'
    for native_only in [0, 1]:
        binary = output / ('glfw-' + str(native_only) + suffix)
        compile_cpp(generated, binary, defines=['AMCL_NATIVE_DESKTOP_ONLY=' + str(native_only)])
        subprocess.run([str(binary)], check=True, timeout=30)
    # 反向对照恢复原先“只保留 nativegl 停车 TLS”的条件，必须被同一行为用例击穿。
    # 改写的仅是临时产物，仓库生产代码不变，也不拿故障变体的失败冒充原实现通过。
    text = generated.read_text(encoding='utf-8')
    condition = 'if (ownedHere && window->context != EGL_NO_CONTEXT &&'
    assert text.count(condition) == 1, 'production parking condition changed; update the negative control explicitly'
    negative = output / 'glfw-old-tls.cpp'
    negative.write_text(text.replace(condition,
        'if (amcl::desktop::NativeGlRequested() && ownedHere && window->context != EGL_NO_CONTEXT &&'),
        encoding='utf-8')
    binary = output / ('glfw-old-tls' + suffix)
    compile_cpp(negative, binary, defines=['AMCL_NATIVE_DESKTOP_ONLY=0'])
    rejected = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
    assert rejected.returncode != 0 and 'g_threadCurrentContext==&window' in rejected.stderr, rejected
    print('PASS EGL lifecycle: production core and GLFW functions; old GLES TLS regression rejected; SDL/GPU not evaluated')
