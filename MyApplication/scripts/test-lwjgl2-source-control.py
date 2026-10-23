"""真实Source/typed Core/完整bridge ring→原L2 JNI→实际交付JAR缓存/poll/next。

只编宿主DLL和测试类，不重建SDK/Ant，不替换JAR维护类/标准字段；当前Source冻点由调用者确认。
所有编译读仓外快照，前后源SHA与工具失败阶段写外置收据。平台窗口是明确外部边缘。
"""
import argparse,hashlib,importlib.util,json,os,re,subprocess,sys,zipfile
from pathlib import Path
from datetime import datetime
sys.dont_write_bytecode=True
from lib.host_cpp import configure_host_cmake,find_host_cmake
from lib.workspace_paths import external_output_path
ROOT=Path(__file__).resolve().parents[1]
def sha(path):
    """摘要按实际原字节，作为编译输入/制品身份；不以文件名代替身份。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()
def refresh(path,data):
    """复用只保持完全相同输入的mtime；任何字节差异仍更新并正常重编，不借缓存冒称新源。"""
    path.parent.mkdir(parents=True,exist_ok=True)
    if not path.is_file() or path.read_bytes()!=data:path.write_bytes(data)
def module(path):
    """复用原源码提取器/平台窗口边缘，不能复用其假五int运输作为Source证据。"""
    spec=importlib.util.spec_from_file_location('source_l2_recipe',path);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
def run(args,cwd,log,negative=False):
    """前台执行并完整留原输出；编译/链接/初始化错误不会变成消费成功。"""
    print('[L2 source] '+' '.join(map(str,args)),flush=True)
    # 正式Core路由在首次getter时锁存；必须在DLL加载前给子进程事实，不能事后setenv改已冻结选择。
    childEnv=dict(os.environ);childEnv.update(AMCL_GLFW_INPUT_BACKEND='typed',AMCL_INPUT_SHADOW='0')
    value=subprocess.run(list(map(str,args)),cwd=cwd,capture_output=True,timeout=180,env=childEnv)
    log.write_bytes(value.stdout+value.stderr);print((value.stdout+value.stderr).decode('utf8',errors='replace')[-9000:],flush=True)
    if negative:
        if value.returncode==0 or b'L2_SOURCE new target same-code source remains held' not in value.stdout+value.stderr or b'AssertionError' not in value.stdout+value.stderr:
            raise RuntimeError('Compiled negative did not fail original target behavior: '+str(log))
    elif value.returncode:raise RuntimeError(str(log)+' exit='+str(value.returncode))
def main(options):
    """一次构建冻结全部必要C/C++与JAR；receipt总在finally写，失败不覆写前次输出。"""
    focusOnly=getattr(options,'focus_only',False)
    if focusOnly and (options.negative_stale_drain or getattr(options,'unicode_negative',None)):
        raise ValueError('focus-only cannot mix original withdrawal matrices')
    if options.negative_stale_drain and getattr(options,'unicode_negative',None):
        raise ValueError('Select one compiled withdrawal; do not mix two original behavior controls')
    out=external_output_path(options.out);build=external_output_path(options.build_out)
    out.mkdir(parents=True,exist_ok=False);build.mkdir(parents=True,exist_ok=options.reuse_build)
    temp=build/'temp';temp.mkdir(exist_ok=options.reuse_build);os.environ.update(TEMP=str(temp),TMP=str(temp),TMPDIR=str(temp))
    before={};start=datetime.now().astimezone().isoformat();phase='freeze';success=False
    try:
        cpp=build/'cpp';originalCpp=ROOT/'entry/src/main/cpp'
        for path in sorted(originalCpp.rglob('*')):
            if path.is_file() and path.suffix in {'.c','.cpp','.h','.hpp'}:
                target=cpp/path.relative_to(originalCpp);refresh(target,path.read_bytes());before[path.relative_to(ROOT).as_posix()]=sha(path)
        inputs=[ROOT/'prebuilt/lwjgl2/ohos-backend/amcl_lwjgl2_backend.c',ROOT/'entry/src/main/resources/rawfile/lwjgl2/lwjgl.jar',
            ROOT/'entry/src/main/resources/rawfile/lwjgl-3.2.3/lwjgl-glfw.jar',ROOT/'scripts/test-lwjgl2-control-delivery.py',
            ROOT/'scripts/fixtures/input-consumer/L2SourceProductionTest.java',ROOT/'scripts/fixtures/input-consumer/l2_source_owner.cpp.in',Path(__file__),
            ROOT/'prebuilt/lwjgl2/patches/java/org/lwjgl/opengl/AMCLDisplay.java',ROOT/'prebuilt/lwjgl2/patches/control-readpoints.patch',ROOT/'prebuilt/lwjgl2/build-inputs.json',ROOT/'scripts/rebuild-lwjgl2-input-jar.py']
        for path in inputs:before[path.relative_to(ROOT).as_posix()]=sha(path)
        backend=inputs[0].read_text(encoding='utf8');jar=build/'lwjgl.jar'
        selectedJar=getattr(options,'jar',None) or inputs[1]
        # 本轮Java候选由完整上游patch/class编译另行核验，真实行为可显式绑定它；不替换交付rawfile。
        selectedJar=selectedJar.resolve();selectedJarSha=sha(selectedJar);jar.write_bytes(selectedJar.read_bytes())
        modern=build/'lwjgl-glfw.jar';modern.write_bytes(inputs[2].read_bytes())
        java=build/'L2SourceProductionTest.java';java.write_bytes(inputs[4].read_bytes())
        refresh(build/'owner.cpp',inputs[5].read_bytes())
        jdk=options.jdk.resolve();archive=options.inputs/'lwjgl-2df01dd.zip'
        lock=json.loads((ROOT/'prebuilt/lwjgl2/build-inputs.json').read_text(encoding='utf8'))
        if sha(archive)!=lock['files'][archive.name]:raise ValueError('unlocked actual L2 source archive')
        with zipfile.ZipFile(archive) as z:common=z.read('lwjgl-'+lock['sourceCommit']+'/src/native/common/common_tools.c').decode('utf8')
        recipe=module(ROOT/'scripts/test-lwjgl2-control-delivery.py');extract=recipe.function_text
        prefix=recipe.NATIVE_PREFIX.replace('static void l2SetTypedChannelActive(int active){(void)active;}',
            '__declspec(dllimport) void sourceL2SetActive(int);\nstatic void l2SetTypedChannelActive(int active){sourceL2SetActive(active);}')
        prefix+='\nstatic void hostDestroyWindow(GLFWwindow*w){(void)w;}\nstatic void (*p_destroy)(GLFWwindow*)=hostDestroyWindow;\n'
        suffix=recipe.NATIVE_SUFFIX
        suffix=suffix.replace(extract(suffix,'next_record'),'__declspec(dllimport) int sourceL2Next(int*,int*,int*,int*,int*);\nstatic int next_record(int*t,int*a,int*b,int*c,int*d){return sourceL2Next(t,a,b,c,d);}')
        suffix=suffix.replace('L2ControlProductionTest','L2SourceProductionTest')
        # 外部OS getter按原调用窗口冻结值；同步reentry换窗不会让该原返回值变成new-window值。
        suffix=suffix.replace('(void)c;\n    if(reentry_mode)', '(void)c; double origin_x=cursor_x;\n    if(reentry_mode)',1)
        suffix=suffix.replace('    return cursor_x;\n}', '    return origin_x;\n}',1)
        suffix=suffix.replace('s_window=(GLFWwindow*)(uintptr_t)0x2000;', 's_window=(GLFWwindow*)(uintptr_t)0x2000;cursor_x=500.0;cursor_y=400.0;',1)
        suffix=suffix.replace(extract(suffix,'Java_org_lwjgl_opengl_AMCLDisplay_nSetGrab'),'')
        # Source target退休场必须执行原JNI退出正文的typed/legacy activation cutoff。
        # 旧control-only夹具仅把OS指针设NULL，不能证明完整窗口close；这里只替真实OS destroy边缘。
        suffix=suffix.replace(extract(suffix,'Java_org_lwjgl_opengl_AMCLDisplay_nDestroyWindow'),'')
        suffix+='\nJNIEXPORT void JNICALL Java_org_lwjgl_opengl_L2SourceProductionTest_armTargetReentry(JNIEnv*e,jclass c){(void)e;(void)c;reentry_mode=2;}\n'
        suffix+='\n__declspec(dllimport) void sourceSetGrab(int);\nstatic void (*p_ib_set_grab)(int)=sourceSetGrab;\n#define A2LOG(...) ((void)0)\n'
        control=backend[backend.index('static int control_write_emission('):backend.index('/* grab 切换：',backend.index('static int control_write_emission('))]
        contract=backend[backend.index('#define AMCL_L2_CONTROL_PROTOCOL'):backend.index('static int s_width')]
        nextStart=backend.index('JNIEXPORT jboolean JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nNextEvent')
        nextBody=backend[nextStart:backend.index('\n/* ===================== 末级控制私有JNI',nextStart)]
        bodies='\n'.join(extract(backend,name) for name in ['Java_org_lwjgl_opengl_AMCLDisplay_nInputContract','Java_org_lwjgl_opengl_AMCLDisplay_nLookContract',
            'Java_org_lwjgl_opengl_AMCLDisplay_nCreateWindow','Java_org_lwjgl_opengl_AMCLContextImplementation_nCreate','Java_org_lwjgl_opengl_AMCLDisplay_nDestroyWindow','Java_org_lwjgl_opengl_AMCLDisplay_nSetGrab'])
        throwers='\n'.join(extract(common,name) for name in ['throwGeneralException','throwException'])
        (build/'consumer.c').write_text('\n'.join([prefix,throwers,contract,suffix,control,bodies,nextBody]),encoding='utf8')
        bridgePath=cpp/'glfw/input_bridge_ohos.c';bridge=bridgePath.read_text(encoding='utf8')
        bridge=re.sub(r'#include "([^\"]+)"',lambda m:'#include "'+(bridgePath.parent/m[1]).resolve().as_posix()+'"' if (bridgePath.parent/m[1]).exists() else m[0],bridge)
        registry=(cpp/'jvm/jni_registry.cpp').read_text(encoding='utf8')
        declarations=registry[registry.index('extern "C" {'):registry.index('// ============================================================\n// 精确方法表')]
        (build/'bridge.cpp').write_text(declarations+'\n'+bridge,encoding='utf8')
        (build/'unistd.h').write_text('#pragma once\n#include <process.h>\ninline int getpid(){return _getpid();}\n',encoding='utf8')
        units=['input/source/source_control.cpp','platform/input_ledger.cpp','platform/external_held_registry.cpp','platform/external_held_edge_router.cpp',
            'platform/legacy_output_runtime.cpp','platform/legacy_physical_edge_router.cpp','input/delivery/control_delivery.cpp','input/delivery/look_execution.cpp',
            'platform/look_delta_math.cpp','platform/look_pipeline_stats.cpp','input/input_state_core.cpp','input/amcl_input_host_descriptor.cpp',
            'input/input_interaction_order.cpp','input/adapters/glfw_source_plane_aggregate.cpp','input/adapters/lwjgl2_event_translate.cpp',
            'input/adapters/backend_input_bridge.cpp','input/adapters/glfw_input_adapter.cpp','input/adapters/backend_keymaps.cpp','platform/physical_wheel_quantizer.cpp',
            'platform/input_source.cpp','input/platform_input_ingress.cpp','input/input_shadow_consumer.cpp','input/input_trace.cpp','jvm/jni_registry.cpp']
        quote=lambda p:'"'+p.as_posix()+'"'
        sources=' '.join(quote(cpp/name) for name in units)
        project='cmake_minimum_required(VERSION 3.20)\nproject(l2_source C CXX)\nset(CMAKE_CXX_STANDARD 17)\nset(CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS ON)\n'
        for name in ['source_owner','source_peer']:
            project+='add_library('+name+' SHARED owner.cpp bridge.cpp '+sources+')\n'
            project+='target_compile_definitions('+name+' PRIVATE AMCL_INPUT_HOST_EXPORTS AMCL_INPUT_BRIDGE_HOST_TESTING AMCL_CONTROL_DELIVERY_HOST_TESTING AMCL_JNI_BRIDGE_HOST_TEST AMCL_INPUT_SHADOW=0 _CRT_SECURE_NO_WARNINGS EVENT_WINDOW_SIZE='+('512' if focusOnly else '8')+')\n'
            project+='target_compile_options('+name+' PRIVATE /utf-8)\n'
            project+='target_include_directories('+name+' PRIVATE '+quote(build)+' '+quote(jdk/'include')+' '+quote(jdk/'include/win32')+' '+quote(cpp)+' '+quote(cpp/'input')+' '+quote(cpp/'platform')+' '+quote(cpp/'tests/host/stubs')+')\n'
        project+='add_library(lwjgl_v2 SHARED consumer.c)\ntarget_compile_definitions(lwjgl_v2 PRIVATE AMCL_CONTROL_DELIVERY_HOST_TESTING _CRT_SECURE_NO_WARNINGS)\n'
        project+='target_include_directories(lwjgl_v2 PRIVATE '+quote(cpp/'input/delivery')+' '+quote(jdk/'include')+' '+quote(jdk/'include/win32')+')\ntarget_link_libraries(lwjgl_v2 PRIVATE source_owner)\n'
        project+='add_library(jni_reregister SHARED '+quote(cpp/'glfw/jni_reregister.c')+')\ntarget_compile_definitions(jni_reregister PRIVATE AMCL_JNI_BRIDGE_HOST_TEST _CRT_SECURE_NO_WARNINGS)\n'
        project+='target_include_directories(jni_reregister PRIVATE '+quote(jdk/'include')+' '+quote(jdk/'include/win32')+')\n'
        (build/'CMakeLists.txt').write_text(project,encoding='utf8');classes=build/'classes';classes.mkdir(exist_ok=options.reuse_build)
        phase='javac';run([jdk/'bin/javac.exe','-encoding','UTF-8','-source','1.6','-target','1.6','-cp',os.pathsep.join([str(jar),str(modern)]),'-d',classes,java],build,out/'javac.log')
        # 正例真实JAR先保原全部private/public/protected/Native签名；只允许固定两helper。
        # 再实际编译一个未知private字段反例并用同一正式门拒绝，不能靠无关编译失败作证。
        abiRecipe=module(ROOT/'scripts/rebuild-lwjgl2-input-jar.py')
        for className in ['org.lwjgl.opengl.AMCLDisplay','org.lwjgl.opengl.EventQueue']:
            declarations=[]
            for label,cp in [('shipping',inputs[1]),('candidate',jar)]:
                result=subprocess.run([str(jdk/'bin/javap.exe'),'-private','-s','-classpath',str(cp),className],capture_output=True,timeout=60)
                (out/(label+'-'+className+'-abi.log')).write_bytes(result.stdout+result.stderr)
                if result.returncode:raise RuntimeError('Actual Unicode ABI javap failed')
                declarations.append(result.stdout)
            abiRecipe.verify_declarations(*declarations,className)
        abiSource=build/'unicode-abi-negative-source';abiSource.mkdir(exist_ok=options.reuse_build)
        candidate=abiSource/'AMCLDisplay.java';text=inputs[7].read_text(encoding='utf8')
        needle='final class AMCLDisplay implements DisplayImplementation {';assert text.count(needle)==1
        candidate.write_text(text.replace(needle,needle+'\n    private int amclUnexpectedUnicodeAbi;',1),encoding='utf8')
        abiClasses=build/'unicode-abi-negative-classes';abiClasses.mkdir(exist_ok=options.reuse_build)
        run([jdk/'bin/javac.exe','-encoding','UTF-8','-source','1.6','-target','1.6','-cp',jar,'-d',abiClasses,candidate],build,out/'unicode-abi-negative-javac.log')
        abiJar=out/'compiled-abi-negative.jar'
        with zipfile.ZipFile(jar) as original,zipfile.ZipFile(abiJar,'w') as result:
            for member in original.infolist():result.writestr(member,(abiClasses/member.filename).read_bytes() if member.filename=='org/lwjgl/opengl/AMCLDisplay.class' else original.read(member))
        actual=subprocess.run([str(jdk/'bin/javap.exe'),'-private','-s','-classpath',str(abiJar),'org.lwjgl.opengl.AMCLDisplay'],capture_output=True,timeout=60)
        (out/'unicode-abi-negative-javap.log').write_bytes(actual.stdout+actual.stderr)
        if actual.returncode:raise RuntimeError('Compiled unknown-member ABI javap failed')
        shipping=subprocess.run([str(jdk/'bin/javap.exe'),'-private','-s','-classpath',str(inputs[1]),'org.lwjgl.opengl.AMCLDisplay'],capture_output=True,timeout=60)
        if shipping.returncode:raise RuntimeError('Shipping ABI javap failed')
        try:abiRecipe.verify_declarations(shipping.stdout,actual.stdout,'org.lwjgl.opengl.AMCLDisplay')
        except ValueError as error:
            if 'Existing Java/JNI declaration changed or unknown addition' not in str(error):raise
            (out/'unicode-abi-negative-rejected.log').write_text(str(error),encoding='utf8')
        else:raise RuntimeError('Compiled unknown private member incorrectly accepted')
        if options.negative_stale_drain:
            # 只撤正式Java的原consumer guard，ABI字段/owner/运输/JNI均保持；编译成功才执行负控。
            path=ROOT/'prebuilt/lwjgl2/patches/java/org/lwjgl/opengl/AMCLDisplay.java';text=path.read_text(encoding='utf8')
            needle='controlConsumer == originConsumer && nNextEvent(evTmp)';assert text.count(needle)==1
            candidate=build/'AMCLDisplay.java';candidate.write_text(text.replace(needle,'nNextEvent(evTmp)'),encoding='utf8')
            negativeClasses=build/'negative-classes';negativeClasses.mkdir(exist_ok=options.reuse_build)
            run([jdk/'bin/javac.exe','-encoding','UTF-8','-source','1.6','-target','1.6','-cp',jar,'-d',negativeClasses,candidate],build,out/'negative-javac.log')
            negativeJar=build/'negative.jar'
            with zipfile.ZipFile(jar) as original,zipfile.ZipFile(negativeJar,'w') as result:
                for member in original.infolist():result.writestr(member,(negativeClasses/member.filename).read_bytes() if member.filename=='org/lwjgl/opengl/AMCLDisplay.class' else original.read(member))
            jar=negativeJar
        unicodeNegative=getattr(options,'unicode_negative',None)
        if unicodeNegative:
            # 外置负控仍从固定ZIP/正式patch和本轮Java原文构造；只撤一项承重行为。
            # 必须先javac成功、封装实际class后，再让同一正式JVM断言拒绝错消费。
            negativeSource=build/'unicode-negative-source';negativeSource.mkdir(exist_ok=options.reuse_build)
            with zipfile.ZipFile(archive) as z:
                for name in ['input/Keyboard.java','input/Mouse.java','opengl/Display.java','opengl/EventQueue.java']:
                    target=negativeSource/'src/java/org/lwjgl'/name;target.parent.mkdir(parents=True,exist_ok=True)
                    target.write_bytes(z.read('lwjgl-'+lock['sourceCommit']+'/src/java/org/lwjgl/'+name))
            patch=ROOT/'prebuilt/lwjgl2/patches/control-readpoints.patch'
            run(['git','-c','core.autocrlf=false','apply','--check',patch],negativeSource,out/'unicode-negative-patch-check.log')
            run(['git','-c','core.autocrlf=false','apply',patch],negativeSource,out/'unicode-negative-patch.log')
            candidate=negativeSource/'AMCLDisplay.java';text=inputs[7].read_text(encoding='utf8')
            eventQueue=negativeSource/'src/java/org/lwjgl/opengl/EventQueue.java'
            if unicodeNegative=='split':
                # 该方法在drain中先有调用；只能从真实定义锚点提取，避免撤回调用后误吞别的方法。
                original=extract(text[text.index('private boolean putCharacterEvent('):],'putCharacterEvent')
                text=text.replace(original,'private boolean putCharacterEvent(int character, long[] origin) { return putKeyRecord(0,true,character,false,null,origin); }',1)
            elif unicodeNegative=='scope':
                for old,new in [
                    ('if (queue == null || origin == null || nKeyboardValidate(origin) != 1) return false;','if (queue == null || origin == null) return false;'),
                    ('if (nKeyboardValidate(origin) != 1 || keyboardEventQueue != queue || keyboardLease != origin) return false;','/* compiled negative: original scope commit guard withdrawn */')]:
                    assert text.count(old)==1;text=text.replace(old,new,1)
            elif unicodeNegative=='pair':
                queueText=eventQueue.read_text(encoding='utf8');old='if (queue.remaining() < bytes) return false;';assert queueText.count(old)==1
                queueText=queueText.replace(old,'if (queue.remaining() < event_size) return false; events.limit(events.position()+Math.min(bytes,queue.remaining()));',1)
                eventQueue.write_text(queueText,encoding='utf8')
            candidate.write_text(text,encoding='utf8');negativeClasses=build/'unicode-negative-classes';negativeClasses.mkdir(exist_ok=options.reuse_build)
            run([jdk/'bin/javac.exe','-encoding','UTF-8','-source','1.6','-target','1.6','-cp',jar,'-d',negativeClasses,candidate,eventQueue],build,out/'unicode-negative-javac.log')
            negativeJar=build/'unicode-negative.jar'
            names=['org/lwjgl/opengl/AMCLDisplay.class','org/lwjgl/opengl/EventQueue.class']
            with zipfile.ZipFile(jar) as original,zipfile.ZipFile(negativeJar,'w') as result:
                for member in original.infolist():result.writestr(member,(negativeClasses/member.filename).read_bytes() if member.filename in names else original.read(member))
            jar=negativeJar
            # 宿主缓存可复用，但每场已执行的负控class/JAR/源码须在证据目录永久冻结。
            # 下一场复用不能覆掉前一场的实际载荷，receipt也绑定这一份保留字节。
            (out/'compiled-negative.jar').write_bytes(jar.read_bytes())
            (out/'AMCLDisplay.java').write_bytes(candidate.read_bytes())
            (out/'EventQueue.java').write_bytes(eventQueue.read_bytes())
            for name in names:
                target=out/'compiled-classes'/name;target.parent.mkdir(parents=True,exist_ok=True)
                target.write_bytes((negativeClasses/name).read_bytes())
            jar=out/'compiled-negative.jar'
        phase='configure';cmake=find_host_cmake(options.cmake);configure_host_cmake(cmake,build,build/'build')
        phase='native-compile';run([cmake,'--build',build/'build','--config','Release','--parallel','1' if focusOnly else '4'],build,out/'compile.log')
        binaries=build/'build/Release';phase='actual-jvm'
        # 每场Native实际载荷也冻结原字节，避免复用构建树的下一次链接覆掉前场证据。
        nativeArtifacts={}
        for name in ['lwjgl_v2.dll','source_owner.dll','source_peer.dll','jni_reregister.dll']:
            target=out/'native-artifacts'/name;target.parent.mkdir(parents=True,exist_ok=True)
            target.write_bytes((binaries/name).read_bytes());nativeArtifacts[name]=sha(target)
        if not focusOnly and not getattr(options,'unicode_only',False) and not unicodeNegative:
            binaries=build/'build/Release';phase='actual-jvm';run([jdk/'bin/java.exe','-XX:-UsePerfData','-Dos.name=Linux','-Djava.library.path='+str(binaries),
                '-Dorg.lwjgl.librarypath='+str(binaries),'-cp',os.pathsep.join([str(classes),str(jar),str(modern)]),'org.lwjgl.opengl.L2SourceProductionTest',
                binaries/'lwjgl_v2.dll',binaries/'source_owner.dll',binaries/'source_peer.dll'],build,out/'production.log',options.negative_stale_drain)
            run([jdk/'bin/java.exe','-XX:-UsePerfData','-Dos.name=Linux','-Djava.library.path='+str(binaries),
                '-Dorg.lwjgl.librarypath='+str(binaries),'-cp',os.pathsep.join([str(classes),str(jar),str(modern)]),'org.lwjgl.opengl.L2SourceProductionTest',
                binaries/'lwjgl_v2.dll',binaries/'source_owner.dll',binaries/'source_peer.dll','poll-target'],build,out/'poll-target.log')
            # 四场使用独立JVM的真实Keyboard/Mouse生命周期，不沿用前场的owner/缓存/静态资格。
            # 它们与原Source/Core/full bridge/JNI/JAR同源，分别核无Keyboard冷拒、局部代次围栏、
            # 唯一合法held基线及旧deferred末松退休；反控Jar仍须在原指定失败场命中行为断言。
            if not options.negative_stale_drain:
                for mode in ['mouse-only','local-recreate','held-recreate','deferred-old-scope','typed-held-recreate','text-char-recreate']:
                    run([jdk/'bin/java.exe','-XX:-UsePerfData','-Dos.name=Linux','-Djava.library.path='+str(binaries),
                        '-Dorg.lwjgl.librarypath='+str(binaries),'-cp',os.pathsep.join([str(classes),str(jar),str(modern)]),'org.lwjgl.opengl.L2SourceProductionTest',
                        binaries/'lwjgl_v2.dll',binaries/'source_owner.dll',binaries/'source_peer.dll',mode],build,out/(mode+'.log'))
        unicodeModes=['unicode-sequence','unicode-budget','unicode-scope','unicode-thread']
        if unicodeNegative:
            mode,marker={'split':('unicode-sequence',b'L2_UNICODE_UTF16_PAIR'),
                'pair':('unicode-budget',b'L2_UNICODE_ATOMIC_PAIR_BUDGET'),
                'scope':('unicode-scope',b'L2_UNICODE_ORIGINAL_SCOPE')}[unicodeNegative]
            command=[jdk/'bin/java.exe','-XX:-UsePerfData','-Dos.name=Linux','-Djava.library.path='+str(binaries),
                '-Dorg.lwjgl.librarypath='+str(binaries),'-cp',os.pathsep.join([str(classes),str(jar),str(modern)]),
                'org.lwjgl.opengl.L2SourceProductionTest',binaries/'lwjgl_v2.dll',binaries/'source_owner.dll',binaries/'source_peer.dll',mode]
            print('[L2 source Unicode compiled withdrawal] '+' '.join(map(str,command)),flush=True)
            result=subprocess.run(list(map(str,command)),cwd=build,capture_output=True,timeout=60,
                env=dict(os.environ,AMCL_GLFW_INPUT_BACKEND='typed',AMCL_INPUT_SHADOW='0'))
            (out/'unicode-negative-behavior.log').write_bytes(result.stdout+result.stderr)
            print((result.stdout+result.stderr).decode('utf8',errors='replace')[-5000:],flush=True)
            if result.returncode==0 or marker not in result.stdout+result.stderr or b'AssertionError' not in result.stdout+result.stderr:
                raise RuntimeError('Compiled Unicode withdrawal did not fail exact behavior marker')
        elif not focusOnly and not options.negative_stale_drain:
            for mode in unicodeModes:
                run([jdk/'bin/java.exe','-XX:-UsePerfData','-Dos.name=Linux','-Djava.library.path='+str(binaries),
                    '-Dorg.lwjgl.librarypath='+str(binaries),'-cp',os.pathsep.join([str(classes),str(jar),str(modern)]),'org.lwjgl.opengl.L2SourceProductionTest',
                    binaries/'lwjgl_v2.dll',binaries/'source_owner.dll',binaries/'source_peer.dll',mode],build,out/(mode+'.log'))
        if focusOnly:
            # 仅本组用真实512槽bridge，公开next可实际穷尽固定256前沿；原8槽压力组不变。
            # 每场独立JVM，仍是原Source/Core/full bridge及原JNI，不用测试sink算资格。
            for mode in ['no-pump','peek','half-pump','half-no-pump','end','retire','split-buffer','legacy-units','fifo','reentry']:
                run([jdk/'bin/java.exe','-XX:-UsePerfData','-Dos.name=Linux','-Djava.library.path='+str(binaries),
                    '-Dorg.lwjgl.librarypath='+str(binaries),'-cp',os.pathsep.join([str(classes),str(jar),str(modern)]),
                    'org.lwjgl.opengl.L2SourceProductionTest',binaries/'lwjgl_v2.dll',binaries/'source_owner.dll',
                    binaries/'source_peer.dll','focus:'+mode],build,out/('focus-'+mode+'.log'))
        success=True;phase='complete'
    finally:
        after={name:sha(ROOT/name) for name in before};drift=[name for name in before if before[name]!=after[name]]
        receipt={'startedAt':start,'completedAt':datetime.now().astimezone().isoformat(),'phase':phase,'success':success,'negativeStaleDrain':options.negative_stale_drain,'unicodeNegative':getattr(options,'unicode_negative',None),'unicodeOnly':getattr(options,'unicode_only',False),'focusOnly':focusOnly,'focusRingCapacity':512 if focusOnly else None,'sourcesBefore':before,'sourcesAfter':after,'sourceDrift':drift,
            'selectedJar':{'path':str(selectedJar),'sha256':selectedJarSha,'afterSha256':sha(selectedJar)} if 'selectedJar' in locals() else None,
            # 负控编译后的实际JVM载荷与原正例JAR分列，不能只记录未执行的selectedJar。
            'executedJar':{'path':str(jar),'sha256':sha(jar)} if 'jar' in locals() and jar.is_file() else None,
            'compiledNativeArtifacts':nativeArtifacts if 'nativeArtifacts' in locals() else {},
            'boundary':'real Source/Core/typed backend/full bridge original JNI/actual shipped JAR caches and reads; external Windows/platform/JNI fixture; no full SDK/device/game adoption'}
        (out/'receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2),encoding='utf8')
        if drift:raise RuntimeError('Source changed during test: '+', '.join(drift))
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--out',type=Path,required=True);parser.add_argument('--build-out',type=Path,required=True)
    parser.add_argument('--jdk',type=Path,required=True);parser.add_argument('--inputs',type=Path,required=True);parser.add_argument('--cmake')
    parser.add_argument('--jar',type=Path,help='显式只读绑定已核验候选JAR；默认仍测试实际交付rawfile，不修改部署资产')
    parser.add_argument('--reuse-build',action='store_true',help='仅复用调用者明确登记的宿主缓存；源码逐字刷新并另落收据，不借旧编译资格')
    parser.add_argument('--focus-only',action='store_true',help='只跑原Core/fullbridge/JNI/JAR焦点scalar10场；真实512槽/单job，旧压力矩阵仍8槽')
    parser.add_argument('--unicode-only',action='store_true',help='只运行本批完整Core/JNI/JAR Unicode四场；旧矩阵在正常默认入口继续保留')
    parser.add_argument('--unicode-negative',choices=['split','pair','scope'],help='外置真实编译后撤回scalar分解/完整pair预算/原scope验证；要求准确行为AssertionError')
    parser.add_argument('--negative-stale-drain',action='store_true',help='仓外编译撤去原consumer guard，必须真实错消费newtarget并行为断言失败');main(parser.parse_args())
