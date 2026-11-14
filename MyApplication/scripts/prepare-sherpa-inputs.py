"""为 Sherpa OHOS 构建取得真实上游输入，全部下载与展开内容留在显式仓外目录。

模组整包必须匹配发布者的 SHA-512；源归档使用完整提交 URL，并记录实际字节摘要。
本工具只准备输入，不运行模组、不改游戏目录；同名已有文件必须验证后才能复用。
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import shutil
import urllib.request


def fetch(item, root):
    """流式写独占的 partial；成功校验后才发布，失败保留现场且不覆盖旧输入。"""
    path = root / item['filename']
    if not path.exists():
        partial = path.with_suffix(path.suffix + '.partial')
        with urllib.request.urlopen(item['url'], timeout=120) as source, partial.open('xb') as target:
            shutil.copyfileobj(source, target, 1024 * 1024)
        partial.rename(path)
    sums = {}
    for algo in ('sha256', 'sha512'):
        with path.open('rb') as stream:
            sums[algo] = hashlib.file_digest(stream, algo).hexdigest()
    if item.get('sha512') and sums['sha512'] != item['sha512']:
        raise ValueError('发布者摘要不匹配：' + str(path))
    if item.get('size') and path.stat().st_size != item['size']:
        raise ValueError('发布者大小不匹配：' + str(path))
    print('已验证 ' + path.name + ' ' + sums['sha256'], flush=True)
    return {**item, **sums, 'size': path.stat().st_size}


def main():
    """调用者必须选择仓外输出；输入来源收据供后续构建/宿主推理交叉核对。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    if any((parent / '.git').exists() for parent in (root, *root.parents)):
        raise ValueError('输入目录必须位于 Git 仓库之外')
    root.mkdir(parents=True, exist_ok=True)
    # 已核实版本的下载身份来自正式允许清单，不因服务器替换同名版本静默改pin。
    contract_path = Path(__file__).resolve().parents[1] / 'prebuilt/mod-natives/sherpa-onnx/verified-bindings.json'
    profiles = json.loads(contract_path.read_text())['profiles']
    inputs = []
    for version in ('5.7.3', '6.0.0'):
        record = next(row['source'] for row in profiles if row['source']['version'] == version)
        inputs.append({'filename': 'verity-' + version + '.jar', 'url': record['url'], 'sha512': record['sha512'],
                       'size': record['size'], 'modVersion': version, 'publicationId': record['publicationId']})
    inputs.extend([
        {'filename': 'sherpa-onnx-330609dab49be6ee8b30702918ca7abbbad1286a.tar.gz',
         'url': 'https://codeload.github.com/k2-fsa/sherpa-onnx/tar.gz/330609dab49be6ee8b30702918ca7abbbad1286a'},
        {'filename': 'onnxruntime-ohos-arm64-v8a-1.16.3.zip',
         'url': 'https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.16.3/onnxruntime-ohos-arm64-v8a-1.16.3.zip'},
        {'filename': 'onnxruntime-win-x64-1.16.3.zip',
         'url': 'https://github.com/microsoft/onnxruntime/releases/download/v1.16.3/onnxruntime-win-x64-1.16.3.zip'}])
    with ThreadPoolExecutor(max_workers=3) as pool:
        actual = list(pool.map(lambda item: fetch(item, root), inputs))
    (root / 'downloads.json').write_text(json.dumps({'schemaVersion': 1, 'inputs': actual}, indent=2) + '\n', encoding='utf-8', newline='\n')


if __name__ == '__main__':
    main()
