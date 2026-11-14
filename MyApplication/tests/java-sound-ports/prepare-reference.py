#!/usr/bin/env python3
"""从项目锁定提交读取Ports原文；只写显式新外置目录，原文SHA和URL逐项保留。"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import hashlib,json
from pathlib import Path
import urllib.request

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--reuse',type=Path,help='optional prior source directory with receipt.json and matching locked hashes')
    args=parser.parse_args();output=args.output.resolve();output.mkdir(parents=True,exist_ok=False)
    project=Path(__file__).resolve().parents[2];lock=json.loads((project/'prebuilt/jdk/build-inputs.json').read_text())
    previous=args.reuse.resolve() if args.reuse else None
    prior={}
    if previous and (previous/'receipt.json').is_file():
        for item in json.loads((previous/'receipt.json').read_text())['files']:prior[(item['major'],item['path'])]=item
    jobs=[]
    for major,identity in lock['runtimes'].items():
        classic=major=='8';classes='jdk/src/share/classes/' if classic else 'src/java.desktop/share/classes/'
        native='jdk/src/share/native/com/sun/media/sound/' if classic else 'src/java.desktop/share/native/libjsound/'
        items=[classes+'com/sun/media/sound/'+name for name in ('PortMixer.java','PortMixerProvider.java')]
        items += [native+'PortMixerProvider.c']
        # 锁定25已移除旧Platform.c；该代不为构建/测试虚构一个上游文件。
        if major!='25':items.append(native+'Platform.c')
        items += ['jdk/make/lib/SoundLibraries.gmk' if classic else 'make/modules/java.desktop/Lib.gmk']
        if classic:items += ['jdk/make/mapfiles/'+name+'/mapfile-vers' for name in ('libjsound','libjsoundalsa')]
        for path in items:jobs.append((major,identity,path))
    def fetch(job):
        major,identity,path=job;repo=identity['repository'].removesuffix('.git').removeprefix('https://github.com/')
        url='https://raw.githubusercontent.com/'+repo+'/'+identity['commit']+'/'+path
        record=prior.get((major,path));old=previous/major/path if previous else None
        if record and old and old.is_file():
            data=old.read_bytes();assert hashlib.sha256(data).hexdigest()==record['sha256'] and record['commit']==identity['commit']
            source='verified previously acquired upstream bytes'
        else:
            data=urllib.request.urlopen(url,timeout=30).read();source='HTTPS exact OpenJDK commit'
        name='mapfile-'+Path(path).parent.name if Path(path).name=='mapfile-vers' else Path(path).name
        target=output/major/name;target.parent.mkdir(exist_ok=True)
        target.write_bytes(data)
        return {'major':major,'path':path,'file':str(target),'url':url,'commit':identity['commit'],
                'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data),'acquisition':source}
    with ThreadPoolExecutor(max_workers=4) as pool:files=list(pool.map(fetch,jobs))
    receipt={'schemaVersion':1,'at':datetime.now().astimezone().isoformat(),'files':files}
    (output/'source.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'output':str(output),'files':len(files)}))

if __name__=='__main__':main()
