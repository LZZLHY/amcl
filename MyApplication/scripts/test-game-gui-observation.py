"""完整生产GUI/Java/Core/原退出State与真实stock JNI的组合回归。

仅Windows宿主实现目前可执行，不能把非Windows或缺JDK/编译工具算通过。原45b同步
反例从实际Git正文编译，修复组直接链接当前生产源；测试不替换JNI函数/owner快照。
所有输出由既有workspace helper或显式仓外参数解析，保留源码/工具/模块SHA和命令。
"""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import uuid
from lib.workspace_paths import external_output_path, workspace_path

root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--jdk',default=os.environ.get('AMCL_JVM_TEST_JAVA_HOME') or os.environ.get('JAVA_HOME'))
parser.add_argument('--output')
parser.add_argument('--build-root')
args=parser.parse_args()
if os.name!='nt':
    print('SKIP actual Windows stock JNI fixture unavailable on this host');sys.exit(0)
if not args.jdk:raise RuntimeError('Pass --jdk with an actual complete Windows JDK; fake JVM is not an alternative')
jdk=Path(args.jdk).resolve();dll=jdk/'bin/server/jvm.dll'
vs=Path(os.environ.get('AMCL_GUI_TEST_VS_ROOT','D:/Microsoft Visual Studio/18/Community'))
cl=vs/'VC/Tools/MSVC/14.51.36231/bin/Hostx64/x64/cl.exe'
output_base=external_output_path(args.output) if args.output else workspace_path('run','game-gui-observation')
build_base=external_output_path(args.build_root) if args.build_root else workspace_path('build','input-exit-gui')
run_id='run-'+datetime.datetime.now().astimezone().strftime('%Y%m%d-%H%M%S')+'-'+uuid.uuid4().hex[:6]
output=output_base/run_id;build=build_base/run_id
output.mkdir(parents=True);build.mkdir(parents=True)
cpp=root/'entry/src/main/cpp'
receipt={'startedAt':datetime.datetime.now().astimezone().isoformat(),'state':'Running','commands':[],'scenes':[]}

def identity(file):
    file=Path(file);return {'path':str(file),'size':file.stat().st_size,'sha256':hashlib.sha256(file.read_bytes()).hexdigest()}
