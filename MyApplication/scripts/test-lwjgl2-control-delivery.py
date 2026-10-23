"""通过真实JVM/JNI和生产neutral owner验证LWJGL2末级控制贡献及真实next/poll。

从摘要固定ZIP应用正式读取点patch，重编完整原Keyboard/Mouse/Display类；JAR仅替换
五个维护类，其他成员逐字保持。Native只替换外部窗口/光标/事件运输，
私有JNI函数原样取生产C正文，链接真实control_delivery/input_state_core/host_descriptor/order。
负控必须编译成功并触发明确行为断言；输出/TEMP均在调用者显式外置目录。
"""
import argparse
import hashlib
from datetime import datetime
import json
import os
from pathlib import Path
import subprocess
import zipfile
from lib.host_cpp import configure_host_cmake, find_host_cmake
from lib.workspace_paths import external_output_path

ROOT=Path(__file__).resolve().parents[1]


def function_text(source,name):
    """定位指定真实生产函数并完整提取；这些入口无字符串括号，不重写函数算法。"""
    location=source.index(name+'(')
    start=source.rfind('\n',0,location)+1
    begin=source.index('{',location);depth=1;end=begin+1
    while depth:
        depth+=(source[end]=='{')-(source[end]=='}');end+=1
    return source[start:end]


