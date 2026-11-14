"""把本轮真实OHOS生产回执、实际ELF与宿主推理结果写为小型锁定资格记录。

本工具不授予真机资格。来源、剥离前后摘要、宿主算法验证和未运行的OHOS
执行分别记录，不把宿主PASS升级成目标系统PASS。
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = ROOT / 'prebuilt/mod-natives/sherpa-onnx'


def sha(path):
    """与生产加载和HAP门禁使用同一实际字节摘要。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """只接受真实成功生产和两版真实离线推理日志，必要字段缺失即拒绝。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--producer', type=Path, required=True)
    parser.add_argument('--host', type=Path, required=True)
    args = parser.parse_args()
    producer = json.loads((args.producer / 'build-receipt.json').read_text())
    host = json.loads((args.host / 'host-receipt.json').read_text())
    if producer['state'] != 'built' or host['state'] != 'PASS':
        raise ValueError('实际生产或宿主推理未通过')
    check_spec = importlib.util.spec_from_file_location('sherpa_elf', ROOT / 'scripts/check-sherpa-artifacts.py')
    checker = importlib.util.module_from_spec(check_spec)
    check_spec.loader.exec_module(checker)
    symbols = ['Java_com_k2fsa_sherpa_onnx_' + name for name in (
        'OfflineRecognizer_newFromFile', 'OfflineRecognizer_createStream', 'OfflineRecognizer_decode',
        'OfflineRecognizer_getResult', 'OfflineRecognizer_delete', 'OfflineStream_acceptWaveform',
        'OfflineStream_delete', 'OfflineTts_newFromFile', 'OfflineTts_generateWithConfigImpl',
        'OfflineTts_generateWithCallbackImpl', 'OfflineTts_getSampleRate', 'OfflineTts_delete')]
    artifacts = []
    for name in ('libsherpa-onnx-jni.so', 'libonnxruntime.so'):
        path = SPEC / 'arm64-v8a' / name
        elf = checker.read_elf(path)
        artifacts.append({'filename': name, 'sha256': sha(path), 'size': path.stat().st_size,
                          'producerRawSha256': sha(args.producer / name), 'needed': elf['needed'],
                          'requiredSymbols': symbols if name.startswith('libsherpa') else ['OrtGetApiBase']})
    inference = {}
    for version in ('5.7.3', '6.0.0'):
        log = args.host / ('inference-' + version + '.log')
        records = [json.loads(line) for line in log.read_text().splitlines() if line.startswith('{"state"')]
        if len(records) != 1 or records[0]['state'] != 'PASS':
            raise ValueError('真实推理输出不完整：' + version)
        inference[version] = {**records[0], 'logSha256': sha(log)}
    result = {'schemaVersion': 1, 'nativeProfile': 'sherpa-onnx-1.13.3-ohos-cpu',
        'targetAbi': 'aarch64-linux-ohos', 'artifacts': artifacts,
        'producer': {'sourceCommit': producer['spec']['sherpa']['commit'],
            'sourceArchiveSha256': producer['spec']['sherpa']['sha256'],
            'ortArchiveSha256': producer['spec']['onnxruntime']['sha256'],
            'jniHeaders': producer['jniHeaders'], 'buildReceiptSha256': sha(args.producer / 'build-receipt.json'),
            'buildLogSha256': sha(args.producer / 'build.log'), 'startedAt': producer['startedAt'],
            'finishedAt': producer['finishedAt']},
        'qualification': {'targetElf': 'PASS', 'targetExecution': 'NOT_RUN',
            'hostEngine': {'platform': 'windows-x86_64', 'sherpaCommit': producer['spec']['sherpa']['commit'],
                'onnxruntime': '1.16.3', 'nativeSha256': host['nativeSha256'],
                'receiptSha256': sha(args.host / 'host-receipt.json'), 'inference': inference},
            'deviceAudio': 'NOT_RUN', 'completeModStartup': 'NOT_RUN'},
        'licenses': {p.relative_to(SPEC).as_posix(): sha(p) for p in sorted((SPEC / 'licenses').rglob('*')) if p.is_file()}}
    (SPEC / 'artifacts.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')


if __name__ == '__main__':
    main()
