"""核固定CTS13真实QPA和独立进程/provider证据；复用fork评分，不实现第二评分器。

只对已取回的原始证据作资格判断，不执行GPU。expected由调用者独立保存，不能
从待验证报告自身推导。缺输入、截断、旧PID/runId、错误映像或强停一律不能PASS。
14等未解析请求逐项保留，不能凭13Pass推断全部EGL/OpenGL或OHOS成立。
"""
from pathlib import Path
from datetime import datetime, timezone
import argparse, hashlib, importlib.util, json, re, sys
sys.dont_write_bytecode=True
REQUIRED={'eglGetDisplay','eglInitialize','eglChooseConfig','eglCreatePbufferSurface',
          'eglCreateContext','eglMakeCurrent','eglGetProcAddress','glGetString',
          'glGetIntegerv','glBindFramebuffer','glReadPixels'}

def sha(path):
    """真实文件摘要用于制品/原始证据绑定。"""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def require(value, message):
    """不使用assert，Python-O也必须执行每项拒绝判据。"""
    if not value: raise ValueError(message)

def parse_maps(text):
    """只读Linux原maps范围/权限/文件offset/dev/inode/path，不凭路径出现接受任意地址。"""
    rows=[];previous_end=0
    pattern=re.compile(r'^([0-9a-fA-F]+)-([0-9a-fA-F]+)\s+([r-][w-][x-][ps])\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+:[0-9a-fA-F]+)\s+(\d+)(?:\s+(.*))?$')
    for line in text.splitlines():
        match=pattern.fullmatch(line);require(match,'invalid actual maps row')
        start,end,permissions,offset,device,inode,path=match.groups()
        start,end=int(start,16),int(end,16)
        require(start<end and start>=previous_end,'overlapping/unordered actual maps ranges')
        previous_end=end
        rows.append({'start':start,'end':end,'permissions':permissions,'offset':int(offset,16),
                     'device':device,'inode':int(inode),'path':path or ''})
    require(rows,'actual maps empty');return rows

def verify_own_ranges(own, maps, provider):
    """把dladdr基址绑定provider offset0映射，再核每个OWN函数属于同inode的可执行段。

    本轮Linux MobileGL ELF按offset0装载；允许同文件其它映射，但它们不能替代被选
    函数的共同imageBase。不会改地址或调用函数，缺可证明映射即拒资格。
    """
    bases={int(x['imageBase'],16) for x in own}
    require(len(bases)==1 and next(iter(bases))>0,'mixed/invalid same-image base')
    base=next(iter(bases));file_rows=[x for x in maps if x['path']==provider]
    roots=[x for x in file_rows if x['offset']==0 and x['start']==base and x['inode']>0]
    require(len(roots)==1,'actual imageBase not bound to unique provider offset0 map')
    identity=(roots[0]['device'],roots[0]['inode'])
    executable=[x for x in file_rows if 'x' in x['permissions'] and
                (x['device'],x['inode'])==identity and x['start']-x['offset']==base]
    require(executable,'selected provider executable mapping absent')
    for item in own:
        address=int(item['address'],16)
        require(any(x['start']<=address<x['end'] for x in executable),
                'OWN function outside selected provider executable map: '+item['symbol'])
    return {'imageBase':hex(base),'device':identity[0],'inode':identity[1],
            'executableRanges':[{'start':hex(x['start']),'end':hex(x['end']),'offset':hex(x['offset'])} for x in executable]}

