#!/usr/bin/env python3
"""薄CPU/IR/cache/current合同调度：只核真实输入，再调用钉版fork既有算法与控制。

源码clean/commit/tree由宿主原生Git在固定QA创建前核对；容器不借Windows全局LFS
配置判断载荷是否dirty。独立proof SHA、image、Linux缓存、每个实际对象仍逐项核定。
任何身份缺失/跨编译缓存/不完整结果为NOT_RUN或FAIL，不会因未执行就给PASS。
"""
from pathlib import Path
from datetime import datetime,timezone
import argparse,hashlib,json,os,re,signal,struct,subprocess,sys,shlex

def sha(path):
    """读取实际文件字节摘要；不采用报告自述SHA验证报告自己。"""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def require(value,message):
    """显式断言保持-O语义；身份不成立时在CPU编译前拒绝。"""
    if not value:raise ValueError(message)

def verify_inputs(source,cache,proof,expected_source,expected_image):
    """逐实际source/cache/object核输入，绝不把OHOS AArch64或旧dirty host当当前CPU资格。"""
    require(proof.get('schema')==1 and proof.get('sourceCommit')==expected_source and proof.get('sourceClean') is True,'source proof differs')
    require(proof.get('imageId')==expected_image and os.environ.get('AMCL_MOBILEGL_HOST_IMAGE')==expected_image,'actual fixed QA image differs')
    require(os.environ.get('AMCL_MOBILEGL_SOURCE_COMMIT')==expected_source and os.environ.get('AMCL_MOBILEGL_SOURCE_TREE')==proof.get('sourceTree') and os.environ.get('AMCL_MOBILEGL_SOURCE_CLEAN')=='1','independent host Git source binding missing')
    require(proof.get('containerPaths')=={'source':str(source),'build':str(cache)},'cache/source container binding differs')
    cache_text=(cache/'CMakeCache.txt').read_text()
    home=re.search(r'^CMAKE_HOME_DIRECTORY:INTERNAL=(.*)$',cache_text,re.MULTILINE)
    require(home and Path(home[1]).resolve()==source,'CMake cache belongs to another source')
    require('OHOS_STL:' not in cache_text and 'ohos.toolchain.cmake' not in cache_text and not re.search(r'^CMAKE_SYSTEM_NAME:.*=OHOS$',cache_text,re.MULTILINE),'OHOS crosscache cannot qualify host CPU')
    required={'CMakeCache.txt','build.ninja','generated/MGGitHash.h','libMobileGL.so'}
    require(isinstance(proof.get('files'),dict) and set(proof['files'])==required,'required cache file identity missing')
    for name,row in proof['files'].items():
        path=cache/name;require(path.is_file() and sha(path)==row.get('sha256') and path.stat().st_size==row.get('bytes'),'actual cache file differs: '+name)
    header=(cache/'generated/MGGitHash.h').read_text();require(expected_source in header,'stale generated source identity')
    elf=(cache/'libMobileGL.so').read_bytes();require(elf[:6]==b'\x7fELF\x02\x01' and struct.unpack_from('<H',elf,18)[0]==62,'host library must be AMD64 ELF')
    require(('GIT@'+expected_source[:7]).encode() in elf,'actual host source marker missing')
    inputs=proof.get('linkInputs');require(isinstance(inputs,dict) and inputs,'actual link inputs missing')
    # 与fork原runner同一只读Ninja接缝获取实际链接argv，不shell执行。仅检查proof
    # 所列项会让删一项仍非空的声明漏过未知对象；必须与实际所有.o/.a集合精确互绑。
    commands=subprocess.check_output(['ninja','-C',str(cache),'-t','commands','MobileGL'],text=True)
    require(sha_text(commands)==proof.get('ninjaCommandsSha256'),'actual Ninja command identity differs')
    actual_inputs=set()
    for token in shlex.split(commands.splitlines()[-1]):
        if token.endswith(('.o','.a')):
            path=Path(token);path=(path if path.is_absolute() else cache/path).resolve()
            require(path.is_relative_to(cache),'actual link input escapes cache')
            actual_inputs.add(path.relative_to(cache).as_posix())
    require(actual_inputs and set(inputs)==actual_inputs,'actual full link input set differs')
    for name,row in inputs.items():
        path=(cache/name).resolve();require(not Path(name).is_absolute() and path.is_relative_to(cache) and path.is_file(),'invalid link input path')
        require(sha(path)==row.get('sha256') and path.stat().st_size==row.get('bytes'),'actual link object/archive differs: '+name)
    runner=source/'tools/cts/scripts/run_fp64_cpu_contract.py';contract=source/'tools/cts/probe/fp64_ir_cache_contract.cpp'
    require(sha(runner)==proof.get('cpuRunnerSha256') and sha(contract)==proof.get('cpuContractSha256'),'pinned fork CPU code differs')
    return runner

