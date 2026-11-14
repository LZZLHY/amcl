#!/usr/bin/env python3
"""实物回归：R9三个正确依赖包必须过，原25必须因缺JNU依赖失败；实际SDK链接作正负控。
仅把ZIP内DSO解析为事实，不执行目标代码；JNU薄探针不是新运行包或完整JDK资格。
"""
import argparse,hashlib,json,shutil,subprocess,sys,zipfile
from datetime import datetime
from pathlib import Path

def sha(path):
    with path.open('rb') as handle:return hashlib.file_digest(handle,'sha256').hexdigest()

def main():
    sys.dont_write_bytecode=True
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--ledger',type=Path,required=True)
    parser.add_argument('--sdk',type=Path,required=True);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();root=Path(__file__).resolve().parents[2];out=args.output.resolve()
    if out==root or root in out.parents:raise ValueError('output must be external')
    out.mkdir(parents=True,exist_ok=False);inputs=out/'inputs';inputs.mkdir()
    for name in ('package_runtime.py','midi_runtime_gate.py','verify_jdk_ports.py','verify_jdk_abi.py'):
        shutil.copyfile(root/'docker/scripts'/name,inputs/name)
    sys.path.insert(0,str(inputs));from package_runtime import elf_facts,validate_sound_symbols
    state=json.loads(args.ledger.read_text());rows=[];last=None
    for major in ('8','17','21','25'):
        entry=state['runtimes'][major];archive=Path(entry['runtime']['file']);assert sha(archive)==entry['runtime']['sha256']
        producer=json.loads(Path(entry['inputManifest']).read_text());sdk_libs=Path(producer['systemLibraryDir'])
        native='jre/lib/aarch64/' if major=='8' else 'lib/';sound=native+'libjsound.so'
        facts={}
        with zipfile.ZipFile(archive) as content:
            for name in content.namelist():
                if '.so' in name.rsplit('/',1)[-1]:facts[name]=elf_facts(content.read(name))
            if major=='25':
                directory=out/'jdk25';directory.mkdir()
                (directory/'libjava.so').write_bytes(content.read(native+'libjava.so'))
                last=(facts,sound,sdk_libs,directory)
        try:proof=validate_sound_symbols(facts,sound,sdk_libs)
        except ValueError as error:
            assert major=='25' and str(error).endswith('JNU_ThrowByName'),str(error)
            rows.append({'major':major,'archiveSha256':entry['runtime']['sha256'],'expectedRejected':str(error),
                         'soundNeeded':facts[sound]['needed'],'actualJavaExportsJnu':'JNU_ThrowByName' in facts[native+'libjava.so']['resolvableExports']})
        else:
            assert major!='25','old25 incorrectly accepted'
            rows.append({'major':major,'archiveSha256':entry['runtime']['sha256'],'proof':proof})
    facts,sound,sdk_libs,directory=last;sdk=args.sdk.resolve();suffix='.exe' if sys.platform=='win32' else ''
    clang=sdk/'llvm/bin'/('clang'+suffix);readelf=sdk/'llvm/bin'/('llvm-readelf'+suffix)
    source=out/'jni-link-probe.c';source.write_text('''/* 只证明JNU真实链接选择；不执行、不代替完整libjsound。 */
extern void JNU_ThrowByName(void*, const char*, const char*);
void AMCL_SoundLinkProbe(void* env) { JNU_ThrowByName(env, "java/lang/Error", "link-only probe"); }
''',encoding='utf-8')
    commands=[]
    for linked in (False,True):
        name='linked' if linked else 'original';output=out/(name+'.so')
        argv=[str(clang),'--target=aarch64-linux-ohos','--sysroot='+str(sdk/'sysroot'),'-shared','-fPIC','-O1',
              '-Wall','-Wextra','-Werror','-Wl,-soname,libjsound.so',str(source)]
        if linked:argv+=['-Wl,--as-needed','-Wl,--no-undefined','-Wl,--allow-shlib-undefined','-L'+str(directory),'-ljava']
        argv+=['-o',str(output)]
        result=subprocess.run(argv,capture_output=True);(out/(name+'-link.log')).write_bytes(result.stdout+result.stderr)
        assert result.returncode==0,(out/(name+'-link.log')).read_text()
        actual=elf_facts(output.read_bytes());assert 'JNU_ThrowByName' in actual['strongImports']
        assert ('libjava.so' in actual['needed']) is linked
        test=dict(facts);test[sound]=actual
        if linked:
            proof=validate_sound_symbols(test,sound,sdk_libs);assert 'libjava.so' in proof['suppliers']
        else:
            try:validate_sound_symbols(test,sound,sdk_libs)
            except ValueError as error:assert 'JNU_ThrowByName' in str(error)
            else:raise AssertionError('SDK unlinked JNU probe accepted')
        text=subprocess.check_output([str(readelf),'-d','--dyn-symbols','--wide',str(output)])
        (out/(name+'-readelf.txt')).write_bytes(text)
        commands.append({'linked':linked,'argv':argv,'sha256':sha(output),'needed':actual['needed']})
    identities={p.name:sha(p) for p in inputs.iterdir() if p.is_file()}
    for name,value in identities.items():assert sha(root/'docker/scripts'/name)==value,'producer changed during audit'
    receipt={'at':datetime.now().astimezone().isoformat(),'result':'PASS','scope':'actual old runtime dependency gate and real AArch64 link only; final25 full rebuild/device load still required',
       'inputs':identities,'actualRuntimes':rows,'sdkLinkProbes':commands,'compilerSha256':sha(clang),
       'actualJavaProviderSha256':sha(directory/'libjava.so')}
    (out/'receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('PASS actual R9 sound closures: 8/17/21 accepted, original25 rejected; SDK original/explicit -ljava negative and positive')
if __name__=='__main__':main()