def qualify(directory, source, cts_source, library, glcts, expectation):
    """返回独立资格表；输入破损收为issues，不能因异常跳过某个实际进程。"""
    require(isinstance(expectation,dict) and expectation.get('backend') in ('DirectGLES','DirectVulkan'),'invalid independent backend expectation')
    require(isinstance(expectation.get('qpaMarkers'),list) and expectation['qpaMarkers'] and
            all(isinstance(x,str) and x for x in expectation['qpaMarkers']),'nonempty independent QPA identity markers required')
    require(isinstance(expectation.get('mappedDriverPaths'),list) and
            all(isinstance(x,str) and x.startswith('/') for x in expectation['mappedDriverPaths']),'independent driver path list must be an explicit array')
    require(expectation['backend']!='DirectVulkan' or expectation['mappedDriverPaths'],'Vulkan actual selected ICD mapping required')
    caselist=Path(__file__).with_name('cases13.txt')
    cases=[x.strip() for x in caselist.read_text().splitlines() if x.strip()]
    require(len(cases)==13 and len(set(cases))==13,'fixed13 denominator changed')
    require(sha(caselist)==expectation['caselistSha256'],'independent fixed caselist differs')
    script=source/'tools/cts/scripts/cts_matrix_report.py'
    require(sha(script)==expectation['matrixSha256'],'selected fork matrix changed')
    require(sha(source/'tools/cts/scripts/run_cts_local.py')==expectation['runnerSha256'],'selected original runner changed')
    require(sha(library)==expectation['librarySha256'] and sha(glcts)==expectation['glctsSha256'],'actual independent library/glcts bytes differ')
    # 来自钉版官方loader的全GL33/EGL core义务，不能只核本轮用到的少数函数。
    required=set(REQUIRED)
    for relative,key in [('framework/opengl/wrapper/glwInitGL33.inl','coreGlSourceSha256'),
                         ('framework/egl/wrapper/eglwInitCore.inl','coreEglSourceSha256')]:
        file=cts_source/relative;require(sha(file)==expectation[key],'official loader input differs')
        names=set(re.findall(r'loader->get\("(\w+)"\)',file.read_text()))
        require(names,'official loader obligation list empty');required.update(names)
    spec=importlib.util.spec_from_file_location('original_cts_matrix',script)
    matrix=importlib.util.module_from_spec(spec);sys.path.insert(0,str(script.parent));spec.loader.exec_module(matrix)
    report=matrix.build_version_report('gl33',str(caselist),[str(directory/'cases')])
    issues=[];processes=[];started=set();seen_pids=set();seen_qpa=set()
    for path in sorted((directory/'native-processes').glob('*.json')):
        try:
            process=json.loads(path.read_text());pid=process['pid'];run=expectation['runId']
            require(type(pid) is int and pid>0 and pid not in seen_pids,'invalid/duplicate PID')
            seen_pids.add(pid)
            require(process['runId']==run and process['backend']==expectation['backend'],'independent run/backend mismatch')
            require(process['forcedKill'] is False and type(process['exitCode']) is int and process['exitCode']==0,'process did not normally complete')
            require(datetime.fromisoformat(process['finishedAt'])>datetime.fromisoformat(process['startedAt']),'process timing incomplete')
            for field in ('librarySha256','glctsSha256','runnerSha256'):
                require(process[field]==expectation[field],'independent '+field+' mismatch')
            require(process['selectedLibrary']==expectation['providerPath'],'selected provider path mismatch')
            actual_cases=process['actualCases'];require(len(set(actual_cases))==len(actual_cases) and set(actual_cases)<=set(cases),'actual argv case denominator differs')
            command=process['command']
            logs=[x.partition('=')[2] for x in command if x.startswith('--deqp-log-filename=')]
            lists=[x.partition('=')[2] for x in command if x.startswith('--deqp-caselist-file=')]
            require(logs==[process['qpaPath']] and len(lists)==1,'actual argv QPA/caselist binding differs')
            case_copy=path.with_suffix('.caselist.txt')
            actual_list=case_copy if case_copy.is_file() else directory/'cases'/Path(lists[0]).name
            require(sha(actual_list)==process['actualCaselistSha256'],'actual Popen caselist bytes differ')
            require([x.strip() for x in actual_list.read_text().splitlines() if x.strip() and not x.lstrip().startswith('#')]==actual_cases,'Popen caselist text differs')
            qpa_name=Path(process['qpaPath']).name;require(qpa_name not in seen_qpa,'QPA reused by another process');seen_qpa.add(qpa_name)
            qpa=directory/'cases'/qpa_name;raw=qpa.read_bytes();text=raw.decode();lines=text.splitlines()
            require(raw.endswith(b'\n') and lines.count('#beginSession')==1 and lines.count('#endSession')==1 and lines[-1]=='#endSession','QPA session truncated/duplicate')
            local=[x.split(None,1)[1] for x in lines if x.startswith('#beginTestCaseResult ')]
            require(len(set(local))==len(local) and set(local)<=set(actual_cases),'QPA actual case starts differ from Popen argv')
            started.update(local)
            for marker in expectation['qpaMarkers']:require(marker in text,'actual QPA source/backend marker missing: '+marker)
            log=directory/f'provider.{pid}.jsonl';raw=log.read_bytes();events=[json.loads(x) for x in raw.decode().splitlines()]
            require(raw.endswith(b'\n') and len(events)>=3,'provider report truncated')
            begin,end=events[0],events[-1];records=events[1:-1]
            require(begin['kind']=='begin' and end['kind']=='end' and end['completed'] is True,'provider terminal missing')
            require(begin['provider']==expectation['providerPath'] and all(x.get('pid')==pid and x.get('runId')==run for x in events),'provider PID/run/path mismatch')
            require(all(type(end.get(key)) is int and end[key]>=0 for key in ('resolutions','missing','foreign','writeErrors')),'provider counts must be actual nonnegative integers')
            require(end['resolutions']==len(records) and all(x.get('kind')=='resolve' for x in records),'provider count/record mismatch')
            own=[x for x in records if x.get('verdict')=='OWN'];missing=[x for x in records if x.get('verdict')=='MISSING']
            require(len(own)+len(missing)==len(records) and end['missing']==len(missing) and end['foreign']==0 and end['writeErrors']==0,'provider foreign/IO/verdict mismatch')
            for item in own:
                require(item['library']==expectation['providerPath'] and re.fullmatch('0x[0-9a-fA-F]+',item['address']) and int(item['address'],16)>0,'foreign/invalid actual symbol')
            require(required<={x['symbol'] for x in own} and all(x['verdict']=='OWN' for x in records if x['symbol'] in required),'fixed13 core/bootstrap required symbols not all OWN')
            mapped=directory/f'provider.{pid}.maps';map_rows=parse_maps(mapped.read_text())
            for image in [expectation['providerPath'],*expectation.get('mappedDriverPaths',[])]:
                require(any(x['path']==image for x in map_rows),'selected provider/driver absent from maps: '+image)
            mapping=verify_own_ranges(own,map_rows,expectation['providerPath'])
            process['providerSummary']={'own':len(own),'unresolvedRequested':len(missing),'unresolvedNames':sorted({x['symbol'] for x in missing}),'requiredOwn':sorted(required),'actualExecutableMapping':mapping,'fileSha256':sha(log),'mapsSha256':sha(mapped),'qpaSha256':sha(qpa)}
            processes.append(process)
        except (ValueError,KeyError,TypeError,OSError,IndexError) as error:issues.append(path.name+': '+str(error))
    if not processes:issues.append('no complete independently observed native process')
    if report['expected']!=13 or report['result']+report['unrun']!=13 or report['cases']['unexpected_results']:issues.append('fixed matrix denominator/identity differs')
    # 原matrix有明确后观察覆盖策略，用于广域恢复汇总；固定13资格要求每项唯一实测。
    # 保原history与评分，单独拒重复或没有真实Popen绑定的QPA，不能吞先前Fail后授PASS。
    duplicates=report['cases']['duplicate_results']
    if duplicates:issues.append('fixed13 case observed repeatedly: '+', '.join(sorted(duplicates)))
    bound={str((directory/'cases'/name).resolve()) for name in seen_qpa}
    if {str(Path(x).resolve()) for x in report['inputs']['qpa_files']}!=bound:issues.append('QPA files not exactly bound to observed Popen invocations')
    statuses={case:report['cases']['results'].get(case,'UNRUN') if case in started else 'NOT_RUN' for case in cases}
    complete=set(cases)<=started and report['result']==13 and report['unrun']==0 and not duplicates and report['validation']['ok']
    allpass=complete and report['pass']==13
    return {'reportedAt':datetime.now(timezone.utc).isoformat(),'scope':'fixed13 Linux host subset only; not fullCTS/core/OHOS/device admission',
            'expectation':expectation,'cases':statuses,'rawMatrix':report,'processes':processes,
            'actualStartedCases':sorted(started),'duplicateCaseObservations':duplicates,'complete':complete,'allStrictPass':allpass,
            'providerQualified':not issues,'issues':issues,'qualified':complete and allpass and not issues}

def main():
    """独立expectation与新外部输出；资格false返回1，输入错误返回2并不伪造结果。"""
    parser=argparse.ArgumentParser(description=__doc__)
    for key in ('directory','source','cts-source','library','glcts','expectation','output'):parser.add_argument('--'+key,type=Path,required=True)
    args=parser.parse_args();output=args.output.resolve()
    require(not output.exists() and args.source.resolve() not in output.parents,'output must be new and outside source')
    result=qualify(args.directory.resolve(),args.source.resolve(),args.cts_source.resolve(),args.library.resolve(),args.glcts.resolve(),json.loads(args.expectation.read_text()))
    output.parent.mkdir(parents=True,exist_ok=True)
    with output.open('x') as stream:stream.write(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'qualified':result['qualified'],'counts':result['rawMatrix']['counts'],'issues':result['issues']}))
    return 0 if result['qualified'] else 1

if __name__=='__main__':
    try:raise SystemExit(main())
    except (ValueError,KeyError,TypeError,OSError) as error:print(str(error),file=sys.stderr);raise SystemExit(2)
