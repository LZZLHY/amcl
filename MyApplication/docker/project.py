"""AMCL Compose 项目执行器：固定服务、受控工作卷复用、独占前台任务与外部证据。

容器不是构建身份：builder/qa 各只有一个服务实例，每次执行有独立 runId/输出/清单。
镜像、SDK 哨兵和配方/补丁变化时拒绝自动复用；--fresh 新建卷但不删除旧独有状态。
禁止全局 prune、强停运行任务、删除数据卷或通过失效 bind 自动补建宿主目录。
"""
import argparse
from contextlib import contextmanager
from datetime import datetime
import hashlib
import importlib.util
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts/lib'))
from workspace_paths import external_output_path, workspace_path, shared_workspace_path

RECIPES = {'smoke': 'build_sysroot_probe.sh', **{name: f'build_{name}_ohos.sh'
           for name in ('curl','fontconfig','gl4es','jdk8','jdk17','jdk21','jdk25','lwjgl','sdl3','shaderc')}}
SENTINELS = ('usr/include/stdio.h','usr/include/aarch64-linux-ohos/bits/alltypes.h',
             'usr/lib/aarch64-linux-ohos/libc.so')
PROJECT = 'amcl'

def now():
    """清单时间在操作现场读取并包含本机时区，不借输出文件 mtime 猜测执行时间。"""
    return datetime.now().astimezone().isoformat()

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))

def write_json(path, value):
    """状态原子替换，调用者已经取得项目锁；每次任务证据使用新的独占目录。"""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.writing-' + uuid.uuid4().hex)
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    os.replace(temporary, path)

def docker(*args):
    """每个参数独立传递；错误立即传播，调用方只传入已验证的本项目身份和路径。"""
    result = subprocess.run(['docker', *map(str,args)], capture_output=True, text=True, encoding='utf-8')
    if result.returncode:
        raise RuntimeError('docker '+str(args[0])+' failed: '+result.stderr.strip())
    return result.stdout.strip()

def image_id(name):
    """把可变标签解析成引擎本地不可变 ID；Compose 禁止隐式拉取另一个同名镜像。"""
    identity = docker('image','inspect','--format','{{.Id}}',name)
    if len(identity)!=71 or not identity.startswith('sha256:') or any(c not in '0123456789abcdef' for c in identity[7:]):
        raise ValueError('Expected an immutable local Docker image ID')
    return identity

def freeze_unwind_source(source, destination):
    """只从固定 Git commit 导出真实输入；忽略工作树修改，补丁另按正式源码冻结。"""
    if not source:
        raise ValueError('unwind qualification requires --unwind-source')
    lock = read_json(ROOT/'prebuilt/abi/source.json')
    source = Path(source).resolve()
    def git(*args):
        # git archive 也会消费宿主 autocrlf；显式保持上游 LF，不能让 Windows 配置
        # 悄悄改变导出的编译输入，或把补丁应用失败错误归因到固定源码版本。
        return subprocess.check_output(['git', '-C', str(source), '-c', 'core.autocrlf=false',
                                        '-c', 'core.eol=lf', *args])
    if git('remote', 'get-url', 'origin').decode().strip() != lock['repository']:
        raise ValueError('Unexpected libunwind source repository')
    if git('rev-parse', lock['commit']+'^{commit}').decode().strip() != lock['commit']:
        raise ValueError('Unverified libunwind source commit')
    destination.mkdir(parents=True, exist_ok=False)
    (destination/'source.tar').write_bytes(git('archive', lock['commit'], *lock['paths']))
    for name in lock['patches']:
        (destination/name).write_bytes((ROOT/'prebuilt/abi/patches'/name).read_bytes())
    for name in lock.get('files', []):
        (destination/name).write_bytes((ROOT/'prebuilt/abi'/name).read_bytes())
    write_json(destination/'source.json', lock)
    return {'commit': lock['commit'], 'repository': lock['repository'],
            'files': {path.name: digest(path) for path in sorted(destination.iterdir())}}

@contextmanager
def project_lock(directory):
    """同 checkout 的状态/Compose 变更持有 OS 文件锁；进程退出自动释放，不凭 PID 删除锁文件。"""
    directory.mkdir(parents=True, exist_ok=True)
    with (directory/'project.lock').open('a+b') as stream:
        stream.seek(0,2)
        if stream.tell()==0: stream.write(b'0'); stream.flush()
        stream.seek(0)
        try:
            if os.name=='nt':
                import msvcrt
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            raise RuntimeError('AMCL Docker project is busy; wait for the foreground task') from error
        try: yield
        finally:
            stream.seek(0)
            if os.name=='nt': msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else: fcntl.flock(stream.fileno(), fcntl.LOCK_UN)

def bind(source, target, readonly=True):
    """长格式 bind 禁止自动创建源目录；所有路径解析后必须已经存在。"""
    source = Path(source).resolve()
    if not source.is_dir(): raise ValueError('Bind source does not exist: '+str(source))
    return {'type':'bind','source':source.as_posix(),'target':target,'read_only':readonly,
            'bind':{'create_host_path':False}}

def install_archive_inputs(path):
    """完整安装测试只认固定四原包身份；先验文件/SHA/size，再允许建立只读挂载。"""
    value = read_json(path)
    if not isinstance(value, dict):
        raise ValueError('install archives manifest must be an object')
    records = value.get('archives')
    if value.get('schemaVersion') != 1 or not isinstance(records, list) or len(records) != 4:
        raise ValueError('install archives require schemaVersion 1 and exactly four candidates')
    result = []
    for record in records:
        if not isinstance(record, dict) or record.get('major') not in ('8', '17', '21', '25'):
            raise ValueError('invalid install archive major')
        archive = Path(record.get('archive', '')).resolve()
        expected = record.get('sha256', '')
        size = record.get('sizeBytes')
        if not archive.is_file() or not re.fullmatch('[0-9a-f]{64}', expected) or type(size) is not int or size <= 0:
            raise ValueError('invalid install archive path, SHA256 or size')
        if archive.stat().st_size != size or digest(archive) != expected:
            raise ValueError('install archive identity mismatch: ' + str(archive))
        result.append({'major':record['major'], 'archive':str(archive), 'sha256':expected, 'sizeBytes':size,
                       'containerPath':'/install-archives/' + record['major'] + '.zip'})
    if {record['major'] for record in result} != {'8', '17', '21', '25'}:
        raise ValueError('install archive majors must be unique')
    return sorted(result, key=lambda record:int(record['major']))

def check_service(service):
    """仅接管本 checkout 的已停止受控服务；发现其他归属或活动容器不强制替换。"""
    ids = docker('ps','-aq','--filter','label=com.docker.compose.project='+PROJECT,
                 '--filter','label=com.docker.compose.service='+service).splitlines()
    if len(ids)>1: raise RuntimeError('Multiple containers for fixed service '+service)
    for identity in ids:
        item = json.loads(docker('inspect',identity))[0]
        labels = item['Config'].get('Labels') or {}
        if labels.get('amcl.checkout')!=str(ROOT) or labels.get('amcl.managed')!='1':
            raise RuntimeError('Refusing foreign/unmanaged Compose service '+service)
        if item['State']['Running']: raise RuntimeError('Compose service is running: '+service)

