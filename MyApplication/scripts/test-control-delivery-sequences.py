"""编译真实生产端口的长序列及四个定点撤回反控；输出全部外置，编译失败不能算反控通过。"""
from pathlib import Path
from datetime import datetime
import argparse,hashlib,json,os,subprocess,uuid,sys
from lib.host_cpp import find_host_cmake,configure_host_cmake
from lib.workspace_paths import external_output_path,workspace_path

ROOT=Path(__file__).resolve().parents[1]
CPP=ROOT/'entry/src/main/cpp'


def identity(path):
    """绑定本次实际输入和可执行文件字节，拒绝把另一版的运行结果贴到当前源码。"""
    data=path.read_bytes()
    return {'path':str(path),'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}


def main():
    """先编译全部目标，正控完成36万步后执行成功编译的反控，最后再跑同一个正控种子。"""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output')
    parser.add_argument('--build-root')
    args=parser.parse_args()
    nonce='run-'+str(os.getpid())+'-'+uuid.uuid4().hex[:6]
    out=external_output_path(args.output) if args.output else workspace_path('run','control-sequences',nonce)
    build=external_output_path(args.build_root) if args.build_root else workspace_path('build','control-sequences',nonce)
    out.mkdir(parents=True,exist_ok=False);build.mkdir(parents=True,exist_ok=False)
    control=CPP/'input/delivery/control_delivery.cpp'
    test=CPP/'tests/host/control_delivery_sequence_test.cpp'
    common=[CPP/name for name in ['input/input_state_core.cpp','input/amcl_input_host_descriptor.cpp',
        'input/input_interaction_order.cpp','input/adapters/backend_keymaps.cpp']]
    inputs=[control,test,*common,Path(__file__).resolve(),ROOT/'scripts/lib/host_cpp.py',
        ROOT/'scripts/lib/workspace_paths.py',CPP/'input/delivery/control_delivery.h',
        CPP/'input/delivery/control_delivery_client.h']
    before=[identity(path) for path in inputs]
    report={'startedAt':datetime.now().astimezone().isoformat(),'state':'running','inputs':before,
        'head':None,
        'scope':'real neutral/Core host port; simulated ABI dispatch/cache; no device acceptance',
        'commands':[],'mutations':[]}
    def save():
        """部分失败也保存原日志和状态；不能把中途失败只压缩成最后一次通过。"""
        (out/'receipt.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    def run(label,command,expected_failure=None):
        """前台实际进程，原始日志落外部。反控须有精确断言标记，信号崩溃/用法错误不授通过。"""
        print(label,flush=True)
        log=out/(label+'.log');chunks=[]
        with log.open('wb') as stream:
            process=subprocess.Popen([str(value) for value in command],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
            for line in iter(process.stdout.readline,b''):
                stream.write(line);stream.flush();chunks.append(line)
                sys.stdout.write(line.decode('utf-8',errors='replace'));sys.stdout.flush()
            result=process.wait()
        body=b''.join(chunks).decode('utf-8',errors='replace')
        report['commands'].append({'label':label,'command':[str(value) for value in command],
            'exitCode':result,'log':identity(log)})
        save()
        if expected_failure is None:
            if result:raise RuntimeError(label+' failed; '+str(log))
        elif result!=1 or 'SEQUENCE FAIL' not in body or expected_failure not in body:
            raise RuntimeError(label+' did not hit its expected executable assertion; '+str(log))
        print(label+' verified',flush=True)
        return body
    try:
        # Git/工具准备失败同样进入finally收据；跨Windows/WSL工作树须显式绑定可读的Git元数据。
        report['head']=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD']).decode().strip()
        original=control.read_text(encoding='utf-8')
        # 只在外置副本撤回四条生产保障；anchor必须唯一，生产源码绝不临时改成坏版本。
        cases=[('stale_completion',
            'if(current){auto h=c->controls.find({e->kind,e->code});h->second.observedHeld=e->action!=0;}',
            'if(true){auto h=c->controls.find({e->kind,e->code});h->second.observedHeld=e->action!=0;}',
            'port->queryDelivered(c,1,0)==0'),
            ('cross_source','if((mask&(1u<<(it->type-1)))&&(!only||it->id==owner))',
             'if(true)','port->query(c,1,0)==1'),
            ('duplicate_claim','||it->second.claimed)return AMCL_CONTROL_REJECTED;',
             ')return AMCL_CONTROL_REJECTED;','port->claim(&down)==AMCL_CONTROL_REJECTED'),
            ('ticket_pressure','if(edge&&c->tickets.size()>=kTickets)return AMCL_CONTROL_PRESSURE;',
             'if(false)return AMCL_CONTROL_PRESSURE;','AMCL_CONTROL_PRESSURE&&e.ticket==0')]
        project=build/'project';project.mkdir()
        sources={'positive':control}
        for name,old,new,expected in cases:
            if original.count(old)!=1:raise RuntimeError(name+' anchor count is not one')
            path=project/(name+'.cpp');path.write_text(original.replace(old,new),encoding='utf-8')
            sources[name]=path
            report['mutations'].append({'name':name,'original':old,'replacement':new,'source':identity(path),
                'expectedAssertion':expected})
        quote=lambda path:'"'+path.as_posix()+'"'
        body='cmake_minimum_required(VERSION 3.16)\nproject(input_sequence LANGUAGES CXX)\n'
        body+='if(NOT CMAKE_CONFIGURATION_TYPES AND NOT CMAKE_BUILD_TYPE)\nset(CMAKE_BUILD_TYPE Release CACHE STRING "Host test configuration" FORCE)\nendif()\nfind_package(Threads REQUIRED)\n'
        body+='add_library(sequence_core STATIC '+' '.join(quote(p) for p in common)+')\n'
        body+='target_compile_features(sequence_core PUBLIC cxx_std_17)\n'
        body+='target_include_directories(sequence_core PUBLIC '+' '.join(quote(CPP/p) for p in
            ['input','input/delivery','tests/host/stubs'])+')\n'
        body+='target_compile_definitions(sequence_core PUBLIC AMCL_INPUT_HOST_EXPORTS AMCL_CONTROL_DELIVERY_HOST_TESTING)\n'
        body+='target_link_libraries(sequence_core PUBLIC Threads::Threads ${CMAKE_DL_LIBS})\n'
        for name,source in sources.items():
            body+='add_executable('+name+' '+quote(test)+' '+quote(source)+')\n'
            body+='target_link_libraries('+name+' PRIVATE sequence_core)\n'
            # POSIX真实descriptor经dlsym验证主程序getter，须导出真实符号；不能替换成恒成功解析。
            body+='set_target_properties('+name+' PROPERTIES ENABLE_EXPORTS ON)\n'
        body+='if(MSVC)\n'
        for name in ['sequence_core',*sources]:body+='target_compile_options('+name+' PRIVATE /utf-8)\n'
        body+='endif()\n'
        (project/'CMakeLists.txt').write_text(body,encoding='utf-8')
        cmake=find_host_cmake();tree=build/'build';configure_host_cmake(cmake,project,tree)
        run('compile',[cmake,'--build',tree,'--config','Release','--parallel','4'])
        executable=lambda name:tree/('Release/'+name+'.exe' if os.name=='nt' else name)
        report['binaries']={name:identity(executable(name)) for name in sources}
        result=run('positive',[executable('positive')])
        if 'SEQUENCE PASS events=360000 ' not in result:raise RuntimeError('positive long sequence coverage incomplete')
        for name,old,new,expected in cases:run(name,[executable(name),'1','1000'],expected)
        run('restored',[executable('positive'),'1','1000'])
        if before!=[identity(path) for path in inputs]:raise RuntimeError('source identity drift during verification')
        report['state']='passed';report['events']=360000;report['compiledNegativeControls']=len(cases)
    except Exception as error:
        report['state']='failed';report['failure']=str(error);raise
    finally:
        report['finishedAt']=datetime.now().astimezone().isoformat();save()
    print('PASS real production control sequences and compiled withdrawals: '+str(out),flush=True)


if __name__=='__main__':main()
