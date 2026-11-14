#!/usr/bin/env python3
"""核对默认字体报告的细项；预期根/FC/FT身份须来自宿主固定侧车，报告本身不是信任根。"""
import argparse
import hashlib
import json
from pathlib import Path
import re


def verify(report, major, root, fc_sha, ft_sha):
    """不凭顶层 passed 或耗时大小猜缓存命中；要求 load-only、磁盘实物与未变槽正文。"""
    problems = []
    def require(condition, message):
        if not condition:
            problems.append(message)
    require(major in ('8', '17', '21', '25') and all(re.fullmatch('[a-f0-9]{64}', v) for v in (fc_sha, ft_sha)), 'invalid independent expected identity')
    require(root.startswith('/') and root != '/' and all(part not in ('', '.', '..') for part in root[1:].split('/')), 'invalid expected canonical root')
    require(report.get('schema') == 1 and report.get('scope') == 'installed-provider isolated-NCP default cache only', 'wrong report scope/schema')
    require(report.get('freshExecQualified') is False, 'NCP report must not claim fresh exec qualification')
    require(report.get('passed') is True and report.get('major') == major and report.get('jdkRoot') == root, 'failed or wrong runtime report')
    require(type(report.get('pid')) is int and report['pid'] > 0, 'invalid process identity')
    for key in ('environmentRestored', 'cwdRestored', 'searchPathRestoredBySetter', 'moduleReferencesClosed', 'runtimeContentAndModesUnchanged'):
        require(report.get(key) is True, key)
    require(report.get('error') == '', 'report contains a failure')
    observed = report.get('observation', {})
    native = root + ('/jre/lib/aarch64/' if major == '8' else '/lib/')
    expected_cache = root.rsplit('/', 1)[0] + '/.amcl-fontconfig-cache/fontconfig'
    require(observed.get('fontconfigOrigin') == native + 'libfontconfig.so', 'Fontconfig symbol came from another provider')
    require(observed.get('freeTypeOrigin') == native + ('libfreetype.so.6' if major == '8' else 'libfreetype.so'), 'FreeType symbol came from another provider')
    for key, expected in (('fontconfigFile', fc_sha), ('freeTypeFile', ft_sha)):
        item = observed.get(key, {})
        require(item.get('sha256') == expected and type(item.get('bytes')) is int and item['bytes'] > 0, key + ' differs from approved file')
    require(observed.get('readOnlyCwd') is True and observed.get('cwdAccessErrno') in (1, 13, 30), 'read-only CWD not observed')
    require(observed.get('expectedCacheDirectory') == expected_cache and observed.get('cacheDirectories') == [expected_cache], 'wrong default cache root')
    require('/system/fonts' in observed.get('fontDirectories', []), 'system fonts absent')
    cache = observed.get('cacheFile', '')
    require(cache.startswith(expected_cache + '/') and '/' not in cache[len(expected_cache) + 1:] and cache != expected_cache + '/', 'cache file is not directly in expected cache directory')
    first, second = observed.get('cacheAfterCold', {}), observed.get('cacheAfterWarm', {})
    require(bool(first) and first == second, 'actual cache file changed across warm load')
    require(re.fullmatch('[a-f0-9]{64}', first.get('sha256', '')) and type(first.get('bytes')) is int and first['bytes'] > 0, 'missing actual cache bytes/hash')
    for key in ('forcedColdRescan', 'warmUsedLoadOnlyApi', 'cacheUnchangedOnWarm', 'cacheDurabilitySync'):
        require(observed.get(key) is True, key)
    require(type(observed.get('cachedFontCount')) is int and observed['cachedFontCount'] > 0, 'no font entries loaded')
    for key in ('coldMicroseconds', 'warmLoadOnlyMicroseconds'):
        require(type(observed.get(key)) is int and observed[key] >= 0, key)
    before = observed.get('runtimeBeforeSha256', '')
    require(re.fullmatch('[a-f0-9]{64}', before) and before == observed.get('runtimeAfterSha256'), 'runtime contents/modes changed')
    require(type(observed.get('runtimeFileCount')) is int and observed['runtimeFileCount'] > 0 and
            type(observed.get('runtimeBytes')) is int and observed['runtimeBytes'] > 0, 'missing runtime inventory')
    matches = observed.get('matches', [])
    require(len(matches) == 2 and {item.get('character') for item in matches} == {0x41, 0x4e2d}, 'Latin/Chinese match coverage incomplete')
    for item in matches:
        require(item.get('covered') is True and bool(item.get('family')) and item.get('file', '').startswith('/system/fonts/'), 'font match failed or not a system font')
    return {'defaultCacheQualified': not problems, 'problems': problems, 'major': major, 'pid': report.get('pid'),
            'fontconfigSha256': fc_sha, 'freeTypeSha256': ft_sha, 'cacheFile': cache,
            'coldMicroseconds': observed.get('coldMicroseconds'), 'warmLoadOnlyMicroseconds': observed.get('warmLoadOnlyMicroseconds'),
            'scope': 'exact approved installed provider, one NCP cache profile; no fresh exec, full CLI, overall performance or device-matrix qualification'}


def strict_object(pairs):
    result = {}
    for name, value in pairs:
        if name in result:
            raise ValueError('duplicate report field: ' + name)
        result[name] = value
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--report', required=True, type=Path)
    parser.add_argument('--major', required=True, choices=('8', '17', '21', '25'))
    parser.add_argument('--jdk-root', required=True)
    parser.add_argument('--fontconfig-sha256', required=True)
    parser.add_argument('--freetype-sha256', required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    raw = args.report.read_bytes()
    if len(raw) > 1024 * 1024:
        raise ValueError('report exceeds bound')
    report = json.loads(raw, object_pairs_hook=strict_object)
    result = verify(report, args.major, args.jdk_root, args.fontconfig_sha256, args.freetype_sha256)
    result['reportSha256'] = hashlib.sha256(raw).hexdigest()
    encoded = json.dumps(result, ensure_ascii=False, indent=2) + '\n'
    if args.output:
        if args.output.resolve().is_relative_to(Path(__file__).resolve().parents[2]):
            raise ValueError('verification output must be external')
        with args.output.open('x', encoding='utf-8') as output:
            output.write(encoded)
    print(encoded, end='')
    raise SystemExit(0 if result['defaultCacheQualified'] else 1)


if __name__ == '__main__':
    main()