def check_volume(name):
    """卷必须存在且无人运行使用；包括其他项目/工具的只读挂载，避免构建时读取半成品。"""
    docker('volume','inspect',name)
    active = docker('ps','-q','--filter','volume='+name)
    if active: raise RuntimeError('Work volume is in use: '+name)

def input_identity(component, image, sysroot):
    """限定共享缓存可复用的输入；SDK 是明确的三个哨兵范围，不冒充整个 SDK 摘要。"""
    sysroot = Path(sysroot).resolve()
    for name in SENTINELS:
        if not (sysroot/name).is_file(): raise ValueError('Missing SDK input: '+name)
    recipe = ROOT/'docker'/RECIPES[component]
    if not recipe.is_file(): raise ValueError('Missing recipe: '+str(recipe))
    files = {recipe, ROOT/'docker/setup_toolchain.sh', ROOT/'deps.lock'}
    for directory in (ROOT/'docker/scripts', ROOT/'docker/stubs', ROOT/'prebuilt/stubs/src'):
        files.update(p for p in directory.rglob('*') if p.is_file() and '__pycache__' not in p.parts)
    if component.startswith('jdk'):
        # 入口、源码准备和兼容 C 文件也是配方闭包，不能只记录顶层 build 脚本。
        files.update(p for p in (ROOT/'docker').rglob('*')
                     if p.is_file() and p.suffix in ('.sh', '.py', '.c', '.h')
                     and '__pycache__' not in p.parts)
        files.add(ROOT/'prebuilt/jdk/build-inputs.json')
        for name in ('patches','shims'):
            files.update(p for p in (ROOT/'prebuilt/jdk'/component[3:]/name).rglob('*') if p.is_file())
        if component in ('jdk17', 'jdk21', 'jdk25'):
            # 新导入的FT源码既有精确patch，也绑定匹配上游版本/逐文件来源和原始许可。
            # 与实际patch字节不符时构建前拒绝；不能在发布时用后来改写的说明追认来源。
            metadata = ROOT/'prebuilt/fontconfig/freetype-completion.json'
            completion = read_json(metadata)['runtimes'][component[3:]]
            expected_patch = f'prebuilt/jdk/{component[3:]}/patches/0016-fontconfig-freetype-bdf-pcf-completion.patch'
            if completion.get('patch') != expected_patch or digest(ROOT/expected_patch) != completion.get('patchSha256'):
                raise ValueError('FreeType completion patch identity mismatch')
            files.add(metadata)
            for license in completion['licenses'].values():
                name = license['path']
                expected_prefix = 'prebuilt/fontconfig/licenses/freetype-' + completion['version'] + '/'
                if not name.startswith(expected_prefix) or '..' in Path(name).parts or digest(ROOT/name) != license['sha256']:
                    raise ValueError('FreeType completion license identity mismatch')
                files.add(ROOT/name)
    else:
        files.update(p for p in (ROOT/'prebuilt'/component/'patches').rglob('*') if p.is_file())
        if component == 'fontconfig':
            # 字体 provider 也冻结完整目标 SDK 与入口；不能用旧三个哨兵或宿主头
            # 代替真实 ABI 输入。消费者 FT 原件保持不变，由候选验收逐一核对导出。
            files.add(ROOT/'prebuilt/fontconfig/build-inputs.json')
            files.add(ROOT/'prebuilt/fontconfig/ohos-defaults.json')
            files.add(ROOT/'prebuilt/fontconfig/ohos-generic-fonts.h')
            files.update(ROOT/'docker'/name for name in (
                'project-build-entry.sh', 'builder-entry.sh', 'resume-builder-entry.sh', 'project.py'))
        if component == 'lwjgl':
            # VMA正式兼容/诊断补丁是编译输入；变化后不能静默认领旧组件工作卷。
            files.add(ROOT/'prebuilt/lwjgl3/local-worktree.patch')
        if component=='gl4es':
            # 源码规格和身份/产物验证器也是复用输入；不能认领上一补丁集的缓存。
            files.update((ROOT/'prebuilt/gl4es/build-inputs.json', ROOT/'docker/verify_gl4es_source.py',
                          ROOT/'docker/verify_gl4es_artifact.py'))
            # SO 消费摘要不参与它自身的重建身份；源码 lock 与独立 build-inputs 必须一致。
            section=re.search(r'^\[gl4es\]\n(.*?)(?=^\[|\Z)',(ROOT/'deps.lock').read_text(),re.M|re.S).group(1)
            values=dict(re.findall(r'^(repo|commit)\s*=\s*(\S+)',section,re.M))
            spec=read_json(ROOT/'prebuilt/gl4es/build-inputs.json')
            if values.get('repo')!=spec['repository'] or values.get('commit')!=spec['commit']:
                raise ValueError('gl4es source lock/build-inputs mismatch')
            files.remove(ROOT/'deps.lock')
    facts = {'component':component,'imageId':image,'sysroot':str(sysroot),
             'sdk':{p:digest(sysroot/p) for p in SENTINELS},
             'files':{p.relative_to(ROOT).as_posix():digest(p) for p in sorted(files)}}
    if component.startswith('jdk') or component == 'fontconfig':
        # 完整目标 sysroot、应用 C++ 头/库及 compiler-rt 在执行前冻结为只读输入。
        sys.path.insert(0, str(ROOT/'docker/scripts'))
        from jdk_native_inputs import native_inputs
        facts['nativeSdk'] = native_inputs(sysroot)
    facts['digest'] = hashlib.sha256(json.dumps(facts,sort_keys=True).encode()).hexdigest()
    if component=='gl4es': facts['consumerLockSha256']=digest(ROOT/'deps.lock')
    return facts

def load_state(directory):
    state = read_json(directory/'state.json') if (directory/'state.json').exists() else {'schema':1,'checkout':str(ROOT),'workspaces':{}}
    if state.get('checkout')!=str(ROOT): raise ValueError('State belongs to a different checkout')
    return state

def compose_args(override):
    return ['compose','--ansi','never','-p',PROJECT,'-f',str(ROOT/'docker/compose.yaml'),'-f',str(override)]

def service_model(service, image, command=None, mounts=None, environment=None):
    """覆盖配置只含当前服务；不加 remove-orphans、不触及同组其他服务及其数据。"""
    model = {'image':image,'labels':{'amcl.checkout':str(ROOT),'amcl.managed':'1'}}
    if command is not None:
        model.update(entrypoint=['/bin/bash'], command=command, working_dir='/build' if service=='builder' else '/workspace')
    if mounts is not None: model['volumes']=mounts
    if environment: model['environment']=environment
    return {'services':{service:model}}

def legacy_services(path):
    """已迁移历史服务必须只读且离线；禁止本机目录表覆盖日常服务或重新接入旧可写挂载。"""
    model=read_json(path)
    for name,item in model.get('services',{}).items():
        if not name.startswith('legacy-') or item.get('read_only') is not True or item.get('network_mode')!='none':
            raise ValueError('Legacy catalog must contain only read-only offline legacy services')
        if item.get('privileged') or item.get('ports') or any(not mount.get('read_only') for mount in item.get('volumes',[])):
            raise ValueError('Legacy catalog cannot grant host write/network privileges')
    return model.get('services',{})

def include_legacy(model, state):
    """同一完整 Compose 项目包含历史服务，避免正常构建把它们误报为孤立容器。"""
    if state.get('legacyConfig'):
        if digest(state['legacyConfig'])!=state['legacyConfigSha256']:
            raise ValueError('Legacy catalog identity changed; explicitly register it again')
        model['services'].update(legacy_services(state['legacyConfig']))
    return model

