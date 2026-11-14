#!/usr/bin/env python3
"""独立验收固定只读 MIDI/Ports 设备资格；不运行设备，也不改写原始证据。

完整 JAR、HAP 部署身份、JDK ZIP 和 Java/Native 退出条件复用 runtime-java 门。
本门另核独占 JSONL 的顺序、平台门、真实 Provider、Port 资源配对及原生 Create
日志。成功仅授予当前设备的枚举/快照资格，绝不授予 MIDI 收发、PCM 或录音资格。
"""
import argparse
from datetime import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import stat
import sys
import zipfile


PROGRESS = 'native-sound-devices-progress.jsonl'
COMPLETE = 'native-sound-devices-complete.json'
PROTOCOL = 'AMCL_NATIVE_SOUND_DEVICES_V1'
MIDI_PROVIDERS = {'com.sun.media.sound.MidiInDeviceProvider', 'com.sun.media.sound.MidiOutDeviceProvider'}
READY = 'AMCL MIDI backend ready: provider=libohmidi.so api=24 callbackAbi=1; real client created'
MAX_ITEMS = 4096
BASE_PATH = Path(__file__).resolve().parents[1] / 'runtime-java' / 'verify-device.py'


def require(condition, message):
    """任一缺证或互相矛盾立即拒绝；调用层把原始失败原因保存到独占收据。"""
    if not condition:
        raise ValueError(message)


def digest(data):
    """仅摘要实物字节，不将重新序列化的 JSON 当作文件身份。"""
    return hashlib.sha256(data).hexdigest()


def parse(data):
    """重复键及非 JSON 数值会造成不同读者看到不同结论，必须拒绝。"""
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate JSON key: ' + key)
            result[key] = value
        return result

    def invalid(value):
        raise ValueError('non-JSON number: ' + value)

    return json.loads(data, object_pairs_hook=pairs, parse_constant=invalid)


def read_regular(path, limit):
    """只读有界普通文件；拒绝符号链接和读取期间大小变化，不能截断后继续验收。"""
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_size <= limit, 'invalid evidence file: ' + str(path))
    data = path.read_bytes()
    require(len(data) == info.st_size, 'evidence size changed: ' + str(path))
    return data


def integer(value, low, high, message):
    """Python bool 也是 int 子类；协议计数不接受 true 冒充数字 1。"""
    require(type(value) is int and low <= value <= high, message)
    return value


