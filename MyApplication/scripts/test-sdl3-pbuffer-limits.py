"""编译现役SDL的容量检查、真实辅助创建分支和resize函数，验证有界原生GL兼容。

只替换EGL/SDL系统边界，不复制被测容量决策或资源提交算法。Windows使用MSVC，
POSIX使用本机C++编译器；GPU替身的成功仅代表生命周期契约，不代表真实设备验收。
"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import importlib.util
import os
import subprocess
import tempfile
from lib.host_cpp import compile_cpp

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('recipe', root/'scripts/generate-desktop-review-tests.py')
recipe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipe)
sources = recipe.patch_sources()
gl, window = sources['SDL_openharmonyopengl.c'], sources['SDL_openharmonywindow.c']
create = recipe.function(window, 'OPENHARMONY_CreateWindow')
auxiliary = recipe.block(create, create.index('    if (data->role == OPENHARMONY_WINDOW_AUXILIARY_PBUFFER)'))
code = (root/'entry/src/main/cpp/tests/host/sdl_pbuffer_limits.cpp.in').read_text(encoding='utf-8')
code = code.replace('@ROOT@', root.as_posix())
code = code.replace('@VALIDATE_SIZE@', recipe.function(gl, 'OPENHARMONY_GLES_ValidatePbufferSize'))
code = code.replace('@VALIDATE_SURFACE@', recipe.function(gl, 'OPENHARMONY_GLES_ValidatePbufferSurface'))
code = code.replace('@CREATE_AUXILIARY@', auxiliary)
code = code.replace('@RESIZE@', recipe.function(window, 'OPENHARMONY_ApplyPendingAuxiliaryResize'))
with workspace_temporary_directory(prefix='amcl-pbuffer-limits-') as temporary:
    source = Path(temporary)/'pbuffer.cpp'
    source.write_text(code, encoding='utf-8')
    binary = Path(temporary)/('pbuffer.exe' if os.name == 'nt' else 'pbuffer')
    compile_cpp(source, binary, includes=[root/'prebuilt/khronos-egl-headers'])
    subprocess.run([str(binary)], check=True, timeout=30)
