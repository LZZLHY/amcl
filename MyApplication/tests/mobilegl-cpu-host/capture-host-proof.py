"""只读收取实际Linux host cache输入证明，不编译、不执行CPU合同、不授予语义资格。

源码commit/tree/clean来自现有project.py宿主原生Git实查；producer image来自独立选取
的正常host构建manifest和其实际四项产物快照，本次reader image不能重贴旧对象来源。
容器不借缺失Windows LFS过滤配置判dirty。公共CI可直接提供正常Git环境，但须通过
同一受控宿主入口发布身份。只有已完成正确cache才能捕获，不能用缺对象构造PASS。
"""
from pathlib import Path
from datetime import datetime,timezone
import argparse,hashlib,json,os,re,shlex,struct,subprocess

def require(value,message):
    """显式检查保持Python-O语义；任何缺失/身份不一致不写出可消费proof。"""
    if not value:raise ValueError(message)

def sha(path):
    """读取真实文件SHA；缺失/IO错误上抛，不能生成部分可消费proof。"""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def direct_inputs(commands,cache):
    """同fork runner读取真实最后链接argv，仅shlex解析，不shell执行，不漏.o/.a。"""
    lines=commands.splitlines();require(lines,'Ninja command list empty');inputs=set()
    for token in shlex.split(lines[-1]):
        # 本轮实际GNU/Ninja把全部直链输入展开在argv；遇response file不能截取部分集合。
        require(not token.startswith('@'),'response-file link inputs require an explicit supported reader')
        if token.endswith(('.o','.a')):
            path=Path(token);path=(path if path.is_absolute() else cache/path).resolve()
            require(path.is_relative_to(cache),'actual link input escapes selected cache')
            inputs.add(path.relative_to(cache).as_posix())
    require(inputs,'actual full direct link inputs missing')
    return sorted(inputs)

def host_path(value):
    """比较已由宿主resolve核实的跨namespace路径文字；不在Linux伪解析Windows物理路径。"""
    require(isinstance(value,str) and value,'explicit host path missing')
    normalized=value.replace('\\','/').rstrip('/')
    return normalized.casefold() if re.match(r'^[A-Za-z]:/',normalized) else normalized

