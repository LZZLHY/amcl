#!/usr/bin/env python3
"""在全新外置目录逐代重放完整正式 series，GitHub 原文仅按锁定 commit 获取。

只下载实际补丁影响的文件，不克隆完整 JDK、不改活动构建卷。所有原文/补丁 SHA 与
每一步 git apply 原输出保留；网络或未知路径失败立即停止，不换用分支最新版本。
"""
import argparse
import concurrent.futures
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--duplex-candidate', type=Path,
                        help='append independently hashed0025 candidate after current formal series, without editing series')
    parser.add_argument('--timeline-candidate', type=Path,
                        help='append independently hashed0028 candidate without editing current formal series')
    args = parser.parse_args()
    if args.duplex_candidate and args.timeline_candidate: raise ValueError('choose one explicit candidate generation')
    repo = Path(__file__).resolve().parents[2]
    out = args.out.resolve()
    if not args.out.is_absolute() or out.is_relative_to(repo): raise ValueError('external absolute output required')
    out.mkdir(parents=True, exist_ok=False)
    locked = json.loads((repo / 'prebuilt/jdk/build-inputs.json').read_text())['runtimes']
    candidate_root = args.timeline_candidate or args.duplex_candidate
    candidate = json.loads((candidate_root / 'receipt.json').read_text()) if candidate_root else None
    receipt = {'startedAt': datetime.datetime.now().astimezone().isoformat(), 'majors': []}
    try:
        for major, identity in locked.items():
            patch_root = repo / 'prebuilt/jdk' / major / 'patches'
            patches = [patch_root / line.strip() for line in (patch_root / 'series').read_text(encoding='utf-8').splitlines()
                       if line.strip() and not line.lstrip().startswith('#')]
            if candidate:
                allowed_last = ('0025-ohos-javasound-duplex-host-callbacks.patch',
                                '0026-ohos-javasound-midi.patch', '0027-ohos-javasound-ports.patch') if args.timeline_candidate else (
                                '0023-ohos-javasound-daudio-playback.patch', '0024-ohos-childproc-safe-fork.patch')
                if patches[-1].name not in allowed_last and not (args.timeline_candidate and patches[-1].name.startswith(('0026-', '0027-'))):
                    raise ValueError('unexpected baseline final patch')
                record = next(item for item in candidate['majors'] if item['major'] == major)
                added_patch = candidate_root / ('jdk' + major + ('-ohos-daudio-timeline.patch' if args.timeline_candidate else '-ohos-daudio-duplex.patch'))
                if record['sourceCommit'] != identity['commit'] or hashlib.sha256(added_patch.read_bytes()).hexdigest() != record['sha256']:
                    raise ValueError('candidate identity differs')
                patches.append(added_patch)
            elif (patches[-1].name != '0033-ohos-javasound-shared-pcm-owner.patch' or
                  '0028-ohos-javasound-presentation-timeline.patch' not in [p.name for p in patches]):
                raise ValueError('expected complete current audio series through0033')
            texts = [p.read_text(encoding='utf-8') for p in patches]
            existing = set(); added = set()
            for text in texts:
                existing.update(re.findall(r'^--- a/(.+)$', text, re.M))
                added.update(re.findall(r'^--- /dev/null\n\+\+\+ b/(.+)$', text, re.M))
            names = sorted(existing - added)
            tree = out / major; tree.mkdir()
            result = {'major': major, 'commit': identity['commit'], 'source': [], 'patches': [],
                      'seriesSha256': hashlib.sha256((patch_root / 'series').read_bytes()).hexdigest()}
            receipt['majors'].append(result)
            repo_name = identity['repository'].rsplit('/', 1)[1].removesuffix('.git')

            def fetch(name):
                if Path(name).is_absolute() or '..' in Path(name).parts: raise ValueError('unsafe source path')
                url = 'https://raw.githubusercontent.com/openjdk/' + repo_name + '/' + identity['commit'] + '/' + name
                with urllib.request.urlopen(url, timeout=35) as response:
                    data = response.read(8 * 1024 * 1024)
                    if response.read(1): raise ValueError('unexpected oversized source')
                path = tree / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
                return {'path': name, 'url': url, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}

            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as workers:
                for item in workers.map(fetch, names): result['source'].append(item)
            env = {**os.environ, 'GIT_CEILING_DIRECTORIES': str(out)}
            for number, patch in enumerate(patches):
                command = ['git', '-c', 'core.autocrlf=false', '-c', 'core.eol=lf', 'apply']
                for mode in ('--check', ''):
                    argv = command + ([mode] if mode else []) + [str(patch)]
                    run = subprocess.run(argv, cwd=tree, env=env, capture_output=True, timeout=30)
                    (tree / ('apply-%02d%s.log' % (number, '-check' if mode else ''))).write_bytes(run.stdout + run.stderr)
                    if run.returncode: raise RuntimeError('full series failed: ' + major + '/' + patch.name + '\n' + run.stderr.decode(errors='replace'))
                result['patches'].append({'name': patch.name, 'sha256': hashlib.sha256(patch.read_bytes()).hexdigest()})
            platform = 'jdk/src/solaris/native/com/sun/media/sound/' if major == '8' else 'src/java.desktop/linux/native/libjsound/'
            native = 'jdk/src/share/native/com/sun/media/sound/' if major == '8' else 'src/java.desktop/share/native/libjsound/'
            shared = [(platform + 'ohos_daudio.c', 'ohos_daudio.c')]
            shared += [(native + name, name) for name in ('ohos_daudio.h', 'ohos_capture_ring.h', 'ohos_daudio_callbacks.h')]
            if args.timeline_candidate or not candidate:
                shared.append((native + 'ohos_playback_timeline.h', 'ohos_playback_timeline.h'))
            for path, name in shared:
                # Windows源码检出可为CRLF，git apply后像为LF；只规范换行，不忽略正文差异。
                if (tree / path).read_text(encoding='utf-8') != (repo / 'entry/src/main/cpp/javasound' / name).read_text(encoding='utf-8'):
                    raise ValueError('formal series differs from shared DAUDIO source: ' + major + '/' + name)
            if not candidate:
                bridge = (repo / 'entry/src/main/cpp/javasound/ohos_daudio_host.h').read_text(encoding='utf-8')
                bridge = bridge.replace('#include "../audio/audio_runtime.h"', '#include "amcl_audio_runtime.h"')
                if (tree / (native + 'ohos_daudio_host.h')).read_text(encoding='utf-8') != bridge or (
                    tree / (native + 'amcl_audio_runtime.h')).read_text(encoding='utf-8') != (
                    repo / 'entry/src/main/cpp/audio/audio_runtime.h').read_text(encoding='utf-8'):
                    raise ValueError('hosted audio bridge/ABI differs from formal series: ' + major)
            result['result'] = 'PASS'
            print('PASS full JDK ' + major + ' series: ' + str(len(patches)) + ' patches / ' + str(len(names)) + ' original files', flush=True)
        receipt['result'] = 'PASS'
    finally:
        receipt['finishedAt'] = datetime.datetime.now().astimezone().isoformat()
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')


if __name__ == '__main__': main()
