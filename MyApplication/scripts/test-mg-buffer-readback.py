"""执行真实MG读回适配器与core/ARB/DSA入口，仅替换GPU和名称表边界。"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import subprocess,tempfile
from lib.host_cpp import compile_cpp
root=Path(__file__).resolve().parents[1];mg=root/'prebuilt/mobileglues/mg_src/MobileGlues-cpp'
def function(text,needle):
    """按平衡花括号保留完整生产正文，不重写其控制流；目标名均为脚本内固定值。"""
    start=text.index(needle);opening=text.index('{',start);depth=1;at=opening+1
    while depth:
        if text[at]=='{':depth+=1
        elif text[at]=='}':depth-=1
        at+=1
    return text[start:at]
buffer=(mg/'gl/buffer.cpp').read_text(encoding='utf-8');dsa=(mg/'gl/ExtWrappers/DSAWrapper.cpp').read_text(encoding='utf-8')
parts=[function(buffer,'struct BufferReadbackDriver {')+';',function(buffer,'void glGetBufferSubData('),
       function(buffer,'void glGetBufferSubDataARB('),function(dsa,'void glGetNamedBufferSubData(')]
template=(mg/'tests/buffer_readback_test.cpp.in').read_text(encoding='utf-8')
with workspace_temporary_directory(prefix='amcl-mg-readback-') as directory:
    out=Path(directory);source=out/'test.cpp';exe=out/'test.exe'
    source.write_text(template.replace('// @PRODUCTION_CODE@','\n'.join(parts)),encoding='utf-8')
    compile_cpp(source,exe,[mg],[])
    subprocess.run([str(exe)],check=True,timeout=20)
    # 同一套真实数据断言必须拒绝旧空实现，而不是只检查新代码里有memcpy字样。
    legacy=(mg/'tests/buffer_readback_stub_before.inc').read_text(encoding='utf-8')
    source.write_text(template.replace('// @PRODUCTION_CODE@',legacy+'\n'+parts[-1]),encoding='utf-8')
    oldExe=out/'old.exe';compile_cpp(source,oldExe,[mg],[])
    old=subprocess.run([str(oldExe)],capture_output=True,text=True,timeout=20)
    if old.returncode==0 or 'FAIL real range contents' not in old.stderr:
        raise RuntimeError('旧空实现未被真实字节断言拒绝: '+old.stdout+old.stderr)
    print('PASS negative control: original core/ARB stubs rejected by real buffer contents')
