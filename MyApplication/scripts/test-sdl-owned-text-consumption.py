"""永久SDL owned文本宿主门；使用原真实Source/Core/SDK配方，执行生产与三项编译撤回。"""
from pathlib import Path
from datetime import datetime
import argparse
import hashlib
import importlib.util
import json
import re
from types import SimpleNamespace
import sys
sys.dont_write_bytecode=True
from lib.workspace_paths import external_output_path
ROOT=Path(__file__).resolve().parents[1]

def verify_sdk_tree(sdk):
    """只回读新控制门机器实取的完整SDK绑定；缺失/替换/正文漂移在编译前拒绝。

    旧实验没有这个身份就保持未验证，不补字段。所有路径均是固定契约，摘要不能
    用自己的小集合或外部路径替代必需SDK正文；raw identity不作换行宽免。
    """
    sdk=Path(sdk).resolve();summary=sdk/'summary.json';proof=json.loads(summary.read_text(encoding='utf-8'))
    lock=(ROOT/'deps.lock').read_text(encoding='utf-8')
    section=re.search(r'^\[sdl3-native\]\s*\n([\s\S]*?)(?=^\[|\Z)',lock,re.M).group(1)
    pin=re.search(r'^commit\s*=\s*([a-f0-9]{40})',section,re.M).group(1)
    if proof.get('pin')!=pin:raise ValueError('SDK_PIN_MISMATCH')
    series_path=ROOT/'prebuilt/sdl3/patches/series';series_bytes=series_path.read_bytes()
    series=[line.strip() for line in series_bytes.decode('utf-8').splitlines() if line.strip() and not line.startswith('#')]
    if len(series)!=len(set(series)):raise ValueError('CURRENT_SERIES_DUPLICATE')
    final=proof.get('sdkFinal')
    if not isinstance(final,dict) or final.get('schema')!='sdl-host-sdk-consumption/v1':raise ValueError('SDK_FINAL_IDENTITY_MISSING')
    # 同时校完整集合和实际应用顺序；不能只检查旧摘要愿意给出的patch项。
    if set(proof.get('patches',{}))!=set(series) or final.get('series')!=series:raise ValueError('SDK_SERIES_INCOMPLETE')
    for name in series:
        if hashlib.sha256((ROOT/'prebuilt/sdl3/patches'/name).read_bytes()).hexdigest()!=proof['patches'][name]:raise ValueError('SDK_PATCH_DRIFT:'+name)
    modes={item['mode']:item['exit'] for item in proof['modes']}
    if not final.get('restoredProduction') or modes.get('production')!=0 or modes.get('restored-production')!=0:raise ValueError('SDK_NOT_RESTORED')
    spec=importlib.util.spec_from_file_location('owned_sdk_contract',ROOT/'scripts/test-sdl-control-delivery.py')
    control=importlib.util.module_from_spec(spec);spec.loader.exec_module(control)
    if set(final.get('consumptionSources',{}))!=set(control.SDK_CONSUMPTION_PATHS):raise ValueError('SDK_SOURCE_SET_INCOMPLETE')
    if set(final.get('cmakeExports',{}))!=set(control.SDK_CMAKE_EXPORT_PATHS):raise ValueError('SDK_CMAKE_SET_INCOMPLETE')
    expected_library='build/sdk/Release/SDL3-static.lib' if sys.platform=='win32' else 'build/sdk/libSDL3.a'
    def bound(relative,row,category):
        """检验实际文件size/SHA与固定相对路径；名称一致本身不给来源资格。"""
        if not isinstance(row,dict) or row.get('path')!=relative:raise ValueError(category+'_PATH')
        data=(sdk/relative).read_bytes();observed={'path':relative,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}
        if observed['bytes']!=row.get('bytes') or observed['sha256']!=row.get('sha256'):raise ValueError(category+'_IDENTITY:'+relative)
        return observed
    library=bound(expected_library,final.get('staticLibrary'),'SDK_LIBRARY')
    sources={name:bound(name,final['consumptionSources'][name],'SDK_SOURCE') for name in control.SDK_CONSUMPTION_PATHS}
    exports={name:bound(name,final['cmakeExports'][name],'SDK_CMAKE') for name in control.SDK_CMAKE_EXPORT_PATHS}
    consumer=bound('consumer.c',final.get('generatedConsumer'),'SDK_CONSUMER')
    expected_series={'path':'prebuilt/sdl3/patches/series','bytes':len(series_bytes),'sha256':hashlib.sha256(series_bytes).hexdigest()}
    if final.get('seriesRaw')!=expected_series:raise ValueError('SDK_SERIES_RAW_IDENTITY')
    for name in ('control_delivery.h','control_delivery_client.h'):
        if (sdk/'source/src/video/openharmony'/name).read_bytes()!=(ROOT/'entry/src/main/cpp/input/delivery'/name).read_bytes():raise ValueError('SDK_NEUTRAL_RAW_MIRROR:'+name)
    return {'path':str(summary),'sha256':hashlib.sha256(summary.read_bytes()).hexdigest(),'pin':pin,
      'staticLibrary':library,'consumptionSources':sources,'cmakeExports':exports,'generatedConsumer':consumer,'series':series}

def main():
    """复用完整锁定SDK树；每个case独立前台编译当前完整owner，原断言不依赖假packet。"""
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--sdk-host-tree',required=True)
    parser.add_argument('--out',required=True);parser.add_argument('--build-out',required=True);parser.add_argument('--cmake')
    args=parser.parse_args();out=external_output_path(args.out);build=external_output_path(args.build_out)
    out.mkdir(parents=True,exist_ok=False);build.mkdir(parents=True,exist_ok=False)
    started=datetime.now().astimezone().isoformat()
    sdk_proof=verify_sdk_tree(args.sdk_host_tree)
    spec=importlib.util.spec_from_file_location('owned_text_source_recipe',ROOT/'scripts/test-sdl-source-delivery.py')
    source=importlib.util.module_from_spec(spec);spec.loader.exec_module(source)
    cases=[]
    for name,negative in [('production',None),('read-withdrawn','text-read-withdrawn'),
                          ('release-withdrawn','text-release-withdrawn'),('scalar-withdrawn','text-scalar-withdrawn'),('restored',None)]:
        options=SimpleNamespace(sdk_host_tree=args.sdk_host_tree,out=str(out/name),build_out=str(build/name),
            cmake=args.cmake,reuse_build=False,negative=negative,owned_text=True)
        source.main(options)
        receipt=out/name/'receipt.json';value=json.loads(receipt.read_text(encoding='utf-8'))
        cases.append({'name':name,'negative':negative,'receipt':str(receipt),
            'receiptSha256':hashlib.sha256(receipt.read_bytes()).hexdigest(),'exitCode':value['exitCode'],'sourceDrift':value['sourceDrift']})
    (out/'summary.json').write_text(json.dumps({'startedAt':started,'completedAt':datetime.now().astimezone().isoformat(),
        'cases':cases,'sdkControlProof':sdk_proof,
        'platform':sys.platform,
        'scope':'complete real locked native host SDL + Core/Source/backend; actual SDK text send/Poll and blobs; no OHOS/IME/game ACK claim'},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('PASS permanent SDL owned text production/compiled withdrawals/restored: '+str(out))

if __name__=='__main__':main()
