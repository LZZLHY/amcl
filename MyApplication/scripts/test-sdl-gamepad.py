"""对指定的完整已应用 SDL 候选运行原生宿主 joystick/无视频 gamepad 测试。"""
import argparse
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
from lib.host_cpp import configure_host_cmake, find_host_cmake
from lib.host_test_lifecycle import HostTestScope
from lib.workspace_paths import external_output_path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True, help='按锁定提交和完整 series 准备的 SDL 源码')
    parser.add_argument('--out', type=Path, required=True, help='本任务外置宿主测试目录')
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    if not (source / 'src/joystick/SDL_amclgamepad_c.h').is_file():
        parser.error('SDL source does not include the AMCL joystick adapter')
    output = external_output_path(args.out)
    output.mkdir(exist_ok=True, parents=True)
    scope = HostTestScope('sdl-gamepad-', parent=output)
    folder = scope.directory
    passed = False
    try:
        fixture = Path(__file__).resolve().parent / 'fixtures/input-consumer/sdl_gamepad.c'
        # 相同 SDL 目标、真实公共 API；仅在此宿主 SDK 替换系统能力/连接读回端口。
        (folder / 'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.20)
project(AmclGamepadTest C CXX)
set(SDL_SHARED OFF CACHE BOOL "" FORCE)
set(SDL_STATIC ON CACHE BOOL "" FORCE)
set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
set(SDL_TESTS OFF CACHE BOOL "" FORCE)
set(SDL_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SDL_HIDAPI OFF CACHE BOOL "" FORCE)
set(SDL_AMCL_DESKTOP_HOST ON CACHE BOOL "" FORCE)
set(SDL_AUDIO OFF CACHE BOOL "" FORCE)
set(SDL_RENDER OFF CACHE BOOL "" FORCE)
set(SDL_GPU OFF CACHE BOOL "" FORCE)
set(SDL_CAMERA OFF CACHE BOOL "" FORCE)
set(SDL_SENSOR OFF CACHE BOOL "" FORCE)
if(UNIX AND NOT APPLE)
  set(SDL_UNIX_CONSOLE_BUILD ON CACHE BOOL "" FORCE)
endif()
add_subdirectory("{source.as_posix()}" sdk)
target_compile_definitions(SDL3-static PRIVATE AMCL_SDL_GAMEPAD_HOST_TEST)
add_executable(sdl_gamepad "{fixture.as_posix()}")
target_include_directories(sdl_gamepad PRIVATE "{source.as_posix()}/src/video/openharmony")
target_link_libraries(sdl_gamepad PRIVATE SDL3::SDL3-static)
enable_testing()
add_test(NAME native_gamepad COMMAND sdl_gamepad)
''', encoding='utf-8')
        cmake = find_host_cmake()
        build = folder / 'build'
        configure_host_cmake(cmake, folder, build)
        subprocess.run([cmake, '--build', str(build), '--config', 'Release', '--target', 'sdl_gamepad',
                        '--parallel', '6'], check=True)
        ctest = Path(cmake).with_name('ctest.exe' if sys.platform == 'win32' else 'ctest')
        subprocess.run([str(ctest), '--test-dir', str(build), '-C', 'Release', '--verbose'], check=True)
        passed = True
    finally:
        scope.close(success=passed)


if __name__ == '__main__':
    main()
