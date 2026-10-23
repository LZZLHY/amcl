"""执行生产 GLES 生命周期与逐字抽取的 GLFW 绑定、终局、checked ABI 和创建前置门回归。

临时目录仅保存宿主产物；不访问 GPU、设备或 HAP。编译器缺失、生成失败、正例失败
都会阻断调用方。SDL 补丁全量校验由原测试负责，这个入口不声称验证了 SDL。
"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import os
import runpy
import subprocess
import sys
import tempfile
from lib.host_cpp import compile_cpp


root = Path(__file__).resolve().parent.parent
host = root / 'entry/src/main/cpp/tests/host'
suffix = '.exe' if os.name == 'nt' else ''
with workspace_temporary_directory(prefix='amcl-egl-lifecycle-') as directory:
    output = Path(directory)
    binary = output / ('core' + suffix)
    compile_cpp(host / 'gles_egl_core_test.cpp', binary, includes=[root / 'prebuilt/khronos-egl-headers'])
    subprocess.run([str(binary)], check=True, timeout=30)
    subprocess.run([sys.executable, str(root / 'scripts/generate-desktop-review-tests.py'),
                    '--glfw-context-only', '--out', str(output)], check=True, timeout=30)
    generated = output / 'glfw_context.cpp'
    # 逐字执行 create 在原有窗口/lease/context 路径之前的零分配前缀。测试尾桩只计数
    # “是否越过前置门”；把指针拒绝值 nullptr 机械适配为整型0，不复制生产判断算法。
    extractor = runpy.run_path(str(root / 'scripts/generate-desktop-review-tests.py'))
    source = (root / 'entry/src/main/cpp/glfw/glfw_compat.cpp').read_text(encoding='utf-8')
    create = extractor['function'](source, 'glfwCreateWindow')
    prefix = create[create.index('{') + 1:create.index('    if ((g_hintVisible')]
    assert 'glfwGraphicsRestartRequired()' in prefix and 'new GLFWwindow' not in prefix
    prefix_test = ('static int createTailCalls=0;\nint TestCreatePrefix(){\n' +
                   prefix.replace('return nullptr;', 'return 0;') +
                   '++createTailCalls;return 1;\n}\n')
    # typed runtime 包装层也使用当前生产函数，验证 precise lost 先于通用创建失败交付。
    typed_report = extractor['function']((root / 'entry/src/main/cpp/glfw/glfw_egl.cpp').read_text(encoding='utf-8'), 'report')
    generated.write_text(generated.read_text(encoding='utf-8').replace('int main(){',
        prefix_test + typed_report + '\nint main(){'), encoding='utf-8')
    test_defines = ['AMCL_TEST_CREATE_PREFIX=1']
    for native_only in [0, 1]:
        binary = output / ('glfw-' + str(native_only) + suffix)
        compile_cpp(generated, binary, defines=[*test_defines, 'AMCL_NATIVE_DESKTOP_ONLY=' + str(native_only)])
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
    compile_cpp(negative, binary, defines=[*test_defines, 'AMCL_NATIVE_DESKTOP_ONLY=0'])
    rejected = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
    assert rejected.returncode != 0 and 'g_threadCurrentContext==&window' in rejected.stderr, rejected
    # 禁用唯一终局 helper 模拟原来的“只回调失败”，同一正式场景必须拒绝该故障变体。
    # 仍执行当前生产绑定/释放/交换函数，不另写一份行为模型充当回归验证。
    condition = 'if (error != EGL_CONTEXT_LOST) return false;'
    assert text.count(condition) == 1, 'production terminal guard changed; update the negative control explicitly'
    negative = output / 'glfw-old-context-loss.cpp'
    negative.write_text(text.replace(condition, 'if (true) return false;'), encoding='utf-8')
    binary = output / ('glfw-old-context-loss' + suffix)
    compile_cpp(negative, binary, defines=[*test_defines, 'AMCL_NATIVE_DESKTOP_ONLY=0'])
    rejected = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
    assert rejected.returncode != 0 and 'subject.contextLostFatal==lost' in rejected.stderr, rejected
    # checked ABI 若退回“只看旧 TLS”的方案，绑定失败仍保留旧窗口时会错误返回成功。
    # 反向变体继续执行生产事务，只把结果判据换成旧状态，必须由同一用例拒绝。
    condition = 'return makeGlfwContextCurrent(window) ? 1 : 0;'
    assert text.count(condition) == 1, 'checked ABI changed; update the negative control explicitly'
    negative = output / 'glfw-old-checked-result.cpp'
    negative.write_text(text.replace(condition,
        'return (makeGlfwContextCurrent(window), g_threadCurrentContext == window) ? 1 : 0;'), encoding='utf-8')
    binary = output / ('glfw-old-checked-result' + suffix)
    compile_cpp(negative, binary, defines=[*test_defines, 'AMCL_NATIVE_DESKTOP_ONLY=0'])
    rejected = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
    assert rejected.returncode != 0 and 'glfwOHOS_MakeContextCurrentChecked(&checked)==0' in rejected.stderr, rejected
    # 移除 create 前置门后，即使旧窗口均已释放也会越过阳性尾桩；必须由正式场景击穿。
    condition = 'if (glfwGraphicsRestartRequired()) {'
    assert text.count(condition) == 1, 'creation restart guard changed; update its negative control explicitly'
    negative = output / 'glfw-old-create-after-loss.cpp'
    negative.write_text(text.replace(condition, 'if (false) {'), encoding='utf-8')
    binary = output / ('glfw-old-create-after-loss' + suffix)
    compile_cpp(negative, binary, defines=[*test_defines, 'AMCL_NATIVE_DESKTOP_ONLY=0'])
    rejected = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
    assert rejected.returncode != 0 and 'TestCreatePrefix()==0' in rejected.stderr, rejected
    # typed 包装层若漏报原始 lost，或者提前调用可销毁 session 的用户回调，分别由独立
    # 反向对照拒绝，不能借直接 EGL 边界的测试阳性替代内部事务边界证据。
    for name, changed, expected in [
        ('typed-context-loss', typed_report.replace(
            'if (win->lastFailure.driverFailure &&', 'if (false && win->lastFailure.driverFailure &&'),
         'fatalReports==1 && fatalError==EGL_CONTEXT_LOST'),
        ('internal-callback', typed_report.replace('    return false;',
            '    if (g_errorCallback) g_errorCallback(GLFW_PLATFORM_ERROR, error.c_str());\n    return false;'),
         'lastError==0'),
    ]:
        assert changed != typed_report and text.count(typed_report) == 1, 'typed report changed; update negative controls'
        negative = output / ('glfw-old-' + name + '.cpp')
        negative.write_text(text.replace(typed_report, changed), encoding='utf-8')
        binary = output / ('glfw-old-' + name + suffix)
        compile_cpp(negative, binary, defines=[*test_defines, 'AMCL_NATIVE_DESKTOP_ONLY=0'])
        rejected = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
        assert rejected.returncode != 0 and expected in rejected.stderr, rejected
    print('PASS EGL lifecycle: production core/GLFW checked ABI and terminal EGL failures; old TLS/context-loss regressions rejected; SDL/GPU not evaluated')
