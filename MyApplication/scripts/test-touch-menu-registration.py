"""真实Entry/Model、几何身份与Native登记/退休的跨层正反回归。

Native沿既有生产提取配方编译，SDK/最终bridge输出保持其宿主接缝；每次从相同初态重放
完整事件历史，Entry收到实际生产函数的接受态。负控使用本轮确证的完整旧Entry源码与SHA，
不能凭几何字符串锚点或纯假NAPI返回值声称修复有效。源码、二进制和行为收据全部外置。
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import uuid
# 正式源只读，导入缓存与多TU目标必须留在本轮外置位置。
sys.dont_write_bytecode=True
from lib.source_host import compile_source_fixture, source_dependencies
from lib.workspace_paths import external_output_path, workspace_path

ROOT=Path(__file__).resolve().parents[1]
OLD_ENTRY_SHA='48e0224fad116fc28b07f5b5128cecc108fdd7c20de982d3c7e1f111ede09345'


def main():
    """正例与真实旧Entry反控共用同一已编译Native，编译/运行失败不能冒充反控成功。"""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cxx',help='显式宿主C++编译器；缺省复用host_cpp自动定位MSVC/c++')
    parser.add_argument('--build-dir',help='仓外构建根，每次使用独占叶目录避免并行覆盖')
    parser.add_argument('--output',help='仓外行为证据根，缺省使用工作区run')
    args=parser.parse_args()
    run_id='run-'+str(os.getpid())+'-'+uuid.uuid4().hex[:8]
    build_base=external_output_path(args.build_dir) if args.build_dir else workspace_path('build','touch-menu-registration')
    output_base=external_output_path(args.output) if args.output else workspace_path('run','touch-menu-registration')
    build=build_base/run_id;output=output_base/run_id
    build.mkdir(parents=True,exist_ok=False);output.mkdir(parents=True,exist_ok=False)

    recipe_path=ROOT/'scripts/test-menu-mouse-production.py'
    recipe=recipe_path.read_text(encoding='utf-8')
    marker="with temporary_directory(prefix='menu-mouse-production-')"
    if recipe.count(marker)!=1: raise ValueError('Complete native recipe boundary required')
    namespace={'__file__':str(recipe_path),'__name__':'menu_registration_native_recipe'}
    # 只复用prefix与逐字提取的production，不运行原配方自己的编译/main，不复制Native持有判定。
    exec(compile(recipe[:recipe.index(marker)],str(recipe_path),'exec'),namespace)
    template=ROOT/'entry/src/main/cpp/tests/host/touch_menu_registration.cpp.in'
    unit=namespace['prefix']+namespace['production']+template.read_text(encoding='utf-8')
    source=build/'native.cpp';binary=build/('native.exe' if os.name=='nt' else 'native')
    source.write_text(unit,encoding='utf-8',newline='\n')
    # 同原菜单recipe使用唯一Source/Core/bridge与mapped/look薄producer，不能给新正文补本地ledger替身。
    # 缺省自动定位正常宿主CMake工具链；显式--cxx仍实际调用所选编译器，不以路径检查代替选择。
    if args.cxx and not (Path(args.cxx).is_file() or shutil.which(args.cxx)):
        raise FileNotFoundError('Requested C++ compiler not found: '+args.cxx)
    cpp=ROOT/'entry/src/main/cpp'
    extra=[cpp/'platform/mapped_look_producer.cpp',cpp/'platform/source_look_producer.cpp',cpp/'platform/source_look_processor.cpp']
    if args.cxx:
        compiler=str(Path(shutil.which(args.cxx) or args.cxx).resolve())
        inputs=[source,*source_dependencies(cpp),*extra]
        defines=['NOMINMAX','AMCL_INPUT_HOST_EXPORTS','AMCL_CONTROL_DELIVERY_HOST_TESTING',
            'AMCL_INPUT_BRIDGE_HOST_TESTING','AMCL_DESKTOP_EVENT_BRIDGE=1','_CRT_SECURE_NO_WARNINGS']
        if Path(compiler).name.lower() in ('cl','cl.exe'):
            # 显式cl沿既有契约要求调用者已准备环境；多TU对象独占一个目录，真实bridge.c按C++编译。
            objects=build/'objects';objects.mkdir()
            command=[compiler,'/nologo','/utf-8','/EHsc','/std:c++17','/TP',
                *['/D'+value for value in defines],'/I'+str(cpp),'/I'+str(cpp/'tests/host/stubs'),
                *[str(path) for path in inputs],'/Fo'+str(objects)+os.sep,'/Fe'+str(binary)]
        else:
            command=[compiler,'-std=c++17','-pthread','-x','c++',*['-D'+value for value in defines],
                '-I'+str(cpp),'-I'+str(cpp/'tests/host/stubs'),*[str(path) for path in inputs],
                '-o',str(binary),'-ldl','-Wl,--export-dynamic']
        subprocess.run(command,check=True)
    else:compile_source_fixture(source,binary,cpp,extra)

    runner=ROOT/'scripts/fixtures/touch-menu-registration/registration.mjs'
    old=ROOT/'scripts/fixtures/touch-menu-registration/EntryVirtualMouse.cached.ets'
    old_bytes=old.read_bytes()
    if hashlib.sha256(old_bytes).hexdigest()!=OLD_ENTRY_SHA:
        raise ValueError('Old Entry snapshot changed; original negative-source SHA no longer matches')
    node=shutil.which('node')
    if not node: raise FileNotFoundError('Node required for actual ArkTS production loader')
    base=[node,str(runner),'--native',str(binary),'--out',str(output)]
    positive=subprocess.run(base,capture_output=True,text=True,timeout=60)
    (output/'positive.log').write_text(positive.stdout+positive.stderr,encoding='utf-8')
    if positive.returncode!=0: raise AssertionError(positive.stdout+positive.stderr)
    negative=subprocess.run(base+['--old-entry',str(old)],capture_output=True,text=True,timeout=60)
    (output/'negative.log').write_text(negative.stdout+negative.stderr,encoding='utf-8')
    if negative.returncode==0 or 'REGISTRATION_RESET_REBIND' not in negative.stderr:
        raise AssertionError('Actual old Entry must fail registration rebind behavior: '+negative.stdout+negative.stderr)
    probe=json.loads((output/'negative-probe.json').read_text(encoding='utf-8'))
    if probe['afterBounds']!=probe['beforeBounds'] or probe['moveAccepted'] or probe['downAccepted']:
        raise AssertionError('Old negative must execute and show missing bounds plus actual Native rejection')

    names=['entry/src/main/ets/components/EntryVirtualMouse.ets','gamecontrol/src/main/ets/VirtualMouseModel.ets',
           'gamecontrol/src/main/ets/RuntimeTouchLayout.ets','gamecontrol/src/main/ets/InputSurfaceContext.ets',
           'entry/src/main/cpp/platform/touch_input.cpp','entry/src/main/cpp/platform/touch_publication_state.h',
           'scripts/test-menu-mouse-production.py','scripts/test-touch-menu-registration.py',
           'scripts/fixtures/touch-menu-registration/registration.mjs',
           'entry/src/main/cpp/tests/host/touch_menu_registration.cpp.in']
    receipt={'files':{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in names},
             'oldEntryOriginalSha256':OLD_ENTRY_SHA,'generatedNativeSha256':hashlib.sha256(unit.encode()).hexdigest(),
             'positiveExit':positive.returncode,'negativeExit':negative.returncode,'nativeBinary':str(binary),
             'scope':'host Entry/Model + actual Native registration/source release; not device mouse/game delivery acceptance'}
    (output/'evidence.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(positive.stdout,end='')
    print('PASS old Entry negative: unchanged bounds cache leaves actual Native move/DOWN rejected; evidence='+str(output))


if __name__=='__main__': main()
