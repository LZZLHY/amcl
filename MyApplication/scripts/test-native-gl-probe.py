"""编译完整生产NativeGL查询/生命周期和固定官方EGL引导正文，检查早期UI初始化及失败退休。
每个用例是新进程；只替换动态库/GPU边界，源码与HAP包级配置另由实际Hvigor测试覆盖。
"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import importlib.util
import os
import subprocess
import tempfile
import shutil
import sys
from lib.host_cpp import compile_cpp

root=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('extract',root/'scripts/generate-desktop-review-tests.py')
extract=importlib.util.module_from_spec(spec);spec.loader.exec_module(extract)
# 冻结上游样本随项目证据树迁移；原始正文与内容指纹不改变，继续提取同一真实 EGL 实现。
official=root/'docs/testing/evidence/nativegl-admission-audit-20260921/openharmony'
core=(official/'egl_core.cpp').read_text(encoding='utf-8')
custom=(official/'egl_wrapper_custom.cpp').read_text(encoding='utf-8')
select=extract.block(core,core.index('bool CheckIfEnableOpengl()'))
initialize=extract.block(core,core.index('bool EglCoreInit()'))
query=extract.block(custom,custom.index('EGLBoolean OHGraphicsQueryGLImpl(void)'))
code=(root/'entry/src/main/cpp/tests/host/native_gl_probe.cpp.in').read_text(encoding='utf-8')
code=code.replace('@ROOT@',root.as_posix()).replace('@OFFICIAL@',select+'\nnamespace OHOS {\n'+initialize+'\n}\n'+query)
includes=[root/'prebuilt/khronos-egl-headers']
with workspace_temporary_directory(prefix='amcl-native-gl-probe-') as temporary:
    # 仓内锁定依赖提供GLES3.2公开头，是这里GL3诊断声明的超集。仅在临时宿主include
    # 目录补同名入口，不复制接口类型、不把OHOS sysroot的libc头混入MSVC标准库。
    header=Path(temporary)/'GLES3/gl3.h';header.parent.mkdir()
    header.write_text('#include <GLES3/gl32.h>\n',encoding='utf-8')
    # 只替换动态链接器边界。不能把其他测试的unistd替身带进来遮住真实fork/getpid。
    shutil.copyfile(root/'entry/src/main/cpp/tests/host/runtime_binding_stubs/dlfcn.h',Path(temporary)/'dlfcn.h')
    includes += [Path(temporary),root/'prebuilt/mobilegl/src/include']
    source=Path(temporary)/'probe.cpp';source.write_text(code,encoding='utf-8')
    binary=Path(temporary)/('probe.exe' if os.name=='nt' else 'probe')
    compile_cpp(source,binary,includes=includes)
    # 可单独重放一个故障顺序；默认覆盖全部场景，新增跨线程和驱动入口缺失边界。
    modes=sys.argv[1:] or ['early','late','missing','unsupported','busy','foreign-gl','config-count','first-and-cleanup',
                          'unbind','context','surface','restore','throw','worker-main','resolver-missing']
    for mode in modes:
        subprocess.run([str(binary),mode],check=True,timeout=20)
    if os.name!='nt' and not sys.argv[1:]:subprocess.run([str(binary),'fork'],check=True,timeout=20)
