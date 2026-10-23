"""编译现役 SDL MakeCurrent 及致命边界，验证辅助/呈现/释放同一终局语义。

正文经既有严格 patch-series 抽取器生成；驱动替身只注入 EGL 错误，不重写被测分支。
输出沿用宿主测试的外置目录，Windows 与 POSIX 都使用仓库现有编译入口。
"""
from pathlib import Path
import importlib.util
import os
import subprocess
from lib.host_cpp import compile_cpp
from lib.workspace_paths import temporary_directory

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('extract', root/'scripts/generate-desktop-review-tests.py')
extract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extract)
sources = extract.patch_sources()
source = sources['SDL_openharmonyopengl.c']
names = ['OPENHARMONY_GLES_MarkRendererRestartRequired', 'OPENHARMONY_GLES_MarkRendererFatalWithError',
         'OPENHARMONY_GLES_MarkRendererFatal', 'OPENHARMONY_GLES_SetCurrentCache',
         'OPENHARMONY_GLES_RestorePreviousBinding', 'OPENHARMONY_GLES_IsRecoverableSurfaceError',
         'OPENHARMONY_GLES_IsFatalContextError', 'OPENHARMONY_GLES_IsRecoveryDeferred',
         'OPENHARMONY_GLES_ContextBindingAllowed',
         'OPENHARMONY_GLES_MakeCurrent']
production = '\n\n'.join(extract.function(source, name) for name in names)
production += '\n\n' + extract.function(sources['SDL_video.c'], 'SDL_GL_MakeCurrent')
template = (root/'entry/src/main/cpp/tests/host/sdl_context_loss.cpp.in').read_text(encoding='utf-8')
with temporary_directory(prefix='sdl-context-loss-') as output:
    path = Path(output)/'test.cpp'
    path.write_text(template.replace('@PRODUCTION@', production), encoding='utf-8')
    binary = Path(output)/('test.exe' if os.name == 'nt' else 'test')
    compile_cpp(path, binary)
    subprocess.run([str(binary)], check=True, timeout=30)
    # 分开删除三道门，避免首个释放断言遮住 auxiliary 或公共缓存的回归。
    mutations = [
        ('release', 'if (!result && OPENHARMONY_GLES_IsFatalContextError(release_error))',
         'if (false && OPENHARMONY_GLES_IsFatalContextError(release_error))'),
        ('auxiliary', 'if (OPENHARMONY_GLES_IsFatalContextError(makecurrent_error)) {',
         'if (false && OPENHARMONY_GLES_IsFatalContextError(makecurrent_error)) {'),
        ('public-cache', 'if (context && _this->GL_MakeCurrent == OPENHARMONY_GLES_MakeCurrent &&',
         'if (false && _this->GL_MakeCurrent == OPENHARMONY_GLES_MakeCurrent &&'),
    ]
    for label, before, after in mutations:
        wrong = production.replace(before, after, 1)
        assert wrong != production, label
        path.write_text(template.replace('@PRODUCTION@', wrong), encoding='utf-8')
        compile_cpp(path, binary)
        rejected = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
        assert rejected.returncode != 0 and 'line ' in rejected.stderr, (label, rejected)
        print('PASS: SDL context-lost negative control rejected: ' + label)
