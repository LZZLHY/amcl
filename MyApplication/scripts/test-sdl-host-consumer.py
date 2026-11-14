"""SDL 宿主组合门：首次执行真实正负恢复，同输入复核原成功证据后明确复用。

--fresh/AMCL_GATE_FRESH 强制重新执行全部原门；失败完整保留，成功默认仅回收本轮
有 owner 身份的大构建树。日志、源码快照、最终库和每例二进制继续留在仓外证据目录。
"""
from pathlib import Path
from datetime import datetime
import argparse
import json
import os
import re
import subprocess
import sys
import uuid
sys.dont_write_bytecode=True
from lib.workspace_paths import external_output_path
from lib.sdl_host_cache import (content_key, exclusive_lock, file_identity, input_identity,
    external_dependencies, retain_success, cleanup_owned_build, routed_path, write_json,
    publish_manifest, validate_cached, STAGES)
from lib.sdl_host_cache import controlled_environment
ROOT=Path(__file__).resolve().parents[1]

def main():
    """锁住输入键后复核成功证据；失效或 Fresh 仍执行原完整三门，不放宽断言。"""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-repo',default=os.environ.get('AMCL_SDL_TEST_REPO'))
    parser.add_argument('--out');parser.add_argument('--build-out')
    parser.add_argument('--cache-root',help='整组合成功结果索引的仓外目录；不接纳旧裸 SDK 树')
    parser.add_argument('--cmake',help='显式选择宿主 CMake，身份及实际工具依赖纳入复用判据')
    parser.add_argument('--fresh',action='store_true',help='强制真实重跑全部编译/负控/恢复，不复用历史结果')
    parser.add_argument('--keep-build',action='store_true',help='成功后保留本轮大树用于排障；失败始终保留')
    args=parser.parse_args()
    fresh=args.fresh or os.environ.get('AMCL_GATE_FRESH','').strip().lower() in ('1','true','yes')
    if not args.source_repo:raise ValueError('AMCL_SDL_TEST_REPO or --source-repo must name an existing Git repository containing the locked SDL commit; CI must run its exact-source materialization step first')
    repo=Path(args.source_repo).resolve()
    if not repo.is_dir():raise FileNotFoundError('SDL source repository does not exist: '+str(repo))
    lock=(ROOT/'deps.lock').read_text(encoding='utf-8');section=re.search(r'^\[sdl3-native\]\s*\n([\s\S]*?)(?=^\[|\Z)',lock,re.M).group(1)
    pin=re.search(r'^commit\s*=\s*([a-f0-9]{40})',section,re.M).group(1)
    checked=subprocess.run(['git','-C',str(repo),'cat-file','-e',pin+'^{commit}'],capture_output=True)
    if checked.returncode:raise ValueError('SDL source repository lacks deps.lock commit '+pin+': '+checked.stderr.decode(errors='replace').strip())
    task='sdl-host-'+str(os.getpid())+'-'+uuid.uuid4().hex[:6]
    out=external_output_path(args.out) if args.out else routed_path(ROOT,'run',task)
    build=external_output_path(args.build_out) if args.build_out else routed_path(ROOT,'build',task)
    cache=external_output_path(args.cache_root) if args.cache_root else routed_path(ROOT,'build','sdl-host-cache')
    for first,second in ((out,build),(out,cache),(build,cache)):
        if first.is_relative_to(second) or second.is_relative_to(first):
            raise ValueError('SDL evidence, build and cache roots must be disjoint')
    out.mkdir(parents=True,exist_ok=False)
    started=datetime.now().astimezone().isoformat();commands=[];state='Running';execution_complete=False
    owner=uuid.uuid4().hex;details={'fresh':fresh,'buildRoot':str(build),'buildCreated':False,
        'cacheRoot':str(cache),'cacheStatus':'not-checked','buildLifecycle':'not-created'}
    def stage(name,arguments):
        """前台显示原子门全部输出，不丢失败、编译负控或恢复；只调用现有真实测试。"""
        command=[sys.executable,'-B',str(ROOT/'scripts'/name),*map(str,arguments)]
        item={'command':command,'startedAt':datetime.now().astimezone().isoformat()};commands.append(item)
        print('[SDL host combination] '+' '.join(command),flush=True)
        result=subprocess.run(command,env=controlled_environment())
        item.update(exitCode=result.returncode,finishedAt=datetime.now().astimezone().isoformat())
        if result.returncode:raise RuntimeError('SDL host combination failed: '+name+' exit '+str(result.returncode))
    def receipt():
        """实际执行、复用和未运行分别记账，复用收据不能升级成新的执行 PASS。"""
        return {'startedAt':started,'completedAt':datetime.now().astimezone().isoformat(),
            'state':state,'sourceRepository':str(repo),'pin':pin,'platform':sys.platform,
            'commands':commands,**details,
            'scope':'actual native host SDL checkout/full SDK control/owned text; no device/game ACK claim'}
    try:
        inputs=input_identity(ROOT,pin,args.cmake);key=content_key(inputs);details['inputKey']=key
        with exclusive_lock(cache/(key+'.lock')):
            # 等待锁期间源码可能变化，不能拿等待之前的身份授予缓存命中或新执行资格。
            if input_identity(ROOT,pin,args.cmake)!=inputs:raise RuntimeError('SDL inputs changed while waiting for cache lock')
            pointer=cache/(key+'.json')
            if not fresh and pointer.is_file():
                try:
                    reused=validate_cached(json.loads(pointer.read_text(encoding='utf-8')),inputs)
                except (OSError,ValueError,KeyError,TypeError) as error:
                    details.update(cacheStatus='invalid',cacheInvalidation=str(error))
                    print('[SDL host combination] cache rejected: '+str(error),flush=True)
                else:
                    if input_identity(ROOT,pin,args.cmake)!=inputs:raise RuntimeError('SDL inputs changed while verifying cache')
                    details.update(cacheStatus='reused',reusedManifest=str(Path(reused['evidenceRoot'])/'cache-manifest.json'),
                        reusedCompletedAt=reused['createdAt'])
                    state='REUSED'
                    print('REUSED SDL host combination: verified unchanged inputs, external headers, original compiled behavior evidence and artifacts: '+reused['evidenceRoot'],flush=True)
                    return
            build.mkdir(parents=True,exist_ok=False)
            write_json(build/'.sdl-combination-owner.json',{'owner':owner,'path':str(build)})
            details.update(buildCreated=True,buildLifecycle='retained-while-running',
                cacheStatus='fresh' if fresh else details['cacheStatus'])
            stage(STAGES[0],['--output',out/'headers','--build-root',build/'headers'])
            sdk=build/'sdk'
            tool=['--cmake',args.cmake] if args.cmake else []
            # 原门默认完整 SDK、全部行为负控及恢复；没有 production-only 或跳过变体。
            stage(STAGES[1],['--source-repo',repo,'--out',sdk,*tool])
            stage(STAGES[2],['--sdk-host-tree',sdk,'--out',out/'owned','--build-out',build/'owned',*tool])
            if input_identity(ROOT,pin,args.cmake)!=inputs:raise RuntimeError('SDL inputs changed during actual combination execution')
            retain_success(ROOT,out,build,inputs)
            try:
                dependencies=external_dependencies(ROOT,build)
            except ValueError as error:
                # 真正业务执行已经成功，但无法取得系统头闭包时不制造可复用资格。
                dependencies=None;details.update(cacheStatus='not-cacheable',cacheInvalidation=str(error))
                print('[SDL host combination] completed execution is not cacheable: '+str(error),flush=True)
            # 归档/依赖收集本身也有耗时；再次确认输入未变后才允许回收本轮成功大树。
            if input_identity(ROOT,pin,args.cmake)!=inputs:raise RuntimeError('SDL inputs changed while preserving successful evidence')
            # 原业务与逐文件保全已经成功；先持久化并回读 PASS，再进入可失败的空间/缓存后处理。
            state='PASS';details['buildLifecycle']='retained-success-proof'
            durable=receipt();write_json(out/'receipt.json',durable)
            if json.loads((out/'receipt.json').read_text(encoding='utf-8'))!=durable:
                raise RuntimeError('SDL durable execution receipt readback failed')
            execution_complete=True
            if args.keep_build:
                details['buildLifecycle']='retained-by-request'
            else:
                try:
                    cleanup_owned_build(build,owner);details['buildLifecycle']='removed-owned-success-build'
                except (OSError,ValueError) as error:
                    # 空间回收失败不撤销已核实的源码/制品/行为资格；保留剩余现场并明确
                    # 记录原因，后续仍发布同一份有效缓存，避免每次因只读文件重新编译。
                    details.update(buildLifecycle='retained-success-cleanup-failed',cleanupError=str(error))
                    print('[SDL host combination] execution/evidence passed; success build cleanup failed: '+str(error),flush=True)
            state='PASS'
            if dependencies is not None:
                details['cacheStatus']='recorded'
                write_json(out/'receipt.json',receipt())
                publish_manifest(out,inputs,dependencies)
                manifest=out/'cache-manifest.json'
                write_json(pointer,{'manifest':str(manifest),'identity':file_identity(manifest)})
    except Exception as error:
        # 失败阶段保持原始退出/日志；组合收据明确FAIL，不让结束的实验遗留Running身份。
        if execution_complete:
            # 此时成功日志、逐成员源码与二进制都已保全。索引发布失败只取消复用资格，
            # 不能伪造业务失败，或声称已被受控回收的成功大树仍是“失败完整现场”。
            state='PASS';details.update(cacheStatus='not-cacheable',postSuccessIssue=str(error),
                buildLifecycle='retained-success-postprocessing-issue' if build.exists() else 'removed-owned-success-build')
            print('[SDL host combination] execution passed; cache/lifecycle postprocessing issue: '+str(error),flush=True)
        else:
            state='FAIL'
            if details['buildCreated'] and build.exists():details['buildLifecycle']='retained-failure'
            raise
    finally:
        # 成功 manifest 已绑定这份收据，之后不得改写 completedAt 使缓存立即自失效。
        if not (state=='PASS' and details['cacheStatus']=='recorded'):
            write_json(out/'receipt.json',receipt())
    print('PASS SDL host combination: '+str(out),flush=True)

if __name__=='__main__':main()
