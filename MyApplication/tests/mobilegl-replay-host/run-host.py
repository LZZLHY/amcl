#!/usr/bin/env python3
"""既有MobileGL CMake/CLI的受控host调度；无GL/SSIM实现，无产品准入写入。

输入必须是完整钉版Git种子或已验证host制品。输出始终显式仓外、每case独立进程；
源码快照只在外部测试树应用已审Linux声明差异，主消费fork/库/pin保持不动。
"""
from pathlib import Path
from datetime import datetime,timezone
import argparse,hashlib,json,os,re,shutil,struct,subprocess,tarfile,time,zlib

def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def call(args,**kwargs):return subprocess.run(args,check=True,**kwargs)
def git(source,*args):return subprocess.check_output(['git','-c','safe.directory=*','-C',str(source),*args],text=True).strip()
def snapshot(source,dest,pin):
 """从Git原始objects展开，逐子模块验证HEAD；不复制dirty正文、凭据或旧构建缓存。"""
 actual=git(source,'rev-parse','HEAD')
 if actual!=pin:raise ValueError('Source seed pin differs: '+str(source))
 if dest.exists() and any(dest.iterdir()):raise ValueError('Refusing existing snapshot contents: '+str(dest))
 dest.mkdir(parents=True,exist_ok=True)
 archive=dest.parent/(dest.name+'-git.tar')
 with archive.open('wb') as f:call(['git','-C',str(source),'archive',pin],stdout=f)
 with tarfile.open(archive) as tar:tar.extractall(dest,filter='data')
 # CMake需要主仓Git身份；复制Git对象metadata，不复制工作区源码或system环境。
 call(['git','init',str(dest)],stdout=subprocess.DEVNULL)
 call(['git','-C',str(dest),'fetch','--no-tags',str(source),pin],stdout=subprocess.DEVNULL)
 call(['git','-C',str(dest),'reset','--mixed',pin],stdout=subprocess.DEVNULL)
 for line in git(source,'ls-tree','-r',pin).splitlines():
  fields=line.split(None,3)
  if fields[0]=='160000':
   # 原CMake明确disabled的可选目录无需伪装已初始化；必需项仍精确pin或失败。
   if fields[3] in ['3rdparty/DiligentCore','3rdparty/tracy','frametrim/tests']:continue
   snapshot(source/fields[3],dest/fields[3],fields[2])
 # glslang依照上游known_good恢复的external仓不是gitlink，也必须绑定实取commit。
 if (source/'known_good.json').is_file():
  for item in json.loads((source/'known_good.json').read_text())['commits']:
   if item['name']=='googletest':continue
   child=source/item['subdir']
   if child.is_dir() and (not (dest/item['subdir']).exists() or not any((dest/item['subdir']).iterdir())):snapshot(child,dest/item['subdir'],git(child,'rev-parse',item['commit']))