def stream_compose(override, service, log):
    """前台附着真实构建，stdout/stderr 同时落盘；返回服务退出码，保留失败证据。"""
    args = compose_args(override)+['up','--no-build','--pull','never','--no-deps',
            '--abort-on-container-exit','--exit-code-from',service,service]
    with Path(log).open('x',encoding='utf-8') as output:
        with subprocess.Popen(['docker',*args],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                              text=True,encoding='utf-8',errors='replace',bufsize=1) as process:
            for line in process.stdout:
                output.write(line); output.flush()
                print(line,end='',flush=True)
            return process.wait()

def adopt_manifest(path, component, facts):
    """显式认领上一代受控构建卷；核对原容器、挂载、镜像、SDK与完整候选配方身份。"""
    manifest = read_json(path)
    if Path(manifest['projectRoot']).resolve()!=ROOT or manifest['recipe']!=RECIPES[component]:
        raise ValueError('Manifest checkout/component mismatch')
    if manifest['imageId']!=facts['imageId'] or manifest['recipeSha256']!=facts['files']['docker/'+RECIPES[component]]:
        raise ValueError('Manifest image/recipe mismatch; use --fresh')
    if {p['path']:p['sha256'] for p in manifest['sysrootSentinels']}!=facts['sdk']:
        raise ValueError('Manifest SDK mismatch')
    old = json.loads(docker('inspect',manifest['container']))[0]
    if old['State']['Running'] or old['Image']!=facts['imageId'] or old['Config']['Labels'].get('amcl.run')!=manifest['runId']:
        raise ValueError('Original managed container identity/state mismatch')
    if not any(m.get('Name')==manifest['workVolume'] and m['Destination']=='/build' for m in old['Mounts']):
        raise ValueError('Original work volume mismatch')
    if component in ('jdk17','jdk21','jdk25'):
        candidates = list(Path(manifest['output']).glob('jdk*-runtime-audio-rc2.manifest.json'))
        if len(candidates)!=1: raise ValueError('Adoption requires a verified complete candidate receipt')
        build = read_json(candidates[0])['build']
        if digest(ROOT/'prebuilt/jdk/build-inputs.json')!=build['inputsSha256']:
            raise ValueError('Candidate source input mismatch')
        for name, value in build['patches'].items():
            if digest(ROOT/'prebuilt/jdk'/component[3:]/'patches'/name)!=value: raise ValueError('Candidate patch mismatch')
        for name,value in build['recipes'].items():
            target = ROOT/'docker'/name
            if not target.exists(): target=ROOT/'docker/scripts'/name
            if digest(target)!=value: raise ValueError('Candidate recipe mismatch')
    check_volume(manifest['workVolume'])
    return {'volume':manifest['workVolume'],'buildId':manifest['runId'],'inputs':facts,
            'adoptedFrom':str(Path(path).resolve()),'createdAt':now()}

