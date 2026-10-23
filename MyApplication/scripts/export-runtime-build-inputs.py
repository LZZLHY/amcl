"""导出运行时的可公开源码输入：白名单目录、精确 patch/recipe 摘要、固定 ZIP 元数据。

只收集构建所需的自有配方和补丁；上游 OpenJDK/FreeType 通过固定 commit 取源。
不会读取凭据、应用源码、签名材料或 Docker 数据卷。可从指定 Git revision 恢复旧候选
对应输入，不用当前已变化的打包器冒充旧候选的生成配方。
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def git(*args):
    """只读 Git 查询，参数独立传递；失败终止导出，不选择其它版本静默兜底。"""
    return subprocess.check_output(['git','-C',str(ROOT),*args])


def recorded_text_bytes(data, expected, checkout=None):
    """仅按记录摘要恢复文本换行，保留 Git revision 与构建时原字节的双重证明。

    Windows 的既有 CRLF 文件被追加 LF 行后可能含混合换行；Git 会统一为 LF。
    只有本机候选与指定 Git blob 在 CRLF→LF 后完全相同，且原字节摘要精确
    命中构建收据，才可恢复该混合换行。正文变化、二进制和摘要不符均不兜底。
    """
    if hashlib.sha256(data).hexdigest() == expected or b'\0' in data:
        return data, False
    lf = data.replace(b'\r\n', b'\n')
    candidates = [lf, lf.replace(b'\n', b'\r\n')]
    if checkout is not None and b'\0' not in checkout and checkout.replace(b'\r\n', b'\n') == lf:
        candidates.append(checkout)
    for candidate in candidates:
        if hashlib.sha256(candidate).hexdigest() == expected:
            return candidate, True
    return data, False


def main():
    """收据给出主版本与摘要；revision 空时使用当前工作树且同样严格验证。"""
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--manifest', type=Path, required=True)
    p.add_argument('--revision')
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    build = json.loads(args.manifest.read_text(encoding='utf-8'))['build']
    major = build['major']
    assert major in ('8','17','21','25')
    prefixes = ['docker','prebuilt/stubs/src',f'prebuilt/jdk/{major}',
                'prebuilt/jdk/build-inputs.json','deps.lock','scripts/lib/workspace_paths.py']
    if args.revision:
        revision = git('rev-parse',args.revision).decode().strip()
        names = git('ls-tree','-r','--name-only',revision,'--',*prefixes).decode().splitlines()
        files = {name:git('show',revision+':'+name) for name in names}
    else:
        revision = git('rev-parse','HEAD').decode().strip()
        names = git('ls-files','--cached','--others','--exclude-standard','--',*prefixes).decode().splitlines()
        files = {name:(ROOT/name).read_bytes() for name in names if (ROOT/name).is_file()}
    # 特别禁止私有目录与已生成包，即使以后被误跟踪，也不能借此出口公开。
    for name in files:
        if any(part in ('.secrets','output','node_modules') for part in Path(name).parts) or name.endswith(('.pem','.p12','.zip')):
            raise ValueError('non-source path in export: '+name)
    required = {'prebuilt/jdk/build-inputs.json':build['inputsSha256']}
    required.update({f'prebuilt/jdk/{major}/patches/{name}':sha for name,sha in build['patches'].items()})
    for name,sha in build['recipes'].items():
        target = 'docker/'+name
        if name.startswith('../'): target = 'docker/'+name[3:]
        elif target not in files: target = 'docker/scripts/'+name
        required[target] = sha
    checkout_eol = []
    for name,expected in required.items():
        # Git blob 常为 LF，旧 Windows checkout 的 patch 可为 CRLF。只接受摘要能
        # 精确命中原收据的换行物化，不能用“内容相近”跳过身份核验。
        if name in files:
            checkout_path = ROOT / name
            checkout = checkout_path.read_bytes() if checkout_path.is_file() else None
            files[name], materialized = recorded_text_bytes(files[name], expected, checkout)
            if materialized:
                checkout_eol.append(name)
        if name not in files or hashlib.sha256(files[name]).hexdigest()!=expected:
            raise ValueError('recorded input mismatch: '+name+'; choose the actual recipe revision')
    files['build-receipt.json'] = args.manifest.read_bytes()
    identity = {'schemaVersion':1,'gitBase':revision,'workingTree':not bool(args.revision),
                'scope':'explicit runtime build source inputs, excludes SDK/toolchain image',
                'checkoutEolMaterializedToMatchReceipt':checkout_eol,
                'files':{n:hashlib.sha256(b).hexdigest() for n,b in sorted(files.items())}}
    files['source-inputs.json'] = (json.dumps(identity,indent=2)+'\n').encode()
    files['README.rebuild.md'] = f'''# JDK {major} 构建输入

本包的 `source-inputs.json` 记录全部文件摘要；收据所列源码锁定、patch 和核心配方已逐项比对。
这是配方与补丁源码包，不含 OHOS SDK 或宿主工具链镜像。工具链仍需要发布文档登记的固定
本地 image ID、clang/boot JDK 和合法取得的 SDK；不宣称任意机器仅解压此包就可位级复现。

以此目录为构建根，将 `AMCL_WORKSPACE_ROOT` 指到仓外输出位置，按发布仓 README 的
Docker 初始化步骤准备镜像与 SDK。执行 `python -B docker/project.py build --component jdk{major}
--jobs 4 --fresh`（同一行，并按初始化要求指定镜像/SDK）。上游源码由 build-inputs.json 固定，
不会复用 legacy 容器里的源码；产物仍需宿主与真机分层验收。旧候选的打包清单可能含
不同的时间或打包版本，新输出必须使用新的 buildId/文件名，不能覆盖旧资产。
'''.encode('utf-8')
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(args.output,'x',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as archive:
        for name,data in sorted(files.items()):
            info = zipfile.ZipInfo(name,(1980,1,1,0,0,0)); info.compress_type=zipfile.ZIP_DEFLATED
            info.external_attr=0o100644<<16; archive.writestr(info,data)
    print(json.dumps({'file':str(args.output),'sha256':hashlib.sha256(args.output.read_bytes()).hexdigest(),
                      'bytes':args.output.stat().st_size,'verifiedInputs':len(required)},ensure_ascii=False))


if __name__ == '__main__': main()