def save():
    (output/'receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2),encoding='utf-8')
def run(name,command,cwd=build,timeout=60):
    item={'label':name,'command':[str(value) for value in command],'cwd':str(cwd),'startedAt':datetime.datetime.now().astimezone().isoformat()}
    receipt['commands'].append(item)
    env=dict(os.environ);env['PATH']=str(jdk/'bin')+os.pathsep+env.get('PATH','')
    result=subprocess.run(command,cwd=cwd,env=env,capture_output=True,timeout=timeout)
    text=(result.stdout+result.stderr).decode('utf-8',errors='replace')
    (output/(name+'.log')).write_text(text,encoding='utf-8')
    item.update(exitCode=result.returncode,finishedAt=datetime.datetime.now().astimezone().isoformat(),log=identity(output/(name+'.log')))
    save();print(text,end='',flush=True)
    if result.returncode!=0:raise RuntimeError(name+' actual tool/process failed; not a business negative control')
    return text

try:
    sources=[cpp/'jvm/game_gui_bridge.cpp',cpp/'jvm/game_gui_observation.cpp',cpp/'jvm/game_gui_observation.h',
        cpp/'jvm/runtime_bootstrap_contract.h',cpp/'jvm/game_process_exit_core.h',cpp/'input/input_state_core.cpp',
        root/'JavaApp/src/com/amcl/launcher/GameGuiBridge.java',root/'JavaApp/test/net/minecraft/client/Minecraft.java',
        root/'scripts/lib/game-gui-observation-host.cpp',root/'scripts/lib/game-gui-observation-test-io.h']
    receipt['inputs']=[identity(file) for file in sources]
    receipt['jdk']={'module':identity(dll),'release':identity(jdk/'release'),'jni':identity(jdk/'include/jni.h')}
    receipt['compiler']=identity(cl)
    classes=build/'classes';old_classes=build/'old-classes';classes.mkdir();old_classes.mkdir()
    run('javac-current',[str(jdk/'bin/javac.exe'),'-encoding','UTF-8','-source','8','-target','8','-d',str(classes),
        str(root/'JavaApp/src/com/amcl/launcher/GameGuiBridge.java'),str(root/'JavaApp/test/net/minecraft/client/Minecraft.java')])
    # 固定被诊断过的真实原生产字节；独立浅克隆也能复现，不依赖维护者Git历史。
    # Manifest核验失败明确停止，不能修改旧源码或以模板生成同步参考模型。
    reference=build/'reference';(reference/'jvm').mkdir(parents=True);(reference/'platform').mkdir()
    frozen_root=root/'scripts/fixtures/game-gui-sync-reference'
    frozen=json.loads((frozen_root/'manifest.json').read_text(encoding='utf-8'))
    for item in frozen['files']:
        data=(frozen_root/item['name']).read_bytes()
        if len(data)!=item['size'] or hashlib.sha256(data).hexdigest()!=item['sha256']:
            raise ValueError('frozen actual synchronous GUI reference changed: '+item['name'])
        target=reference/'jvm/game_gui_bridge.cpp' if item['name'].endswith('.cpp') else reference/'GameGuiBridge.java'
        target.write_bytes(data)
    for name in ['game_gui_bridge.h','jvm_launcher.h']:
        shutil.copyfile(cpp/'jvm'/name,reference/'jvm'/name)
    shutil.copyfile(cpp/'platform/render_scale.h',reference/'platform/render_scale.h')
    receipt['reference']={'commit':frozen['sourceRef'],'manifest':identity(frozen_root/'manifest.json'),
        'gui':identity(reference/'jvm/game_gui_bridge.cpp'),'java':identity(reference/'GameGuiBridge.java')}
    run('javac-old-helper',[str(jdk/'bin/javac.exe'),'-encoding','UTF-8','-source','8','-target','8','-d',str(old_classes),
        str(reference/'GameGuiBridge.java'),str(root/'JavaApp/test/net/minecraft/client/Minecraft.java')])
    # Core 的真实 L2 held reader 依赖生产 mapper；补完整强链接，不以 weak/noop 或假映射替代。
    native=[root/'scripts/lib/game-gui-observation-host.cpp',cpp/'platform/render_scale.cpp',cpp/'input/input_state_core.cpp',cpp/'input/adapters/backend_keymaps.cpp',
        cpp/'input/amcl_input_host_descriptor.cpp',cpp/'input/input_interaction_order.cpp',cpp/'input/delivery/control_delivery.cpp']
    for kind in ['reference','async']:
        folder=build/('binary-'+kind);folder.mkdir();objects=folder/'objects';objects.mkdir()
        executable=folder/'gui-observation.exe'
        flags=['/nologo','/std:c++17','/EHsc','/utf-8','/MD','/O2','/D_CRT_SECURE_NO_WARNINGS','/DAMCL_INPUT_HOST_EXPORTS',
            '/FI'+str(jdk/'include/jni.h'),'/I'+str(jdk/'include'),'/I'+str(jdk/'include/win32'),'/I'+str(cpp/'jvm'),
            '/I'+str(cpp/'input'),'/I'+str(cpp/'tests/host/stubs'),'/I'+str(root/'scripts/lib'),
            '/Fo'+str(objects)+'\\','/Fe'+str(executable),'/Fd'+str(folder/'probe.pdb')]
        if kind=='reference':flags+=['/DAMCL_GUI_SYNC_REFERENCE'];code=[reference/'jvm/game_gui_bridge.cpp']
        else:flags+=['/DAMCL_GUI_OBSERVATION_HOST_TESTING'];code=[cpp/'jvm/game_gui_bridge.cpp',cpp/'jvm/game_gui_observation.cpp']
        command=[str(cl),*flags,*map(str,native+code)]
        cmd=folder/'compile.cmd';cmd.write_text('@echo off\ncall "'+str(vs/'VC/Auxiliary/Build/vcvars64.bat')+'" -vcvars_ver=14.51\n'
            'if errorlevel 1 exit /b %errorlevel%\n'+subprocess.list2cmdline(command)+'\nexit /b %errorlevel%\n',encoding='utf-8')
        receipt[kind+'Compile']=command;run('compile-'+kind,['cmd.exe','/d','/c',str(cmd)],folder)
        receipt[kind+'Executable']=identity(executable)
    for mode,kind,cp in [('reference','reference',classes),('async-exit','async',classes),('live','async',classes),('old-helper','async',old_classes)]:
        scene=build/('case-'+mode);scene.mkdir();text=run(mode,[str(build/('binary-'+kind)/'gui-observation.exe'),mode,str(dll),str(cp),str(scene),str(os.getpid())],timeout=25)
        loaded=re.search(r'^LOADED_JVM (.+)$',text,re.MULTILINE)
        if not loaded or identity(loaded.group(1).strip())!=receipt['jdk']['module']:raise RuntimeError('actual loaded JVM module mismatch')
        if mode=='reference':
            if 'name=original_pending_gui_enter' not in text or 'name=unexpected_original_gui_return' in text or not re.search(r'name=timeout value=30\d\d',text):
                raise RuntimeError('Original source real-JVM counterexample not observed')
        else:
            if 'name=async_event_getter_returned' not in text or 'name=same_event_thread_exit_poll' not in text or 'name=acknowledged' not in text or 'name=timeout' in text:
                raise RuntimeError('Async ports did not allow original same-event-thread exit ACK')
        records=[{'file':identity(file),'record':json.loads(file.read_text())} for file in (scene/'game-exits').glob('*.json')]
        handoffs=[{'file':identity(file),'record':json.loads(file.read_text())} for file in (scene/'game-exits').glob('*.handoff.log')]
        if len(records)!=1 or len(handoffs)!=1 or records[0]['record']['exitCode']!=0 or handoffs[0]['record']['waitBudgetMs']!=3000:
            raise RuntimeError('original exit code/budget evidence incomplete')
        receipt['scenes'].append({'mode':mode,'journal':records,'handoff':handoffs})
        save()
    receipt['inputsAfter']=[identity(file) for file in sources]
    if receipt['inputsAfter']!=receipt['inputs']:raise RuntimeError('production inputs changed during actual compilation/execution')
    receipt['state']='PASS';print('PASS actual stock JNI GUI observation/restore/lease/window/worker/exit evidence='+str(output))
except Exception as error:
    receipt['state']='FAIL';receipt['error']={'type':type(error).__name__,'message':str(error)}
    raise
finally:
    receipt['finishedAt']=datetime.datetime.now().astimezone().isoformat();save()
