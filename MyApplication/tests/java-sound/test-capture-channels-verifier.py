"""用明确合成的文件测试基础Java verifier对channels的精确分派。

这里没有JVM、HAP或设备执行；占位JAR/ZIP并非可运行产物。测试只证明profile、阶段、
正文SHA和专项失败不能被普通Java成功字段掩盖，绝不输出目标音频资格。
"""
import argparse
import copy
from datetime import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host-report', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    out = args.out.resolve()
    if not args.out.is_absolute() or out.is_relative_to(repo): raise ValueError('external absolute output required')
    out.mkdir(parents=True, exist_ok=False)
    base_path = repo / 'tests/runtime-java/verify-device.py'
    spec = importlib.util.spec_from_file_location('base_verify', base_path)
    base = importlib.util.module_from_spec(spec); spec.loader.exec_module(base)
    raw_host = args.host_report.read_bytes()
    host = json.loads(raw_host)
    host['pid'] = 123; host['provider'] = '/system/lib64/ndk/libohaudio.so'
    jar = b'SYNTHETIC parser fixture; not an executable JAR'
    archive = out / 'SYNTHETIC-not-a-runtime.zip'; archive.write_bytes(b'SYNTHETIC parser fixture; not a JDK')
    jar_sha = hashlib.sha256(jar).hexdigest(); archive_sha = base.digest(archive); hap_sha = '1' * 64
    cases = []

    def fixture(name):
        """独占微型文件，全部标记合成，不复制或修改真实设备材料。"""
        directory = out / name; run = directory / 'run-25'; run.mkdir(parents=True)
        report = copy.deepcopy(host)
        raw = json.dumps(report).encode('utf-8')
        (run / 'capture-channels-report.json').write_bytes(raw)
        stages = [{'stage': 'capture-main'}, {'stage': 'capture-main-return', 'result': 0},
                  {'stage': 'capture-channels-observed', 'reportSha256': hashlib.sha256(raw).hexdigest()},
                  {'stage': 'jvm-init'}]
        (run / 'native-stages.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in stages), encoding='utf-8')
        transfer = {'profile': 'sound-capture-channels', 'major': '25', 'candidate': str(archive),
                    'archiveSha256': archive_sha, 'hapSha256': hap_sha, 'parentReportReceived': True, 'syntheticOnly': True}
        native = {'profile': 'sound-capture-channels', 'major': '25', 'pid': 123, 'specialtyResult': 0,
                  'archiveSha256': archive_sha, 'fixtureSha256': jar_sha, 'passed': True, 'completionProof': True,
                  'initResult': 0, 'mainResult': 0, 'destroyResult': 0, 'syntheticOnly': True}
        parent = {'transportOk': True, 'text': json.dumps({'stage': 'native-child-start', 'pid': 123, 'result': 0}) + '\n' +
                  json.dumps({'stage': 'native-child-exit', 'observed': True, 'signal': 0, 'timedOut': False}), 'syntheticOnly': True}
        for path, value in ((directory / 'transfer.json', transfer), (directory / 'parent-result.json', parent), (run / 'result.json', native)):
            path.write_text(json.dumps(value), encoding='utf-8')
        (run / 'qualification.jar').write_bytes(jar)
        for name in ('fixture-pass.txt', 'non-daemon.txt', 'shutdown-hook.txt', 'main-thread-ended.txt'):
            (run / name).write_text('AMCL-JAVA-QUALIFICATION:1:25\n', encoding='utf-8')
        (run / 'stdout.log').write_text('SYNTHETIC parser input\n100 1 4 RuntimeQualification::hotLoop\n', encoding='utf-8')
        (run / 'fixture-results.txt').write_text('mainThreadJoinRequired=true\nlogicalFontFacesChecked=20\nfontFallbackMissingGlyphs=0\nfontFallbackGlyphComparisons=1\npngRoundtripPixels=17920\n', encoding='utf-8')
        return directory, run

    def mutate_json(path, mutate):
        value = json.loads(path.read_text(encoding='utf-8')); mutate(value)
        path.write_text(json.dumps(value), encoding='utf-8')

    directory, run = fixture('synthetic-positive')
    result = base.verify(directory, hap_sha, jar_sha)
    assert result['fixtureQualified'] and result['captureChannelsObservation']['signalQualified'] is False
    cases.append({'name': 'exact-profile-dispatch', 'syntheticParserAccepted': True})
    mutations = [
        ('missing-specialty-report', lambda directory, run: (run / 'capture-channels-report.json').unlink()),
        ('old-profile-report', lambda directory, run: mutate_json(run / 'capture-channels-report.json', lambda value: value.update(protocol='AMCL_CAPTURE_STARTUP_V1'))),
        ('sha-mismatch', lambda directory, run: (run / 'capture-channels-report.json').write_bytes((run / 'capture-channels-report.json').read_bytes() + b' ')),
        ('specialty-return-failed', lambda directory, run: mutate_json(run / 'result.json', lambda value: value.update(specialtyResult=1))),
        ('transfer-profile-mismatch', lambda directory, run: mutate_json(directory / 'transfer.json', lambda value: value.update(profile='basic'))),
        ('native-profile-mismatch', lambda directory, run: mutate_json(run / 'result.json', lambda value: value.update(profile='basic'))),
        ('missing-capture-stage', lambda directory, run: (run / 'native-stages.jsonl').write_text('{"stage":"jvm-init"}\n', encoding='utf-8')),
    ]
    for name, mutate in mutations:
        directory, run = fixture(name); mutate(directory, run)
        result = base.verify(directory, hap_sha, jar_sha)
        assert not result['fixtureQualified'] and result['problems'], name
        cases.append({'name': name, 'rejected': True, 'problems': result['problems']})
    directory, run = fixture('basic-route-preserved')
    mutate_json(directory / 'transfer.json', lambda value: value.update(profile='basic'))
    mutate_json(run / 'result.json', lambda value: value.update(profile='basic'))
    (run / 'capture-channels-report.json').unlink()
    result = base.verify(directory, hap_sha, jar_sha)
    assert result['fixtureQualified'] and 'captureChannelsObservation' not in result
    cases.append({'name': 'basic-route-preserved', 'syntheticParserAccepted': True})
    mutate_json(directory / 'transfer.json', lambda value: value.update(profile='native-temp'))
    try: base.verify(directory, hap_sha, jar_sha)
    except ValueError as error: assert 'native-only' in str(error)
    else: raise AssertionError('native-only was accepted as Java')
    cases.append({'name': 'native-only-still-requires-own-verifier', 'rejected': True})
    receipt = {'recordedAt': datetime.now().astimezone().isoformat(), 'passed': True, 'syntheticOnly': True,
               'deviceQualified': False, 'cases': cases, 'hostReportSha256': hashlib.sha256(raw_host).hexdigest(),
               'baseVerifierSha256': base.digest(base_path), 'testSourceSha256': base.digest(Path(__file__))}
    (out / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('PASS ten synthetic verifier dispatch/binding controls; no VM or device qualification')


if __name__ == '__main__': main()
