"""直接编译生产owner函数；fake EGL/broker只模拟外部边界，负控验证关键拒绝可失败。"""
from pathlib import Path
from datetime import datetime
import argparse,hashlib,json,subprocess
from lib.host_cpp import compile_cpp
p=argparse.ArgumentParser();p.add_argument('--output',required=True);a=p.parse_args()
repo=Path(__file__).resolve().parents[1];platform=repo/'entry/src/main/cpp/platform';out=Path(a.output).resolve();out.mkdir(exist_ok=False)
features=(platform/'graphics_features.cpp').read_text();egl=(platform/'graphics_egl_context.cpp').read_text();aux=(platform/'sdl_aux_runtime.cpp').read_text()
def function(text,name):
    # 这些函数没有字符串花括号；从完整签名开始取平衡函数体，不重写逻辑。
    import re
    match=re.search(r'^(?:static )?(?:bool|void) '+name+r'\([^;]*?\) \{',text,re.M);assert match,name
    start=match.start();i=match.end();depth=1
    while depth:
        if text[i]=='{':depth+=1
        elif text[i]=='}':depth-=1
        i+=1
    return text[start:i]
blocks={'FEATURES':'\n'.join(function(features,n)for n in ['CommitGraphicsContext','RetireGraphicsContext','ReleaseGraphicsContextPermit','RecordPresentingEglSurface','RevokePresentingEglSurface']),
        'VERIFY':function(aux,'VerifiedPresentingEgl'),'CREATED':function(egl,'created'),'RETIRING':function(egl,'retiringSurface'),'ATTACHED':function(egl,'attached')}
template=(repo/'entry/src/main/cpp/tests/host/sdl_aux_surface.cpp.in').read_text()
for name,value in blocks.items():template=template.replace('@'+name+'@',value)
negative=template.replace('if(surface==runtime.features->presentingSurfaces.end() || !surface->second.matches(proof))return false;','/* negative: skip physical association */')
assert negative!=template
results=[]
for name,text,wanted in [('production',template,0),('missing-physical-record',negative,7)]:
    source=out/(name+'.cpp');binary=out/(name+'.exe');source.write_text(text,encoding='utf-8')
    compile_cpp(source,binary,includes=[platform,repo/'entry/src/main/cpp/glfw'])
    run=subprocess.run([str(binary)],capture_output=True,timeout=15)
    (out/(name+'.stdout')).write_bytes(run.stdout);(out/(name+'.stderr')).write_bytes(run.stderr)
    results.append({'case':name,'exitCode':run.returncode,'expected':wanted,'passed':run.returncode==wanted,'sourceSha256':hashlib.sha256(source.read_bytes()).hexdigest()})
    print(name,run.returncode,run.stdout.decode(),run.stderr.decode())
    if run.returncode==wanted:binary.unlink();binary.with_suffix('.obj').unlink(missing_ok=True)
(out/'receipt.json').write_text(json.dumps({'at':datetime.now().astimezone().isoformat(),'results':results,'scope':'actual owner functions; external EGL/broker fakes; not device'},indent=2)+'\n')
assert all(r['passed']for r in results)