def verify_documents(progress_raw, complete_raw, stdout_raw, major, pid):
    """纯报告门，供真实入口与小型字节损坏负控复用；不读取设备或修改证据。

    按固定夹具实际串行控制流逐条消费，不能以集合相等掩盖漏 close、重复 open、
    先 complete 后操作或错误 Provider。独占 JSONL 是数据源，stdout 只佐证真实
    原生 client Create；不尝试修复与 PrintCompilation 交织的普通输出。
    """
    require(major in (8, 17, 21, 25), 'unsupported major')
    integer(pid, 1, 2**31 - 1, 'invalid actual child PID')
    require(progress_raw.endswith(b'\n'), 'progress lacks final newline')
    lines = progress_raw.decode('utf-8', errors='strict').splitlines()
    require(0 < len(lines) <= 65536 and all(lines), 'invalid progress line count/blank line')
    rows = [parse(line) for line in lines]
    for index, row in enumerate(rows):
        require(isinstance(row, dict) and type(row.get('sequence')) is int and row['sequence'] == index,
                'progress sequence missing/duplicate/reordered')
    marker = parse(complete_raw.decode('utf-8', errors='strict'))
    require(isinstance(marker, dict) and marker.get('protocol') == PROTOCOL and
            type(marker.get('major')) is int and marker['major'] == major and marker.get('passed') is True and
            marker.get('midiIoQualified') is False and marker.get('progressSha256') == digest(progress_raw),
            'completion identity/SHA/read-only scope mismatch')
    integer(marker.get('portCount'), 1, MAX_ITEMS * 2, 'zero/invalid completed Port count')
    at = 0

    def take(event, keys):
        nonlocal at
        require(at < len(rows), 'missing event: ' + event)
        row = rows[at]; at += 1
        require(row.get('event') == event, 'expected ' + event + ', got ' + str(row.get('event')))
        require(set(row) == {'sequence', 'event', *keys}, 'unexpected/missing fields: ' + event)
        return row

    row = take('start', ('major', 'pid', 'midiPortsOpened', 'midiEventsSent', 'captureOpened', 'pcmStreamsRequested'))
    require(type(row['major']) is int and row['major'] == major and isinstance(row['pid'], str) and
            re.fullmatch(str(pid) + r'@[^\s@]+', row['pid']), 'start major/PID differs from native child')
    require(all(row[key] is False for key in ('midiPortsOpened', 'midiEventsSent', 'captureOpened', 'pcmStreamsRequested')),
            'read-only start flags changed')
    if major == 8:
        mask = take('native-load-mask', ('loadedLibs', 'mainMask'))
        bits = integer(mask['loadedLibs'], 0, 2**31 - 1, 'invalid JDK8 native mask')
        main = integer(mask['mainMask'], 1, 2**31 - 1, 'invalid JDK8 main mask')
        require(bits & main == main, 'JDK8 main native library was not loaded')
    gates = take('platform-gates', ('nativeLibraryLoaded', 'midiIOEnabled', 'midiProviderEnabled', 'portsEnabled'))
    require(all(gates[key] is True for key in ('nativeLibraryLoaded', 'midiIOEnabled', 'midiProviderEnabled', 'portsEnabled')),
            'actual Platform/provider gate is disabled')

    providers = {}
    for _ in range(2):
        begin = take('midi-enumeration-start', ('provider',))
        name = begin['provider']
        require(name in MIDI_PROVIDERS and name not in providers, 'wrong/duplicate native MIDI provider')
        row = take('midi-provider', ('provider', 'endpointCount', 'observation', 'midiIoQualified', 'requiresNativeProviderEvidence'))
        count = integer(row['endpointCount'], 0, MAX_ITEMS, 'invalid MIDI endpoint count')
        require(row['provider'] == name and row['midiIoQualified'] is False and row['requiresNativeProviderEvidence'] is True,
                'MIDI provider/scope mismatch')
        require(row['observation'] == ('ENDPOINTS_ENUMERATED' if count else 'NO_ENDPOINTS_OR_OPTIONAL_API_UNAVAILABLE'),
                'MIDI endpoint observation contradicts count')
        endpoints = []
        for index in range(count):
            endpoint = take('midi-endpoint', ('provider', 'index', 'name', 'vendor', 'description', 'version'))
            require(endpoint['provider'] == name and type(endpoint['index']) is int and endpoint['index'] == index,
                    'MIDI endpoint provider/index mismatch')
            require(all(endpoint[key] is None or isinstance(endpoint[key], str) for key in ('name', 'vendor', 'description', 'version')),
                    'MIDI endpoint metadata type mismatch')
            endpoints.append({key: value for key, value in endpoint.items() if key not in ('event', 'sequence')})
        providers[name] = {'endpointCount': count, 'endpoints': endpoints, 'midiIoQualified': False}

    count = integer(take('port-provider', ('mixerCount',))['mixerCount'], 1, MAX_ITEMS, 'zero/invalid native PortMixer count')
    mixers, ports = [], []
    for index in range(count):
        row = take('mixer-open-start', ('mixer', 'name'))
        require(type(row['mixer']) is int and row['mixer'] == index and isinstance(row['name'], str) and row['name'],
                'mixer open identity/name mismatch')
        name = row['name']; port_index = 0
        while at < len(rows) and rows[at].get('event') == 'port-open-start':
            identity = {'mixer': index, 'index': port_index}
            begin = take('port-open-start', ('mixer', 'index'))
            opened = take('port-opened', ('mixer', 'index', 'name', 'isSource', 'lineClass', 'controls', 'snapshotOnly'))
            closed = take('port-closed', ('mixer', 'index'))
            require(all(all(type(item[key]) is int and item[key] == value for key, value in identity.items())
                        for item in (begin, opened, closed)), 'Port open/query/close identity mismatch')
            require(isinstance(opened['name'], str) and opened['name'] and type(opened['isSource']) is bool and
                    opened['lineClass'] == 'com.sun.media.sound.PortMixer$PortMixerPort' and opened['snapshotOnly'] is True,
                    'Port type/name/snapshot contract mismatch')
            require(opened['controls'] == [], 'Port controls were not actually empty')
            # 标准Port名称有固定方向；其他真实设备可使用Native返回的自定义名称，不能
            # 为只接受当前平板而把设备清单写死成SPEAKER/MICROPHONE两个名字。
            directions = {'MICROPHONE': True, 'LINE_IN': True, 'COMPACT_DISC': True,
                          'SPEAKER': False, 'HEADPHONE': False, 'LINE_OUT': False}
            if opened['name'] in directions:
                require(opened['isSource'] is directions[opened['name']], 'standard Port name/direction mismatch')
            ports.append({key: value for key, value in opened.items() if key not in ('event', 'sequence')})
            port_index += 1
            require(port_index <= MAX_ITEMS * 2, 'too many Ports in mixer')
        closed = take('mixer-closed', ('mixer',))
        require(type(closed['mixer']) is int and closed['mixer'] == index and port_index > 0,
                'mixer close missing/wrong identity or zero typed Ports')
        mixers.append({'index': index, 'name': name, 'portCount': port_index, 'closed': True})

    final = take('complete', ('portsQualified', 'portCount', 'midiIoQualified'))
    require(final['portsQualified'] is True and final['midiIoQualified'] is False and type(final['portCount']) is int and
            final['portCount'] == marker['portCount'] == len(ports) and at == len(rows),
            'completion count/scope differs or trailing progress exists')
    require(set(marker) == {'protocol', 'major', 'passed', 'midiIoQualified', 'portCount', 'progressSha256'},
            'unexpected completion fields')

    log = stdout_raw.decode('utf-8', errors='strict')
    # 精确原生日志整行，不接受某个设备名称/Java异常文本里嵌入同样的句子冒充Create。
    ready_matches = list(re.finditer(r'(?m)^' + re.escape(READY) + r'\r?$', log))
    ready = [{'line': log.count('\n', 0, match.start()) + 1, 'text': READY} for match in ready_matches]
    require(ready, 'actual native MIDI client Create readiness log missing')
    require('AMCL MIDI capability:' not in log and 'AMCL MIDI shutdown retained live ownership:' not in log,
            'native MIDI capability/ownership failure reported')
    # 独占报告负责结构化数据。只要求两端固定print锚点夹住原生ready，拒绝混入另一轮
    # stdout的ready；中间行可有JIT输出交织，不从该共享流重建或猜修JSONL。
    start = log.find('NATIVE_SOUND ' + lines[0]); end = log.find('NATIVE_SOUND ' + lines[-1])
    require(start >= 0 and end > start and any(start < match.start() < end for match in ready_matches),
            'native readiness is outside this fixture log interval')
    return {'progressSha256': digest(progress_raw), 'completeSha256': digest(complete_raw),
            'eventCount': len(rows), 'midiProviders': providers, 'midiBackendReady': ready,
            'mixers': mixers, 'ports': ports, 'portCount': len(ports)}


