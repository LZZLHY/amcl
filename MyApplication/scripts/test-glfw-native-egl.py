"""直接编译真实 NativeEGL 查询/错误槽，验证资源身份、回调重入与线程错误隔离。"""
from pathlib import Path
import argparse
import subprocess
import sys
from lib.host_cpp import compile_cpp


ROOT = Path(__file__).resolve().parents[1]


def region(path, name):
    """只接受唯一生产标记对，避免源码删除或歧义时悄悄测试一份旧的替代实现。"""
    source = path.read_text(encoding='utf-8')
    begin, end = f'// {name}_BEGIN', f'// {name}_END'
    if source.count(begin) != 1 or source.count(end) != 1:
        raise ValueError(f'{path}: production region {name} is missing or ambiguous')
    return source.split(begin, 1)[1].split(end, 1)[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--compile-only', action='store_true')
    parser.add_argument('--negative-controls', action='store_true')
    args = parser.parse_args()
    output = args.out.resolve()
    if output == ROOT or ROOT in output.parents:
        parser.error('--out must be outside the application source checkout')
    output.mkdir(parents=True, exist_ok=True)
    template = (ROOT / 'entry/src/main/cpp/tests/host/glfw_native_egl.cpp.in').read_text(encoding='utf-8')
    glfw = ROOT / 'entry/src/main/cpp/glfw'
    # 查询核心编译运行，外围寿命事件另核实际接线：init/terminate 均撤销资格，两个成功
    # 交付出口（隐藏/可见）才准入。删掉事件调用不能靠fixture手动状态继续蒙混通过。
    production = (glfw / 'glfw_compat.cpp').read_text(encoding='utf-8')
    if production.count('g_nativeEglContextCreated = false;') != 3 or production.count('g_nativeEglContextCreated = true;') != 2:
        raise ValueError('NativeEGL init/terminate and successful create eligibility wiring changed')
    source = template.replace('@ERROR_SLOT@', region(glfw / 'glfw_callbacks.cpp', 'AMCL_GLFW_ERROR_SLOT'))
    source = source.replace('@NATIVE_EGL@', region(glfw / 'glfw_compat.cpp', 'AMCL_NATIVE_EGL_ACCESS'))
    generated = output / 'glfw_native_egl.cpp'
    generated.write_text(source, encoding='utf-8', newline='\n')
    binary = output / ('glfw_native_egl.exe' if sys.platform == 'win32' else 'glfw_native_egl')
    # 复用项目宿主编译器发现逻辑，Windows 确实编成本机 MSVC 可执行程序，不把 OHOS
    # clang 交叉编译成功冒充实际运行。所有生成源码/对象/可执行文件都落显式外部目录。
    compile_cpp(generated, binary)
    if not args.compile_only:
        subprocess.run([str(binary)], check=True)

    # 晚加载桥不依赖真实 GPU。只提供现有服务描述符与 PID 外部边界，包含完整现役生产
    # 文件编译，能观察缺 owner、旧 PID、损坏 ABI、未 ready、未知函数的失败关闭。
    bridge_template = (ROOT / 'entry/src/main/cpp/tests/host/lwjgl_egl_bridge.cpp.in').read_text(encoding='utf-8')
    bridge_source = ROOT / 'entry/src/main/cpp/platform/lwjgl_egl_bridge.cpp'
    bridge_generated = output / 'lwjgl_egl_bridge.cpp'
    bridge_generated.write_text(bridge_template.replace('@PRODUCTION_SOURCE@', bridge_source.as_posix()),
                                encoding='utf-8', newline='\n')
    # 真实产品仍包含系统 unistd.h；宿主测试头仅改名 PID 外部函数，不实现任何查询逻辑。
    stub = output / 'stubs'
    stub.mkdir(exist_ok=True)
    (stub / 'unistd.h').write_text('#pragma once\nint amclLwjglEglTestPid();\n#define getpid amclLwjglEglTestPid\n',
                                  encoding='utf-8', newline='\n')
    bridge_binary = output / ('lwjgl_egl_bridge.exe' if sys.platform == 'win32' else 'lwjgl_egl_bridge')
    compile_cpp(bridge_generated, bridge_binary, includes=(stub,))
    if not args.compile_only:
        subprocess.run([str(bridge_binary)], check=True)

    if args.negative_controls and not args.compile_only:
        # 仅变更本次外部测试输入，生产文件保持原样。反控必须由同一套真实断言拒绝，
        # 证明窗口身份错误和跨进程资格丢失不会因夹具过宽而被门禁放过。
        controls = [
            ('native-context-identity', source, 'result.context = window->context;',
             'result.context = nullptr;', ()),
            ('native-error-thread-isolation', source, 'static thread_local int g_lastError = 0;',
             'static int g_lastError = 0;', ()),
            ('native-config-preservation', source, 'int glfwGetEGLConfig(GLFWwindow* window, void** config) {',
             'int glfwGetEGLConfig(GLFWwindow* window, void** config) { if (config) *config = nullptr;', ()),
            ('native-display-last-window', source, 'display = amcl::graphics::InitializedEglDisplay(*runtime);',
             'display = g_windows.empty() ? nullptr : amcl::graphics::InitializedEglDisplay(*runtime);', ()),
            ('native-display-reinit-eligibility', source, 'initialized && g_nativeEglContextCreated && runtime',
             'initialized && runtime', ()),
        ]
        for name, original, old, new, includes in controls:
            if original.count(old) != 1:
                raise ValueError(f'{name}: negative control anchor is missing or ambiguous')
            control = output / (name + '.cpp')
            # Windows CRT assert 的失败可能唤起交互窗口；仅在反控生成物把 assert 改为
            # 非交互退出，断言表达式和生产核心保持不变，确保 CI 可重放且失败码明确。
            failure = '#include <cstdlib>\n#undef assert\n#define assert(x) do { if (!(x)) std::exit(7); } while (0)\n'
            control.write_text(original.replace(old, new).replace('@ERROR_SLOT@', '')
                               .replace('int main() {', failure + '\nint main() {'), encoding='utf-8')
            executable = control.with_suffix('.exe' if sys.platform == 'win32' else '')
            compile_cpp(control, executable, includes=includes)
            rejected = subprocess.run([str(executable)], check=False, timeout=20)
            if rejected.returncode != 7:
                raise RuntimeError(f'{name}: expected controlled rejection 7, received {rejected.returncode}')
            print('PASS negative control rejected:', name)

        # 移除公共表 PID 校验：旧进程的函数表会被错误调用，现有断言必须能截获。
        bridge_original = bridge_source.read_text(encoding='utf-8')
        old = 'api->processId != static_cast<uint64_t>(pid) || '
        if bridge_original.count(old) != 1:
            raise ValueError('bridge PID negative control anchor is missing or ambiguous')
        altered = output / 'bridge-without-public-pid.cpp'
        # 负控制文件离开生产目录后仍从实际生产头取得 ABI；只改一处受测分支。
        altered.write_text(bridge_original.replace(old, '').replace('"graphics_runtime_service.h"',
            '"' + (ROOT / 'entry/src/main/cpp/platform/graphics_runtime_service.h').as_posix() + '"'), encoding='utf-8')
        failure = '#undef assert\n#define assert(x) do { if (!(x)) std::exit(7); } while (0)\n'
        control = output / 'bridge-public-pid-control.cpp'
        control.write_text(bridge_template.replace('@PRODUCTION_SOURCE@', altered.as_posix())
                           .replace('int main() {', failure + '\nint main() {'), encoding='utf-8')
        executable = control.with_suffix('.exe' if sys.platform == 'win32' else '')
        compile_cpp(control, executable, includes=(stub,))
        rejected = subprocess.run([str(executable)], check=False, timeout=20)
        if rejected.returncode != 7:
            raise RuntimeError(f'bridge-public-pid: expected rejection 7, received {rejected.returncode}')
        print('PASS negative control rejected: bridge-public-pid')


if __name__ == '__main__':
    main()