def run(args, directory, log, expected=0, failure_marker=b'AssertionError'):
    """保持前台子进程；完整原始输出写外置证据，明确区分负控行为失败与编译失败。"""
    print('[l2-production] '+' '.join(map(str,args)),flush=True)
    result=subprocess.run(list(map(str,args)),cwd=directory,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
    log.write_bytes(result.stdout)
    print(result.stdout.decode('utf-8',errors='replace')[-7000:],flush=True)
    if expected==0 and result.returncode!=0: raise RuntimeError('failed: '+str(log))
    if expected!=0 and (result.returncode==0 or failure_marker not in result.stdout):
        raise RuntimeError('negative control did not fail a behavior assertion: '+str(log))
    return result


NATIVE_PREFIX=r'''
#include <jni.h>
#include <windows.h>
#include <stdint.h>
#include <string.h>
#include "control_delivery_client.h"
#include "look_execution_client.h"
#include "../input_latency_client.h"
#include "l2_keyboard_scope_client.h"
typedef void* GLFWwindow;
static GLFWwindow* s_window=(GLFWwindow*)(uintptr_t)0x1000;
static const AmclControlDeliveryPortV1* s_control_port=NULL;
static uint64_t s_control_consumer=0;
static uint64_t s_control_target=0;
static int platform_creates=0,platform_reads=0;
static int s_width=0,s_height=0;
static unsigned char s_ctx_handle[16];
static void read_dimensions(int* width,int* height){*width=800;*height=600;}
static int ensure_window(void){if(s_window==NULL){++platform_creates;s_window=(GLFWwindow*)(uintptr_t)0x1000;}return 1;}
static void l2SetTypedChannelActive(int active){(void)active;}
'''

NATIVE_SUFFIX=r'''
/* 原五整数Next函数仍从真实JNI函数调用；fixture仅代外部运输，不裁决最终边沿。 */
static int records[10000][5],begin_record=0,end_record=0;
static double cursor_x=100.0,cursor_y=200.0;
static int next_record(int* t,int* a,int* b,int* c,int* d){
    ++platform_reads;
    if(begin_record==end_record)return 0;
    int* e=records[begin_record++];*t=e[0];*a=e[1];*b=e[2];*c=e[3];*d=e[4];
    if(*t==1010){uint64_t xb=((uint64_t)(uint32_t)e[2]<<32)|(uint32_t)e[1];
        uint64_t yb=((uint64_t)(uint32_t)e[4]<<32)|(uint32_t)e[3];
        memcpy(&cursor_x,&xb,sizeof(xb));memcpy(&cursor_y,&yb,sizeof(yb));}
    return 1;
}
static int (*p_ib_next)(int*,int*,int*,int*,int*)=next_record;
static void resolve_input(void){}
JNIEXPORT void JNICALL Java_org_lwjgl_opengl_L2ControlProductionTest_publish(JNIEnv* e,jclass c,jboolean valid){
    (void)e;(void)c;
    if(valid){amclControlDeliveryPublishV1();amclLookExecutionPublishV1();
        const AmclLookExecutionPortV1* look=amclLookExecutionGetPortV1();
        look->bindSession(1);look->publishMode(1,1,0);
    }else _putenv_s(AMCL_CONTROL_ENV,"AMCLCONTROL:1:bad");
}
JNIEXPORT void JNICALL Java_org_lwjgl_opengl_L2ControlProductionTest_push(JNIEnv* e,jclass c,jint t,jint a,jint b,jint x,jint y){
    (void)e;(void)c;int* r=records[end_record++];r[0]=t;r[1]=a;r[2]=b;r[3]=x;r[4]=y;
}
static int reentry_mode=0;
JNIEXPORT void JNICALL Java_org_lwjgl_opengl_L2ControlProductionTest_armReentry(JNIEnv* e,jclass c,jint mode){(void)e;(void)c;reentry_mode=mode;}
JNIEXPORT void JNICALL Java_org_lwjgl_opengl_L2ControlProductionTest_restoreWindow(JNIEnv* e,jclass c){(void)e;(void)c;s_window=(GLFWwindow*)(uintptr_t)0x2000;}
JNIEXPORT void JNICALL Java_org_lwjgl_opengl_L2InputContractTest_resetPlatform(JNIEnv* e,jclass c){
    (void)e;(void)c;s_window=NULL;platform_creates=0;platform_reads=0;
}
JNIEXPORT jintArray JNICALL Java_org_lwjgl_opengl_L2InputContractTest_platformCounts(JNIEnv* e,jclass c){
    (void)c;jint values[2]={platform_creates,platform_reads};jintArray result=(*e)->NewIntArray(e,2);
    (*e)->SetIntArrayRegion(e,result,0,2,values);return result;
}
JNIEXPORT jdouble JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nGetCursorX(JNIEnv* e,jclass c){
    (void)c;
    if(reentry_mode){int mode=reentry_mode;reentry_mode=0;
        jclass test=(*e)->FindClass(e,"org/lwjgl/opengl/L2ControlProductionTest");
        jmethodID method=(*e)->GetStaticMethodID(e,test,"reenter","(I)V");
        (*e)->CallStaticVoidMethod(e,test,method,mode);
    }
    return cursor_x;
}
JNIEXPORT jdouble JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nGetCursorY(JNIEnv* e,jclass c){(void)e;(void)c;return cursor_y;}
JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nGetDesktopWidth(JNIEnv* e,jclass c){(void)e;(void)c;return 800;}
JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nGetDesktopHeight(JNIEnv* e,jclass c){(void)e;(void)c;return 600;}
JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nGetWidth(JNIEnv* e,jclass c){(void)e;(void)c;return 800;}
JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nGetHeight(JNIEnv* e,jclass c){(void)e;(void)c;return 600;}
JNIEXPORT void JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nSetGrab(JNIEnv* e,jclass c,jboolean v){(void)e;(void)c;(void)v;}
JNIEXPORT void JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nDestroyWindow(JNIEnv* e,jclass c){(void)e;(void)c;s_window=NULL;}
JNIEXPORT jint JNICALL Java_org_lwjgl_DefaultSysImplementation_getJNIVersion(JNIEnv* e,jobject c){(void)e;(void)c;return 19;}
JNIEXPORT jint JNICALL Java_org_lwjgl_DefaultSysImplementation_getPointerSize(JNIEnv* e,jobject c){(void)e;(void)c;return 8;}
JNIEXPORT void JNICALL Java_org_lwjgl_DefaultSysImplementation_setDebug(JNIEnv* e,jobject c,jboolean v){(void)e;(void)c;(void)v;}
'''


def build(options):
    """构建完整真实消费闭包，并分别执行正例与省掉读取证据/验证的可编译负控。"""
    output=external_output_path(options.out)
    if output.exists(): raise ValueError('Test output must be a new directory: '+str(output))
    output.mkdir(parents=True)
    # 并行施工不等于并行修改本次构建输入。所有正式CPP/header在第一次读取时冻结，
    # 编译器只见这一份仓外闭包，receipt绑定实际字节而非测试末尾的新工作树内容。
    cpp_source=ROOT/'entry/src/main/cpp'
    cpp_snapshot=output/'production-cpp';cpp_identities={}
    for path in sorted(cpp_source.rglob('*')):
        if path.is_file() and path.suffix in {'.c','.cpp','.h','.hpp'}:
            data=path.read_bytes();target_path=cpp_snapshot/path.relative_to(cpp_source)
            target_path.parent.mkdir(parents=True,exist_ok=True);target_path.write_bytes(data)
            cpp_identities[path.relative_to(ROOT).as_posix()]=hashlib.sha256(data).hexdigest()
    acquired_at=datetime.now().astimezone().isoformat()
    producer_inputs=[ROOT/'prebuilt/lwjgl2/ohos-backend/amcl_lwjgl2_backend.c',
        ROOT/'prebuilt/lwjgl2/patches/java/org/lwjgl/opengl/AMCLDisplay.java',
        ROOT/'prebuilt/lwjgl2/patches/control-readpoints.patch',
        ROOT/'scripts/fixtures/input-consumer/L2LookProductionTest.java',
        ROOT/'scripts/fixtures/input-consumer/l2_look_support.c.in',Path(__file__)]
    producer_identities={path.relative_to(ROOT).as_posix():hashlib.sha256(path.read_bytes()).hexdigest() for path in producer_inputs}
    temp=output/'temp';temp.mkdir(exist_ok=True)
    os.environ['TEMP']=str(temp);os.environ['TMP']=str(temp)
    jdk=options.jdk.resolve();suffix='.exe' if os.name=='nt' else ''
    spec=json.loads((ROOT/'prebuilt/lwjgl2/build-inputs.json').read_text(encoding='utf-8'))
    archive=options.inputs/'lwjgl-2df01dd.zip'
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=spec['files'][archive.name]: raise ValueError('unlocked ZIP')
    source=output/'source';source.mkdir(exist_ok=True)
    with zipfile.ZipFile(archive) as z:
        common_tools=z.read('lwjgl-'+spec['sourceCommit']+'/src/native/common/common_tools.c').decode('utf-8')
        for name in ['input/Keyboard.java','input/Mouse.java','opengl/Display.java','opengl/EventQueue.java']:
            path=source/'src/java/org/lwjgl'/name;path.parent.mkdir(parents=True,exist_ok=True)
            path.write_bytes(z.read('lwjgl-'+spec['sourceCommit']+'/src/java/org/lwjgl/'+name))
    patch=ROOT/'prebuilt/lwjgl2/patches/control-readpoints.patch'
    run(['git','apply','--check',patch],source,output/'patch-check.log')
    run(['git','apply',patch],source,output/'patch.log')
    classes=output/'classes';classes.mkdir(exist_ok=True)
    base=ROOT/'entry/src/main/resources/rawfile/lwjgl2/lwjgl.jar'
    java=list((ROOT/'prebuilt/lwjgl2/patches/java').rglob('*.java'))
    points=list((source/'src/java').rglob('*.java'))
    test=ROOT/'scripts/fixtures/input-consumer/L2ControlProductionTest.java'
    contract_test=ROOT/'scripts/fixtures/input-consumer/L2InputContractTest.java'
    look_test=ROOT/'scripts/fixtures/input-consumer/L2LookProductionTest.java'
    # 可选观测反控只撤真实Java hook，原Mouse.poll、cache及生产票complete仍正常执行。
    # 只有定向L2 ON门使用；编译失败不能充当观察缺段的行为证据。
    if options.latency_negative:
        original=ROOT/'prebuilt/lwjgl2/patches/java/org/lwjgl/opengl/AMCLDisplay.java'
        text=original.read_text(encoding='utf-8')
        needle={'poll':'nLookLatencyNote(originalView, 5);',
                'cache':'nLookLatencyNote(emission, 4);'}[options.latency_negative]
        if text.count(needle)!=1:raise ValueError('Latency withdrawal anchor changed')
        text=text.replace(needle,'/* compiled withdrawal: real latency hook removed */',1)
        changed=output/'candidate-java/AMCLDisplay.java';changed.parent.mkdir();changed.write_text(text,encoding='utf-8')
        java=[changed if path==original else path for path in java]
    # look反控只改仓外candidate；原游戏类/owner仍完整，编译失败不能当消费负控。
    if options.look_negative in ['cache','latest']:
        original=ROOT/'prebuilt/lwjgl2/patches/java/org/lwjgl/opengl/AMCLDisplay.java'
        text=original.read_text(encoding='utf-8')
        if options.look_negative=='cache':
            for needle in ['lookCursorX = Double.longBitsToDouble(emission[9]);','lookCursorY = Double.longBitsToDouble(emission[10]);']:
                assert text.count(needle)==1;text=text.replace(needle,'/* compiled negative: cache write removed */',1)
        else:
            for axis in ['X','Y']:
                needle='double d'+('x' if axis=='X' else 'y')+'Raw = lookCursor'+axis+' - lastCursor'+axis+';'
                assert text.count(needle)==1;text=text.replace(needle,needle.replace('lookCursor'+axis,'nGetCursor'+axis+'()'),1)
        candidate=output/'candidate-java/AMCLDisplay.java';candidate.parent.mkdir();candidate.write_text(text,encoding='utf-8')
        java=[candidate if path==original else path for path in java]
    elif options.look_negative=='poll':
        display=source/'src/java/org/lwjgl/opengl/Display.java';text=display.read_text(encoding='utf-8')
        needle='((AMCLDisplay)source).lookPollView(coordinates);';assert text.count(needle)==1
        display.write_text(text.replace(needle,'{ /* compiled negative: actual poll receipt removed */ }',1),encoding='utf-8')
    run([jdk/'bin'/('javac'+suffix),'-encoding','UTF-8','-source','1.6','-target','1.6','-cp',base,'-d',classes,*java,*points,test,contract_test,look_test],output,output/'javac.log')
    replacements=['org/lwjgl/opengl/AMCLDisplay.class','org/lwjgl/opengl/Display.class','org/lwjgl/input/Keyboard.class','org/lwjgl/input/Mouse.class','org/lwjgl/opengl/EventQueue.class']
    jar=output/'consumer.jar'
    with zipfile.ZipFile(base) as z,zipfile.ZipFile(jar,'w') as result:
        for member in z.infolist():result.writestr(member,(classes/member.filename).read_bytes() if member.filename in replacements else z.read(member))
    if options.consumer_jar:
        # 完整重建产物也必须含本轮真实读取类；拿源码通过替代旧JAR运行会在此被拒绝。
        candidate=options.consumer_jar.resolve()
        with zipfile.ZipFile(jar) as expected,zipfile.ZipFile(candidate) as actual,zipfile.ZipFile(base) as original:
            if actual.namelist()!=original.namelist(): raise ValueError('consumer JAR membership changed')
            for name in replacements:
                if actual.read(name)!=expected.read(name): raise ValueError('consumer class differs from tested production: '+name)
        jar=candidate
    # 测试classpath只放fixture类目录+真实维护JAR，避免新生成的上游inner类覆盖原JAR成员。
    testclasses=output/'testclasses';target=testclasses/'org/lwjgl/opengl';target.mkdir(parents=True,exist_ok=True)
    (target/'L2ControlProductionTest.class').write_bytes((classes/'org/lwjgl/opengl/L2ControlProductionTest.class').read_bytes())
    (target/'L2InputContractTest.class').write_bytes((classes/'org/lwjgl/opengl/L2InputContractTest.class').read_bytes())
    (target/'L2LookProductionTest.class').write_bytes((classes/'org/lwjgl/opengl/L2LookProductionTest.class').read_bytes())
    backend=(ROOT/'prebuilt/lwjgl2/ohos-backend/amcl_lwjgl2_backend.c').read_text(encoding='utf-8')
    start=backend.index('static int control_write_emission(')
    end=backend.index('/* grab 切换：',start)
    control=backend[start:end]
    nextstart=backend.index('JNIEXPORT jboolean JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nNextEvent')
    nextend=backend.index('\n/* ===================== 末级控制私有JNI',nextstart)
    nextfunc=backend[nextstart:nextend]
    # 新/旧组合均取真实生产函数，旧JAR原字节单独保存，不能由替身marker代替。
    # 独立Keyboard表/原POD在正式协议段内声明；本处逐字提取，不能在prefix复制第二份状态。
    contract=backend[backend.index('#define AMCL_L2_CONTROL_PROTOCOL'):backend.index('static int s_width')]
    handshake='\n'.join(function_text(backend,name) for name in [
        'Java_org_lwjgl_opengl_AMCLDisplay_nInputContract','Java_org_lwjgl_opengl_AMCLDisplay_nLookContract'])
    throwers='\n'.join(function_text(common_tools,name) for name in ['throwGeneralException','throwException'])
    window=function_text(backend,'Java_org_lwjgl_opengl_AMCLDisplay_nCreateWindow')
    context=function_text(backend,'Java_org_lwjgl_opengl_AMCLContextImplementation_nCreate')
    # 默认读取逐字冻结的实际旧交付样本；公开快照与浅克隆不一定保有维护者历史commit。
    # Manifest先核尺寸/摘要，再读正文；只用于行为反控，不能作为生产重建的隐式输入。
    baseline_root=ROOT/'scripts/fixtures/input-consumer/l2-baseline'
    baseline_manifest=json.loads((baseline_root/'manifest.json').read_text(encoding='utf-8'))
    baseline_files={item['name']:item for item in baseline_manifest['files']}
    def frozen_baseline(name):
        data=(baseline_root/name).read_bytes();expected=baseline_files[name]
        if len(data)!=expected['size'] or hashlib.sha256(data).hexdigest()!=expected['sha256']:
            raise ValueError('actual old baseline fixture changed: '+name)
        return data
    baseline_ref=options.baseline_ref or baseline_manifest['sourceRef']
    baseline_backend=(subprocess.check_output(['git','show',options.baseline_ref+':prebuilt/lwjgl2/ohos-backend/amcl_lwjgl2_backend.c'],cwd=ROOT)
        if options.baseline_ref else frozen_baseline('amcl_lwjgl2_backend.c')).decode('utf-8')
    (output/'baseline-backend.c').write_text(baseline_backend,encoding='utf-8',newline='')
    # 当前交付rawfile已经是新协议，不能再将它当旧组合校准。默认用同一已核验旧样本；
    # 显式旧ref或外部制品仍可使用，随后继续检查真正缺少新握手。
    baseline_jar=options.baseline_jar.resolve() if options.baseline_jar else None
    baseline_bytes=baseline_jar.read_bytes() if baseline_jar else (
        subprocess.check_output(['git','show',options.baseline_ref+':entry/src/main/resources/rawfile/lwjgl2/lwjgl.jar'],cwd=ROOT)
        if options.baseline_ref else frozen_baseline('lwjgl.jar'))
    old_jar=output/'baseline-lwjgl.jar';old_jar.write_bytes(baseline_bytes)
    with zipfile.ZipFile(old_jar) as original:
        if b'AMCL_CONTROL_PROTOCOL' in original.read('org/lwjgl/opengl/AMCLDisplay.class'):
            raise ValueError('baseline JAR already has new handshake; specify the actual old artifact')
    old_window=function_text(baseline_backend,'Java_org_lwjgl_opengl_AMCLDisplay_nCreateWindow')
    old_context=function_text(baseline_backend,'Java_org_lwjgl_opengl_AMCLContextImplementation_nCreate')
    old_next=function_text(baseline_backend,'Java_org_lwjgl_opengl_AMCLDisplay_nNextEvent')
    # 实际P3已交付、尚缺look的第二代基线，专门证明control-v1不能代称新增look资格。
    prelook_root=ROOT/'scripts/fixtures/input-consumer/l2-look-baseline'
    prelook_manifest=json.loads((prelook_root/'manifest.json').read_text(encoding='utf-8'))
    prelook_data={}
    for item in prelook_manifest['files']:
        data=(prelook_root/item['name']).read_bytes()
        if len(data)!=item['size'] or hashlib.sha256(data).hexdigest()!=item['sha256']:
            raise ValueError('actual prelook baseline changed: '+item['name'])
        prelook_data[item['name']]=data
    prelook_backend=prelook_data['amcl_lwjgl2_backend.c'].decode('utf-8')
    prelook_jar=output/'prelook-lwjgl.jar';prelook_jar.write_bytes(prelook_data['lwjgl.jar'])
    with zipfile.ZipFile(prelook_jar) as original:
        marker_bytes=original.read('org/lwjgl/opengl/AMCLDisplay.class')
        if b'AMCL_CONTROL_PROTOCOL' not in marker_bytes or b'AMCL_LOOK_PROTOCOL' in marker_bytes:
            raise ValueError('prelook fixture must be actual control-aware Java without look ABI')
    prelook_contract=prelook_backend[prelook_backend.index('#define AMCL_L2_CONTROL_PROTOCOL'):prelook_backend.index('static int s_width')]
    prelook_pieces=prelook_contract+'\n'+'\n'.join(function_text(prelook_backend,'Java_org_lwjgl_opengl_AMCLDisplay_'+name)
        for name in ['nInputContract','nCreateWindow','nNextEvent'])+'\n'+function_text(prelook_backend,'Java_org_lwjgl_opengl_AMCLContextImplementation_nCreate')
    cmake=find_host_cmake(options.cmake)
    facts=[]
    for mode in (['production'] if options.look_only else ['production','no-game-read','stale-enqueue','enqueue-as-read','no-neutral-owner','fixed-create-thread']):
        directory=output/mode;directory.mkdir(exist_ok=True)
        body=control
        if options.latency_mode in ['old-native','partial-note','partial-finish']:
            # 只撤三个可选新增JNI，原全部control/look业务JNI正文和真实owner仍保留。
            # 真实JVM应在冷available探测产生LinkageError并由新Java只关闭诊断，
            # 不能借普通getter缺席测试冒称这一Java/Native兼容分支已经实际执行。
            missing={'old-native':['nLookLatencyAvailable','nLookLatencyNote','nLookLatencyFinish'],
                     'partial-note':['nLookLatencyNote'],'partial-finish':['nLookLatencyFinish']}[options.latency_mode]
            for optional in missing:
                name='Java_org_lwjgl_opengl_AMCLDisplay_'+optional
                original=function_text(body,name)
                body=body.replace(original,'/* host old-native: optional diagnostic JNI absent */',1)
        if mode=='no-game-read':
            body=body.replace('return s_control_port->complete(&emission, (uint32_t)phase);',
                'return s_control_port->complete(&emission, phase == 2 ? 0 : (uint32_t)phase);')
        elif mode=='stale-enqueue':
            body=body.replace('return s_control_port->validate(&emission);','return AMCL_CONTROL_EDGE;')
        elif mode=='enqueue-as-read':
            body=body.replace('return s_control_port->complete(&emission, (uint32_t)phase);',
                'return s_control_port->complete(&emission, phase == 0 ? 2 : (uint32_t)phase);')
        elif mode=='no-neutral-owner':
            # 可编译的明确负控：JNI省去owner而直接伪造Edge。真实owner快照必须拆穿它。
            begin=body.index('    int32_t result = s_control_port->apply(')
            end=body.index('    if (result == AMCL_CONTROL_EDGE)',begin)
            body=body[:begin]+'''    memset(&emission,0,sizeof(emission)); emission.size=sizeof(emission);
    emission.kind=kind; emission.code=code; emission.scanCode=scan; emission.action=action;
    emission.consumer=consumer; emission.activation=1; emission.revision=1;
    emission.ticket=1; emission.target=(uint64_t)(uintptr_t)s_window;
    int32_t result=AMCL_CONTROL_EDGE;
'''+body[end:]
            body=body.replace('result = s_control_port->claim(&emission);','result = AMCL_CONTROL_EDGE;')
        prefix,suffix_body=NATIVE_PREFIX,NATIVE_SUFFIX
        if os.name!='nt':
            # 两种宿主使用各自真实加载器/进程身份；pthread只供恢复线程误门的负控。
            prefix=prefix.replace('#include <windows.h>','#include <pthread.h>\n#include <stdlib.h>')
            suffix_body=suffix_body.replace('_putenv_s(AMCL_CONTROL_ENV,"AMCLCONTROL:1:bad")',
                'setenv(AMCL_CONTROL_ENV,"AMCLCONTROL:1:bad",1)')
        if mode=='fixed-create-thread':
            # 负控恢复本轮审查发现的错误：用创建线程拒绝旧GlobalLock合法跨线程poll。
            if os.name=='nt':
                prefix+='static DWORD fixture_creation_thread=0;\n'
                assign='fixture_creation_thread=GetCurrentThreadId();'
                denied='GetCurrentThreadId()!=fixture_creation_thread'
            else:
                prefix+='static pthread_t fixture_creation_thread;\n'
                assign='fixture_creation_thread=pthread_self();'
                denied='!pthread_equal(pthread_self(),fixture_creation_thread)'
            body=body.replace('s_control_target = (uint64_t)(uintptr_t)s_window;',
                's_control_target = (uint64_t)(uintptr_t)s_window; '+assign)
            body=body.replace('(void)cls;\n    if (s_control_port == NULL || s_window == NULL || s_control_target',
                '(void)cls;\n    if ('+denied+') return AMCL_CONTROL_STALE;\n    if (s_control_port == NULL || s_window == NULL || s_control_target',1)
        if mode=='production':
            # 源JNI setGrab/validate正文保留；两个夹具钩子只发布外部mode和安排源退休时刻。
            # 不fake look resolver、claim/validate返回值或实际Mouse/Keyboard缓存。
            prefix+='static int look_fixture_cursor_reads=0;\n'
            suffix_body=suffix_body.replace('(void)c;\n    if(reentry_mode)', '(void)c; ++look_fixture_cursor_reads;\n    if(reentry_mode)',1)
            old_grab=function_text(suffix_body,'Java_org_lwjgl_opengl_AMCLDisplay_nSetGrab')
            suffix_body=suffix_body.replace(old_grab,'',1)
            support=(ROOT/'scripts/fixtures/input-consumer/l2_look_support.c.in').read_text(encoding='utf-8')
            validate=function_text(body,'Java_org_lwjgl_opengl_AMCLDisplay_nLookValidate')
            hooked=validate.replace('{','{\n    look_fixture_before_validate();',1)
            if options.look_negative=='validate':
                assert hooked.count('return s_look_port->validate(&e);')==1
                hooked=hooked.replace('return s_look_port->validate(&e);','return AMCL_LOOK_PREFIX_READY;',1)
            body=body.replace(validate,hooked,1)
            real_grab=function_text(backend,'Java_org_lwjgl_opengl_AMCLDisplay_nSetGrab')
            pieces=[prefix,throwers,contract,handshake,suffix_body,support,body,real_grab,window,context,nextfunc]
        else: pieces=[prefix,throwers,contract,handshake,body,suffix_body,window,context,nextfunc]
        (directory/'consumer.c').write_text('\n'.join(pieces),encoding='utf-8')
        cpp=cpp_snapshot/'input'
        # Core 的真实 L2 held reader 依赖生产 mapper；补完整强链接，不以 weak/noop 或假映射替代。
        production=[cpp/'delivery/control_delivery.cpp',cpp/'delivery/look_execution.cpp',
            cpp.parent/'platform/look_delta_math.cpp',cpp.parent/'platform/look_pipeline_stats.cpp',
            cpp/'input_state_core.cpp',cpp/'adapters/backend_keymaps.cpp',cpp/'amcl_input_host_descriptor.cpp',cpp/'input_interaction_order.cpp']
        # 真collector仍与原Core/look位于同一个测试映像；getter只由fixture借出原函数表，
        # 不复制时钟/固定表/匹配/终态算法。诊断OFF编为空TU，保原业务消费检查。
        if options.look_only:production.append(cpp/'input_latency_observation.cpp')
        cmaketext='cmake_minimum_required(VERSION 3.20)\nproject(l2_control C CXX)\nset(CMAKE_CXX_STANDARD 17)\nadd_library(lwjgl_v2 SHARED consumer.c '+ ' '.join('"'+p.as_posix()+'"' for p in production)+')\n'
        cmaketext+='target_compile_definitions(lwjgl_v2 PRIVATE AMCL_CONTROL_DELIVERY_HOST_TESTING AMCL_INPUT_HOST_TESTING AMCL_INPUT_HOST_EXPORTS _CRT_SECURE_NO_WARNINGS)\n'
        if options.look_only:
            cmaketext+='target_compile_definitions(lwjgl_v2 PRIVATE AMCL_INPUT_TRACE='+('0' if options.latency_mode in ['off','old-native'] else '1')+' AMCL_INPUT_LATENCY_SAMPLE_INTERVAL=1)\n'
            if options.latency_mode=='foreign':cmaketext+='target_compile_definitions(lwjgl_v2 PRIVATE AMCL_L2_LATENCY_FOREIGN)\n'
        if os.name=='nt': cmaketext+='target_compile_options(lwjgl_v2 PRIVATE /utf-8)\n'
        else: cmaketext+='target_compile_definitions(lwjgl_v2 PRIVATE _GNU_SOURCE)\ntarget_link_libraries(lwjgl_v2 PRIVATE ${CMAKE_DL_LIBS} pthread)\n'
        jni_platform='win32' if os.name=='nt' else 'linux'
        cmaketext+='target_include_directories(lwjgl_v2 PRIVATE "'+(cpp/'delivery').as_posix()+'" "'+(cpp.parent/'tests/host/stubs').as_posix()+'" "'+(jdk/'include').as_posix()+'" "'+(jdk/'include'/jni_platform).as_posix()+'")\n'
        (directory/'CMakeLists.txt').write_text(cmaketext,encoding='utf-8')
        configure_host_cmake(cmake,directory,directory/'build')
        run([cmake,'--build',directory/'build','--config','Release'],output,output/(mode+'-compile.log'))
        dll=directory/('build/Release/lwjgl_v2.dll' if os.name=='nt' else 'build/liblwjgl_v2.so')
        cp=os.pathsep.join([str(testclasses),str(jar)])
        if mode=='production':
            result=run([jdk/'bin'/('java'+suffix),'-XX:-UsePerfData','-Dos.name=Linux','-Damcl.test.latency='+options.latency_mode,'-Dorg.lwjgl.librarypath='+str(dll.parent),'-cp',cp,
                'org.lwjgl.opengl.L2LookProductionTest',dll],output,output/'look-production.log',
                1 if options.look_negative or options.latency_negative or options.latency_expect_partial_failure else 0,
                b'UnsatisfiedLinkError' if options.latency_expect_partial_failure else b'AssertionError')
            if options.latency_expect_partial_failure:
                expected_symbol={'partial-note':b'nLookLatencyNote','partial-finish':b'nLookLatencyFinish'}[options.latency_mode]
                if expected_symbol not in result.stdout:raise RuntimeError('Partial JNI failed outside the declared optional symbol')
            if options.latency_negative and b'L2_LOOK latency ' not in result.stdout:
                raise RuntimeError('Latency withdrawal failed outside intended consumer assertion')
            if options.look_negative:
                # 只接受该撤回接缝应造成的真实消费错误；Core初始化/坏getter等其它
                # AssertionError不能误记为cache、poll或validate的负控证明。
                expected_message={'cache':'actual poll integer truncation/fraction retained',
                    'latest':'actual poll integer truncation/fraction retained',
                    'poll':'poll-only cache plus actual upstream poll hook',
                    'validate':'retire one source before cache reprepare only sibling'}[options.look_negative]
                if ('L2_LOOK '+expected_message).encode() not in result.stdout:
                    raise RuntimeError('look negative failed outside intended consumer assertion')
            if options.look_only:
                (output/'look-summary.json').write_text(json.dumps({'schema':1,'negative':options.look_negative,
                    'latencyMode':options.latency_mode,'latencyNegative':options.latency_negative,
                    'partialFailureExpected':options.latency_expect_partial_failure,'exit':result.returncode,
                    'recordedAt':datetime.now().astimezone().isoformat(),'acquiredAt':acquired_at,
                    'frozenCppSources':cpp_identities,
                    'sources':producer_identities,
                    'nativeCandidateSha256':hashlib.sha256((directory/'consumer.c').read_bytes()).hexdigest(),
                    'compiledDllSha256':hashlib.sha256(dll.read_bytes()).hexdigest(),
                    'consumerJarSha256':hashlib.sha256(jar.read_bytes()).hexdigest(),
                    'scope':'real Core/control/look owner, original JNI and complete Java poll/next; external platform/mode/5int transport; no game camera claim'},indent=2)+'\n',encoding='utf-8')
                return
        result=run([jdk/'bin'/('java'+suffix),'-Dos.name=Linux','-Dorg.lwjgl.librarypath='+str(dll.parent),'-cp',cp,'org.lwjgl.opengl.L2ControlProductionTest',dll],output,output/(mode+'.log'),0 if mode=='production' else 1)
        facts.append({'mode':mode,'exit':result.returncode,'consumerJarSha256':hashlib.sha256(jar.read_bytes()).hexdigest()})
    # 合法旧/旧校准、合法新/新与两个真实混搭；撤去新Native握手的编译负控必须被断言拒绝。
    contract_facts=[]
    # Core 的真实 L2 held reader 依赖生产 mapper；补完整强链接，不以 weak/noop 或假映射替代。
    production=[cpp/'delivery/control_delivery.cpp',cpp/'delivery/look_execution.cpp',
        cpp.parent/'platform/look_delta_math.cpp',cpp.parent/'platform/look_pipeline_stats.cpp',
        cpp/'input_state_core.cpp',cpp/'adapters/backend_keymaps.cpp',cpp/'amcl_input_host_descriptor.cpp',cpp/'input_interaction_order.cpp']
    for native_mode in ['baseline-native','prelook-native','new-native','cancel-native-handshake']:
        directory=output/native_mode;directory.mkdir()
        prefix,suffix_body=NATIVE_PREFIX,NATIVE_SUFFIX
        if os.name!='nt':
            prefix=prefix.replace('#include <windows.h>','#include <stdlib.h>')
            suffix_body=suffix_body.replace('_putenv_s(AMCL_CONTROL_ENV,"AMCLCONTROL:1:bad")','setenv(AMCL_CONTROL_ENV,"AMCLCONTROL:1:bad",1)')
        pieces=old_window+old_context+old_next if native_mode=='baseline-native' else contract+handshake+window+context+nextfunc
        if native_mode=='prelook-native': pieces=prelook_pieces
        if native_mode=='cancel-native-handshake':
            # 仅在生成的负控源码撤销原helper；实际旧JAR的类/marker字节未修改。
            for name in ['l2_require_input_class','l2_require_input_ready']:
                original=function_text(pieces,name)
                declaration=original[:original.index('{')+1]
                pieces=pieces.replace(original,declaration+' return 1; }')
        (directory/'consumer.c').write_text('\n'.join([prefix,throwers,suffix_body,pieces]),encoding='utf-8')
        (directory/'CMakeLists.txt').write_text(cmaketext,encoding='utf-8')
        configure_host_cmake(cmake,directory,directory/'build')
        run([cmake,'--build',directory/'build','--config','Release'],output,output/(native_mode+'-compile.log'))
        dll=directory/('build/Release/lwjgl_v2.dll' if os.name=='nt' else 'build/liblwjgl_v2.so')
        combinations=[('old-old',old_jar,0),('new-java-old-native',jar,0)] if native_mode=='baseline-native' else [
            ('old-java-new-native',old_jar,1 if native_mode=='cancel-native-handshake' else 0)]
        if native_mode=='new-native': combinations.append(('new-new',jar,0))
        if native_mode=='prelook-native': combinations=[('old-old',prelook_jar,0),('new-java-old-native',jar,0)]
        if native_mode in ['new-native','cancel-native-handshake']:
            combinations.append(('old-java-new-native',prelook_jar,1 if native_mode=='cancel-native-handshake' else 0))
        for case,active_jar,expected in combinations:
            cp=os.pathsep.join([str(testclasses),str(active_jar)])
            log_case=case+('-prelook' if active_jar==prelook_jar else '')
            result=run([jdk/'bin'/('java'+suffix),'-Dos.name=Linux','-Dorg.lwjgl.librarypath='+str(dll.parent),'-cp',cp,
                'org.lwjgl.opengl.L2InputContractTest',dll,case],output,output/(native_mode+'-'+log_case+'.log'),expected)
            contract_facts.append({'nativeMode':native_mode,'case':case,'exit':result.returncode,
                'javaBaseline':'prelook-P3' if active_jar==prelook_jar else 'pre-P3' if active_jar==old_jar else 'current',
                'jarSha256':hashlib.sha256(active_jar.read_bytes()).hexdigest()})
    # 双向合同的Java侧也有可编译撤回反控：只撤verify主体，保真实新class的所有marker/接口。
    negative_java=output/'cancel-java-handshake';negative_java.mkdir()
    java_text=(ROOT/'prebuilt/lwjgl2/patches/java/org/lwjgl/opengl/AMCLDisplay.java').read_text(encoding='utf-8')
    start=java_text.index('\tprivate static void verifyInputContract() throws LWJGLException {')
    begin=java_text.index('{',start);depth=1;end=begin+1
    while depth:
        depth+=(java_text[end]=='{')-(java_text[end]=='}');end+=1
    java_text=java_text[:begin+1]+' /* compiled negative: handshake canceled */ }'+java_text[end:]
    java_file=negative_java/'AMCLDisplay.java';java_file.write_text(java_text,encoding='utf-8')
    negative_classes=negative_java/'classes';negative_classes.mkdir()
    run([jdk/'bin'/('javac'+suffix),'-encoding','UTF-8','-source','1.6','-target','1.6','-cp',jar,
        '-d',negative_classes,java_file],output,output/'cancel-java-handshake-compile.log')
    negative_jar=negative_java/'lwjgl.jar'
    with zipfile.ZipFile(jar) as original,zipfile.ZipFile(negative_jar,'w') as result:
        for member in original.infolist():
            result.writestr(member,(negative_classes/member.filename).read_bytes() if member.filename=='org/lwjgl/opengl/AMCLDisplay.class' else original.read(member))
    baseline_dll=output/'baseline-native'/('build/Release/lwjgl_v2.dll' if os.name=='nt' else 'build/liblwjgl_v2.so')
    cp=os.pathsep.join([str(testclasses),str(negative_jar)])
    result=run([jdk/'bin'/('java'+suffix),'-Dos.name=Linux','-Dorg.lwjgl.librarypath='+str(baseline_dll.parent),'-cp',cp,
        'org.lwjgl.opengl.L2InputContractTest',baseline_dll,'new-java-old-native'],output,output/'cancel-java-handshake-new-java-old-native.log',1)
    contract_facts.append({'nativeMode':'baseline-native','case':'cancel-java-handshake','exit':result.returncode,
        'jarSha256':hashlib.sha256(negative_jar.read_bytes()).hexdigest()})
    sources=[
             ROOT/'prebuilt/lwjgl2/ohos-backend/amcl_lwjgl2_backend.c',
             ROOT/'prebuilt/lwjgl2/patches/java/org/lwjgl/opengl/AMCLDisplay.java']
    (output/'summary.json').write_text(json.dumps({'schema':1,'results':facts,'contractResults':contract_facts,
        'baselineNativeRef':baseline_ref,'baselineNativeSha256':hashlib.sha256(baseline_backend.encode('utf-8')).hexdigest(),
        'baselineJarInput':str(baseline_jar) if baseline_jar else ('git:'+options.baseline_ref if options.baseline_ref else 'frozen-old-delivery-fixture'),
        'baselineJarSha256':hashlib.sha256(old_jar.read_bytes()).hexdigest(),'sourceCommit':spec['sourceCommit'],
        'frozenCppSources':cpp_identities,'acquiredAt':acquired_at,'recordedAt':datetime.now().astimezone().isoformat(),
        'productionSources':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
        'readpointsPatchSha256':hashlib.sha256(patch.read_bytes()).hexdigest()},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs',type=Path,required=True)
    parser.add_argument('--jdk',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--cmake')
    parser.add_argument('--consumer-jar',type=Path,help='可选：完整受控重建的JAR，先核维护类字节再用它真实运行')
    parser.add_argument('--baseline-ref',help='可选实际旧JNI/JAR生产Git身份；缺省使用冻结实际旧样本')
    parser.add_argument('--baseline-jar',type=Path,help='可选实际旧交付JAR字节；缺省用指定ref或冻结样本')
    parser.add_argument('--look-only',action='store_true',help='仅执行真正look/JNI/Java消费轨迹，定向开发不重复原P3矩阵')
    parser.add_argument('--look-negative',choices=['cache','poll','latest','validate'],help='仓外可编译look行为反控，仅与look-only一起使用')
    parser.add_argument('--latency-mode',choices=['off','on','foreign','old-native','partial-note','partial-finish'],default='off',help='定向look门可选：真实collector、错误诊断PID、缺全部/部分可选JNI')
    parser.add_argument('--latency-expect-partial-failure',action='store_true',help='只供旧Java反例：完整编译后首个热调用产生指定可选JNI的UnsatisfiedLinkError')
    parser.add_argument('--latency-negative',choices=['cache','poll'],help='定向ON门撤回真实consumer hook；编译成功后应在诊断行为断言失败')
    options=parser.parse_args()
    if options.look_negative and not options.look_only:parser.error('--look-negative requires --look-only')
    if options.latency_negative and (not options.look_only or options.latency_mode!='on' or options.look_negative):
        parser.error('--latency-negative requires --look-only --latency-mode on without --look-negative')
    if options.latency_expect_partial_failure and (not options.look_only or options.latency_mode not in ['partial-note','partial-finish']):
        parser.error('--latency-expect-partial-failure requires --look-only and a partial JNI mode')
    build(options)
