"""只读外置0030/0031 postimage，重放正式补丁并执行实际快照/UID函数的宿主回归。

--sources-root包含8/17/21/25子目录；逐文件摘要与仓内锁定夹具匹配，不能拿未知源码
当上游证据。复制到独占输出后才reverse/replay，不修改调用者源码或正式series。
宿主函数测试不授予目标AF_UNIX、共享计数、双VM Attach或完整CLI资格。
"""
from pathlib import Path
from datetime import datetime
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from lib.host_cpp import compile_cpp
from lib.workspace_paths import external_output_path

ROOT = Path(__file__).resolve().parents[1]


def digest(data):
    """源码允许Git等价CRLF检出，正文其它字节必须相同。"""
    return hashlib.sha256(data.replace(b'\r\n', b'\n')).hexdigest()


def function(text, signature):
    """提取已知真实函数的完整花括号正文；没有在测试中另写生产选择算法。"""
    begin = text.index(signature)
    end = text.index('{', begin) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[begin:end]


PREFIX = r'''
// 实际函数只替换HotSpot堆和NSS输入；Windows也可运行，无需伪造系统passwd。
#include "actual_temp.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <limits>
#ifdef _WIN32
typedef unsigned int uid_t;
struct passwd { char* pw_name; };
#else
#include <pwd.h>
#endif
static unsigned live;
static void* owned(size_t n){void* p=malloc(n);if(!p)abort();++live;return p;}
static void release(void* p){if(p){--live;free(p);}}
#define NEW_C_HEAP_ARRAY(t,n,tag) static_cast<t*>(owned(n*sizeof(t)))
#define FREE_C_HEAP_ARRAY(t,p,...) release(p)
#define sysconf(name) 1024L
#define jio_snprintf snprintf
#define warning(...) fprintf(stderr,__VA_ARGS__)
static const bool PrintMiscellaneous=false,Verbose=false;
struct os {static const char* strerror(int e){return ::strerror(e);}};
static int mode;
static int test_passwd(uid_t,passwd* p,char* b,size_t,passwd** result){
    *result=NULL;
    if(mode==0){errno=EIO;return 0;} // 成功无条目允许遗留errno，不把它误当当前错误。
    if(mode==1)return EIO;
    if(mode==2)return ERANGE;
    if(mode==3)return ENOMEM;
    *result=p;
    if(mode==4){p->pw_name=NULL;return 0;}
    if(mode==5){b[0]=0;p->pw_name=b;return 0;}
    strcpy(b,"named_user");p->pw_name=b;return 0;
}
#define getpwuid_r test_passwd
'''
SUFFIX = r'''
#undef getpwuid_r
static void check(bool p,const char* reason){if(!p){fprintf(stderr,"FAIL %s\n",reason);exit(1);}}
int main(){
    AmclOhosTempDirectory s=AMCL_OHOS_TEMP_INITIALIZER;
    const std::string root=u8"/private/中文😀/temp";
    check(std::string(amcl_ohos_temp_directory(&s))=="/tmp","initial fallback");
    check(amcl_freeze_ohos_temp_directory(&s,root.c_str())==0,"freeze");
    check(amcl_freeze_ohos_temp_directory(&s,"/changed")==0&&amcl_ohos_temp_directory(&s)==root,"immutable exact bytes");
    AmclOhosTempDirectory bad=AMCL_OHOS_TEMP_INITIALIZER;
    check(amcl_freeze_ohos_temp_directory(&bad,"relative")==EINVAL,"relative fails");
    check(std::string(amcl_ohos_temp_directory(&bad))=="/tmp"&&bad.error==EINVAL,"failure not success");
    AmclOhosTempDirectory longRoot=AMCL_OHOS_TEMP_INITIALIZER;
    check(amcl_freeze_ohos_temp_directory(&longRoot,("/"+std::string(4095,'x')).c_str())==ENAMETOOLONG,"no truncation");
    unsigned count=0;
    for(mode=0;mode<7;++mode)for(uid_t uid:{uid_t(0),uid_t(20020237),std::numeric_limits<uid_t>::max()}){
        char* actual=get_user_name(uid);
        if(mode==0)check(actual&&std::string(actual)=="uid_"+std::to_string((unsigned long long)uid),"actual UID identity");
        else if(mode==6)check(actual&&std::string(actual)=="named_user","real name retained");
        else check(actual==NULL,"error or malformed entry rejected");
        release(actual);check(live==0,"buffer lifetime");++count;
    }
    printf("PASS actual snapshot + UID production functions: %u UID cases\n",count);
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sources-root', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    output = external_output_path(args.output)
    output.mkdir(parents=True, exist_ok=False)
    inputs = json.loads((ROOT / 'tests/runtime-native-temp/source-inputs.json').read_text(encoding='utf-8'))
    env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
    rows = []
    for major, expected in inputs['majors'].items():
        area = output / major
        target = area / 'source'; target.mkdir(parents=True)
        patchdir = area / 'patches'; patchdir.mkdir()
        selected = []
        for name, sha in expected['patches'].items():
            source = ROOT / 'prebuilt/jdk' / major / 'patches' / name
            data = source.read_bytes()
            if digest(data) != sha:
                raise ValueError('正式补丁变化，需要review并更新明确source fixture: ' + name)
            shutil.copyfile(source, patchdir / name); selected.append(name)
        (patchdir / 'series').write_text('\n'.join(selected) + '\n', encoding='utf-8', newline='\n')
        for name, sha in expected['files'].items():
            source = args.sources_root / major / name
            if source.is_symlink() or not source.resolve().is_relative_to(args.sources_root.resolve()) or digest(source.read_bytes()) != sha:
                raise ValueError('source postimage identity mismatch: ' + str(source))
            dest = target / name; dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(source.read_bytes().replace(b'\r\n', b'\n'))

        def command(*argv, succeeds=True):
            result = subprocess.run([str(a) for a in argv], cwd=target, env=env, capture_output=True)
            with (area / 'commands.log').open('ab') as log:
                log.write(repr(argv).encode('utf-8') + b'\n' + result.stdout + result.stderr + b'\n')
            if (result.returncode == 0) != succeeds:
                raise AssertionError(result.stdout + result.stderr)
            return result

        for name in reversed(selected):
            command('git', '-c', 'core.autocrlf=false', 'apply', '--reverse', patchdir / name)
        command('git', 'init', '-q')
        command('git', 'config', 'core.autocrlf', 'false')
        command('git', 'add', '--', '.')
        command('git', '-c', 'user.name=AMCL source fixture', '-c', 'user.email=tests@invalid',
                'commit', '-qm', 'Selected recorded preimages, not an upstream commit')
        runner = ROOT / 'docker/scripts/apply_jdk_patches.py'
        for _ in range(2):
            command(sys.executable, '-B', runner, '--target', target, '--patch-dir', patchdir)
            for name, sha in expected['files'].items():
                assert digest((target / name).read_bytes()) == sha
        perf = next(name for name in expected['files'] if '/perfMemory_' in name)
        header = next(name for name in expected['files'] if name.endswith('/ohos_temp_directory.hpp'))
        (area / 'actual_temp.hpp').write_bytes((target / header).read_bytes())
        body = function((target / perf).read_text(encoding='utf-8'), 'static char* get_user_name(uid_t uid)')
        driver = area / 'actual.cpp'
        driver.write_text(PREFIX + body + SUFFIX, encoding='utf-8', newline='\n')
        binary = area / ('actual.exe' if os.name == 'nt' else 'actual')
        compile_cpp(driver, binary, defines=('__OHOS__',))
        command(binary)
        # 原新增文件发生未知修改时必须拒绝，且全部文件保持本次故障前的字节。
        with (target / header).open('ab') as file:
            file.write(b'\n// unknown fixture change\n')
        snapshot = {name: (target / name).read_bytes() for name in expected['files']}
        failure = command(sys.executable, '-B', runner, '--target', target, '--patch-dir', patchdir, succeeds=False)
        assert '未知修改'.encode('utf-8') in failure.stdout + failure.stderr
        assert all((target / name).read_bytes() == data for name, data in snapshot.items())
        rows.append({'major': major, 'patches': expected['patches'], 'postimages': expected['files'],
                     'replayAndIdempotence': True, 'actualFunctionCases': 21, 'unknownChangePreserved': True})
        print('PASS native temp source ' + major, flush=True)
    (output / 'result.json').write_text(json.dumps({'recordedAt': datetime.now().astimezone().isoformat(),
        'sourceFixtureSha256': digest((ROOT / 'tests/runtime-native-temp/source-inputs.json').read_bytes()),
        'results': rows, 'scope': 'selected source replay + actual host functions; target runtime qualification separate'},
        ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
