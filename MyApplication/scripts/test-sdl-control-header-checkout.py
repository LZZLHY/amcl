"""在独立 Git index 中实际 checkout 两份 SDL/neutral 控制头，验证窄 LF 合同与 raw 门。

只读产品与正式 series，所有 Git 对象、index、checkout 和证据写仓外。不建 commit，
不修改源仓 index/config。正例与撤属性、真正内容漂移反例都保留 raw/LF 身份。
"""
from pathlib import Path
from datetime import datetime
import argparse
import hashlib
import importlib.util
import json
import subprocess
import sys
sys.dont_write_bytecode = True
from lib.workspace_paths import external_output_path, workspace_path

ROOT = Path(__file__).resolve().parents[1]
HEADERS = ('control_delivery.h', 'control_delivery_client.h')
PATHS = tuple('entry/src/main/cpp/input/delivery/' + name for name in HEADERS)

def identity(data):
    """raw 与 LF 投影分别记账；LF 仅用于诊断，不参与原始字节门判决。"""
    return {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
            'crlf': data.count(b'\r\n'), 'lfSha256': hashlib.sha256(data.replace(b'\r\n', b'\n')).hexdigest()}

def main():
    """使用真实 Git attributes/index/checkout；比较仍为严格原 bytes equality。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output'); parser.add_argument('--build-root')
    args = parser.parse_args()
    output = external_output_path(args.output) if args.output else workspace_path('run', 'sdl-header-checkout')
    build = external_output_path(args.build_root) if args.build_root else workspace_path('build', 'sdl-header-checkout')
    output.mkdir(parents=True, exist_ok=False); build.mkdir(parents=True, exist_ok=False)
    started = datetime.now().astimezone().isoformat(); commands = []
    attributes = (ROOT / '.gitattributes').read_bytes()
    before = {name: (ROOT / name).read_bytes() for name in ('.gitattributes', *PATHS)}
    rules = tuple(path + ' text eol=lf' for path in PATHS)
    text = attributes.decode('utf-8')
    for rule in rules:
        if text.splitlines().count(rule) != 1: raise ValueError('必须有且只有精确合同: ' + rule)
    spec = importlib.util.spec_from_file_location('sdl_checkout_series', ROOT / 'scripts/generate-desktop-review-tests.py')
    recipe = importlib.util.module_from_spec(spec); spec.loader.exec_module(recipe)
    reconstructed = recipe.patch_sources()
    expected = {path: reconstructed[name].encode('utf-8') for path, name in zip(PATHS, HEADERS)}
    repo = build / 'git'; repo.mkdir()
    def git(*arguments):
        """命令参数数组不经 shell；仅使用这个新外置 fixture 的 Git 配置与 index。"""
        command = ['git', '-C', str(repo), '-c', 'core.autocrlf=true', '-c', 'core.safecrlf=false', *map(str, arguments)]
        item = {'command': command, 'startedAt': datetime.now().astimezone().isoformat()}
        result = subprocess.run(command, capture_output=True)
        item.update(exitCode=result.returncode, finishedAt=datetime.now().astimezone().isoformat())
        commands.append(item)
        if result.returncode: raise RuntimeError(result.stdout.decode(errors='replace') + result.stderr.decode(errors='replace'))
        return result.stdout
    git('init', '-q')
    (repo / '.gitattributes').write_bytes(attributes)
    for path in PATHS:
        destination = repo / path; destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(before[path])
    # 非合同头是阳性范围见证；添加两条精确路径规则不能把整个 *.h 改为 LF。
    (repo / 'unrelated.h').write_bytes(b'int unchanged_header;\n')
    git('add', '--', '.gitattributes', *PATHS, 'unrelated.h')
    facts = []
    def checkout(case):
        destination = build / case; destination.mkdir()
        git('checkout-index', '--all', '--force', '--prefix=' + destination.as_posix() + '/')
        return destination
    positive = checkout('positive')
    for path in PATHS:
        actual = (positive / path).read_bytes()
        if actual != expected[path]: raise AssertionError('严格 SDL raw mirror 正向拒绝: ' + path)
        facts.append({'case': 'positive', 'path': path, 'rawAccepted': True, 'identity': identity(actual), 'expected': identity(expected[path])})
    if (positive / 'unrelated.h').read_bytes() != b'int unchanged_header;\r\n':
        raise AssertionError('窄路径合同不应改变其他头的 checkout')
    # 只撤这两条精确规则，再由同一真实 index 正常 checkout；不伪造 CRLF 数据来代替 Git。
    lines = text.splitlines(keepends=True)
    (repo / '.gitattributes').write_bytes(''.join(line for line in lines if line.rstrip('\r\n') not in rules).encode('utf-8'))
    git('add', '--', '.gitattributes')
    negative = checkout('removed-rules')
    for path in PATHS:
        actual = (negative / path).read_bytes()
        if actual == expected[path] or b'\r\n' not in actual or actual.replace(b'\r\n', b'\n') != expected[path]:
            raise AssertionError('撤规则必须真实产生只有换行不同的 raw 拒绝: ' + path)
        facts.append({'case': 'removed-rules', 'path': path, 'rawAccepted': False, 'identity': identity(actual), 'expected': identity(expected[path])})
    # 恢复属性后，改变实际候选正文并重新进入 Git index；真正内容漂移同样被 byte 门拒绝。
    (repo / '.gitattributes').write_bytes(attributes)
    changed_path = repo / PATHS[0]
    changed_path.write_bytes(before[PATHS[0]] + b'\n/* deliberate header content drift */\n')
    git('add', '--', '.gitattributes', PATHS[0])
    changed = checkout('content-drift'); actual = (changed / PATHS[0]).read_bytes()
    if actual == expected[PATHS[0]] or b'\r\n' in actual: raise AssertionError('真实内容漂移应在 LF checkout 下仍拒绝')
    facts.append({'case': 'content-drift', 'path': PATHS[0], 'rawAccepted': False, 'identity': identity(actual), 'expected': identity(expected[PATHS[0]])})
    # 最后恢复原正文并再次 checkout，保证证据末态不是未恢复的负控。
    changed_path.write_bytes(before[PATHS[0]]); git('add', '--', PATHS[0])
    restored = checkout('restored')
    for path in PATHS:
        actual = (restored / path).read_bytes()
        if actual != expected[path]: raise AssertionError('恢复后严格 raw mirror 应通过: ' + path)
        facts.append({'case': 'restored', 'path': path, 'rawAccepted': True, 'identity': identity(actual)})
    after = {name: (ROOT / name).read_bytes() for name in before}
    drift = [name for name in before if before[name] != after[name]]
    receipt = {'startedAt': started, 'completedAt': datetime.now().astimezone().isoformat(),
               'sourceRoot': str(ROOT), 'rules': list(rules), 'facts': facts, 'commands': commands,
               'sourceIdentities': {name: identity(data) for name, data in before.items()}, 'sourceDrift': drift,
               'scope': 'real Git checkout / two exact LF contracts / strict raw byte mirror; no commit or product/SDK/device change'}
    (output / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    if drift: raise RuntimeError('源仓字节漂移: ' + ', '.join(drift))
    print('PASS real Git LF checkout, removed-rules/content-drift raw negatives and restored raw gate: ' + str(output))

if __name__ == '__main__': main()
