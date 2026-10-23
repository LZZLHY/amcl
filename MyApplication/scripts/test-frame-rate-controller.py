"""编译完整生产帧率controller，以明确SDK边界计数验证稳定刷新和生命周期。

原CPP正文快照与旧force撤回分别真实编译；负控须退出2并命中SDK调用次数断言，
不能用编译失败冒充证明。NativeXComponent/DisplayManager/hilog/foreground发布
均为具名外部接缝；没有完整XComponent、OHOS调度、CPU或输入延迟测量结论。
"""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import os
import subprocess
import uuid
from lib.host_cpp import configure_host_cmake, find_host_cmake
from lib.workspace_paths import external_output_path, workspace_path

ROOT = Path(__file__).resolve().parents[1]
PLATFORM = ROOT / 'entry/src/main/cpp/platform'


def identity(path):
    """绑定实际检出字节，明确生产源、测试样本、平台接缝和宿主工具的区别。"""
    data = path.read_bytes()
    return {'path': str(path), 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}


def main():
    """全新外置树中配置MSVC/本机C++；逐命令保留输出、退出码与原始正负结果。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir'); parser.add_argument('--output'); parser.add_argument('--cmake')
    args = parser.parse_args()
    leaf = 'run-'+str(os.getpid())+'-'+uuid.uuid4().hex[:8]
    build = (external_output_path(args.build_dir) if args.build_dir else workspace_path('build','input-frame-controller')) / leaf
    output = (external_output_path(args.output) if args.output else workspace_path('run','input-frame-controller')) / leaf
    project = build/'source'; project.mkdir(parents=True, exist_ok=False); output.mkdir(parents=True, exist_ok=False)
    sources = [PLATFORM/'ohos_frame_rate_hint.cpp', PLATFORM/'ohos_frame_rate_hint.h',
               PLATFORM/'input_foreground_gate.h', PLATFORM/'graphics_observation_abi.h', PLATFORM/'graphics_runtime_export.h',
               ROOT/'entry/src/main/cpp/tests/host/frame_rate_controller_test.cpp', Path(__file__),
               ROOT/'scripts/lib/host_cpp.py', ROOT/'scripts/lib/workspace_paths.py']
    receipt = {'startedAt': datetime.datetime.now().astimezone().isoformat(), 'state': 'Running',
               'scope': 'Full production controller; explicit SDK and foreground notification boundaries, not OHOS/device performance',
               'sources': [identity(path) for path in sources], 'commands': []}
    def save():
        """每步实际完成后写收据；失败也保留，缺失不能补写PASS。"""
        (output/'receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2),encoding='utf-8')
    def run(label, command):
        """参数数组调用前台进程；记录全量stdout/stderr和原返回码，不吞编译错误。"""
        item={'label':label,'command':list(map(str,command)), 'startedAt':datetime.datetime.now().astimezone().isoformat()}
        receipt['commands'].append(item); print(label, flush=True)
        result=subprocess.run(list(map(str,command)),capture_output=True,text=True,timeout=180)
        log=output/(label+'.log'); log.write_text(result.stdout+result.stderr,encoding='utf-8')
        item.update(exitCode=result.returncode,finishedAt=datetime.datetime.now().astimezone().isoformat(),log=identity(log)); save()
        print(result.stdout+result.stderr,flush=True); return result
    try:
        # SDK接缝只声明此controller实际使用的两个接口；完整算法直接编译生产TU，不能复制纯模型代证。
        stubs=project/'stubs'; (stubs/'ace/xcomponent').mkdir(parents=True); (stubs/'window_manager').mkdir(); (stubs/'hilog').mkdir()
        (stubs/'ace/xcomponent/native_interface_xcomponent.h').write_text('''#pragma once
#include <stdint.h>
struct OH_NativeXComponent { int identity; };
struct OH_NativeXComponent_ExpectedRateRange { int32_t min,max,expected; };
extern "C" int32_t OH_NativeXComponent_SetExpectedFrameRateRange(OH_NativeXComponent*,OH_NativeXComponent_ExpectedRateRange*);
''',encoding='utf-8')
        (stubs/'window_manager/oh_display_manager.h').write_text('''#pragma once
#include <stdint.h>
enum NativeDisplayManager_ErrorCode { DISPLAY_MANAGER_OK=0 };
extern "C" NativeDisplayManager_ErrorCode OH_NativeDisplayManager_GetDefaultDisplayRefreshRate(uint32_t*);
''',encoding='utf-8')
        (stubs/'hilog/log.h').write_text('''#pragma once
void frameControllerRecordLog(const char*);
template<class... Values> void frameControllerLog(int,const char* text,Values&&...) { frameControllerRecordLog(text); }
#define LOG_APP 0
#define OH_LOG_INFO(...) frameControllerLog(__VA_ARGS__)
#define OH_LOG_WARN(...) frameControllerLog(__VA_ARGS__)
#define OH_LOG_ERROR(...) frameControllerLog(__VA_ARGS__)
''',encoding='utf-8')
        if os.name=='nt':
            (stubs/'strings.h').write_text('#pragma once\n#include <cstring>\ninline int strcasecmp(const char* a,const char* b){return _stricmp(a,b);}\n',encoding='utf-8')
        original=sources[0].read_text(encoding='utf-8')
        anchor='return ApplyControllerLocked(lifecycleStage, false, false, displayRate);'
        if original.count(anchor)!=1:raise ValueError('stable refresh anchor is not unique')
        (project/'positive.cpp').write_text(original,encoding='utf-8')
        (project/'old-force.cpp').write_text(original.replace(anchor,'return ApplyControllerLocked(lifecycleStage, true, false, displayRate);'),encoding='utf-8')
        fixture=project/'fixture.cpp'; fixture.write_bytes(sources[5].read_bytes())
        cmake_text='cmake_minimum_required(VERSION 3.16)\nproject(frame_controller LANGUAGES CXX)\n'
        for name,file in [('positive','positive.cpp'),('old-force','old-force.cpp')]:
            cmake_text+='add_executable('+name+' '+file+' fixture.cpp)\n'
            cmake_text+='target_include_directories('+name+' PRIVATE "'+stubs.as_posix()+'" "'+PLATFORM.as_posix()+'")\n'
            cmake_text+='target_compile_features('+name+' PRIVATE cxx_std_20)\n'
            cmake_text+='if(MSVC)\n target_compile_options('+name+' PRIVATE /utf-8)\n target_compile_definitions('+name+' PRIVATE _CRT_SECURE_NO_WARNINGS)\nendif()\n'
        (project/'CMakeLists.txt').write_text(cmake_text,encoding='utf-8')
        receipt['generatedInputs']=[identity(path) for path in sorted(project.rglob('*')) if path.is_file()]
        cmake=find_host_cmake(args.cmake); receipt['cmake']=identity(Path(cmake)); configure_host_cmake(cmake,project,build/'native')
        compiled=run('compile',[cmake,'--build',build/'native','--config','Debug','--parallel','2'])
        if compiled.returncode:raise RuntimeError('controller compile failed')
        folder=build/'native'/('Debug' if os.name=='nt' else '')
        positive=run('positive',[folder/('positive.exe' if os.name=='nt' else 'positive')])
        if positive.returncode:raise AssertionError('actual controller behavior failed')
        negative=run('old-force-negative',[folder/('old-force.exe' if os.name=='nt' else 'old-force')])
        if negative.returncode!=2 or 'CHECK STABLE_REFRESH_SINGLE_SDK' not in negative.stderr:
            raise AssertionError('old-force must compile and fail SDK-call count behavior')
        receipt['sourceDrift']=[str(path) for before,path in zip(receipt['sources'],sources) if before!=identity(path)]
        if receipt['sourceDrift']:raise RuntimeError('source changed during actual controller validation')
        receipt['binaries']=[identity(folder/(name+'.exe' if os.name=='nt' else name)) for name in ['positive','old-force']]
        receipt['state']='Validated'; receipt['positiveExit']=positive.returncode; receipt['negativeExit']=negative.returncode
        print('PASS complete controller and successfully compiled old-force behavior negative; evidence='+str(output),flush=True)
    except Exception as error:
        receipt['state']='Failed'; receipt['failure']=str(error); raise
    finally:
        receipt['finishedAt']=datetime.datetime.now().astimezone().isoformat(); save()


if __name__=='__main__':main()
