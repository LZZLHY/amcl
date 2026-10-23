"""沿既有build-lwjgl2-ohos的Java配方双编/确定性封装；Native源码/SO不变时不重编SDK。

完整上游固定ZIP、ContextGL冻结样本与两正式patch仍核实；只替正常recipe的六维护class。
不读取private gitref，不下载环境，不修改任何用户全局TEMP/JAVA_HOME。
"""
from pathlib import Path
import argparse,hashlib,json,os,subprocess,zipfile
from datetime import datetime
from lib.workspace_paths import external_output_path
ROOT=Path(__file__).resolve().parents[1]
def sha(p):
    """记录实取原字节SHA；固定ZIP/正式patch/每维护类均绑定这次实际读取的内容。"""
    return hashlib.sha256(p.read_bytes()).hexdigest()
def run(args,cwd,log,env):
    """所有工具前台并保原日志；失败直接终止，不能用旧制品补新源码身份。"""
    result=subprocess.run(list(map(str,args)),cwd=cwd,capture_output=True,env=env,timeout=120)
    log.write_bytes(result.stdout+result.stderr);print((result.stdout+result.stderr).decode(errors='replace')[-3000:],flush=True)
    if result.returncode:raise RuntimeError(str(log))
def verify_declarations(old_output,new_output,class_name):
    """逐项保既有全部可见性、字段/方法及JNI descriptor，只允许登记的确切私有增量。

    javap读取已编译class，不用源码字符串猜ABI；未知新成员、旧成员丢失/改签名/
    修饰符或顺序变化均拒绝。包内bulk入口和自有private codec不扩公开Keyboard。
    """
    def entries(output):
        lines=output.decode('utf8').splitlines();result=[];declaration=None
        for line in lines:
            stripped=line.strip()
            if stripped.startswith('Compiled from '):continue
            if stripped.startswith('descriptor:'):
                if declaration is None:raise ValueError('javap descriptor without declaration')
                result.append((declaration,stripped));declaration=None
            elif stripped and stripped!='}':declaration=stripped
        # class声明也须一致，不能通过新增class modifier绕过成员比较。
        header=next(line.strip() for line in lines if line.strip().endswith('{') and ' class ' in ' '+line.strip())
        return header,result
    # 每项声明都从真实 javap -private -s 输出核实；这里只白名单本批诊断的三个私有
    # 字段、三个 helper 和三个 JNI，不把任意 private/名字前缀变成豁免。旧消费者的
    # control/look JNI、上游公开 API 与声明顺序仍须逐项相等，未来已含这些项也不能删改。
    allowed={
        'org.lwjgl.opengl.AMCLDisplay':[
            ('private boolean putCharacterEvent(int, long[]);','descriptor: (I[J)Z'),
            # 原scalar构造点的两FIFO/状态与有界preflight均是确切增量，不豁免任意private。
            ('private final java.util.LinkedList<long[]> keyboardQueuedScalars;','descriptor: Ljava/util/LinkedList;'),
            ('private final java.util.LinkedList<long[]> keyboardReadScalars;','descriptor: Ljava/util/LinkedList;'),
            ('private boolean inputDraining;','descriptor: Z'),
            ('private boolean drainEvents(int);','descriptor: (I)Z'),
            ('boolean keyboardReadPreflight();','descriptor: ()Z'),
            ('private boolean lookLatencyAvailable;','descriptor: Z'),
            ('private long[] lookLatencyPending;','descriptor: [J'),
            ('private long[] lookLatencyPoll;','descriptor: [J'),
            ('private void clearLookLatency(int);','descriptor: (I)V'),
            ('private void cacheLookLatency(long[]);','descriptor: ([J)V'),
            ('private void beginLookLatencyPoll();','descriptor: ()V'),
            ('private static native boolean nLookLatencyAvailable();','descriptor: ()Z'),
            ('private static native void nLookLatencyNote(long[], int);','descriptor: ([JI)V'),
            ('private static native void nLookLatencyFinish(long[], int);','descriptor: ([JI)V')],
        'org.lwjgl.opengl.Display':[
            ('public static boolean amclKeyboardReadPreflight(org.lwjgl.opengl.InputImplementation);',
             'descriptor: (Lorg/lwjgl/opengl/InputImplementation;)Z')],
        'org.lwjgl.opengl.EventQueue':[
            ('synchronized boolean putEvents(java.nio.ByteBuffer);','descriptor: (Ljava/nio/ByteBuffer;)Z')]}
    old_header,old_entries=entries(old_output);new_header,new_entries=entries(new_output)
    if class_name in allowed:
        additions=allowed[class_name]
        # 旧JAR尚无某一登记项时只允许该确切项新增；以后已同步的JAR也作为正常基线，
        # 这些项已是既有成员，必须同其它声明保持完全一致，不能阻断后续正规重建。
        for addition in additions:
            if new_entries.count(addition)!=1:raise ValueError('Missing exact allowed Java addition: '+class_name+' '+addition[0])
            if addition not in old_entries:new_entries.remove(addition)
    if old_header!=new_header or old_entries!=new_entries:
        raise ValueError('Existing Java/JNI declaration changed or unknown addition: '+class_name)

