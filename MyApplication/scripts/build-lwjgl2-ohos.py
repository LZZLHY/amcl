"""用锁定上游输入重建 LWJGL2 Native、ContextGL与最终输入消费者，输出始终外置。

生成器依赖 JDK8；Native 使用本机 OHOS SDK，不复用旧容器或历史 .o。兼容 JAR
只替换本次维护的 ContextGL/AMCLDisplay和真实Keyboard/Mouse/Display读取点，其余成员保持原字节/元数据，避免重新生成
全部 Java 绑定造成无关接口变更。此脚本不部署、不改锁；产物审核后由维护者显式同步。
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
from lib.workspace_paths import external_output_path


def digest(path):
    """文件内容身份用于输入拒绝与产物比较，不用时间戳推测来源。"""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(args, cwd, env=None):
    """前台显示每个步骤和子命令输出，任一生成/编译失败都中止。"""
    print('[lwjgl2-build] ' + ' '.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True)


def build(options):
    """验证固定输入后在全新外部目录生成；不覆盖历史构建树或产品制品。"""
    spec = json.loads((ROOT / 'prebuilt/lwjgl2/build-inputs.json').read_text(encoding='utf-8'))
    inputs = options.inputs.resolve()
    for name in ['lwjgl-2df01dd.zip', 'ant-1.10.15.jar', 'ant-launcher-1.10.15.jar']:
        if digest(inputs / name) != spec['files'][name]:
            raise ValueError('Unpinned input: ' + name)
    output = external_output_path(options.out)
    if output.exists():
        raise ValueError('Build output must be a new directory: ' + str(output))
    suffix = '.exe' if os.name == 'nt' else ''
    jdk = options.jdk.resolve()
    java = jdk / 'bin' / ('java' + suffix)
    javac = jdk / 'bin' / ('javac' + suffix)
    javah = jdk / 'bin' / ('javah' + suffix)
    version = subprocess.check_output([str(java), '-version'], stderr=subprocess.STDOUT, text=True)
    if '"1.8.' not in version or not javah.is_file():
        raise ValueError('Upstream generator requires JDK8 including javah')
    sdk = options.sdk.resolve()
    clang = sdk / 'native/llvm/bin' / ('clang' + suffix)
    strip = sdk / 'native/llvm/bin' / ('llvm-strip' + suffix)
    readelf = sdk / 'native/llvm/bin' / ('llvm-readelf' + suffix)
    for tool in [clang, strip, readelf]:
        if not tool.is_file():
            raise FileNotFoundError(tool)
    output.mkdir(parents=True)
    source = output / 'upstream'
    with zipfile.ZipFile(inputs / 'lwjgl-2df01dd.zip') as archive:
        # 压缩包身份已锁定，仍检查目录边界，避免误传归档时写出本次构建目录。
        # 去掉冗长的官方归档根名，避免 JDK8 在 Windows 的路径长度限制。
        prefix = 'lwjgl-' + spec['sourceCommit'] + '/'
        for name in archive.namelist():
            if not name.startswith(prefix):
                raise ValueError('Unexpected source archive root')
            target = (source / name[len(prefix):]).resolve()
            if not target.is_relative_to(source):
                raise ValueError('Archive path escapes build: ' + name)
            if name.endswith('/'):
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(name))
    context = source / 'src/java/org/lwjgl/opengl/ContextGL.java'
    fixture = ROOT / 'prebuilt/lwjgl2/source-fixtures/ContextGL.java'
    expected = spec['sourceFixtures']['source-fixtures/ContextGL.java']
    if digest(context) != expected or digest(fixture) != expected:
        raise ValueError('ContextGL source does not match the regression fixture')
    patch = ROOT / 'prebuilt/lwjgl2/patches/context-current.patch'
    run(['git', 'apply', '--check', patch], source)
    run(['git', 'apply', patch], source)
    # 真实next/poll必须接旁带ticket；上游源始终来自固定ZIP，patch应用失败不能退回提取式模型。
    readpoints_patch = ROOT / 'prebuilt/lwjgl2/patches/control-readpoints.patch'
    # 使用固定 JDK/Ant，显式设置本次进程环境，绝不修改用户全局 JAVA_HOME/PATH。
    env = os.environ.copy()
    env['JAVA_HOME'] = str(options.jdk.resolve())
    env['PATH'] = str(options.jdk.resolve() / 'bin') + os.pathsep + env.get('PATH', '')
    ant_cp = os.pathsep.join([*[str(inputs / name) for name in ['ant-1.10.15.jar', 'ant-launcher-1.10.15.jar']],
                              str(jdk / 'lib/tools.jar')])
    for target in ['generate-all', 'headers']:
        run([java, '-cp', ant_cp, 'org.apache.tools.ant.Main', '-Dplatform=linux', target], source, env)
    # Ant的headers先编译纯上游，AMCL类由下面受控javac提供；过早改Display工厂会让Ant
    # 在尚无AMCLDisplay的上游source path查类失败。生成绑定结束后再改真实读取点。
    run(['git', 'apply', '--check', readpoints_patch], source)
    run(['git', 'apply', readpoints_patch], source)
    # Java 工厂保持既有 AMCL 路由；只编译本次消费的 ContextGL 与 AMCL JNI 头所需类。
    text = context.read_text(encoding='utf-8')
    old = 'return new LinuxContextImplementation();'
    if text.count(old) != 1:
        raise ValueError('Unexpected ContextGL platform factory')
    context.write_text(text.replace(old, 'return new AMCLContextImplementation();'), encoding='utf-8')
    java_sources = sorted((ROOT / 'prebuilt/lwjgl2/patches/java').rglob('*.java'))
    classes = output / 'classes'
    headers = output / 'headers'
    classes.mkdir()
    headers.mkdir()
    base_jar = ROOT / 'entry/src/main/resources/rawfile/lwjgl2/lwjgl.jar'
    readpoints = [source / ('src/java/org/lwjgl/' + name) for name in
                  ['input/Keyboard.java','input/Mouse.java','opengl/Display.java','opengl/EventQueue.java']]
    run([javac, '-encoding', 'UTF-8', '-source', '1.6', '-target', '1.6', '-cp', base_jar,
         '-d', classes, *java_sources, context, *readpoints], source, env)
    # 完整配方同Java-only配方共用封闭声明门；Native头生成前确认原JNI签名/协议字段
    # 未变，只白名单本批两个非公开helper，不能用重编SO让未知ABI增量悄然进入cohort。
    abi_path = ROOT / 'scripts/rebuild-lwjgl2-input-jar.py'
    abi_spec = importlib.util.spec_from_file_location('lwjgl2_java_abi_recipe', abi_path)
    abi_recipe = importlib.util.module_from_spec(abi_spec); abi_spec.loader.exec_module(abi_recipe)
    for class_name in ['org.lwjgl.opengl.ContextGL','org.lwjgl.opengl.AMCLDisplay','org.lwjgl.opengl.Display',
                       'org.lwjgl.input.Keyboard','org.lwjgl.input.Mouse','org.lwjgl.opengl.EventQueue']:
        old = subprocess.check_output([str(jdk / 'bin' / ('javap' + suffix)), '-private', '-s', '-classpath', str(base_jar), class_name], env=env)
        new = subprocess.check_output([str(jdk / 'bin' / ('javap' + suffix)), '-private', '-s', '-classpath', str(classes), class_name], env=env)
        abi_recipe.verify_declarations(old, new, class_name)
    run([javah, '-force', '-classpath', os.pathsep.join([str(classes), str(base_jar)]), '-d', headers,
         'org.lwjgl.opengl.AMCLDisplay', 'org.lwjgl.opengl.AMCLContextImplementation'], source, env)
    native = source / 'src/native'
    jni = ROOT / 'prebuilt/mod-natives/imgui-java/jni/jni-headers'
    includes = [jni, jni / 'linux', native / 'common', native / 'common/opengl',
                native / 'linux', native / 'linux/opengl', headers,
                ROOT / 'entry/src/main/cpp/input/delivery']
    flags = ['--target=aarch64-linux-ohos', '--sysroot=' + str(sdk / 'native/sysroot'),
             '-O2', '-fPIC', '-std=c99', '-fno-strict-aliasing', '-DLWJGL_LINUX', '-D_GNU_SOURCE']
    sources = []
    for directory in ['common', 'common/opengl', 'generated/opengl', 'generated/openal']:
        for path in sorted((native / directory).glob('*.c')):
            name = path.name
            # AWT 名称按上游原大小写匹配；不能 lower() 后搜 awt，NVDrawTexture
            # 中的 DrawT 也会命中，造成现有 JNI 入口静默漏编。
            if 'AWT' in name or 'awt' in name or 'opencl' in name or '_CL' in name:
                continue
            if name in ['org_lwjgl_opengl_NVVideoCaptureUtil.c', 'org_lwjgl_opengl_NVPresentVideoUtil.c']:
                continue
            sources.append(path)
    sources += sorted((ROOT / 'prebuilt/lwjgl2/ohos-backend').glob('*.c'))
    objects = output / 'objects'
    objects.mkdir()
    object_files = []
    for index, path in enumerate(sources):
        obj = objects / (str(index) + '-' + path.stem + '.o')
        run([clang, *flags, *['-I' + str(p) for p in includes], '-c', path, '-o', obj], output)
        object_files.append(obj)
    library = output / 'liblwjgl_v2.so'
    # 完整重链，禁止未解析 JNI/GL 实现；不把旧二进制作为隐式输入。
    run([clang, *flags, '-shared', '-Wl,--no-undefined', '-Wl,-soname,liblwjgl_v2.so',
         '-Wl,-z,noexecstack', '-o', library, *object_files, '-lm'], output)
    run([strip, '--strip-all', library], output)
    identity = subprocess.check_output([str(readelf), '-h', '-d', str(library)], text=True)
    if 'AArch64' not in identity or 'liblwjgl_v2.so' not in identity:
        raise ValueError('Native identity mismatch')
    nm = sdk / 'native/llvm/bin' / ('llvm-nm' + suffix)
    def exports(path):
        """对照当前交付库的真实动态导出，生成器/筛选错误不能变成新的锁定结果。"""
        text = subprocess.check_output([str(nm), '--dynamic', '--defined-only', str(path)], text=True)
        return {line.split()[-1] for line in text.splitlines() if line.split()}
    missing = exports(ROOT / 'entry/libs/arm64-v8a/liblwjgl_v2.so') - exports(library)
    if missing:
        raise ValueError('Existing native exports disappeared: ' + ', '.join(sorted(missing)))
    # 输入消费者与context均必须进入同一交付JAR；只编译源码而不替换AMCLDisplay会交付旧输入行为。
    replacements = {name: classes / name for name in [
        'org/lwjgl/opengl/ContextGL.class', 'org/lwjgl/opengl/AMCLDisplay.class',
        'org/lwjgl/opengl/Display.class', 'org/lwjgl/input/Keyboard.class', 'org/lwjgl/input/Mouse.class','org/lwjgl/opengl/EventQueue.class']}
    jar = output / 'lwjgl.jar'
    with zipfile.ZipFile(base_jar) as original, zipfile.ZipFile(jar, 'w') as result:
        for member in original.infolist():
            data = replacements[member.filename].read_bytes() if member.filename in replacements else original.read(member)
            result.writestr(member, data)
    # JAR 非目标成员必须逐字一致，Java ABI 面由正式回归与兼容槽门禁另行核对。
    with zipfile.ZipFile(base_jar) as original, zipfile.ZipFile(jar) as result:
        if original.namelist() != result.namelist():
            raise ValueError('JAR membership changed')
        for name in original.namelist():
            if name not in replacements and original.read(name) != result.read(name):
                raise ValueError('Unrelated JAR member changed: ' + name)
    report = {'schema': 1, 'upstreamCommit': spec['sourceCommit'], 'sourceArchiveSha256': digest(inputs / 'lwjgl-2df01dd.zip'),
              'patchSha256': digest(patch), 'readpointsPatchSha256': digest(readpoints_patch),
              'controlPortHeaders': {p.name: digest(p) for p in [
                  ROOT / 'entry/src/main/cpp/input/delivery/control_delivery.h',
                  ROOT / 'entry/src/main/cpp/input/delivery/control_delivery_client.h']},
              'lookPortHeaders': {p.name: digest(p) for p in [
                  ROOT / 'entry/src/main/cpp/input/delivery/look_execution.h',
                  ROOT / 'entry/src/main/cpp/input/delivery/look_execution_client.h']},
              # 可选诊断私有表与借用层进入实际 JNI 编译，独立记录原字节身份；
              # 缺失观察不影响 input 配对，但新 cohort 不能漏记该编译依赖。
              'latencyPortHeaders': {p.name: digest(p) for p in [
                  ROOT / 'entry/src/main/cpp/input/input_latency_observation.h',
                  ROOT / 'entry/src/main/cpp/input/input_latency_client.h']},
              # 独立Keyboard资格表也进入实际JNI编译；必须记录两头原字节身份，
              # 不能只核control/look头而漏掉同源装配所需的Keyboard私有契约。
              'keyboardPortHeaders': {p.name: digest(p) for p in [
                  ROOT / 'entry/src/main/cpp/input/delivery/l2_keyboard_scope.h',
                  ROOT / 'entry/src/main/cpp/input/delivery/l2_keyboard_scope_client.h']},
              'buildScriptSha256': digest(__file__), 'javaAbiRecipeSha256': digest(abi_path), 'jdkVersion': version.strip(),
              'compiler': subprocess.check_output([str(clang), '--version'], text=True).splitlines()[0],
              'baseJarSha256': digest(base_jar), 'sources': {str(p.relative_to(ROOT)) if p.is_relative_to(ROOT) else str(p.relative_to(source)): digest(p) for p in sources},
              'artifacts': {p.name: {'size': p.stat().st_size, 'sha256': digest(p)} for p in [library, jar]},
              'javaChangedMembers': sorted(replacements),
              'javaSources': {str(p.relative_to(ROOT)): digest(p) for p in java_sources},
              'upstreamReadpointSources': {str(p.relative_to(source)): digest(p) for p in readpoints}, 'nativeIdentity': identity}
    (output / 'provenance.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('[lwjgl2-build] complete: ' + json.dumps(report['artifacts']), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', type=Path, required=True, help='固定源码ZIP与两份Ant JAR所在目录')
    parser.add_argument('--jdk', type=Path, required=True, help='JDK8目录，必须包含javac/javah')
    parser.add_argument('--sdk', type=Path, required=True, help='包含native/的OpenHarmony SDK目录')
    parser.add_argument('--out', type=Path, required=True, help='尚不存在的仓库外构建目录')
    build(parser.parse_args())
