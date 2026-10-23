"""按已核官方CTS7项锁获取全新external输入，保真实下载/Git收据；不安装全局。

只写显式CTS的新src与新仓外输出。拒覆盖已有src，不调用clean/reset，不替换URL/tag，
归档SHA或Git完整commit不成立即失败并保原收据。本候选阶段不执行下载。
"""
from pathlib import Path
from datetime import datetime,timezone
import argparse,hashlib,json,shutil,subprocess,tarfile,urllib.request

def sha(path):
    """校验原始字节，不以解包名称或下载成功代替供应链身份。"""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def main():
    """先验证所有7项目的地为空与官方输入脚本，再前台顺序获取、保存每项成败。"""
    parser=argparse.ArgumentParser(description=__doc__)
    for key in ('cts','output'):parser.add_argument('--'+key,type=Path,required=True)
    args=parser.parse_args();cts=args.cts.resolve();output=args.output.resolve()
    lockfile=Path(__file__).with_name('external-inputs.json');lock=json.loads(lockfile.read_text())
    head=subprocess.check_output(['git','-C',str(cts),'rev-parse','HEAD'],text=True).strip()
    if head!=lock['ctsCommit'] or output.exists() or cts in output.parents:raise ValueError('new external output and exact CTS commit required')
    if subprocess.check_output(['git','-C',str(cts),'status','--porcelain','--untracked-files=no'],text=True).strip():raise ValueError('official tracked CTS sources changed')
    rows=lock['inputs'];names={x['name'] for x in rows}
    if len(rows)!=7 or names!={'zlib','libpng','spirv-tools','glslang','spirv-headers','amber','jsoncpp'}:raise ValueError('fixed official seven input list differs')
    official=cts/'external/fetch_sources.py'
    for row in rows:
        if sha(official)!=row['officialScriptSha256'] or (cts/'external'/row['name']/'src').exists():raise ValueError('official input changed or existing src: '+row['name'])
    output.mkdir(parents=True,exist_ok=False);results=[]
    for row in rows:
        record={**row,'startedAt':datetime.now(timezone.utc).isoformat()}
        destination=(cts/'external'/row['name']/'src').resolve()
        if not destination.is_relative_to(cts/'external'):raise ValueError('external destination escapes CTS')
        try:
            with (output/(row['name']+'.log')).open('x') as log:
                if row['officialType']=='GitRepo':
                    destination.mkdir(parents=True,exist_ok=False)
                    commands=[['git','init',str(destination)],['git','-C',str(destination),'remote','add','origin',row['url']],
                              ['git','-C',str(destination),'fetch','--depth','1','origin',row['commit']],
                              ['git','-C',str(destination),'checkout','--detach','FETCH_HEAD']]
                    for command in commands:subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True)
                    actual=subprocess.check_output(['git','-C',str(destination),'rev-parse','HEAD'],text=True).strip()
                    if actual!=row['commit']:raise ValueError('actual external commit differs')
                    record['actualCommit']=actual
                else:
                    archive=output/(row['name']+'.tar.gz')
                    with urllib.request.urlopen(row['url'],timeout=120) as response,archive.open('xb') as stream:
                        shutil.copyfileobj(response,stream)
                    actual=sha(archive)
                    if actual!=row['archiveSha256']:raise ValueError('official archive checksum differs')
                    stage=output/(row['name']+'-extract');stage.mkdir()
                    with tarfile.open(archive) as tar:
                        tops={x.name.split('/')[0] for x in tar.getmembers()}
                        if len(tops)!=1:raise ValueError('archive top-level shape differs')
                        tar.extractall(stage,filter='data')
                    extracted=stage/next(iter(tops));destination.mkdir(parents=True,exist_ok=False)
                    for entry in extracted.iterdir():shutil.move(str(entry),str(destination/entry.name))
                    record['actualArchiveSha256']=actual
                    if row['name']=='libpng':
                        shutil.copyfile(destination/'scripts/pnglibconf.h.prebuilt',destination/'pnglibconf.h')
                        record['postExtractPngConfigSha256']=sha(destination/'pnglibconf.h')
                record['exitCode']=0
        except (OSError,ValueError,tarfile.TarError,subprocess.CalledProcessError) as error:
            record.update(exitCode=1,error=str(error))
        record['finishedAt']=datetime.now(timezone.utc).isoformat();results.append(record)
        (output/(row['name']+'.json')).write_text(json.dumps(record,indent=2)+'\n')
        if record['exitCode']:break
    receipt={'ctsCommit':head,'lockSha256':sha(lockfile),'rows':results,'completed':len(results)==7 and all(x['exitCode']==0 for x in results),'scope':'actual exact external source acquisition only; no build/GPU qualification'}
    (output/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');return 0 if receipt['completed'] else 1

if __name__=='__main__':raise SystemExit(main())