def main(options):
    """输出目录必须新建；实际编译输入与字节收据独立保留。"""
    out=external_output_path(options.out);out.mkdir(parents=True,exist_ok=False)
    source=out/'source';source.mkdir();temp=out/'temp';temp.mkdir();env=dict(os.environ);env.update(TEMP=str(temp),TMP=str(temp),TMPDIR=str(temp))
    spec=json.loads((ROOT/'prebuilt/lwjgl2/build-inputs.json').read_text(encoding='utf8'));archive=options.inputs/'lwjgl-2df01dd.zip'
    if sha(archive)!=spec['files'][archive.name]:raise ValueError('Locked source ZIP mismatch')
    prefix='lwjgl-'+spec['sourceCommit']+'/'
    with zipfile.ZipFile(archive) as z:
        for member in z.namelist():
            if not member.startswith(prefix+'src/java/') or member.endswith('/'):continue
            target=(source/member[len(prefix):]).resolve()
            if not target.is_relative_to(source.resolve()):raise ValueError('Source path crosses workspace')
            target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(z.read(member))
    fixture=ROOT/'prebuilt/lwjgl2/source-fixtures/ContextGL.java';expected=spec['sourceFixtures']['source-fixtures/ContextGL.java']
    if sha(fixture)!=expected:raise ValueError('Frozen ContextGL changed')
    context=source/'src/java/org/lwjgl/opengl/ContextGL.java';context.write_bytes(fixture.read_bytes())
    patches=[ROOT/'prebuilt/lwjgl2/patches/context-current.patch',ROOT/'prebuilt/lwjgl2/patches/control-readpoints.patch']
    for i,patch in enumerate(patches):
        run(['git','-c','core.autocrlf=false','apply','--check',patch],source,out/(str(i)+'-check.log'),env)
        run(['git','-c','core.autocrlf=false','apply',patch],source,out/(str(i)+'-apply.log'),env)
    text=context.read_text(encoding='utf8');needle='return new LinuxContextImplementation();';assert text.count(needle)==1
    context.write_text(text.replace(needle,'return new AMCLContextImplementation();'),encoding='utf8')
    java=sorted((ROOT/'prebuilt/lwjgl2/patches/java').rglob('*.java'))
    readpoints=[source/('src/java/org/lwjgl/'+name) for name in ['input/Keyboard.java','input/Mouse.java','opengl/Display.java','opengl/EventQueue.java']]
    classes=out/'classes';classes.mkdir();base=ROOT/'entry/src/main/resources/rawfile/lwjgl2/lwjgl.jar'
    run([options.jdk/'bin/javac.exe','-encoding','UTF-8','-source','1.6','-target','1.6','-cp',base,'-d',classes,*java,context,*readpoints],source,out/'javac.log',env)
    replacements=['org/lwjgl/opengl/ContextGL.class','org/lwjgl/opengl/AMCLDisplay.class','org/lwjgl/opengl/Display.class','org/lwjgl/input/Keyboard.class','org/lwjgl/input/Mouse.class','org/lwjgl/opengl/EventQueue.class']
    jar=out/'lwjgl.jar'
    with zipfile.ZipFile(base) as old,zipfile.ZipFile(jar,'w') as result:
        for info in old.infolist():result.writestr(info,(classes/info.filename).read_bytes() if info.filename in replacements else old.read(info))
    changed=[]
    with zipfile.ZipFile(base) as old,zipfile.ZipFile(jar) as current:
        if old.namelist()!=current.namelist():raise ValueError('Jar membership changed')
        for name in old.namelist():
            if old.read(name)!=current.read(name):changed.append(name)
            if name not in replacements and old.read(name)!=current.read(name):raise ValueError('Unrelated Jar class changed')
    # 编译后核六个维护class的全部声明；既有私有JNI/协议/字段不因codec增量被放宽。
    for class_name in ['org.lwjgl.opengl.ContextGL','org.lwjgl.opengl.AMCLDisplay','org.lwjgl.opengl.Display',
        'org.lwjgl.input.Keyboard','org.lwjgl.input.Mouse','org.lwjgl.opengl.EventQueue']:
        declarations=[]
        for label,cp in [('old',base),('new',jar)]:
            p=subprocess.run([str(options.jdk/'bin/javap.exe'),'-private','-s','-classpath',str(cp),class_name],capture_output=True,env=env,timeout=60)
            (out/(label+'-'+class_name+'-javap.log')).write_bytes(p.stdout+p.stderr)
            if p.returncode:raise RuntimeError('Actual javap failed')
            declarations.append(p.stdout)
        verify_declarations(*declarations,class_name)
    report={'recordedAt':datetime.now().astimezone().isoformat(),'scope':'Normal existing Java recipe; actual JDK8 compile and six-member deterministic packaging; SO untouched',
        'baseJarSha':sha(base),'sourceArchiveSha':sha(archive),'patches':{str(p.relative_to(ROOT)):sha(p) for p in patches},
        'javaSources':{str(p.relative_to(ROOT)):sha(p) for p in java},'upstreamReadpoints':{str(p.relative_to(source)):sha(p) for p in readpoints},
        'changedMembers':changed,'artifact':{'size':jar.stat().st_size,'sha256':sha(jar)},'scriptSha':sha(Path(__file__))}
    (out/'receipt.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8');print(json.dumps(report['artifact']),flush=True)
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--inputs',type=Path,required=True);parser.add_argument('--jdk',type=Path,required=True);parser.add_argument('--out',type=Path,required=True);main(parser.parse_args())
