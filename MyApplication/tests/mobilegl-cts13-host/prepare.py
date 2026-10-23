"""为全新明确CTS checkout接入fork原platform和只读owner观察，保存来源delta。

仅接受官方4.6.8.1真实commit与固定mustpass；不会下载、checkout、清理、覆盖旧port
或修改case实现。source目录必须由调用者准备；本工具将受控新增port/targets归入
CTS实验输入，不把这些新增或JsonCpp stock生成正文冒称官方clean原始树。
"""
from pathlib import Path
from datetime import datetime,timezone
import argparse,difflib,hashlib,json,re,shutil,subprocess

CTS_COMMIT='067e8832315e79817ede1c4863804e440f5d1c80'
MUSTPASS_SHA='c77e9da87383c9aa4db4bdce9c71225b72444eb4963e8dbc17e8dd574c51aea4'

def sha(path):
    """收取实际原文、生成物摘要，配套receipt不依赖本机绝对路径。"""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def require(value,message):
    """拒绝已有或不匹配输入，避免污染其它实验；Python-O同样执行。"""
    if not value:raise ValueError(message)

def prepare(cts,source,output,expected_source,expected_port_sha):
    """先核身份/目标不存在，再调用所属fork同步工具并只追加观察；返回实际来源表。"""
    git=lambda root,*argv:subprocess.check_output(['git','-C',str(root),*argv],text=True).strip()
    require(git(cts,'rev-parse','HEAD')==CTS_COMMIT,'official CTS commit differs')
    require(not git(cts,'status','--porcelain','--untracked-files=no'),'official tracked CTS sources changed')
    require(git(source,'rev-parse','HEAD')==expected_source and not git(source,'status','--porcelain'),'selected fork source not clean/pinned')
    destinations=['framework/platform/mobilegl','targets/mobilegl','targets/mobilegl-desktop']
    require(all(not (cts/x).exists() for x in destinations),'existing CTS platform/target must not be overwritten')
    require(not output.exists() and cts not in output.parents and source not in output.parents,'receipt output must be new and external')
    here=Path(__file__).resolve().parent;cases=(here/'cases13.txt').read_text().splitlines()
    mustpass=cts/'external/openglcts/data/gl_cts/data/mustpass/gl/khronos_mustpass/main/gl33-main.txt'
    require(sha(mustpass)==MUSTPASS_SHA and len(cases)==13 and len(set(cases))==13 and all(mustpass.read_text().splitlines().count(x)==1 for x in cases),'official fixed13 mustpass identity differs')
    original=source/'tools/cts/platform/tcuMobileGLPlatform.cpp';require(sha(original)==expected_port_sha,'independent original platform input differs')
    sync=source/'tools/cts/scripts/sync_to_cts.py'
    subprocess.run(['python3',str(sync),str(cts)],check=True)
    port=cts/'framework/platform/mobilegl/tcuMobileGLPlatform.cpp';before=port.read_text();text=before
    old='return (glw::GenericFuncType)m_egl.getProcAddress(name);'
    require(text.count(old)==2,'original public loader seams changed; do not guess replacement')
    new='// 仅观察原地址，不接管调用或加入系统fallback。\n        const auto result = (glw::GenericFuncType)m_egl.getProcAddress(name);\n        amcl_cts_observation::observe("GL-loader", name, reinterpret_cast<const void*>(result));\n        return result;'
    text=text.replace(old,new)
    include='#include "eglwLibrary.hpp"';require(text.count(include)==1,'original EGL include seam changed')
    text=text.replace(include,include+'\n#include "amclCtsProviderObservation.hpp"')
    fields=re.findall(r'(egl\w+Func)\s+(\w+);',(cts/'framework/egl/wrapper/eglwFunctions.inl').read_text())
    require(fields,'official EGL function table empty')
    observed='// 派生类只观察原DefaultLibrary真实函数表，调用/返回值仍由原实现承担。\nclass ObservedEglLibrary : public eglw::DefaultLibrary {\npublic:\n    explicit ObservedEglLibrary(const char* name) : eglw::DefaultLibrary(name) {\n'
    for typename,field in fields:observed+='        amcl_cts_observation::observe("EGL-table", "'+typename[:-4]+'", reinterpret_cast<const void*>(m_egl.'+field+'));\n'
    observed+='    }\n};\n\n'
    seam='class EglRenderContext : public glu::RenderContext'
    require(text.count(seam)==1 and text.count('const eglw::DefaultLibrary m_egl;')==1,'original context/table seams changed')
    text=text.replace(seam,observed+seam).replace('const eglw::DefaultLibrary m_egl;','const ObservedEglLibrary m_egl;')
    port.write_text(text,encoding='utf-8',newline='\n')
    header=cts/'framework/platform/mobilegl/amclCtsProviderObservation.hpp'
    shutil.copyfile(here/header.name,header)
    output.mkdir(parents=True,exist_ok=False)
    delta=''.join(difflib.unified_diff(before.splitlines(keepends=True),text.splitlines(keepends=True),fromfile='fork/platform/tcuMobileGLPlatform.cpp',tofile='cts/platform/tcuMobileGLPlatform.cpp'))
    (output/'observer-port.diff').write_text(delta,encoding='utf-8',newline='\n')
    record={'createdAt':datetime.now(timezone.utc).isoformat(),'ctsCommit':CTS_COMMIT,
            'mobileglCommit':expected_source,'mobileglTree':git(source,'rev-parse','HEAD^{tree}'),
            'mustpassSha256':sha(mustpass),'casesSha256':sha(here/'cases13.txt'),'cases':cases,
            'originalPortSha256':sha(original),'syncScriptSha256':sha(sync),'observedPortSha256':sha(port),
            'observationHeaderSha256':sha(header),'observationDeltaSha256':sha(output/'observer-port.diff'),
            'coreGlSourceSha256':sha(cts/'framework/opengl/wrapper/glwInitGL33.inl'),
            'coreEglSourceSha256':sha(cts/'framework/egl/wrapper/eglwInitCore.inl'),
            'fboPatchApplied':False,'scope':'source preparation only; official CTS + fork platform + readonly observer; no GPU qualification'}
    (output/'source-inputs.json').write_text(json.dumps(record,indent=2)+'\n')
    return record

def main():
    """显式全路径与独立pin，不能默用维护者目录；新增目标拒覆盖。"""
    parser=argparse.ArgumentParser(description=__doc__)
    for key in ('cts','source','output'):parser.add_argument('--'+key,type=Path,required=True)
    for key in ('expected-source','expected-port-sha'):parser.add_argument('--'+key,required=True)
    args=parser.parse_args();record=prepare(args.cts.resolve(),args.source.resolve(),args.output.resolve(),args.expected_source,args.expected_port_sha)
    print(json.dumps(record));return 0

if __name__=='__main__':raise SystemExit(main())
