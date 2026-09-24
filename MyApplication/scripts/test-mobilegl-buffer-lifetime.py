"""编译真实MobileGL BufferObject/PipeResource，外部图形头只替换为基础类型。

不复制映射实现或为用例重写产品类。--source-root可指向旧源码快照执行负对照；
--expect-pointer-move仅用于确认旧缺陷，不作为修复通过条件。
"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import argparse,os,subprocess,tempfile,shutil
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('--source-root',type=Path,default=root/'prebuilt/mobilegl/src');parser.add_argument('--expect-pointer-move',action='store_true');parser.add_argument('--expect-unbacked-read',action='store_true');args=parser.parse_args()
source=args.source_root.resolve()/'MobileGL/MG_State/GLState/BufferState/BufferObject.cpp'
types=(root/'prebuilt/mobilegl/src/MobileGL/MG_Util/Types.h').read_text(encoding='utf-8')
# Flags运算直接采用同一真实基础类型定义，stub只隔离与buffer无关的GLSL/EGL加载依赖。
flags=types[types.index('    template <typename Bit,'):types.rindex('} // namespace MobileGL')]
with workspace_temporary_directory(prefix='amcl-mobilegl-map-') as temporary:
    out=Path(temporary);(out/'MG_Util/Math').mkdir(parents=True)
    includes='''#pragma once
#include <algorithm>
#include <atomic>
#include <bit>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <string>
#include <type_traits>
#include <vector>
using GLbitfield=unsigned;
constexpr unsigned GL_MAP_READ_BIT=1,GL_MAP_WRITE_BIT=2,GL_MAP_PERSISTENT_BIT=0x40,GL_MAP_COHERENT_BIT=0x80,GL_DYNAMIC_STORAGE_BIT=0x100;
#define MOBILEGL_ASSERT(expr, ...) do {if(!(expr)){std::cerr<<"assert "<<#expr<<'\\n';std::abort();}}while(false)
namespace MobileGL {
using Bool=bool;using Uint=unsigned;using Uint8=uint8_t;using Uint64=uint64_t;using SizeT=size_t;
template<class T>using SharedPtr=std::shared_ptr<T>;
template<class T,class... A>SharedPtr<T>MakeShared(A&&... a){return std::make_shared<T>(std::forward<A>(a)...);}
struct Range1D{SizeT start=0,end=~SizeT(0);Range1D()=default;Range1D(SizeT s,SizeT e):start(s),end(e){}};
struct DataPtr{void* data;SizeT size;};
inline void Memcpy(void* d,const void* s,SizeT n){std::memcpy(d,s,n);}
inline void Memset(void* d,int c,SizeT n){std::memset(d,c,n);}
inline void Memmove(void* d,const void* s,SizeT n){std::memmove(d,s,n);}
'''+flags+'}\n'
    (out/'Includes.h').write_text(includes,encoding='utf-8')
    for name in ['MG_Util/Types.h','MG_Util/Math/VectorTypes.h']:(out/name).write_text('#pragma once\n#include <Includes.h>\n')
    unit=out/'test.cpp';unit.write_text('#include "'+source.as_posix()+'"\n#include "'+(root/'scripts/mobilegl-buffer-lifetime-test.cpp').as_posix()+'"\n',encoding='utf-8')
    exe=out/('test.exe' if os.name=='nt' else 'test')
    if os.name=='nt':
        vc=Path('D:/Microsoft Visual Studio/18/Community/VC/Auxiliary/Build/vcvars64.bat')
        assert vc.is_file(),'需要MSVC C++23工具链'
        # 固定工具和本轮临时路径；无用户输入插入shell，不复用用户环境变量名。
        batch=out/'build.cmd';batch.write_text('@echo off\ncall "'+str(vc)+'" >nul\ncl /nologo /utf-8 /EHsc /std:c++latest /I"'+str(out)+'" "'+str(unit)+'" /Fo"'+str(out/'test.obj')+'" /Fe"'+str(exe)+'"\nexit /b %errorlevel%\n',encoding='utf-8')
        subprocess.run(['cmd','/d','/c',str(batch)],check=True)
    else:subprocess.run(['c++','-std=c++23','-I'+str(out),str(unit),'-o',str(exe)],check=True)
    mode='--expect-pointer-move' if args.expect_pointer_move else '--expect-unbacked-read' if args.expect_unbacked_read else None
    subprocess.run([str(exe),*([mode] if mode else [])],check=True,timeout=20)