def sha_text(text):
    """Ninja文本使用同实际工具UTF-8输出指纹，不通过报告中的对象数量猜完整性。"""
    return hashlib.sha256(text.encode()).hexdigest()

def verify_receipt(receipt,source,out,proof):
    """廉价复核fork原runner收据绑定新输出与当前契约；19/精确阴性由钉版fork强验。"""
    record=json.loads(receipt.read_text());require(record.get('sourceMainSha256')==proof['cpuContractSha256'],'actual fork receipt source differs')
    rows=record.get('commands');names={'main-compile','positive-link','positive-run','legacy-epoch-compile',
        'legacy-epoch-link','legacy-epoch-run','pointer-owner-compile','pointer-owner-link'}
    require(isinstance(rows,list) and len(rows)==len(names) and {row.get('name') for row in rows}==names,'fork receipt command completeness differs')
    for row in rows:
        require(row.get('exitCode')==(1 if row['name']=='legacy-epoch-run' else 0),'fork receipt execution failed')
        require(isinstance(row.get('command'),list) and row['command'],'fork receipt actual argv missing')
    by_name={row['name']:row for row in rows};directory=out/'contract'
    require(by_name['positive-run']['command']==[str(directory/'cpu-contract'),str(directory/'positive-raw')],'fork positive borrowed old output')
    require(by_name['legacy-epoch-run']['command']==[str(directory/'cpu-contract-legacy-epoch'),str(directory/'negative-raw'),'--cache-control-only'],'fork negative borrowed old output')
    require(str(source/'tools/cts/probe/fp64_ir_cache_contract.cpp') in by_name['main-compile']['command'],'fork compiled another contract')

def main():
    """输入验证后一次独占进程，记录实际argv/完成与强停边界；不调CTS或replay。"""
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--cache',type=Path,required=True);parser.add_argument('--proof',type=Path,required=True)
    parser.add_argument('--expected-proof-sha',required=True);parser.add_argument('--expected-source',required=True)
    parser.add_argument('--expected-image',required=True);parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--timeout',type=int,default=600);args=parser.parse_args()
    source=args.source.resolve();cache=args.cache.resolve();out=args.output.resolve()
    require(not out.exists() and out!=source and source not in out.parents and out!=cache and cache not in out.parents,'output must be a new independent external directory')
    require(re.fullmatch('[0-9a-f]{40}',args.expected_source) and re.fullmatch('[0-9a-f]{64}',args.expected_proof_sha),'independent expected identities invalid')
    require(30<=args.timeout<=1800,'CPU timeout outside bounded range')
    require(sha(args.proof)==args.expected_proof_sha,'independent host proof SHA differs')
    proof=json.loads(args.proof.read_text());runner=verify_inputs(source,cache,proof,args.expected_source,args.expected_image)
    out.mkdir(parents=True);started=datetime.now(timezone.utc).isoformat()
    command=[sys.executable,str(runner),'--source-dir',str(source),'--build-dir',str(cache),'--output-dir',str(out/'contract')]
    forced=False
    with (out/'cpu.log').open('wb') as log:
        process=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,cwd=out,start_new_session=True)
        try:code=process.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            forced=True;os.killpg(process.pid,signal.SIGTERM)
            try:code=process.wait(timeout=5)
            except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);code=process.wait()
    record={'startedAt':started,'finishedAt':datetime.now(timezone.utc).isoformat(),'pid':process.pid,
            'runId':os.environ.get('AMCL_RUN_ID'),'sourceCommit':args.expected_source,'sourceTree':proof['sourceTree'],
            'imageId':args.expected_image,'proofSha256':args.expected_proof_sha,'command':command,'exitCode':code,'forcedKill':forced,
            'scope':'fork-owned CPU/IR/cache/current object contract only; no CTS/replay/device/API admission'}
    # fork既有runner已验证19唯一正控/15阴性与精确失败；这里只核它实际形成收据并正常完成。
    receipt=out/'contract/cpu-receipt.json';complete=receipt.is_file() and not forced and code==0
    if complete:verify_receipt(receipt,source,out,proof)
    record.update(completed=complete,passed=complete)
    (out/'result.json').write_text(json.dumps(record,indent=2)+'\n');print('MobileGL CPU '+('PASS' if complete else 'FAIL'))
    return 0 if complete else (code or 1)

if __name__=='__main__':
    try:raise SystemExit(main())
    except Exception as error:print('MobileGL CPU NOT_RUN/ERROR: '+str(error),file=sys.stderr);raise SystemExit(2)