def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--source',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
 p.add_argument('--expected-source',required=True);p.add_argument('--case',default='OpenRA',choices=['OpenRA'])
 p.add_argument('--backends',nargs='+',choices=['DirectGLES','DirectVulkan'],default=['DirectGLES','DirectVulkan'])
 p.add_argument('--artifacts',type=Path,help='明确已验证host制品目录；必须提供build-source.json而非借未绑定旧库')
 p.add_argument('--artifact-proof-sha',help='调用方独立选择的build-source.json实际SHA，禁止收据自身验证自身')
 p.add_argument('--icd',type=Path);p.add_argument('--icd-source',type=Path);p.add_argument('--jobs',type=int,default=6)
 p.add_argument('--mode',choices=['positive','controls'],default='positive');args=p.parse_args()
 project=Path(__file__).resolve().parents[2];source=args.source.resolve();output=args.output.resolve()
 if output==project or project in output.parents:raise ValueError('Output must be explicitly outside checkout')
 if not re.fullmatch('[0-9a-f]{40}',args.expected_source):raise ValueError('Expected exact independently selected source commit')
 if git(source,'rev-parse','HEAD')!=args.expected_source:raise ValueError('Source seed differs from independently selected full commit')
 if not 1<=args.jobs<=8:raise ValueError('Host jobs outside bounded range')
 output.mkdir(parents=True,exist_ok=False)
 host_delta=Path(__file__).with_name('host-glx-display.patch');delta_sha=sha(host_delta)
 if args.artifacts:
  built=args.artifacts.resolve();proof_path=built/'build-source.json'
  if not re.fullmatch('[0-9a-f]{64}',args.artifact_proof_sha or '') or sha(proof_path)!=args.artifact_proof_sha:raise ValueError('Reusable artifact proof differs from independent host SHA')
  proof=json.loads(proof_path.read_text())
  if proof['sourceCommit']!=args.expected_source or proof['hostDeltaSha256']!=delta_sha:raise ValueError('Reusable host source/delta differs')
  for name in ['libMobileGL.so','mobilegl_trace_replay']:
   if sha(built/name)!=proof['files'][name]['sha256']:raise ValueError('Reusable host bytes differ: '+name)
 else:
  seed=source;source=output/'source';snapshot(seed,source,args.expected_source)
  # Git archive的LFS对象可能只是pointer；仅本次固定已实取fixture从独立seed补足。
  for name in ['openra.tgz','openra.0000031249.png']:shutil.copyfile(seed/'tools/trace_replay/fixtures'/name,source/'tools/trace_replay/fixtures'/name)
  call(['git','-C',str(source),'apply','--check',str(host_delta)]);call(['git','-C',str(source),'apply',str(host_delta)])
  built=output/'build'
  loader=Path('/lib/x86_64-linux-gnu/libvulkan.so.1')
  call(['cmake','-S',str(source),'-B',str(built),'-G','Ninja','-DCMAKE_BUILD_TYPE=Release','-DMOBILEGL_BUILD_TEST=OFF','-DMOBILEGL_BUILD_BENCHMARK=OFF','-DMOBILEGL_ENABLE_TRACY=OFF','-DMOBILEGL_BUILD_TRACE_REPLAY=ON','-DVulkan_INCLUDE_DIR='+str(source/'3rdparty/Vulkan-Headers/include'),'-DVulkan_LIBRARY='+str(loader)])
  call(['cmake','--build',str(built),'--target','MobileGL','mobilegl_trace_replay','--parallel',str(args.jobs)])
  artifact=output/'artifacts';artifact.mkdir()
  for src,name in [(built/'libMobileGL.so','libMobileGL.so'),(built/'tools/trace_replay/mobilegl_trace_replay','mobilegl_trace_replay')]:shutil.copyfile(src,artifact/name)
  built=artifact
  proof={'sourceCommit':args.expected_source,'hostDeltaSha256':delta_sha,'sourceFileSha256':sha(source/'MobileGL/MG_Impl/GLXImpl/GLXImpl.cpp'),'files':{n:{'sha256':sha(built/n)} for n in ['libMobileGL.so','mobilegl_trace_replay']}}
  (built/'build-source.json').write_text(json.dumps(proof,indent=2)+'\n')
 # 唯一manifest定义case，runner不复制golden/容差/图元义务。
 # manifest/backend名称从指定commit的对象读取；dirty种子的文字不能改变固定case义务。
 manifest=json.loads(git(source,'show',args.expected_source+':tools/trace_replay/trace_cases.json'));case=dict(manifest['defaults'],**next(c for c in manifest['cases'] if c['name']==args.case))
 golden=source/'tools/trace_replay/fixtures'/case['golden'];archive=source/'tools/trace_replay/fixtures'/case['trace_archive']
 if archive.read_bytes().startswith(b'version https://git-lfs.github.com') or golden.read_bytes().startswith(b'version https://git-lfs.github.com'):raise ValueError('Required actual corpus objects are LFS pointers, NOT_RUN')
 for corpus in [archive,golden]:
  rel=corpus.relative_to(source).as_posix();blob=subprocess.check_output(['git','-c','safe.directory=*','-C',str(source),'show',args.expected_source+':'+rel])
  pointer=re.search(rb'^oid sha256:([0-9a-f]{64})$',blob,re.M)
  wanted=pointer.group(1).decode() if pointer else hashlib.sha256(blob).hexdigest()
  if sha(corpus)!=wanted:raise ValueError('Actual corpus differs from pinned Git/LFS bytes: '+rel)
 call(['cc','-shared','-fPIC','-O2','-std=gnu11',str(Path(__file__).with_name('provider_observer.c')),'-ldl','-o',str(output/'observer.so')])
 work=[(backend,'none') for backend in args.backends] if args.mode=='positive' else [('DirectGLES','no-golden'),('DirectGLES','wrong-golden'),('DirectGLES','wrong-provider')]
 results=[]
 for backend,control in work:
  directory=output/(backend if control=='none' else control);directory.mkdir();(directory/'input').mkdir()
  with tarfile.open(archive) as tar:tar.extractall(directory/'input',filter='data')
  trace=directory/'input'/case['trace_file'];command=[str(built/'mobilegl_trace_replay'),'--trace',str(trace),'--target-call',str(case['target_call']),'--output',str(directory/'output'),'--backend',backend,'--mobilegl-library',str(built/'libMobileGL.so'),'--pbuffer-surface']
  oracle=golden
  if control=='wrong-golden':
   def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data))
   oracle=directory/'black.png';w,h=case['width'],case['height'];oracle.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,6,0,0,0))+chunk(b'IDAT',zlib.compress((b'\0'+b'\0\0\0\xff'*w)*h))+chunk(b'IEND',b''))
  if control!='no-golden':command+=['--golden',str(oracle)]
  for key in ['width','height','crop_x','crop_y','crop_width','crop_height','ssim_threshold']:command+=['--'+key.replace('_','-'),str(case[key])]
  env=dict(os.environ,EGL_PLATFORM='surfaceless',LIBGL_ALWAYS_SOFTWARE='1',LD_PRELOAD=str(output/'observer.so'),AMCL_PROVIDER_OBSERVER_LOG=str(directory/'provider.jsonl'),AMCL_PROVIDER_OBSERVER_MAPS=str(directory/'loaded-maps.txt'),AMCL_PROVIDER_OBSERVER_LIBRARY=str(built/'libMobileGL.so'))
  if args.icd:
   if not args.icd_source:raise ValueError('Explicit ICD requires independently selected actual driver file')
   config=json.loads(args.icd.read_text());config['ICD']['library_path']=str(args.icd_source.resolve())
   selected=directory/'runtime-icd.json';selected.write_text(json.dumps(config,indent=2)+'\n');env['VK_ICD_FILENAMES']=str(selected)
   (directory/'driver-input.json').write_text(json.dumps({'sourceIcdSha256':sha(args.icd),'runtimeIcdSha256':sha(selected),'driverSha256':sha(args.icd_source),'driverPath':str(args.icd_source.resolve())},indent=2)+'\n')
  if control=='wrong-provider':env['AMCL_PROVIDER_OBSERVER_LIBRARY']='/lib/x86_64-linux-gnu/libEGL.so.1'
  runid=env.get('AMCL_RUN_ID','standalone-host-'+str(time.time_ns()));env['AMCL_RUN_ID']=runid;forced=False;started=datetime.now(timezone.utc).isoformat()
  with (directory/'cli.log').open('wb') as log:
   process=subprocess.Popen(command,env=env,stdout=log,stderr=subprocess.STDOUT)
   try:code=process.wait(timeout=case['timeout_seconds'])
   except subprocess.TimeoutExpired:forced=True;process.kill();code=process.wait()
  invocation={'sourceCommit':args.expected_source,'pid':process.pid,'runId':runid,'backend':backend,'exitCode':code,'forcedKill':forced,'providerCanonical':str((built/'libMobileGL.so').resolve()),'providerSha256':sha(built/'libMobileGL.so'),'executableSha256':sha(built/'mobilegl_trace_replay'),'traceSha256':sha(trace),'goldenSha256':sha(golden),'candidate':{'patchSha256':delta_sha},'command':command,'startedAt':started,'finishedAt':datetime.now(timezone.utc).isoformat()}
  (directory/'invocation.json').write_text(json.dumps(invocation,indent=2)+'\n')
  backend_text=git(source,'show',args.expected_source+':MobileGL/MG_Backend/'+backend+'/BackendObject_'+backend+'.cpp')
  expected={**{k:invocation[k] for k in ['sourceCommit','pid','runId','backend']},'provider':invocation['providerCanonical'],'librarySha256':invocation['providerSha256'],'executable':str(built/'mobilegl_trace_replay'),'executableSha256':invocation['executableSha256'],'tracePath':str(trace),'traceSha256':sha(trace),'goldenPath':str(golden),'goldenSha256':sha(golden),'case':case,'backendDisplayName':re.search(r'\.BackendName\s*=\s*"([^"]+)"',backend_text).group(1),'rendererName':re.search(r'\.RendererName\s*=\s*"([^"]+)"',backend_text).group(1),'hostDeltaSha256':delta_sha,'sourceFile':str(source/'MobileGL/MG_Impl/GLXImpl/GLXImpl.cpp'),'sourceFileSha256':proof['sourceFileSha256'],'icdPath':str(args.icd_source.resolve()) if args.icd_source else None,'icdSha256':sha(args.icd_source) if args.icd_source else None}
  # 原CLI比较后的PNG摘要在独立Popen事务中固定，宿主门稍后重新实取原文件，拒绝后续替换。
  pixel_path=directory/'output/actual.png';expected['actualPngSha256']=sha(pixel_path) if pixel_path.exists() else None
  expected_path=directory/'expected.json';expected_path.write_text(json.dumps(expected,indent=2)+'\n')
  # 软件图形image只需Python/native工具；Node薄门在宿主执行，避免私自给image装runtime。
  # 此处是实际字节取证，独立expected来自Popen事务与入参，不从native报告倒填身份。
  result_path=directory/'output/result.json';provider_path=directory/'provider.jsonl';pixel_path=directory/'output/actual.png'
  result_bytes=result_path.read_bytes();provider_bytes=provider_path.read_bytes()
  try:actual=json.loads(result_bytes);events=[json.loads(x) for x in provider_bytes.decode().splitlines()]
  except Exception:actual=None;events=[]
  evidence={'invocation':invocation,'result':actual,'providerEvents':events,'resultComplete':result_bytes.endswith(b'\n'),'providerComplete':provider_bytes.endswith(b'\n'),
   'librarySha256':sha(built/'libMobileGL.so'),'executableSha256':sha(built/'mobilegl_trace_replay'),'traceSha256':sha(trace),'goldenSha256':sha(golden),
   'actualPngValid':pixel_path.exists() and pixel_path.stat().st_size>=33 and pixel_path.read_bytes()[:8]==b'\x89PNG\r\n\x1a\n',
   'glInfo':(directory/'output/retrace.log').read_text() if (directory/'output/retrace.log').exists() else '',
   'loadedMaps':(directory/'loaded-maps.txt').read_text() if (directory/'loaded-maps.txt').exists() else '',
   'sourceFileSha256':sha(source/'MobileGL/MG_Impl/GLXImpl/GLXImpl.cpp'),'icdSha256':sha(args.icd_source) if args.icd_source else None}
  (directory/'evidence.json').write_text(json.dumps(evidence,indent=2)+'\n')
  checked=None;accepted=code==0 if control=='none' else actual is not None
  results.append({'backend':backend,'control':control,'processExitCode':code,'qualificationExitCode':checked,'accepted':accepted,'directory':str(directory)})
 (output/'results.json').write_text(json.dumps({'scope':'Fixed golden host regression only; not CTS/OHOS/GPU admission','source':proof,'runs':results},indent=2)+'\n')
 return 0 if all(row['accepted'] for row in results) else 1
if __name__=='__main__':
 try:raise SystemExit(main())
 except Exception as error:print('MobileGL host NOT_RUN/ERROR:',type(error).__name__,str(error),file=__import__('sys').stderr);raise SystemExit(2)