def verify_producer(manifest,expected_sha,compose_sha,log_sha,expected_source,expected_tree,image,host_source,host_cache,host_producer_dir):
    """核普通生产收据与真实复制产物；不循环要求已有host-proof，不把reader当producer。

    原9952正常构建收据未单列tree；宿主按该完整commit读取Git tree对象并独立传入。
    如收据本身有tree还须一致。此推导来源显式记录，不能补写历史manifest字段。
    """
    require(re.fullmatch('[0-9a-f]{64}',expected_sha) and sha(manifest)==expected_sha,'independently selected producer manifest differs')
    row=json.loads(manifest.read_text())
    require(row.get('state')=='completed' and type(row.get('exitCode')) is int and row['exitCode']==0,'producer did not normally complete')
    start=datetime.fromisoformat(row['startedAt']);end=datetime.fromisoformat(row['finishedAt'])
    require(start.tzinfo is not None and end.tzinfo is not None and end>start,'producer actual timing incomplete')
    require(row.get('sourceCommit')==expected_source,'producer source commit differs')
    require(row.get('sourceDirty') is False or ('sourceDirty' not in row and row.get('sourceClean') is True),'producer source was not clean')
    require(row.get('sourceTree',expected_tree)==expected_tree,'producer source tree differs')
    require(host_path(row.get('sourceRoot'))==host_path(host_source) and host_path(row.get('nativeCache'))==host_path(host_cache),'producer source/cache host binding differs')
    producer_image=row.get('imageId');require(re.fullmatch('sha256:[0-9a-f]{64}',producer_image or ''),'immutable producer image missing')
    require(producer_image==image,'reader image differs from actual cache producer image; relabel forbidden')
    # 生产manifest本身没有产物摘要；使用同次独立选取的Compose和原日志闭合实际
    # mount/output/编译器边界，快照只从该生产run目录读取，禁止任意四个文件冒充。
    compose_path=manifest.parent/'compose.json';log_path=manifest.parent/'build.log'
    require(re.fullmatch('[0-9a-f]{64}',compose_sha) and sha(compose_path)==compose_sha,'independently selected producer Compose differs')
    require(re.fullmatch('[0-9a-f]{64}',log_sha) and sha(log_path)==log_sha,'independently selected producer build log differs')
    service=json.loads(compose_path.read_text())['services']['qa']
    require(service.get('image')==producer_image,'producer Compose image differs from manifest')
    mounts={item.get('target'):item for item in service.get('volumes',[]) if item.get('type')=='bind'}
    for target,host in [('/mobilegl-source',host_source),('/native-cache',host_cache),('/receipt-output',row.get('output'))]:
        require(target in mounts and host_path(mounts[target].get('source'))==host_path(host),'producer Compose host binding differs: '+target)
    # 宿主已用原生Path.resolve核实际manifest目录；容器只比较明确发布的host文字，
    # 不能在Linux伪resolve D盘。异目录复制原字节收据/快照不属于原生产run。
    require(host_path(row.get('output'))==host_path(host_producer_dir.rstrip('/\\')+'/out'),'producer receipt/output host directory differs')
    artifacts=manifest.parent/'out/artifacts'
    # 普通构建配方真实复制四项产物；proof-only阶段没有这些快照，不能冒充生产构建。
    files={name:{'sha256':sha(artifacts/filename),'bytes':(artifacts/filename).stat().st_size}
           for name,filename in [('CMakeCache.txt','CMakeCache.txt'),('build.ninja','build.ninja'),
                                ('generated/MGGitHash.h','MGGitHash.h'),('libMobileGL.so','libMobileGL.so')]}
    # 原受控配方先打印c++ --version；只解析独立SHA绑定的原生产日志，绝不把
    # 本次reader的c++版本写成producer。完整日志身份仍保留，便于审查增量构建事实。
    output_lines=[re.sub(r'^[^|]*\| ?', '',line) for line in log_path.read_text().splitlines()]
    versions=[line for line in output_lines if re.match(r'^c\+\+ \(.+\) [0-9]',line)]
    require(len(versions)==1,'producer log does not identify unique CXX version')
    compiler=re.search(r'^CMAKE_CXX_COMPILER:[^=]+=([^\n]+)$',(artifacts/'CMakeCache.txt').read_text(),re.MULTILINE)
    require(compiler,'producer CMake compiler binding missing')
    return {'manifestSha256':expected_sha,'runId':row.get('runId'),'imageId':producer_image,
            'manifestDirectoryHost':host_producer_dir,
            'composeSha256':compose_sha,'buildLogSha256':log_sha,
            'compiler':{'cmakePath':compiler[1],'versionLine':versions[0],
                        'boundary':'original normal producer c++ --version log and producer CMake snapshot; reused objects retain incremental-cache boundary'},
            'sourceCommit':expected_source,'sourceTree':expected_tree,
            'recordedSourceTree':row.get('sourceTree'),
            'treeEvidence':'recorded producer tree' if 'sourceTree' in row else 'host native Git immutable full-commit tree lookup',
            'startedAt':row['startedAt'],'finishedAt':row['finishedAt'],'artifactSnapshots':files}

