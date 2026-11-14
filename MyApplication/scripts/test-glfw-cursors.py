"""编译真实cursor入口和terminate接线；外置生成物、负控与有界结果收据。"""
from pathlib import Path
from datetime import datetime
import argparse,hashlib,json,subprocess,sys
from lib.host_cpp import compile_cpp

ROOT=Path(__file__).resolve().parents[1]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--negative-controls',action='store_true')
    args=parser.parse_args();out=args.out.resolve()
    if out==ROOT or ROOT in out.parents:parser.error('--out must be outside the source checkout')
    out.mkdir(parents=True,exist_ok=False)
    glfw=ROOT/'entry/src/main/cpp/glfw';test=ROOT/'entry/src/main/cpp/tests/host/glfw_cursor_lifecycle_test.cpp'
    core=(glfw/'glfw_compat.cpp').read_text(encoding='utf-8')
    begin='// AMCL_GLFW_TERMINATE_LIFECYCLE_BEGIN';end='// AMCL_GLFW_TERMINATE_LIFECYCLE_END'
    assert core.count(begin)==1 and core.count(end)==1
    terminate=core.split(begin)[1].split(end)[0]
    template=test.read_text(encoding='utf-8').replace('"../../glfw/glfw_compat.h"','"'+(glfw/'glfw_compat.h').as_posix()+'"')
    implementation=(glfw/'glfw_cursor.inc').read_text(encoding='utf-8')
    template=template.replace('#include "../../glfw/glfw_cursor.inc"',implementation).replace('// @AMCL_GLFW_TERMINATE@',terminate)
    # 负控只改外部副本；统一用exit(7)避免Windows断言弹出交互窗口或产生core dump。
    failure='#include <cstdlib>\n#undef assert\n#define assert(x) do { if (!(x)) std::exit(7); } while (0)\n'
    template=template.replace('static bool failObject',failure+'\nstatic bool failObject')
    variants=[('positive',template,0)]
    if args.negative_controls:
        for name,old,new in [
            ('create-null','cursor->shape = shape;','delete cursor; return nullptr;'),
            ('skip-unbind','for (auto* window : g_windows) if (window->cursor == cursor) window->cursor = nullptr;',''),
            ('skip-terminate-cleanup','    glfwOHOS_ClearCursorsLocked();',''),
            ('missing-pixels-copy','    std::memcpy(cursor->pixels.get(), image->pixels, bytes);','    std::memset(cursor->pixels.get(),0,bytes);')]:
            assert template.count(old)==1,(name,'ambiguous production anchor')
            variants.append((name,template.replace(old,new),7))
    results=[]
    try:
        for name,source,expected in variants:
            generated=out/(name+'.cpp');generated.write_text(source,encoding='utf-8',newline='\n')
            binary=out/(name+('.exe'if sys.platform=='win32'else''))
            compile_cpp(generated,binary)
            result=subprocess.run([str(binary)],capture_output=True,timeout=30)
            (out/(name+'.stdout')).write_bytes(result.stdout);(out/(name+'.stderr')).write_bytes(result.stderr)
            results.append({'name':name,'exitCode':result.returncode,'expected':expected})
            assert result.returncode==expected,results[-1]
            print('PASS',name)
            # 仅回收本轮亲建且已关闭的可再生程序；失败现场保留供诊断。
            binary.unlink();obj=out/(name+'.obj')
            if obj.exists():obj.unlink()
    finally:
        receipt={'at':datetime.now().astimezone().isoformat(),'passed':len(results)==len(variants)and all(x['exitCode']==x['expected']for x in results),'results':results,'inputs':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in [test,glfw/'glfw_cursor.inc',glfw/'glfw_compat.cpp']},'scope':'real cursor and terminate logic; mocked window/driver teardown boundary; no target appearance claim'}
        (out/'receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

if __name__=='__main__':main()
