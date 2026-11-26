"""用真实交付的 L2 JAR/JDK8 和生产 JNI 检查标准手柄接口，替换平台 reader 边缘。"""
import argparse
import os
from pathlib import Path
import subprocess

from lib.host_cpp import configure_host_cmake, find_host_cmake
from lib.host_test_lifecycle import HostTestScope
from lib.workspace_paths import external_output_path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jdk', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--jar', type=Path, help='复建中的真实候选 JAR；默认核验交付资源')
    args = parser.parse_args()
    jdk = args.jdk.resolve()
    fixture = ROOT / 'scripts/fixtures/input-consumer/l2-gamepad'
    sdk = ROOT / 'entry/src/main/cpp/platform'
    jar = (args.jar or ROOT / 'entry/src/main/resources/rawfile/lwjgl2/lwjgl.jar').resolve()
    suffix = '.exe' if os.name == 'nt' else ''
    parent = external_output_path(args.out)
    parent.mkdir(parents=True, exist_ok=True)
    scope = HostTestScope('l2-gamepad-', parent=parent)
    work = scope.directory
    passed = False
    try:
        build = work / 'build'
        # 宿主替换同进程 reader 解析，生产 JNI 仍使用同一份快照结构、代次判断和转换代码。
        (work / 'gamepad_reader.h').write_text(
            '#include "desktop_host_api.h"\n'
            'typedef int32_t (*AmclGamepadReadFn)(int32_t, AmclDesktopGamepad*);\n'
            'AmclGamepadReadFn amclResolveGamepadReader(void);\n'
            'int amclTestPid(void);\n#define getpid amclTestPid\n',
            encoding='utf8')
        platform = 'win32' if os.name == 'nt' else 'linux'
        native = ROOT / 'prebuilt/lwjgl2/ohos-backend/amcl_lwjgl2_gamepad.c'
        (work / 'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.18)
project(l2_pad C)
set(CMAKE_C_STANDARD 11)
add_library(lwjgl_v2 SHARED "{native.as_posix()}" "{(fixture/'device.c').as_posix()}")
target_include_directories(lwjgl_v2 PRIVATE "{work.as_posix()}" "{sdk.as_posix()}"
    "{(jdk/'include').as_posix()}" "{(jdk/'include'/platform).as_posix()}")
''', encoding='utf8')
        cmake = find_host_cmake()
        configure_host_cmake(cmake, work, build)
        subprocess.run([cmake, '--build', str(build), '--config', 'Release'], check=True)
        javac, java = [str(jdk / 'bin' / (name + suffix)) for name in ('javac', 'java')]
        subprocess.run([javac, '-encoding', 'UTF-8', '-cp', str(jar), '-d', str(work),
                        str(fixture / 'L2GamepadProbe.java')], check=True)
        dll = next(build.rglob('lwjgl_v2.dll' if os.name == 'nt' else 'liblwjgl_v2.so'))
        subprocess.run([java, '-Dos.name=Linux', '-Dorg.lwjgl.librarypath=' + str(dll.parent),
                        '-cp', os.pathsep.join(map(str, (jar, work))), 'L2GamepadProbe'], check=True)
        passed = True
    finally:
        scope.close(success=passed)


if __name__ == '__main__':
    main()