def capture(source,cache,expected_source,expected_tree,image,producer_manifest,producer_sha,compose_sha,log_sha,host_source,host_cache,host_producer_dir):
    """核实际CMake/Ninja/GIT头/AMD64库与全部直链输入，返回schema1来源而非正确性PASS。"""
    require(re.fullmatch('[0-9a-f]{40}',expected_source) and re.fullmatch('[0-9a-f]{40}',expected_tree),'full source/tree identities required')
    require(os.environ.get('AMCL_MOBILEGL_SOURCE_COMMIT')==expected_source and
            os.environ.get('AMCL_MOBILEGL_SOURCE_TREE')==expected_tree and
            os.environ.get('AMCL_MOBILEGL_SOURCE_CLEAN')=='1' and
            os.environ.get('AMCL_MOBILEGL_HOST_IMAGE')==image,'independent managed host source/image binding missing')
    require(re.fullmatch('sha256:[0-9a-f]{64}',image),'immutable QA image ID required')
    producer=verify_producer(producer_manifest,producer_sha,compose_sha,log_sha,expected_source,expected_tree,image,host_source,host_cache,host_producer_dir)
    text=(cache/'CMakeCache.txt').read_text()
    home=re.search(r'^CMAKE_HOME_DIRECTORY:INTERNAL=(.*)$',text,re.MULTILINE)
    require(home and Path(home[1]).resolve()==source,'actual cache belongs to another source')
    require('OHOS_STL:' not in text and 'ohos.toolchain.cmake' not in text and
            not re.search(r'^CMAKE_SYSTEM_NAME:.*=OHOS$',text,re.MULTILINE),'OHOS crosscache cannot be host proof')
    header=(cache/'generated/MGGitHash.h').read_text();require(expected_source in header,'generated source identity differs')
    library=(cache/'libMobileGL.so').read_bytes()
    require(library[:6]==b'\x7fELF\x02\x01' and struct.unpack_from('<H',library,18)[0]==62,'actual host library is not AMD64 ELF')
    require(('GIT@'+expected_source[:7]).encode() in library,'actual host library source marker missing')
    commands=subprocess.check_output(['ninja','-C',str(cache),'-t','commands','MobileGL'],text=True)
    names=direct_inputs(commands,cache);inputs={}
    for name in names:
        path=cache/name;require(path.is_file(),'actual direct link file missing: '+name)
        inputs[name]={'sha256':sha(path),'bytes':path.stat().st_size}
    files={name:{'sha256':sha(cache/name),'bytes':(cache/name).stat().st_size}
           for name in ('CMakeCache.txt','build.ninja','generated/MGGitHash.h','libMobileGL.so')}
    require(files==producer['artifactSnapshots'],'current cache differs from actual normal producer snapshots')
    compiler=re.search(r'^CMAKE_CXX_COMPILER:[^=]+=([^\n]+)$',text,re.MULTILINE)
    require(compiler,'actual CMake CXX compiler binding missing')
    return {'schema':1,'capturedAt':datetime.now(timezone.utc).isoformat(),'sourceCommit':expected_source,
            'sourceTree':expected_tree,'sourceClean':True,
            'sourceCleanBoundary':'project.py native host Git checked clean before fixed QA OS lock; container does not reinterpret Windows LFS payload status',
            'imageId':producer['imageId'],'captureImageId':image,'producer':producer,
            'containerPaths':{'source':str(source),'build':str(cache)},'files':files,'linkInputs':inputs,
            'ninjaCommandsSha256':hashlib.sha256(commands.encode()).hexdigest(),
            'cpuRunnerSha256':sha(source/'tools/cts/scripts/run_fp64_cpu_contract.py'),
            'cpuContractSha256':sha(source/'tools/cts/probe/fp64_ir_cache_contract.cpp'),
            'cmakeCompilerPath':compiler[1],
            'captureToolCompilerVersion':subprocess.check_output(['c++','--version'],text=True),
            'scope':'actual Linux AMD64 completed cache input only; no CPU/GPU/OHOS semantic qualification'}

def main():
    """明确source/cache/新外部输出；拒绝覆盖旧证明，stdout给实际文件摘要供独立选取。"""
    parser=argparse.ArgumentParser(description=__doc__)
    for key in ('source','cache','output','producer-manifest'):parser.add_argument('--'+key,type=Path,required=True)
    for key in ('expected-source','expected-tree','expected-image','expected-producer-sha','expected-producer-compose-sha','expected-producer-log-sha','expected-host-source','expected-host-cache','expected-host-producer-dir'):parser.add_argument('--'+key,required=True)
    args=parser.parse_args();source=args.source.resolve();cache=args.cache.resolve();output=args.output.resolve()
    require(not output.exists() and source not in output.parents and cache not in output.parents,'proof output must be new and outside source/cache')
    record=capture(source,cache,args.expected_source,args.expected_tree,args.expected_image,
        args.producer_manifest.resolve(),args.expected_producer_sha,args.expected_producer_compose_sha,args.expected_producer_log_sha,args.expected_host_source,args.expected_host_cache,args.expected_host_producer_dir)
    output.parent.mkdir(parents=True,exist_ok=True)
    with output.open('x',encoding='utf-8') as stream:stream.write(json.dumps(record,indent=2)+'\n')
    print('HOST_INPUT_PROOF inputs='+str(len(record['linkInputs']))+' sha256='+sha(output))

if __name__=='__main__':main()
