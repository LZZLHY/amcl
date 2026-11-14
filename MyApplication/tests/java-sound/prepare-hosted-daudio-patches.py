#!/usr/bin/env python3
"""重放四代现役 DAUDIO 正文，再从单一平台源生成共享 PCM owner 增量。

只生成/新增0033，不改历史补丁。完整重放后像必须与已审R12的同源正文相同，
不能凭文件名推定基线。目录、日志、收据都由调用者显式放到仓外；失败原件保留。
"""
import argparse
from datetime import datetime
import difflib
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BASE = 'ca45edbe36296442dbbedb57f4ef81d5e4bb99c6'
PATCH = '0033-ohos-javasound-shared-pcm-owner.patch'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--write', action='store_true')
    parser.add_argument('--previous-receipt', type=Path,
                        help='仅续作本轮尚未跟踪的0033；核对上一生成收据并保全原字节')
    args = parser.parse_args()
    output = args.output.resolve()
    if not args.output.is_absolute() or output.is_relative_to(ROOT): raise ValueError('需要显式仓外绝对输出')
    output.mkdir(parents=True, exist_ok=False)
    original = subprocess.check_output(['git', '-C', str(ROOT), 'show',
                                       BASE + ':entry/src/main/cpp/javasound/ohos_daudio.c']).decode('utf-8').replace('\r\n', '\n')
    canonical = ROOT / 'entry/src/main/cpp/javasound'
    native = (canonical / 'ohos_daudio.c').read_text(encoding='utf-8')
    bridge = (canonical / 'ohos_daudio_host.h').read_text(encoding='utf-8')
    anchor = '#include "../audio/audio_runtime.h"'
    if bridge.count(anchor) != 1: raise ValueError('唯一共享 ABI include 接点改变')
    bridge = bridge.replace(anchor, '#include "amcl_audio_runtime.h"')
    api = (ROOT / 'entry/src/main/cpp/audio/audio_runtime.h').read_text(encoding='utf-8')
    records = []
    for major in ('8', '17', '21', '25'):
        stage = output / major; stage.mkdir()
        platform = 'jdk/src/solaris/native/com/sun/media/sound/' if major == '8' else 'src/java.desktop/linux/native/libjsound/'
        shared = 'jdk/src/share/native/com/sun/media/sound/' if major == '8' else 'src/java.desktop/share/native/libjsound/'
        target = platform + 'ohos_daudio.c'
        patches = ROOT / 'prebuilt/jdk' / major / 'patches'
        env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(output))
        replayed = []
        for name in (patches / 'series').read_text().splitlines():
            name = name.strip()
            if not name or name.startswith('#') or name == PATCH: continue
            patch = patches / name
            if '+++ b/' + target not in patch.read_text(encoding='utf-8'): continue
            command = ['git', '-c', 'core.autocrlf=false', '-c', 'core.eol=lf', 'apply', '--include=' + target]
            checked = subprocess.run([*command, '--check', str(patch)], cwd=stage, env=env, capture_output=True)
            applied = subprocess.run([*command, str(patch)], cwd=stage, env=env, capture_output=True) if checked.returncode == 0 else checked
            with (output / ('replay-' + major + '.log')).open('ab') as log:
                log.write(name.encode() + b'\n' + checked.stdout + checked.stderr + applied.stdout + applied.stderr)
            if checked.returncode or applied.returncode: raise ValueError('上游平台正文重放失败：' + major + '/' + name)
            replayed.append(name)
        if (stage / target).read_text(encoding='utf-8') != original:
            raise ValueError('活动 series 的 DAUDIO 后像不等于已审R12同源正文：' + major)
        content = ''.join(difflib.unified_diff(original.splitlines(True), native.splitlines(True),
                                              fromfile='a/' + target, tofile='b/' + target))
        for path, data in ((shared + 'ohos_daudio_host.h', bridge), (shared + 'amcl_audio_runtime.h', api)):
            content += ''.join(difflib.unified_diff([], data.splitlines(True), fromfile='/dev/null', tofile='b/' + path))
        candidate = output / ('jdk' + major + '.patch')
        candidate.write_text(content, encoding='utf-8', newline='\n')
        subprocess.run(['git', '-c', 'core.autocrlf=false', 'apply', '--check', str(candidate)], cwd=stage, env=env, check=True)
        subprocess.run(['git', '-c', 'core.autocrlf=false', 'apply', str(candidate)], cwd=stage, env=env, check=True)
        if (stage / target).read_text(encoding='utf-8') != native: raise ValueError('0033 重放后像不一致')
        records.append({'major': major, 'replayed': replayed, 'patchSha256': hashlib.sha256(candidate.read_bytes()).hexdigest()})
    # 先核完四代再写产品；已存在不同0033须另起修订，绝不覆盖历史内容。
    if args.write:
        previous = json.loads(args.previous_receipt.read_text(encoding='utf-8')) if args.previous_receipt else None
        previous_hashes = {item['major']: item['patchSha256'] for item in previous['majors']} if previous else {}
        for item in records:
            target = ROOT / 'prebuilt/jdk' / item['major'] / 'patches' / PATCH
            data = (output / ('jdk' + item['major'] + '.patch')).read_bytes()
            if target.exists() and target.read_bytes() != data:
                tracked = subprocess.run(['git', '-C', str(ROOT), 'ls-files', '--error-unmatch', '--',
                                          target.relative_to(ROOT).as_posix()], capture_output=True)
                old = target.read_bytes()
                if tracked.returncode == 0 or hashlib.sha256(old).hexdigest() != previous_hashes.get(item['major']):
                    raise ValueError('不能覆盖历史或未知0033：' + str(target))
                (output / ('previous-jdk' + item['major'] + '.patch')).write_bytes(old)
        for item in records:
            patches = ROOT / 'prebuilt/jdk' / item['major'] / 'patches'
            (patches / PATCH).write_bytes((output / ('jdk' + item['major'] + '.patch')).read_bytes())
            series = (patches / 'series').read_text(encoding='utf-8')
            if PATCH not in series.splitlines():
                (patches / 'series').write_text(series.rstrip() + '\n\n# 已签名宿主存在时共享PCM owner、录音政策与流生命周期；独立CLI保持原生后端。\n' + PATCH + '\n', encoding='utf-8', newline='\n')
    (output / 'receipt.json').write_text(json.dumps({'recordedAt': datetime.now().astimezone().isoformat(),
        'base': BASE, 'written': args.write, 'majors': records}, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__': main()
