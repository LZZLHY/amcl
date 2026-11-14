"""直接执行正式libjli脚本的只读门禁/目录解析；现有真实AArch64库为正控，SDK小库为反控。

只在显式仓外新目录写入夹具和日志，不调用Docker、不链接整份JDK、不执行目标AArch64代码。
"""
from pathlib import Path
import argparse, datetime, hashlib, json, subprocess

repo=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser()
parser.add_argument('--library',required=True,type=Path)
parser.add_argument('--clang',required=True,type=Path)
parser.add_argument('--output',required=True,type=Path)
parser.add_argument('--wsl',default='Ubuntu')
args=parser.parse_args()
output=args.output.resolve()
assert args.output.is_absolute() and repo not in output.parents and output!=repo
output.mkdir(parents=True,exist_ok=False)
script=repo/'docker/scripts/rebuild_libjli.sh'
retired=repo/'docker/scripts/incremental_rebuild.sh'
receipt=dict(startedAt=datetime.datetime.now().astimezone().isoformat(),state='running',
    inputs={str(path):hashlib.sha256(path.read_bytes()).hexdigest() for path in (script,retired,args.library)},commands=[])


def linux(path):
    path=path.resolve();assert len(path.drive)==2 and path.drive[1]==':'
    return '/mnt/'+path.drive[0].lower()+path.as_posix()[2:]


def run(command,name,expected=0):
    """保留原始双流并要求准确退出状态；WSL诊断编码与工具输出不混拼。"""
    process=subprocess.run(list(map(str,command)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=45)
    (output/(name+'.stdout.log')).write_bytes(process.stdout)
    (output/(name+'.stderr.bin')).write_bytes(process.stderr)
    receipt['commands'].append(dict(name=name,command=list(map(str,command)),exitCode=process.returncode,expected=expected))
    (output/'receipt.json').write_text(json.dumps(receipt,indent=2),encoding='utf-8')
    assert process.returncode==expected,(name,process.returncode,process.stdout,process.stderr)
    print('PASS',name,'exit='+str(process.returncode),flush=True)
    return process


prefix=['wsl.exe','-d',args.wsl,'--exec']
try:
    for name,path in [('rebuild',script),('retired',retired)]:run(prefix+['bash','-n',linux(path)],'syntax-'+name)
    run(prefix+['env','READELF=readelf','bash',linux(script),'--verify-only',linux(args.library)],'actual-libjli')
    exports='__attribute__((visibility("default"))) '
    cases={
      'good':(exports+'int JLI_Launch(void){return 1;}\n'+exports+'int JLI_ManifestIterate(void){return 2;}\n',0),
      'missing-launch':(exports+'int JLI_ManifestIterate(void){return 2;}\n',1),
      'missing-manifest':(exports+'int JLI_Launch(void){return 1;}\n',1),
      'hidden-even-with-map':('int JLI_Launch(void){return 1;}\nint JLI_ManifestIterate(void){return 2;}\n',1),
      'undefined-manifest':('extern int JLI_ManifestIterate(void);\n'+exports+'int JLI_Launch(void){return JLI_ManifestIterate();}\n',1),
      'lookalike-launch':(exports+'int JLI_Launch_extra(void){return 1;}\n'+exports+'int JLI_ManifestIterate(void){return 2;}\n',1),
      'object-not-function':(exports+'int JLI_Launch=1;\n'+exports+'int JLI_ManifestIterate(void){return 2;}\n',1),
    }
    version=output/'exports.map';version.write_text('{ global: JLI_*; local: *; };\n')
    for name,(body,expected) in cases.items():
        source=output/(name+'.c');source.write_text(body)
        library=output/(name+'.so')
        run([args.clang,'--target=aarch64-linux-ohos','-fuse-ld=lld','-shared','-nostdlib','-fPIC',
             '-fvisibility=hidden','-Wl,--version-script='+str(version),source,'-o',library],'compile-'+name)
        run(prefix+['env','READELF=readelf','bash',linux(script),'--verify-only',linux(library)],'verify-'+name,expected)
    # 非AArch64格式即使拥有同名导出也不能过目标库门禁。
    wrong=output/'wrong-architecture.so'
    run([args.clang,'--target=x86_64-linux-gnu','-fuse-ld=lld','-shared','-nostdlib','-fPIC',output/'good.c','-o',wrong],'compile-wrong-architecture')
    run(prefix+['env','READELF=readelf','bash',linux(script),'--verify-only',linux(wrong)],'verify-wrong-architecture',1)
    run(prefix+['env','READELF=/bin/false','bash',linux(script),'--verify-only',linux(args.library)],'reader-failure',1)

    # 与正式脚本共用函数；在另一配置存在时默认只选固定AArch64树，显式错路径绝不回落。
    source=output/'source'; fixed=source/'build/linux-aarch64-server-release'
    for item in ('support/native/java.base/libjli','support/modules_libs/java.base','images/jdk/lib'):
        (fixed/item).mkdir(parents=True,exist_ok=True)
    (fixed/'spec.gmk').write_text('test fixture only\n')
    other=source/'build/linux-x86_64-server-release';other.mkdir()
    shell=['bash','-c','source "$1"; shift; resolve_libjli_build_dir "$@"','libjli-test',linux(script)]
    result=run(prefix+shell+[linux(source)],'default-exact-directory')
    assert result.stdout.decode().strip()==linux(fixed)
    run(prefix+shell+[linux(source),linux(fixed)],'explicit-exact-directory')
    run(prefix+shell+[linux(source),linux(other)],'explicit-other-directory',1)
    run(prefix+shell+[linux(source),linux(source/'does-not-exist')],'explicit-missing-directory',1)
    run(prefix+shell+[linux(source),'relative'],'explicit-relative-directory',1)
    (fixed/'spec.gmk').unlink()
    run(prefix+shell+[linux(source)],'incomplete-directory',1)
    run(prefix+['bash',linux(script),''],'explicit-empty-directory',2)
    run(prefix+['env','JDK_VERSION=8','bash',linux(script)],'unsupported-major',2)
    result=run(prefix+['bash',linux(retired)],'retired-no-side-effects',2)
    assert b'is retired' in result.stderr and b'python docker/project.py build --component jdk17' in result.stderr
    receipt['state']='pass'
finally:
    if receipt['state']=='running':receipt['state']='failed'
    receipt['finishedAt']=datetime.datetime.now().astimezone().isoformat()
    (output/'receipt.json').write_text(json.dumps(receipt,indent=2),encoding='utf-8')
