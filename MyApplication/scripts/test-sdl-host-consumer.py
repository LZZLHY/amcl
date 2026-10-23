"""普通构建/CI共同SDL宿主组合门：真实checkout→全新锁定SDK→真实owned消费。

既有CI已取得exact SDL源码，此入口只读取给定Git仓中的pin并archive，不每次克隆。
每次用独占仓外输出，失败完整传播；Windows/Linux都执行相同场景而不是伪skip。
"""
from pathlib import Path
from datetime import datetime
import argparse
import json
import os
import re
import subprocess
import sys
import uuid
sys.dont_write_bytecode=True
from lib.workspace_paths import external_output_path,workspace_path
ROOT=Path(__file__).resolve().parents[1]

def main():
    """先确认真实source前置，然后按同一不可省略顺序执行原入口，保存实际命令/时间。"""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-repo',default=os.environ.get('AMCL_SDL_TEST_REPO'))
    parser.add_argument('--out');parser.add_argument('--build-out');args=parser.parse_args()
    if not args.source_repo:raise ValueError('AMCL_SDL_TEST_REPO or --source-repo must name an existing Git repository containing the locked SDL commit; CI must run its exact-source materialization step first')
    repo=Path(args.source_repo).resolve()
    if not repo.is_dir():raise FileNotFoundError('SDL source repository does not exist: '+str(repo))
    lock=(ROOT/'deps.lock').read_text(encoding='utf-8');section=re.search(r'^\[sdl3-native\]\s*\n([\s\S]*?)(?=^\[|\Z)',lock,re.M).group(1)
    pin=re.search(r'^commit\s*=\s*([a-f0-9]{40})',section,re.M).group(1)
    checked=subprocess.run(['git','-C',str(repo),'cat-file','-e',pin+'^{commit}'],capture_output=True)
    if checked.returncode:raise ValueError('SDL source repository lacks deps.lock commit '+pin+': '+checked.stderr.decode(errors='replace').strip())
    task='sdl-host-'+str(os.getpid())+'-'+uuid.uuid4().hex[:6]
    out=external_output_path(args.out) if args.out else workspace_path('run',task)
    build=external_output_path(args.build_out) if args.build_out else workspace_path('build',task)
    out.mkdir(parents=True,exist_ok=False);build.mkdir(parents=True,exist_ok=False)
    started=datetime.now().astimezone().isoformat();commands=[];state='Running'
    def stage(name,arguments):
        """前台显示原子门全部输出，不丢失败、编译负控或恢复；只调用现有真实测试。"""
        command=[sys.executable,'-B',str(ROOT/'scripts'/name),*map(str,arguments)]
        item={'command':command,'startedAt':datetime.now().astimezone().isoformat()};commands.append(item)
        print('[SDL host combination] '+' '.join(command),flush=True)
        result=subprocess.run(command)
        item.update(exitCode=result.returncode,finishedAt=datetime.now().astimezone().isoformat())
        if result.returncode:raise RuntimeError('SDL host combination failed: '+name+' exit '+str(result.returncode))
    try:
        stage('test-sdl-control-header-checkout.py',['--output',out/'headers','--build-root',build/'headers'])
        # 每轮新SDK树完整执行默认原正反/restored，不接受预先存在同名库或production-only。
        sdk=build/'sdk'
        stage('test-sdl-control-delivery.py',['--source-repo',repo,'--out',sdk])
        stage('test-sdl-owned-text-consumption.py',['--sdk-host-tree',sdk,'--out',out/'owned','--build-out',build/'owned'])
        state='PASS'
    except Exception:
        # 失败阶段保持原始退出/日志；组合收据明确FAIL，不让结束的实验遗留Running身份。
        state='FAIL'
        raise
    finally:
        (out/'receipt.json').write_text(json.dumps({'startedAt':started,'completedAt':datetime.now().astimezone().isoformat(),
          'state':state,'sourceRepository':str(repo),'pin':pin,'platform':sys.platform,'commands':commands,
          'scope':'actual native host SDL checkout/full SDK control/owned text; no device/game ACK claim'},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('PASS SDL host combination: '+str(out),flush=True)

if __name__=='__main__':main()
