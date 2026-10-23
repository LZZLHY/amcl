"""LWJGL2现役JNI/GL查询与ContextGL提交时序的宿主行为回归。

原样抽取Native函数，并从仓内摘要锁定的完整上游ContextGL样本应用正式patch后
抽取Java方法。只替换驱动、动态加载器、JNI抛错及Java平台实现边界，不构建产品。
--source-zip可额外核对上游归档；--java-home或JAVA_HOME/PATH提供宿主JDK，缺失明确失败。
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import zipfile
from lib.host_cpp import compile_cpp
from lib.workspace_paths import external_output_path, workspace_path

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / 'prebuilt/lwjgl2/ohos-backend'
PATCH = ROOT / 'prebuilt/lwjgl2/patches/context-current.patch'
INPUTS = ROOT / 'prebuilt/lwjgl2/build-inputs.json'
SOURCE_FIXTURE = ROOT / 'prebuilt/lwjgl2/source-fixtures/ContextGL.java'


def block(source, start):
    """以掩码数括号，返回原始正文；注释和字符串内括号不能改变函数边界。"""
    masked = re.sub(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
                    lambda match: ' ' * len(match[0]), source)
    end = masked.index('{', start) + 1
    depth = 1
    while depth:
        depth += (masked[end] == '{') - (masked[end] == '}')
        end += 1
    return source[start:end]


def function(source, name):
    """只接收唯一函数声明；没有找到真实源码时立即失败，不能用手抄实现替代。"""
    matches = list(re.finditer(r'^\s*(?:[\w*]+\s+)+\b' + re.escape(name) + r'\([^;{}]*\)\s*(?:throws [\w., ]+)?\s*\{', source, re.M))
    if len(matches) != 1:
        raise ValueError('Expected exactly one production function: ' + name)
    return block(source, matches[0].start()).strip()


def run(command, output, name, expected=0, cwd=None):
    """保存每个进程的原始输出；负控只接受明确非零行为失败，不接受编译失败作为反例。"""
    env = os.environ.copy()
    for key in list(env):
        if key.upper() in ('JAVA_TOOL_OPTIONS', '_JAVA_OPTIONS', 'JDK_JAVA_OPTIONS'):
            del env[key]
    result = subprocess.run([str(part) for part in command], cwd=cwd, env=env, capture_output=True, timeout=60)
    (output / (name + '.log')).write_bytes(result.stdout + b'\n' + result.stderr)
    if (expected == 0 and result.returncode != 0) or (expected != 0 and result.returncode == 0):
        raise RuntimeError(f'{name}: unexpected exit {result.returncode}, see {output / (name + ".log")}')
    print(f'{name}: ' + ('PASS' if expected == 0 else 'negative control rejected'))
    return result


NATIVE_PREAMBLE = r'''
#include <cstring>
#include <iostream>
#include <string>
#include <thread>
#define JNIEXPORT
#define JNICALL
#define JNI_TRUE true
#define JNI_FALSE false
#define RTLD_NOW 1
#define RTLD_GLOBAL 2
#define RTLD_NOLOAD 4
using jboolean=bool; using jclass=void*; struct JNIEnv {};
thread_local int exceptionCount=0;
thread_local std::string exceptionText;
void throwException(JNIEnv*,const char* message){++exceptionCount;exceptionText=message;}
void* fixtureOpen(const char*,int);
void* fixtureSymbol(void*,const char*);
#define dlopen fixtureOpen
#define dlsym fixtureSymbol
'''

NATIVE_FIXTURE = r'''
thread_local GLFWwindow* current=nullptr;
bool checkedResult=true, leaveState=false, missingChecked=false, missingCurrent=false;
int checkedCalls=0, symbolCalls=0;
GLFWwindow* windowA=reinterpret_cast<GLFWwindow*>(0x1000);
GLFWwindow* windowB=reinterpret_cast<GLFWwindow*>(0x2000);
int checked(GLFWwindow* window){++checkedCalls;if(checkedResult&&!leaveState)current=window;return checkedResult;}
GLFWwindow* getCurrent(){return current;}
void* fixtureOpen(const char*,int){return reinterpret_cast<void*>(0x3000);}
void* fixtureSymbol(void*,const char* name){
    ++symbolCalls;
    if(!std::strcmp(name,"glfwOHOS_MakeContextCurrentChecked"))return missingChecked?nullptr:reinterpret_cast<void*>(checked);
    if(!std::strcmp(name,"glfwGetCurrentContext"))return missingCurrent?nullptr:reinterpret_cast<void*>(getCurrent);
    return reinterpret_cast<void*>(0x4000);
}
#define CHECK(value) do{if(!(value)){std::cerr<<"CHECK line "<<__LINE__<<": "<<#value<<"\n";return 1;}}while(0)
'''

NATIVE_MAIN = r'''
int main(){
    // 冷装载缺入口以及保留句柄后的第二次调用都必须拒绝。
    missingChecked=true;CHECK(!load_glfw());int seen=symbolCalls;CHECK(!load_glfw());CHECK(symbolCalls==seen);
    s_glfw=nullptr;missingChecked=false;missingCurrent=true;CHECK(!load_glfw());CHECK(!load_glfw());
    s_glfw=nullptr;missingCurrent=false;CHECK(load_glfw());s_window=windowA;
    CHECK(!Java_org_lwjgl_opengl_AMCLContextImplementation_nIsCurrent(nullptr,nullptr));
    Java_org_lwjgl_opengl_AMCLContextImplementation_nMakeCurrent(nullptr,nullptr);
    CHECK(exceptionCount==0&&current==windowA);
    CHECK(Java_org_lwjgl_opengl_AMCLContextImplementation_nIsCurrent(nullptr,nullptr));
    bool otherThreadCurrent=true;int otherThreadExceptions=-1;
    std::thread other([&]{otherThreadCurrent=Java_org_lwjgl_opengl_AMCLContextImplementation_nIsCurrent(nullptr,nullptr);otherThreadExceptions=exceptionCount;});other.join();
    CHECK(!otherThreadCurrent&&otherThreadExceptions==0);
    // 原本已current仍须尊重本次checked返回，不能因TLS相同而吞掉驱动失败。
    checkedResult=false;exceptionCount=0;
    Java_org_lwjgl_opengl_AMCLContextImplementation_nMakeCurrent(nullptr,nullptr);
    CHECK(exceptionCount==1&&current==windowA);
    exceptionCount=0;Java_org_lwjgl_opengl_AMCLContextImplementation_nReleaseCurrentContext(nullptr,nullptr);
    CHECK(exceptionCount==1&&current==windowA);
    checkedResult=true;leaveState=true;exceptionCount=0;
    Java_org_lwjgl_opengl_AMCLContextImplementation_nReleaseCurrentContext(nullptr,nullptr);
    CHECK(exceptionCount==1&&current==windowA);
    leaveState=false;exceptionCount=0;Java_org_lwjgl_opengl_AMCLContextImplementation_nReleaseCurrentContext(nullptr,nullptr);
    CHECK(exceptionCount==0&&current==nullptr);
    CHECK(!Java_org_lwjgl_opengl_AMCLContextImplementation_nIsCurrent(nullptr,nullptr));
    // checked声称成功但实际current未改变，也不能提交成功。
    leaveState=true;Java_org_lwjgl_opengl_AMCLContextImplementation_nMakeCurrent(nullptr,nullptr);
    CHECK(exceptionCount==1&&current==nullptr);leaveState=false;
    current=windowB;exceptionCount=0;seen=checkedCalls;
    CHECK(!Java_org_lwjgl_opengl_AMCLContextImplementation_nIsCurrent(nullptr,nullptr));
    Java_org_lwjgl_opengl_AMCLContextImplementation_nReleaseCurrentContext(nullptr,nullptr);
    CHECK(exceptionCount==1&&current==windowB&&checkedCalls==seen);
    p_makecur_checked=nullptr;exceptionCount=0;
    Java_org_lwjgl_opengl_AMCLContextImplementation_nMakeCurrent(nullptr,nullptr);
    Java_org_lwjgl_opengl_AMCLContextImplementation_nReleaseCurrentContext(nullptr,nullptr);
    CHECK(exceptionCount==2&&current==windowB);
    p_makecur_checked=checked;p_getcurrent=nullptr;exceptionCount=0;
    CHECK(!Java_org_lwjgl_opengl_AMCLContextImplementation_nIsCurrent(nullptr,nullptr));CHECK(exceptionCount==1);
    Java_org_lwjgl_opengl_AMCLContextImplementation_nMakeCurrent(nullptr,nullptr);
    Java_org_lwjgl_opengl_AMCLContextImplementation_nReleaseCurrentContext(nullptr,nullptr);
    CHECK(exceptionCount==3);p_getcurrent=getCurrent;
    s_window=nullptr;exceptionCount=0;
    CHECK(!Java_org_lwjgl_opengl_AMCLContextImplementation_nIsCurrent(nullptr,nullptr));CHECK(exceptionCount==0);
    Java_org_lwjgl_opengl_AMCLContextImplementation_nMakeCurrent(nullptr,nullptr);CHECK(exceptionCount==1);
    std::cout<<"JNI context/current/checked ABI and failure ownership PASS\n";
}
'''


def native_context(build, output, identities):
    """抽取真实指针声明、装载器与JNI函数，驱动状态用线程局部替身控制。"""
    source = (BACKEND / 'amcl_lwjgl2_backend.c').read_text(encoding='utf-8')
    loader = function(source, 'load_glfw')
    # 本用例只验证GLFW context/current与checked绑定，不需要Display输入配对JNI。
    # 生产文件在指针声明与loader之间新增了真正JNI字段查询，若把整个区间复制到
    # 简化JNIEnv夹具，会在无关代码编译处失败，无法执行下面的三个真实行为反控。
    # 因此边界锚到唯一真实s_window声明，loader和三个被测JNI函数仍原字节抽取。
    declaration = 'static GLFWwindow* s_window = NULL;'
    if source.count(declaration) != 1:
        raise ValueError('Expected unique production context state boundary')
    prefix = source[source.index('typedef void* GLFWwindow;'):source.index(declaration) + len(declaration)]
    # SONAME条件宏也是生产loader的输入，位于后续声明之后；独立原样取得它，
    # 不手抄库名、不扩假JNI、不截去loader或JNI函数内部的实际检查。
    if source.count('#ifndef AMCL_GLFW_SONAME') != 1:
        raise ValueError('Expected unique production GLFW SONAME macro')
    macro_begin = source.index('#ifndef AMCL_GLFW_SONAME')
    macro_end = source.index('#endif', macro_begin) + len('#endif')
    prefix += '\n' + source[macro_begin:macro_end] + '\n'
    names = ['nMakeCurrent', 'nReleaseCurrentContext', 'nIsCurrent']
    functions = '\n\n'.join(function(source, 'Java_org_lwjgl_opengl_AMCLContextImplementation_' + name) for name in names)
    code = NATIVE_PREAMBLE + prefix + loader + NATIVE_FIXTURE + functions + NATIVE_MAIN
    identities['nativeSourceSha256'] = hashlib.sha256(source.encode()).hexdigest()
    identities['nativeExtractedSha256'] = hashlib.sha256((prefix + loader + functions).encode()).hexdigest()
    variants = [('native-context', code, 0)]
    # 只退回“忽略checked失败”和“资源存在即current”两个旧接缝；负控仍运行同一测试正文。
    ignored = re.sub(r'if \(!p_makecur_checked\(s_window\) \|\| p_getcurrent\(\) != s_window\)\s*throwException\(env, "[^"]+"\);',
                     'p_makecur_checked(s_window);', code)
    if ignored == code:
        raise ValueError('Missing checked-operation negative-control seam')
    variants.append(('native-context-old-make', ignored, 1))
    old_release = re.sub(r'if \(!p_makecur_checked\(NULL\) \|\| p_getcurrent\(\) != NULL\)\s*throwException\(env, "[^"]+"\);',
                        'p_makecur_checked(NULL);', code)
    if old_release == code:
        raise ValueError('Missing release-operation negative-control seam')
    variants.append(('native-context-old-release', old_release, 1))
    old_query = code.replace('return p_getcurrent() == s_window ? JNI_TRUE : JNI_FALSE;',
                             'return s_window != NULL ? JNI_TRUE : JNI_FALSE;')
    if old_query == code:
        raise ValueError('Missing current-query negative-control seam')
    variants.append(('native-context-old-query', old_query, 1))
    for name, body, expected in variants:
        path = build / (name + '.cpp'); path.write_text(body, encoding='utf-8')
        binary = build / (name + ('.exe' if os.name == 'nt' else ''))
        compile_cpp(path, binary)
        result = run([binary], output, name, expected)
        if expected and b'CHECK line' not in result.stderr:
            raise RuntimeError('Native negative control did not reach a behavior assertion: ' + name)


EXTGL_FIXTURE = r'''
#include <cstring>
#include <iostream>
#include <string>
#define RTLD_NOW 1
#define RTLD_LOCAL 2
#define RTLD_GLOBAL 4
#define RTLD_NOLOAD 8
#define RTLD_DEFAULT reinterpret_cast<void*>(0)
struct JNIEnv{};
std::string scenario, profile="gl4es";
int opened=0, forbidden=0, lookedUp=0, closed=0;
void* answer=reinterpret_cast<void*>(0x5000);
const char* fixtureProfile(){return scenario=="null-profile"?nullptr:profile.c_str();}
void* fixtureProc(const char* name){++lookedUp;return name&&scenario!="null-result"?answer:nullptr;}
void* fixtureOpen(const char* name,int){++opened;if(std::strcmp(name,"libamcl_graphics_runtime.so"))++forbidden;return scenario=="no-runtime"?nullptr:reinterpret_cast<void*>(0x6000);}
void* fixtureSymbol(void* handle,const char* name){
    if(handle==RTLD_DEFAULT){++forbidden;return answer;}
    if(!std::strcmp(name,"amclGraphicsGlProcV1"))return scenario=="missing-proc"?nullptr:reinterpret_cast<void*>(fixtureProc);
    if(!std::strcmp(name,"amclGraphicsBoundProfileV1"))return scenario=="missing-profile"?nullptr:reinterpret_cast<void*>(fixtureProfile);
    ++forbidden;return nullptr;
}
int fixtureClose(void*){++closed;return 0;}
#define dlopen fixtureOpen
#define dlsym fixtureSymbol
#define dlclose fixtureClose
#define CHECK(value) do{if(!(value)){std::cerr<<"CHECK line "<<__LINE__<<": "<<#value<<"\n";return 1;}}while(0)
'''

EXTGL_MAIN = r'''
int main(int argc,char** argv){
    scenario=argc>1?argv[1]:"valid";
    if(scenario=="unbound")profile="UNKNOWN";
    if(scenario=="wrong-profile")profile="nativegl";
    const bool ready=scenario=="valid"||scenario=="null-result"||scenario=="inherited-provider";
    CHECK(extgl_Open(nullptr)==ready);
    if(!ready){CHECK(extgl_GetProcAddress("glGetString")==nullptr);CHECK(lookedUp==0);}
    else if(scenario=="null-result"){CHECK(extgl_GetProcAddress("glGetString")==nullptr);CHECK(lookedUp==1);}
    else {
        int queried=lookedUp;CHECK(extgl_GetProcAddress(nullptr)==nullptr);CHECK(extgl_GetProcAddress("")==nullptr);CHECK(lookedUp==queried);
        CHECK(extgl_GetProcAddress("glGetString")==answer);
        int before=opened;extgl_Close();CHECK(closed==0);
        CHECK(extgl_Open(nullptr));CHECK(extgl_GetProcAddress("glGetString")==answer);CHECK(opened==before);
        if(scenario=="inherited-provider"){
            // 模拟runtime的PID隔离返回UNKNOWN，不在宿主伪造真正OHOS namespace/fork。
            profile="UNKNOWN";before=lookedUp;
            CHECK(!extgl_Open(nullptr));CHECK(extgl_GetProcAddress("glGetString")==nullptr);CHECK(lookedUp==before);
        }
    }
    CHECK(forbidden==0);CHECK(closed==0);
    std::cout<<"extgl "<<scenario<<" PASS\n";
}
'''


def extgl_context(build, output, identities):
    """完整编译现役extgl后端，替换动态加载边界并追踪所有越界装载/默认命名空间查询。"""
    source = (BACKEND / 'extgl_ohos.c').read_text(encoding='utf-8')
    identities['extglSourceSha256'] = hashlib.sha256(source.encode()).hexdigest()
    body = re.sub(r'^#include\s+[<"](?:dlfcn\.h|extgl\.h)[>"]\s*$', '', source, flags=re.M)
    code = EXTGL_FIXTURE + body + EXTGL_MAIN
    path = build / 'extgl-context.cpp'; path.write_text(code, encoding='utf-8')
    binary = build / ('extgl-context.exe' if os.name == 'nt' else 'extgl-context')
    compile_cpp(path, binary)
    for scenario in ['valid', 'no-runtime', 'unbound', 'null-profile', 'wrong-profile', 'missing-proc', 'missing-profile',
                     'null-result', 'inherited-provider']:
        run([binary, scenario], output, 'extgl-' + scenario)
    # 负控重新引入全局兜底；即使全局同名函数存在，未命中的冻结provider也必须返回空。
    fallback = code.replace('return s_runtime_proc(name);',
                            'void *value=s_runtime_proc(name);return value?value:dlsym(RTLD_DEFAULT,name);')
    if fallback == code:
        raise ValueError('Missing runtime-proc negative-control seam')
    path = build / 'extgl-old-fallback.cpp'; path.write_text(fallback, encoding='utf-8')
    binary = build / ('extgl-old-fallback.exe' if os.name == 'nt' else 'extgl-old-fallback')
    compile_cpp(path, binary)
    result = run([binary, 'null-result'], output, 'extgl-old-fallback', expected=1)
    if b'CHECK line' not in result.stderr:
        raise RuntimeError('GL lookup negative control did not reach a behavior assertion')


JAVA_FIXTURE = r'''
public final class ContextGL {
    static final class LWJGLException extends Exception { LWJGLException(){super("native operation failed");} }
    static final ThreadLocal<ContextGL> current_context_local=new ThreadLocal<ContextGL>();
    static final FixtureImplementation implementation=new FixtureImplementation();
    final Object peer_info=new Object(), handle=new Object();
    boolean destroyed=false, forwardCompatible=false;
    Thread thread;
    int destroyChecks=0;
    void checkDestroy(){destroyChecks++;}
    static final class FixtureImplementation {
        boolean bindFails=false, releaseFails=false;
        int binds=0,releases=0;
        ContextGL target, nativeCurrent, observedTls;
        Thread observedOwner;
        void makeCurrent(Object peer,Object handle) throws LWJGLException {
            binds++;observedOwner=target.thread;observedTls=getCurrentContext();
            if(bindFails)throw new LWJGLException();nativeCurrent=target;
        }
        void releaseCurrentContext() throws LWJGLException {
            releases++;if(releaseFails)throw new LWJGLException();nativeCurrent=null;
        }
    }
    static final class GLContext {
        static ContextGL context;
        static void useContext(ContextGL value){context=value;}
        static void useContext(ContextGL value,boolean forward){context=value;}
    }
'''

JAVA_MAIN = r'''
    static void check(boolean value,String reason){if(!value)throw new AssertionError(reason);}
    public static void main(String[] args) throws Exception {
        ContextGL old=new ContextGL(),next=new ContextGL();
        implementation.target=old;old.makeCurrent();
        check(old.thread==Thread.currentThread()&&getCurrentContext()==old&&GLContext.context==old,"successful bind commits owner/TLS/capabilities");
        boolean nativeSawOld=implementation.observedOwner==null&&implementation.observedTls==null;
        final boolean[] other={false};
        Thread worker=new Thread(new Runnable(){public void run(){
            other[0]=getCurrentContext()==null;
            try{old.makeCurrent();other[0]=false;}catch(IllegalStateException expected){}catch(Exception unexpected){other[0]=false;}
        }});worker.start();worker.join();check(other[0],"other thread cannot steal Java owner");
        implementation.target=next;implementation.bindFails=true;
        boolean failed=false;try{next.makeCurrent();}catch(LWJGLException expected){failed=true;}
        check(failed,"native bind exception must reach caller");
        check(next.thread==null&&getCurrentContext()==old&&GLContext.context==old&&implementation.nativeCurrent==old,
            "failed bind preserves old owner/TLS/capabilities");
        check(nativeSawOld,"native sees old state before Java commit");
        implementation.target=old;failed=false;try{old.makeCurrent();}catch(LWJGLException expected){failed=true;}
        check(failed&&old.thread==Thread.currentThread()&&getCurrentContext()==old,"repeated-current failure preserves owner");
        implementation.bindFails=false;implementation.releaseFails=true;failed=false;
        try{old.releaseCurrent();}catch(LWJGLException expected){failed=true;}
        check(failed&&old.thread==Thread.currentThread()&&getCurrentContext()==old&&GLContext.context==old&&old.destroyChecks==0,
            "release failure retains owner/TLS and avoids destroy");
        implementation.releaseFails=false;old.releaseCurrent();
        check(old.thread==null&&getCurrentContext()==null&&GLContext.context==null&&old.destroyChecks==1,"successful release clears state");
        int releases=implementation.releases;old.releaseCurrent();check(releases==implementation.releases,"release without current is no-op");
        implementation.target=next;next.makeCurrent();
        check(next.thread==Thread.currentThread()&&getCurrentContext()==next&&GLContext.context==next,"successful retry commits new context");
        next.releaseCurrent();next.destroyed=true;int binds=implementation.binds;
        try{next.makeCurrent();throw new AssertionError("destroyed context bound");}catch(IllegalStateException expected){}
        check(implementation.binds==binds&&next.thread==null&&getCurrentContext()==null,"destroyed context refuses before native");
        System.out.println("ContextGL production methods: native failure/success/release ownership PASS");
    }
}
'''


def java_context(build, output, source_zip, java_home, identities):
    """将正式patch应用到锁定上游文件；正例与未打补丁负例均执行提取的真实Java方法。"""
    inputs = json.loads(INPUTS.read_text(encoding='utf-8'))
    fixture_bytes = SOURCE_FIXTURE.read_bytes()
    fixture_digest = hashlib.sha256(fixture_bytes).hexdigest()
    if fixture_digest != inputs['sourceFixtures']['source-fixtures/ContextGL.java']:
        raise ValueError('ContextGL source fixture hash differs from build-inputs.json')
    relative = 'src/java/org/lwjgl/opengl/ContextGL.java'
    if source_zip is not None:
        digest = hashlib.sha256(source_zip.read_bytes()).hexdigest()
        if digest != inputs['files']['lwjgl-2df01dd.zip']:
            raise ValueError('LWJGL2 source ZIP does not match build-inputs.json')
        with zipfile.ZipFile(source_zip) as archive:
            name = 'lwjgl-' + inputs['sourceCommit'] + '/' + relative
            if archive.read(name) != fixture_bytes:
                raise ValueError('ContextGL fixture differs from locked source ZIP')
        identities['sourceZipSha256'] = digest
    upstream = fixture_bytes.decode('utf-8')
    tree = build / 'source'; source_path = tree / relative
    source_path.parent.mkdir(parents=True, exist_ok=True)
    source_path.write_text(upstream, encoding='utf-8', newline='\n')
    run(['git', 'apply', '--check', PATCH], output, 'java-patch-check', cwd=tree)
    run(['git', 'apply', PATCH], output, 'java-patch-apply', cwd=tree)
    patched = source_path.read_text(encoding='utf-8')
    identities['sourceCommit'] = inputs['sourceCommit']
    identities['javaSourceFixtureSha256'] = fixture_digest
    identities['javaPatchSha256'] = hashlib.sha256(PATCH.read_bytes()).hexdigest()
    identities['javaPatchedSourceSha256'] = hashlib.sha256(patched.encode()).hexdigest()
    suffix = '.exe' if os.name == 'nt' else ''
    javac = java_home / 'bin' / ('javac' + suffix)
    java = java_home / 'bin' / ('java' + suffix)
    for name, source, expected in [('java-context', patched, 0), ('java-context-old-order', upstream, 1)]:
        methods = '\n'.join(function(source, method) for method in
                            ['getCurrentContext', 'canAccess', 'checkAccess', 'makeCurrent', 'releaseCurrent'])
        identities[name + '-methodsSha256'] = hashlib.sha256(methods.encode()).hexdigest()
        directory = build / name; directory.mkdir(parents=True, exist_ok=True)
        path = directory / 'ContextGL.java'
        # 上游BSD声明随抽取的第三方方法保留；类字段与边界实现是本测试自己的fixture。
        notice = source[:source.index('package org.lwjgl.opengl;')]
        path.write_text(notice + JAVA_FIXTURE + methods + JAVA_MAIN, encoding='utf-8')
        run([javac, '-encoding', 'UTF-8', '-source', '8', '-target', '8', '-d', directory, path], output, name + '-compile')
        result = run([java, '-cp', directory, 'ContextGL'], output, name, expected)
        if expected and b'AssertionError' not in result.stderr:
            raise RuntimeError('Old Java ordering did not fail a behavior assertion')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-zip', default=os.environ.get('AMCL_LWJGL2_SOURCE_ZIP', ''))
    parser.add_argument('--java-home', default=os.environ.get('AMCL_LWJGL2_TEST_JAVA_HOME', '')
                        or os.environ.get('AMCL_JVM_TEST_JAVA_HOME', '') or os.environ.get('JAVA_HOME', ''))
    parser.add_argument('--build-dir', default='')
    parser.add_argument('--out-dir', default='')
    args = parser.parse_args()
    source_zip = Path(args.source_zip) if args.source_zip else None
    javac_path = shutil.which('javac')
    java_home = Path(args.java_home) if args.java_home else Path(javac_path).resolve().parent.parent if javac_path else None
    suffix = '.exe' if os.name == 'nt' else ''
    if java_home is None or not (java_home / 'bin' / ('javac' + suffix)).is_file() or not (java_home / 'bin' / ('java' + suffix)).is_file():
        raise RuntimeError('Provide host JDK with --java-home, JAVA_HOME or javac on PATH')
    if not PATCH.is_file():
        raise RuntimeError('Production context-current.patch missing')
    build = external_output_path(args.build_dir) if args.build_dir else workspace_path('build', 'lwjgl2-context')
    output = external_output_path(args.out_dir) if args.out_dir else workspace_path('run', 'lwjgl2-context')
    build.mkdir(parents=True, exist_ok=True); output.mkdir(parents=True, exist_ok=True)
    identities = {'boundary': 'host JNI/loader/driver replacements and extracted production Java methods; not device/game verification'}
    run([java_home / 'bin' / ('java' + suffix), '-version'], output, 'host-java-version')
    native_context(build, output, identities)
    extgl_context(build, output, identities)
    java_context(build, output, source_zip, java_home, identities)
    (output / 'identity.json').write_text(json.dumps(identities, indent=2) + '\n', encoding='utf-8')
    print('LWJGL2 context and runtime dispatch regression PASS')


if __name__ == '__main__':
    main()