def daudio_test_inputs(args):
    """DAUDIO 仅是 java-sound-17 的明确输入模式；两个参数成对且绑定独立 SHA。"""
    manifest = getattr(args, 'java_sound_daudio_sources', None)
    expected_sha = getattr(args, 'java_sound_daudio_sha', None)
    if not manifest and not expected_sha:
        return None
    if args.action != 'test' or args.suite != 'java-sound-17' or not manifest or not expected_sha:
        raise ValueError('DAUDIO input/independent SHA pair is restricted to java-sound-17')
    if getattr(args, 'test_arg', []):
        raise ValueError('DAUDIO uses fixed test inputs; arbitrary test arguments are not accepted')
    module_path = ROOT / 'tests/java-sound/daudio_qa_inputs.py'
    spec = importlib.util.spec_from_file_location('amcl_daudio_qa_inputs', module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    commit = read_json(ROOT / 'prebuilt/jdk/build-inputs.json')['runtimes']['17']['commit']
    return module.validate(manifest, expected_sha, commit)


def run(args):
    """解析请求后先完成只读预检；计划模式无目录/卷/容器副作用。"""
    # Compose的控制状态和卷登记必须跨任务复用，不能跟随本轮AMCL_BUILD_DIR迁移。
    directory = external_output_path(args.state_dir) if args.state_dir else shared_workspace_path('build','docker-project')
    state = load_state(directory)
    daudio_sources = daudio_test_inputs(args)
    fontconfig_sources = None
    if getattr(args, 'fontconfig_sources', None):
        if args.action != 'test' or args.suite != 'fontconfig-freetype':
            raise ValueError('--fontconfig-sources is restricted to fontconfig-freetype')
        manifest_path = Path(args.fontconfig_sources).resolve()
        font_inputs = read_json(manifest_path)
        if font_inputs.get('schemaVersion') != 1 or set(font_inputs.get('runtimes', {})) != {'17', '21', '25'}:
            raise ValueError('Expected all three FreeType before/after source pairs')
        # 预检绑定实际清单和六份只读归档；套件内还会独立检查所有源码成员摘要。
        # 路径只能是该清单同目录的普通文件，不能隐式挂入其他源树或临时目录。
        archives = []
        for major, item in font_inputs['runtimes'].items():
            for variant in ('before', 'after'):
                record = item[variant]
                name = record['file']
                path = manifest_path.parent / name
                if (not re.fullmatch(r'[A-Za-z0-9._-]+', name) or path.is_symlink()
                        or not path.is_file() or path.resolve().parent != manifest_path.parent
                        or digest(path) != record['sha256']):
                    raise ValueError('Unexpected FreeType source archive: ' + str(name))
                archives.append({'major': major, 'variant': variant, 'file': name,
                                 'sha256': record['sha256'], 'sizeBytes': path.stat().st_size})
        fontconfig_sources = {'manifest': str(manifest_path), 'sha256': digest(manifest_path),
                              'archives': archives, 'containerDirectory': '/fontconfig-sources'}
    if args.action == 'test' and args.suite == 'fontconfig-freetype' and not fontconfig_sources:
        raise ValueError('fontconfig-freetype requires explicit --fontconfig-sources')
    fontconfig_fallback_sources = None
    if getattr(args, 'fontconfig_fallback_sources', None):
        if args.action != 'test' or args.suite != 'fontconfig-fallback':
            raise ValueError('--fontconfig-fallback-sources is restricted to fontconfig-fallback')
        manifest_path = Path(args.fontconfig_fallback_sources).resolve()
        fallback_inputs = read_json(manifest_path)
        if (fallback_inputs.get('schemaVersion') not in (1, 2) or fallback_inputs.get('kind') != 'fontconfig-fallback-sources'
                or set(fallback_inputs.get('runtimes', {})) != {'8', '17', '21', '25'}):
            raise ValueError('Expected four locked Fontconfig fallback source pairs')
        # 只接受同目录具名普通文件并绑定真实 SHA；容器内再次对照仓库补丁身份。
        files = []
        for major, item in fallback_inputs['runtimes'].items():
            expected_files = {'native', 'java', 'stream'} if fallback_inputs['schemaVersion'] == 2 else {'native', 'java'}
            if set(item['files']) != expected_files:
                raise ValueError('Incomplete Fontconfig native/Java source pair')
            for language, pair in item['files'].items():
                for variant in ('before', 'after'):
                    record = pair[variant]
                    name = record['file']
                    path = manifest_path.parent / name
                    if (not re.fullmatch(r'[A-Za-z0-9._-]+', name) or path.is_symlink()
                            or not path.is_file() or path.resolve().parent != manifest_path.parent
                            or digest(path) != record['sha256'] or path.stat().st_size != record['size']):
                        raise ValueError('Unexpected Fontconfig source: ' + str(name))
                    files.append({'major': major, 'language': language, 'variant': variant,
                                  'file': name, 'sha256': record['sha256'], 'sizeBytes': record['size']})
        fontconfig_fallback_sources = {'manifest': str(manifest_path), 'sha256': digest(manifest_path),
                                      'files': files, 'containerDirectory': '/fontconfig-fallback-sources'}
    if args.action == 'test' and args.suite == 'fontconfig-fallback' and not fontconfig_fallback_sources:
        raise ValueError('fontconfig-fallback requires explicit --fontconfig-fallback-sources')
    fontconfig_default_sources = None
    if getattr(args, 'fontconfig_default_sources', None):
        if args.action != 'test' or args.suite != 'fontconfig-defaults':
            raise ValueError('--fontconfig-default-sources is restricted to fontconfig-defaults')
        manifest_path = Path(args.fontconfig_default_sources).resolve()
        default_inputs = read_json(manifest_path)
        if (default_inputs.get('schemaVersion') != 1 or default_inputs.get('kind') != 'fontconfig-default-sources'
                or set(default_inputs.get('files', {})) != {'before', 'after'}):
            raise ValueError('Expected locked Fontconfig default source pair')
        files = []
        for variant, record in default_inputs['files'].items():
            name = record['file']
            path = manifest_path.parent / name
            if (not re.fullmatch(r'[A-Za-z0-9._-]+', name) or path.is_symlink() or not path.is_file()
                    or path.resolve().parent != manifest_path.parent or digest(path) != record['sha256']
                    or path.stat().st_size != record['size']):
                raise ValueError('Unexpected Fontconfig default source: ' + str(name))
            files.append(dict(record, variant=variant))
        fontconfig_default_sources = {'manifest': str(manifest_path), 'sha256': digest(manifest_path),
                                     'files': files, 'containerDirectory': '/fontconfig-default-sources'}
    if args.action == 'test' and args.suite == 'fontconfig-defaults' and not fontconfig_default_sources:
        raise ValueError('fontconfig-defaults requires explicit --fontconfig-default-sources')
    install_archives = None
    if getattr(args, 'install_archives', None):
        if args.action != 'test' or args.suite != 'runtime-install':
            raise ValueError('--install-archives is restricted to runtime-install')
        install_archives = install_archive_inputs(args.install_archives)
    tls_negative = None
    if getattr(args, 'tls_negative_header', None):
        if args.action != 'test' or args.suite != 'tls-storage':
            raise ValueError('--tls-negative-header is restricted to tls-storage')
        header = Path(args.tls_negative_header).resolve()
        if not header.is_file():
            raise ValueError('TLS negative control header does not exist')
        # 旧算法仅作明确指定的负对照，绑定实际字节，不混入现役源码或隐式选择历史文件。
        tls_negative = {'path':str(header), 'sha256':digest(header),
                        'containerPath':'/tls-negative/reference.h'}
    tls_module_negative = None
    if getattr(args, 'tls_module_negative_header', None):
        if args.action != 'test' or args.suite != 'tls-storage':
            raise ValueError('--tls-module-negative-header is restricted to tls-storage')
        header = Path(args.tls_module_negative_header).resolve()
        if not header.is_file():
            raise ValueError('TLS module negative control header does not exist')
        tls_module_negative = {'path':str(header), 'sha256':digest(header),
                               'containerPath':'/tls-negative/module-reference.h'}
    if args.action=='status':
        print(json.dumps({'project':PROJECT,'statePath':str(directory/'state.json'),
              'workspaces':{name:{'volume':item['volume'],'inputIdentity':item['inputs']['digest'],
                  'latestRun':item.get('latestRun'),'adoptedFrom':item.get('adoptedFrom')}
                  for name,item in state['workspaces'].items()},
              'lastRun':state.get('lastRun'),'containers':docker('ps','-a','--filter','label=com.docker.compose.project='+PROJECT,
              '--format','{{.Names}} {{.Status}}')},ensure_ascii=False,indent=2)); return 0
    # 本机历史目录同样先验证，再创建任何卷/输出；显式 init 注册允许替换旧的已漂移登记。
    if getattr(args,'legacy_config',None):
        if args.action!='init': raise ValueError('--legacy-config is only accepted by init')
        legacy_services(args.legacy_config)
    else:
        include_legacy({'services':{}},state)
    image_name = args.image or state.get('imageName') or 'amcl-jdk-toolchain:runtime-audio-v2'
    qa_name = args.qa_image or state.get('qaImageName') or 'amcl-elf-link-test:runtime-audio'
    sysroot = args.sysroot or state.get('sysroot')
    component = args.component
    if args.action in ('build','adopt','init') and not sysroot: raise ValueError('Provide --sysroot on first use')
    # 先验证本地输入再连接 Docker，错误路径不能创建任何引擎对象。
    if sysroot:
        for name in SENTINELS:
            if not (Path(sysroot)/name).is_file(): raise ValueError('Missing SDK input: '+name)
    service = 'qa' if args.action=='test' else 'builder'
    # gl4es 的软件 GLES/sanitizer 镜像独立选择，不能把它登记成 JDK builder 或 ELF 默认镜像。
    if args.action=='test' and args.suite=='gl4es-draw':
        image = image_id(args.gl4es_qa_image or 'amcl-gl4es-draw-qa:1')
        if not args.gl4es_source:
            raise ValueError('gl4es-draw requires --gl4es-source pointing to a clean pinned Git checkout')
    elif args.action=='test' and args.suite=='mobilegl-replay-host':
        # 独立host软件资格复用已验qa镜像，不改JDK builder/ELF默认image身份。
        image=image_id(args.mobilegl_qa_image or 'amcl-gl4es-draw-qa:1')
        if not args.mobilegl_source or not re.fullmatch('[0-9a-f]{40}',args.mobilegl_expected_source or ''):
            raise ValueError('mobilegl-replay-host requires actual standalone source seed and independent full commit')
        if args.mobilegl_artifacts and not re.fullmatch('[0-9a-f]{64}',args.mobilegl_artifact_proof_sha or ''):
            raise ValueError('reusable mobilegl host artifacts require independent build-source.json SHA')
    elif args.action=='test' and args.suite in ('mobilegl-cpu-host','mobilegl-cpu-proof'):
        # CPU合同沿fork正式入口执行；先在宿主原生Git验证source-clean，避免容器缺少
        # Windows LFS全局配置误认实际载荷。未知host cache/proof不能替代为OHOS缓存。
        image=image_id(args.mobilegl_qa_image or 'amcl-gl4es-draw-qa:1')
        if not args.mobilegl_source or not re.fullmatch('[0-9a-f]{40}',args.mobilegl_expected_source or ''):
            raise ValueError('mobilegl-cpu-host requires independent full pinned source')
        if not args.mobilegl_host_cache:
            raise ValueError('MobileGL CPU input capture/run requires actual Linux cache')
        def source_git(*arguments):
            return subprocess.check_output(['git','-C',str(args.mobilegl_source),*arguments],text=True).strip()
        if source_git('rev-parse','HEAD')!=args.mobilegl_expected_source or source_git('status','--porcelain'):
            raise ValueError('actual MobileGL source is not the selected clean commit')
        cpu_source_tree=source_git('rev-parse','HEAD^{tree}')
        # 收取proof只读取已完成cache；执行CPU合同仍必须独立选取并核实既有proof。
        # 两者共用宿主真实Git/固定image资格，不能用容器env自称clean取代宿主检查。
        if args.suite=='mobilegl-cpu-host':
            if not args.mobilegl_host_proof or not re.fullmatch('[0-9a-f]{64}',args.mobilegl_host_proof_sha or ''):
                raise ValueError('mobilegl-cpu-host requires independent proof SHA')
            cpu_proof_path=Path(args.mobilegl_host_proof).resolve()
            if digest(cpu_proof_path)!=args.mobilegl_host_proof_sha:
                raise ValueError('independently selected host proof changed')
            cpu_proof=read_json(cpu_proof_path)
            if cpu_proof.get('sourceCommit')!=args.mobilegl_expected_source or cpu_proof.get('sourceTree')!=cpu_source_tree or cpu_proof.get('imageId')!=image or cpu_proof.get('sourceClean') is not True:
                raise ValueError('actual CPU source/tree/image proof mismatch')
        else:
            # 收取不能把reader镜像贴到旧对象上：独立选择正常producer的manifest、
            # Compose与原日志摘要，核其source/cache/image及四项真实产物快照。
            # 此处不要求已有host-proof，避免先有proof才能收取proof的循环。
            if not args.mobilegl_producer_manifest:
                raise ValueError('mobilegl-cpu-proof requires actual normal producer manifest')
            producer_path=Path(args.mobilegl_producer_manifest).resolve()
            # 先用本机原生文件系统闭合run目录；复制同字节manifest/快照到异目录
            # 不能继承原生产身份。容器后续只比较这一已核实的host路径文字。
            producer_row=read_json(producer_path)
            if Path(producer_row['output']).resolve()!=(producer_path.parent/'out').resolve():
                raise ValueError('selected producer manifest directory differs from its recorded output')
            spec=importlib.util.spec_from_file_location('amcl_cpu_capture',ROOT/'tests/mobilegl-cpu-host/capture-host-proof.py')
            collector=importlib.util.module_from_spec(spec);spec.loader.exec_module(collector)
            cpu_producer=collector.verify_producer(producer_path,args.mobilegl_producer_sha,
                args.mobilegl_producer_compose_sha,args.mobilegl_producer_log_sha,
                args.mobilegl_expected_source,cpu_source_tree,image,
                str(Path(args.mobilegl_source).resolve()),str(Path(args.mobilegl_host_cache).resolve()),str(producer_path.parent))
        if not (Path(args.mobilegl_host_cache)/'CMakeCache.txt').is_file():
            raise ValueError('actual Linux object cache missing')
    else:
        image = image_id(qa_name if args.action=='test' and args.suite in ('elf', 'jdk-abi-run', 'runtime-io', 'runtime-install', 'runtime-java', 'runtime-process', 'tls-storage', 'tls-crt-reference', 'fontconfig-freetype', 'jdk-probe-owner', 'processor-setup', 'unwind-cache') else image_name)
    check_service(service)
    facts = input_identity(component,image,sysroot) if args.action in ('build','adopt') else None
    cached = state['workspaces'].get(component)
    if args.reuse_manifest: cached=adopt_manifest(args.reuse_manifest,component,facts)
    if args.action=='adopt' and not args.reuse_manifest: raise ValueError('adopt requires --reuse-manifest')
    if cached and facts and not args.fresh and cached['inputs']['digest']!=facts['digest']:
        raise ValueError('Workspace input identity changed; use --fresh to retain old state separately')
    reuse = cached is not None and not args.fresh
    if reuse and facts: check_volume(cached['volume'])
    source = None
    if args.action=='test' and args.suite.startswith('java-sound-'):
        source = state['workspaces'].get('jdk'+args.suite.rsplit('-',1)[1])
        if not source: raise ValueError('Build/adopt matching JDK source workspace first')
        check_volume(source['volume'])
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S')+'-'+uuid.uuid4().hex[:6]
    suite_id={'mobilegl-replay-host':'mgl-replay','mobilegl-cpu-host':'mgl-cpu','mobilegl-cpu-proof':'mgl-proof','fontconfig-freetype':'font-ft','fontconfig-fallback':'font-fallback','fontconfig-defaults':'font-defaults'}.get(args.suite,args.suite) if service=='qa' else args.suite
    run_id = 'docker-'+(suite_id if service=='qa' else component)+'-'+stamp
    out_root = workspace_path('build',run_id)
    work = cached if reuse else {'volume':'amcl-work-'+component+'-'+uuid.uuid4().hex[:8],
              'buildId':run_id,'inputs':facts,'createdAt':now()}
    plan = {'schemaVersion':2,'project':PROJECT,'service':service,'runId':run_id,'createdAt':now(),
            'projectRoot':str(ROOT),'state':'planned','imageId':image,'component':component,
            'output':str(out_root/'out'),'workVolume':work['volume'] if facts else None,
            'workspaceMode':('reuse' if reuse else 'fresh') if facts else ('read-only-source' if source else 'isolated-test'),
            'inputs':facts,'suite':args.suite if service=='qa' else None}
    if install_archives:
        plan['installArchives'] = install_archives
        plan['scratch'] = {'type':'tmpfs', 'path':'/dev/shm', 'limitBytes':2 * 1024**3,
                           'evidence':'per-file SHA256/mode and logs persisted to external output; source ZIP unchanged'}
    if tls_negative:
        plan['tlsNegativeControl'] = tls_negative
    if tls_module_negative:
        plan['tlsModuleNegativeControl'] = tls_module_negative
    if fontconfig_sources:
        plan['fontconfigSources'] = fontconfig_sources
    if fontconfig_fallback_sources:
        plan['fontconfigFallbackSources'] = fontconfig_fallback_sources
    if fontconfig_default_sources:
        plan['fontconfigDefaultSources'] = fontconfig_default_sources
    if daudio_sources:
        plan['javaSoundDaudioSources'] = daudio_sources
    if args.plan_only: print(json.dumps(plan,ensure_ascii=False,indent=2)); return 0
    if source:
        # Java Sound QA真实读取已登记源码卷；缓存身份只是输入声明，实际编译文件
        # 由套件的sound-provenance.json另记摘要，不把旧发行包来源提升为已知。
        plan['sourceWorkspace'] = {'component': 'jdk'+args.suite.rsplit('-',1)[1],
            'volume': source['volume'], 'buildId': source.get('buildId'),
            'inputsDigest': (source.get('inputs') or {}).get('digest')}
    with project_lock(directory):
        # 持锁后重读，防止排队期间另一次请求已经换过状态；活动 Compose 再检查一次。
        latest = load_state(directory)
        if latest!=state: raise RuntimeError('Project state changed during preflight; retry')
        check_service(service)
        if daudio_sources and daudio_test_inputs(args) != daudio_sources:
            raise ValueError('DAUDIO inputs changed while waiting for the fixed QA lock')
        if service=='qa' and args.suite=='mobilegl-cpu-proof':
            # 等待固定QA锁期间不能借旧source-clean声明收取新缓存；再次原生Git核源。
            # 与现有合同一样，调用者还须冻结host cache写者；只读bind不代替宿主写者协调。
            if source_git('rev-parse','HEAD')!=args.mobilegl_expected_source or source_git('rev-parse','HEAD^{tree}')!=cpu_source_tree or source_git('status','--porcelain'):
                raise ValueError('actual MobileGL capture source changed while waiting for QA lock')
            # 排队结束再次读取同一个producer，避免manifest/Compose/log在锁外替换。
            if collector.verify_producer(producer_path,args.mobilegl_producer_sha,
                args.mobilegl_producer_compose_sha,args.mobilegl_producer_log_sha,
                args.mobilegl_expected_source,cpu_source_tree,image,
                str(Path(args.mobilegl_source).resolve()),str(Path(args.mobilegl_host_cache).resolve()),str(producer_path.parent))!=cpu_producer:
                raise ValueError('actual MobileGL producer changed while waiting for QA lock')
        state.update(imageName=image_name,qaImageName=qa_name)
        if sysroot: state['sysroot']=str(Path(sysroot).resolve())
        if getattr(args,'legacy_config',None):
            if args.action!='init': raise ValueError('--legacy-config is only accepted by init')
            legacy_services(args.legacy_config)
            state.update(legacyConfig=str(Path(args.legacy_config).resolve()),legacyConfigSha256=digest(args.legacy_config))
        if args.action=='adopt':
            state['workspaces'][component]=work
            write_json(directory/'state.json',state)
            print('Adopted verified workspace '+component+': '+work['volume']); return 0
        if args.action=='init':
            check_service('qa')
            model=service_model('builder',image)
            model['services'].update(service_model('qa',image_id(qa_name))['services'])
            config=directory/'idle.compose.json'; write_json(config,include_legacy(model,state))
            docker(*compose_args(config),'config','--quiet')
            docker(*compose_args(config),'create','--no-build','builder','qa')
            write_json(directory/'state.json',state)
            print('Prepared amcl/builder and amcl/qa; containers are stopped'); return 0
        out_root.mkdir(parents=True,exist_ok=False); (out_root/'out').mkdir()
        if facts:
            if not reuse:
                if docker('volume','ls','--filter','name=^'+work['volume']+'$','--format','{{.Name}}'):
                    raise RuntimeError('New work volume already exists')
                docker('volume','create','--label','amcl.project=amcl','--label','amcl.component='+component,work['volume'])
            check_volume(work['volume'])
            state['workspaces'][component]=work
            recipe_root, prebuilt_root, sdk_root = ROOT/'docker', ROOT/'prebuilt', Path(sysroot)
            native_mount = None
            if component.startswith('jdk') or component == 'fontconfig':
                from jdk_native_inputs import freeze_files
                frozen = out_root/'inputs'
                freeze_files(ROOT, facts['files'], frozen/'project')
                freeze_files(facts['nativeSdk']['root'], facts['nativeSdk']['files'], frozen/'native')
                recipe_root, prebuilt_root = frozen/'project/docker', frozen/'project/prebuilt'
                sdk_root, native_mount = frozen/'native/sysroot', frozen/'native'
                write_json(out_root/'out/build-inputs.json', facts)
                plan['frozenInputs'] = str(frozen)
            mounts=[bind(recipe_root,'/recipes'),bind(prebuilt_root,'/prebuilt'),
                    bind(sdk_root,'/ohos-sysroot'),bind(out_root/'out','/output',False),
                    {'type':'volume','source':'work','target':'/build','volume':{'nocopy':True}}]
            command=['/recipes/project-build-entry.sh','reuse' if reuse else 'fresh',RECIPES[component],*args.recipe_arg]
            env={'AMCL_BUILDER_MANAGED':'1','AMCL_BUILD_ID':work['buildId'],'AMCL_RUN_ID':run_id,
                 'AMCL_SYSROOT_BASE':'/ohos-sysroot','JOBS':str(args.jobs)}
            if getattr(args, 'upstream_test_image', False):
                if component not in ('jdk17', 'jdk21', 'jdk25'):
                    raise ValueError('upstream-test-image requires a modern JDK build; JDK8 uses its own upstream suites')
                env['AMCL_JDK_TEST_IMAGE'] = '1'
            if native_mount:
                mounts.append(bind(native_mount, '/ohos-native'))
                env.update(AMCL_JDK_NATIVE_ROOT='/ohos-native',
                           AMCL_TARGET_INPUTS_DIGEST=facts['digest'],
                           AMCL_TARGET_RESOURCE_VERSION=facts['nativeSdk']['resourceVersion'])
            model=service_model(service,image,command,mounts,env)
            model['volumes']={'work':{'external':True,'name':work['volume']}}
        else:
            mounts=[bind(ROOT,'/workspace'),bind(out_root/'out','/output',False)]
            # 源码种子只读挂载；测试在独占 /output 中展开、应用受控补丁并编译完整生产库。
            if args.suite=='gl4es-draw':
                mounts.append(bind(args.gl4es_source,'/gl4es-source'))
            qa_env={'AMCL_RUN_ID':run_id}
            if daudio_sources:
                # 只挂已核完整闭包，不把 arbitrary 路径或命令透传给通用 QA 入口。
                mounts.append(bind(daudio_sources['root'], '/daudio-inputs'))
                qa_env['AMCL_DAUDIO_INPUT_SHA'] = daudio_sources['manifestSha256']
            if fontconfig_sources:
                manifest_path = Path(fontconfig_sources['manifest'])
                mounts.append(bind(manifest_path.parent, '/fontconfig-sources'))
                qa_env['AMCL_FONTCONFIG_SOURCES_MANIFEST'] = '/fontconfig-sources/' + manifest_path.name
            if fontconfig_fallback_sources:
                manifest_path = Path(fontconfig_fallback_sources['manifest'])
                mounts.append(bind(manifest_path.parent, '/fontconfig-fallback-sources'))
                qa_env['AMCL_FONTCONFIG_FALLBACK_SOURCES_MANIFEST'] = '/fontconfig-fallback-sources/' + manifest_path.name
            if fontconfig_default_sources:
                manifest_path = Path(fontconfig_default_sources['manifest'])
                mounts.append(bind(manifest_path.parent, '/fontconfig-default-sources'))
                qa_env['AMCL_FONTCONFIG_DEFAULT_SOURCES_MANIFEST'] = '/fontconfig-default-sources/' + manifest_path.name
            if tls_negative:
                mounts.append({'type':'bind', 'source':Path(tls_negative['path']).as_posix(),
                               'target':tls_negative['containerPath'], 'read_only':True,
                               'bind':{'create_host_path':False}})
                qa_env['TLS_STORAGE_NEGATIVE_HEADER'] = tls_negative['containerPath']
            if tls_module_negative:
                mounts.append({'type':'bind', 'source':Path(tls_module_negative['path']).as_posix(),
                               'target':tls_module_negative['containerPath'], 'read_only':True,
                               'bind':{'create_host_path':False}})
                qa_env['TLS_STORAGE_MODULE_NEGATIVE_HEADER'] = tls_module_negative['containerPath']
            if install_archives:
                # 不扩大通用bind目录契约；此专用分支只挂载已验证的四个普通文件。
                for record in install_archives:
                    mounts.append({'type':'bind','source':Path(record['archive']).as_posix(),
                                   'target':record['containerPath'],'read_only':True,
                                   'bind':{'create_host_path':False}})
                write_json(out_root/'out/install-archives.json', {'schemaVersion':1, 'archives':install_archives})
                (out_root/'out/install-archives.tsv').write_text(''.join(
                    f"{r['major']}\t{r['containerPath']}\t{r['sha256']}\t{r['sizeBytes']}\n" for r in install_archives),encoding='utf-8')
                qa_env['AMCL_INSTALL_ARCHIVES'] = '/output/install-archives.tsv'
            if args.suite in ('unwind-cache', 'application-abi'):
                plan['unwindInputs'] = freeze_unwind_source(args.unwind_source, out_root/'unwind-input')
                mounts.append(bind(out_root/'unwind-input', '/unwind-input'))
            if args.suite in ('elf', 'jdk-abi-run') and getattr(args, 'elf_fixtures', None):
                # 只读实际候选 ELF，驱动仅做映射/解析/权限验证，不运行这些库的代码。
                mounts.append(bind(args.elf_fixtures, '/elf-fixtures'))
                qa_env['AMCL_ELF_FIXTURES'] = '/elf-fixtures'
            if args.suite=='jdk-abi-run':
                # 显式使用先前真实编译产物和设备只读运行库。该套件只授予
                # AArch64/QEMU 行为证据，不代表设备沙箱或自定义 loader 通过。
                if not args.abi_artifacts or not args.abi_libc:
                    raise ValueError('jdk-abi-run requires --abi-artifacts and --abi-libc')
                libc = Path(args.abi_libc).resolve()
                if not libc.is_file():
                    raise ValueError('Actual device libc is missing')
                mounts.extend((bind(args.abi_artifacts, '/abi'), bind(libc.parent, '/device-libc')))
                qa_env['AMCL_ABI_LIBC_FILE'] = libc.name
            if args.suite in ('jdk-abi', 'application-abi'):
                # 编译资格只读取本次冻结的完整目标 SDK。执行资格由实际运行环境
                # 另行出具，不能把此编译套件的退出 0 写成设备 ABI 已通过。
                if not sysroot:
                    raise ValueError('jdk-abi requires --sysroot from selected native SDK')
                sys.path.insert(0, str(ROOT/'docker/scripts'))
                from jdk_native_inputs import native_inputs, freeze_files
                native_facts = native_inputs(sysroot)
                if args.suite == 'application-abi':
                    # SDK 的合并静态归档已含 libc++abi；只加入此配方真实消费的额外输入，
                    # 不把该输入强加给此前四份 JDK 配方，避免虚假联动其重建身份。
                    archive = read_json(ROOT/'prebuilt/abi/source.json')['sdkArchive']
                    native_facts['files'][archive] = digest(Path(native_facts['root'])/archive)
                freeze_files(native_facts['root'], native_facts['files'], out_root/'native-input')
                write_json(out_root/'out/native-inputs.json', native_facts)
                mounts.append(bind(out_root/'native-input', '/ohos-native'))
                qa_env['AMCL_TARGET_RESOURCE_VERSION'] = native_facts['resourceVersion']
            if args.suite=='mobilegl-replay-host':
                mounts.append(bind(args.mobilegl_source,'/mobilegl-source'))
                qa_env['AMCL_MOBILEGL_SOURCE_COMMIT']=args.mobilegl_expected_source
                if args.mobilegl_artifacts:
                    mounts.append(bind(args.mobilegl_artifacts,'/mobilegl-artifacts'))
                    qa_env['AMCL_MOBILEGL_ARTIFACT_PROOF_SHA']=args.mobilegl_artifact_proof_sha
                if args.mobilegl_icd:mounts.append(bind(args.mobilegl_icd,'/mobilegl-icd'))
            if args.suite in ('mobilegl-cpu-host','mobilegl-cpu-proof'):
                # 与实际cache记录的容器绝对路径一致，只读对象；fork工具只在/output
                # 编译合同/控制，不改source或cache，不调用CTS/replay或准入写入。
                mounts.append(bind(args.mobilegl_source,'/mobilegl-source'))
                mounts.append(bind(args.mobilegl_host_cache,'/native-cache'))
                qa_env.update(AMCL_MOBILEGL_SOURCE_COMMIT=args.mobilegl_expected_source,
                    AMCL_MOBILEGL_SOURCE_TREE=cpu_source_tree,AMCL_MOBILEGL_SOURCE_CLEAN='1',
                    AMCL_MOBILEGL_HOST_IMAGE=image)
                if args.suite=='mobilegl-cpu-host':
                    mounts.append(bind(cpu_proof_path.parent,'/mobilegl-host-proof'))
                    qa_env.update(AMCL_MOBILEGL_HOST_PROOF_SHA=args.mobilegl_host_proof_sha,
                        AMCL_MOBILEGL_HOST_PROOF_FILE=cpu_proof_path.name)
                else:
                    mounts.append(bind(producer_path.parent,'/mobilegl-producer'))
                    qa_env.update(AMCL_MOBILEGL_PRODUCER_FILE=producer_path.name,
                        AMCL_MOBILEGL_PRODUCER_SHA=args.mobilegl_producer_sha,
                        AMCL_MOBILEGL_PRODUCER_COMPOSE_SHA=args.mobilegl_producer_compose_sha,
                        AMCL_MOBILEGL_PRODUCER_LOG_SHA=args.mobilegl_producer_log_sha,
                        AMCL_MOBILEGL_HOST_SOURCE=str(Path(args.mobilegl_source).resolve()),
                        AMCL_MOBILEGL_HOST_CACHE=str(Path(args.mobilegl_host_cache).resolve()),
                        AMCL_MOBILEGL_HOST_PRODUCER_DIR=str(producer_path.parent))
            if source:
                qa_env.update(AMCL_QA_SOURCE_VOLUME=source['volume'],
                    AMCL_QA_SOURCE_INPUTS_DIGEST=(source.get('inputs') or {}).get('digest') or 'unknown')
            model=service_model(service,image,['/workspace/docker/project-test-entry.sh',args.suite,*args.test_arg],mounts,qa_env)
            if install_archives:
                # 只有显式四包完整安装测试使用2GiB内存POSIX树；不改其他服务/套件默认资源。
                model['services'][service]['shm_size'] = '2gb'
            if source:
                mounts.append({'type':'volume','source':'source','target':'/source','read_only':True,'volume':{'nocopy':True}})
                model['volumes']={'source':{'external':True,'name':source['volume']}}
        config=out_root/'compose.json'; write_json(config,include_legacy(model,state))
        plan.update(composeFile=str(config),workspaceBuildId=work['buildId'] if facts else None,
                    startedAt=now(),state='running',log=str(out_root/'build.log'))
        write_json(out_root/'build-manifest.json',plan)
        write_json(directory/'state.json',state)
        try:
            docker(*compose_args(config),'config','--quiet')
            code=stream_compose(config,service,out_root/'build.log')
            if service=='qa' and args.suite=='mobilegl-replay-host':
                # software image仅运行native/Python，宿主Node对实际bundle执行同一纯证据门。
                # native失败或身份/完整性任一失败都不可变成总PASS，正式流程不装临时runtime。
                mode='positive'
                if '--mode' in args.test_arg:mode=args.test_arg[args.test_arg.index('--mode')+1]
                backends=['DirectGLES','DirectVulkan']
                if '--backends' in args.test_arg:
                    index=args.test_arg.index('--backends')+1;backends=[]
                    while index<len(args.test_arg) and not args.test_arg[index].startswith('--'):
                        backends.append(args.test_arg[index]);index+=1
                required=['DirectGLES/'+control for control in ['no-golden','wrong-golden','wrong-provider']] if mode=='controls' else [backend+'/none' for backend in backends]
                bundle=out_root/'out/mobilegl-replay'
                host_artifacts=Path(args.mobilegl_artifacts) if args.mobilegl_artifacts else bundle/'artifacts'
                host_source=Path(args.mobilegl_source) if args.mobilegl_artifacts else bundle/'source'
                verify_args=['node',str(ROOT/'scripts/check-mobilegl-replay-evidence.mjs'),'--bundle',str(bundle),'--required-runs',json.dumps(required),'--host-artifacts',str(host_artifacts),'--host-source',str(host_source),'--expected-source',args.mobilegl_expected_source]
                proof_sha=args.mobilegl_artifact_proof_sha if args.mobilegl_artifacts else hashlib.sha256((host_artifacts/'build-source.json').read_bytes()).hexdigest()
                verify_args+=['--host-proof-sha',proof_sha]
                if args.mobilegl_icd:verify_args+=['--host-icd',str(Path(args.mobilegl_icd)/'libvulkan_lvp.so')]
                verified=subprocess.run(verify_args,check=False)
                if verified.returncode:code=verified.returncode
            plan.update(exitCode=code,state='completed' if code==0 else 'failed')
            if facts: work['latestRun']=str(out_root/'build-manifest.json')
            print(f'AMCL {service}: exit={code}; manifest={out_root / "build-manifest.json"}',flush=True)
            return code
        except BaseException as error:
            plan.update(state='interrupted' if isinstance(error,KeyboardInterrupt) else 'failed',error=str(error))
            raise
        finally:
            plan['finishedAt']=now()
            write_json(out_root/'build-manifest.json',plan)
            state['lastRun']=str(out_root/'build-manifest.json')
            write_json(directory/'state.json',state)

def main():
    """所有变更经单一入口；旧 PowerShell 命令只负责参数兼容，不再直接 docker run。"""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=('status','init','build','adopt','test'))
    parser.add_argument('--state-dir')
    parser.add_argument('--image')
    parser.add_argument('--qa-image')
    parser.add_argument('--legacy-config',help='init only: explicitly register the local read-only legacy catalog')
    parser.add_argument('--sysroot')
    parser.add_argument('--component',choices=RECIPES,default='smoke')
    parser.add_argument('--upstream-test-image', action='store_true',
                        help='build original OpenJDK native/gtest test-image with the same frozen modern JDK inputs')
    parser.add_argument('--suite',choices=('elf','jdk-abi','jdk-abi-run','runtime-io','runtime-install','runtime-java','runtime-process','runtime-childproc','runtime-midi','tls-storage','tls-crt-reference','fontconfig-freetype','fontconfig-fallback','fontconfig-defaults','jdk-probe-owner','jni-invocation','processor-setup','unwind-cache','application-abi','java-sound-8','java-sound-17','java-sound-21','java-sound-25','java-ports','sound-links','gl4es-draw','mobilegl-replay-host','mobilegl-cpu-host','mobilegl-cpu-proof'),default='elf')
    parser.add_argument('--unwind-source',help='unwind qualification: fixed vendor Git source; exact commit exported read-only')
    parser.add_argument('--abi-artifacts',help='jdk-abi-run: target harness build output directory')
    parser.add_argument('--elf-fixtures',help='elf: exact candidate native files with list.txt, read-only')
    parser.add_argument('--install-archives',help='runtime-install only: explicit schema-v1 manifest of four immutable ZIPs with independent SHA256/size')
    parser.add_argument('--fontconfig-sources',help='fontconfig-freetype only: complete-series source manifest and six immutable before/after archives')
    parser.add_argument('--fontconfig-fallback-sources',help='fontconfig-fallback only: four locked native/Java before/after source pairs')
    parser.add_argument('--fontconfig-default-sources',help='fontconfig-defaults only: locked Fontconfig fccfg.c before/after source pair')
    parser.add_argument('--java-sound-daudio-sources',help='java-sound-17 only: fixed DAUDIO JNI source/patch/SDK manifest.json')
    parser.add_argument('--java-sound-daudio-sha',help='independent SHA256 of the selected DAUDIO input manifest')
    parser.add_argument('--tls-negative-header',help='tls-storage only: read-only historical header for the exact recovery-race negative control')
    parser.add_argument('--tls-module-negative-header',help='tls-storage only: read-only historical header for the exact module-retention negative control')
    parser.add_argument('--abi-libc',help='jdk-abi-run: actual device ld-musl/libc file, read-only')
    parser.add_argument('--mobilegl-source',help='MobileGL host suites: actual hydrated standalone pinned Git seed, read-only')
    parser.add_argument('--mobilegl-expected-source',help='independent full source commit required by host qualification')
    parser.add_argument('--mobilegl-qa-image',help='host software graphics image; does not alter default builder/ELF image')
    parser.add_argument('--mobilegl-artifacts',help='explicit verified reusable host artifacts with build-source.json')
    parser.add_argument('--mobilegl-artifact-proof-sha',help='independent host SHA of selected reusable build-source.json')
    parser.add_argument('--mobilegl-icd',help='explicit software ICD input directory with driver/source receipt')
    parser.add_argument('--mobilegl-host-cache',help='mobilegl-cpu-host only: actual source-bound Linux Ninja object cache, read-only')
    parser.add_argument('--mobilegl-host-proof',help='mobilegl-cpu-host only: independently selected actual host-cache-proof.json')
    parser.add_argument('--mobilegl-host-proof-sha',help='independent host SHA of the selected Linux cache proof')
    parser.add_argument('--mobilegl-producer-manifest',help='mobilegl-cpu-proof only: actual completed normal host build manifest')
    parser.add_argument('--mobilegl-producer-sha',help='independent SHA256 of selected normal producer manifest')
    parser.add_argument('--mobilegl-producer-compose-sha',help='independent SHA256 of same producer Compose')
    parser.add_argument('--mobilegl-producer-log-sha',help='independent SHA256 of same producer build log')
    parser.add_argument('--gl4es-source',help='gl4es-draw only: clean pinned source seed, mounted read-only')
    parser.add_argument('--gl4es-qa-image',help='gl4es-draw only: software GLES/sanitizer image')
    parser.add_argument('--test-arg',action='append',default=[],help='explicit test-suite argument, passed without shell expansion')
    parser.add_argument('--jobs',type=int,choices=range(1,65),default=8)
    parser.add_argument('--fresh',action='store_true')
    parser.add_argument('--plan-only',action='store_true')
    parser.add_argument('--reuse-manifest')
    parser.add_argument('--recipe-arg',action='append',default=[])
    args=parser.parse_args()
    try: return run(args)
    except (ValueError,RuntimeError,OSError) as error:
        print('AMCL Docker: '+str(error),file=sys.stderr); return 1

if __name__=='__main__': sys.exit(main())
