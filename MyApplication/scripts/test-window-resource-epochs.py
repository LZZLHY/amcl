"""执行 WindowHost、BackendSession 和真实 SDL 补丁头的资源/几何代际及清理反例。"""
from pathlib import Path
import os
import subprocess
import tempfile
from lib.host_cpp import compile_cpp

root = Path(__file__).resolve().parent.parent
host = root / 'entry/src/main/cpp/tests/host'
with tempfile.TemporaryDirectory(prefix='amcl-window-epochs-') as temporary:
    output = Path(temporary)
    cases = [('window_host_core.cpp', 'window_host_core_test.cpp'),
             ('graphics_backend_session.cpp', 'graphics_backend_session_host_test.cpp')]
    for production, test in cases:
        source = output / test
        source.write_text('#include "' + (root / 'entry/src/main/cpp/platform' / production).as_posix() + '"\n'
            + '#include "' + (host / test).as_posix() + '"\n', encoding='utf-8')
        binary = output / (test + ('.exe' if os.name == 'nt' else '.out'))
        compile_cpp(source, binary)
        subprocess.run([str(binary)], check=True, timeout=30)
    subprocess.run(['node', str(root / 'scripts/extract-sdl3-presentation-header.mjs'),
        '--patch', str(root / 'prebuilt/sdl3/patches/0012-openharmony-presentation-session.patch'),
        '--output', str(output / 'SDL_amclpresentation.h')], check=True, timeout=30)
    binary = output / ('sdl.exe' if os.name == 'nt' else 'sdl')
    compile_cpp(host / 'sdl_presentation_host_test.cpp', binary,
        includes=[output, root / 'entry/src/main/cpp/glfw'])
    subprocess.run([str(binary)], check=True, timeout=30)