def verify(directory, hap_sha, jar_sha, archive_sha):
    """先复用完整运行身份门，再核本专项；失败也返回可落盘诊断而不授予局部PASS。

    HAP/JAR/ZIP预期值必须由调用者给出构建/部署/发布收据身份，不能从待验材料自动
    推导。HAP身份复用部署记录；本工具不会连接设备或重新声明安装动作已发生。
    """
    directory = Path(directory)
    result = {'schemaVersion': 1, 'verifiedAt': datetime.now().astimezone().isoformat(),
              'qualified': False, 'problems': [], 'midiIoQualified': False, 'captureQualified': False,
              'pcmQualified': False, 'evidenceDirectory': str(directory.resolve()),
              'expectedHapSha256': hap_sha, 'expectedJarSha256': jar_sha, 'expectedArchiveSha256': archive_sha,
              'scope': 'named device/run native MIDI enumeration and read-only Port snapshots only; no MIDI I/O, capture, PCM, hotplug or other-device qualification',
              'verifiers': {str(path): digest(path.read_bytes()) for path in (Path(__file__), BASE_PATH)}}
    try:
        require(all(re.fullmatch('[0-9a-f]{64}', value) for value in (hap_sha, jar_sha, archive_sha)), 'expected SHA256 must be lower-case hex')
        transfer_raw = read_regular(directory / 'transfer.json', 64 * 1024)
        transfer = parse(transfer_raw.decode('utf-8-sig'))
        require(transfer['major'] in ('8', '17', '21', '25') and transfer.get('profile') == 'native-sound-devices', 'wrong transfer major/profile')
        run = directory / ('run-' + transfer['major'])
        native_raw = read_regular(run / 'result.json', 64 * 1024)
        native = parse(native_raw)
        require(native.get('profile') == 'native-sound-devices' and type(native.get('specialtyResult')) is int and
                native['specialtyResult'] == 0 and native.get('installComplete') is True and native.get('error') == '',
                'native sound specialty/installation failed')
        require(native.get('archiveSha256') == transfer.get('archiveSha256') == archive_sha, 'expected ZIP identity mismatch')
        # 从相邻正式文件加载现有基础门，不复制其JIT/字体/退出合同，不生成仓内pycache。
        old = sys.dont_write_bytecode; sys.dont_write_bytecode = True
        try:
            spec = importlib.util.spec_from_file_location('amcl_runtime_java_verifier', BASE_PATH)
            base = importlib.util.module_from_spec(spec); spec.loader.exec_module(base)
        finally:
            sys.dont_write_bytecode = old
        result['javaFixture'] = base.verify(directory, hap_sha, jar_sha)
        require(result['javaFixture']['fixtureQualified'], 'Java base gate: ' + '; '.join(result['javaFixture']['problems']))
        result['major'], result['pid'] = transfer['major'], native['pid']
        stages_raw = read_regular(run / 'native-stages.jsonl', 256 * 1024)
        stages = [parse(line) for line in stages_raw.splitlines() if line]
        require([item for item in stages if 'schema' in item] == [native], 'native stream/result receipt differs')
        begins = [i for i, item in enumerate(stages) if item.get('stage') == 'native-sound-devices-main']
        ends = [i for i, item in enumerate(stages) if item.get('stage') == 'native-sound-devices-return']
        require(len(begins) == len(ends) == 1 and begins[0] < ends[0] and stages[ends[0]].get('result') == 0,
                'native specialty call/return proof incomplete')
        parent_raw = read_regular(directory / 'parent-result.json', 512 * 1024)
        parent = parse(parent_raw.decode('utf-8-sig'))
        require(stages_raw.decode('utf-8') in parent['text'], 'parent does not contain actual native report bytes')
        exits = [parse(line) for line in parent['text'].splitlines() if line.startswith('{"stage":"native-child-exit"')]
        require(len(exits) == 1 and exits[0].get('reportBytes') == len(stages_raw), 'native report byte count differs')
        raw = {name: read_regular(run / name, limit) for name, limit in
               ((PROGRESS, 2 * 1024 * 1024), (COMPLETE, 4096), ('stdout.log', 32 * 1024 * 1024))}
        result.update(verify_documents(raw[PROGRESS], raw[COMPLETE], raw['stdout.log'], int(transfer['major']), native['pid']))
        # 整JAR已由基础门实算SHA；另列固定class身份，便于从receipt回溯构建，不把
        # 当前工作树Java源码冒充设备实际载荷。仅接受根目录中的唯一class52条目。
        with zipfile.ZipFile(run / 'qualification.jar') as jar:
            name = 'NativeSoundDevicesQualification.class'
            require(jar.namelist().count(name) == 1, 'fixed fixture class missing/duplicate')
            klass = jar.read(name)
            require(klass[:4] == b'\xca\xfe\xba\xbe' and klass[6:8] == b'\x00\x34', 'fixed fixture is not class52')
            result['fixtureClassSha256'] = digest(klass)
        result['files'] = {name: digest(data) for name, data in raw.items()}
        result['files'].update({'result.json': digest(native_raw), 'native-stages.jsonl': digest(stages_raw),
                                '../transfer.json': digest(transfer_raw), '../parent-result.json': digest(parent_raw)})
        result['qualified'] = True
    except (OSError, ValueError, KeyError, TypeError, AttributeError, zipfile.BadZipFile) as error:
        result['problems'].append(type(error).__name__ + ': ' + str(error))
    return result


def main():
    """独占创建收据，退出码反映资格；报告已存在时拒绝覆盖，原始材料始终只读。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    for kind in ('hap', 'jar', 'archive'):
        parser.add_argument('--expected-' + kind + '-sha256', required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    result = verify(args.evidence, args.expected_hap_sha256, args.expected_jar_sha256, args.expected_archive_sha256)
    with args.report.open('x', encoding='utf-8', newline='\n') as output:
        json.dump(result, output, ensure_ascii=False, indent=2); output.write('\n')
    print(json.dumps({'qualified': result['qualified'], 'problems': result['problems']}, ensure_ascii=False))
    raise SystemExit(0 if result['qualified'] else 1)


if __name__ == '__main__':
    main()
