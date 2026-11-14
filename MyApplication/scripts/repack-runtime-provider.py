"""仅以已完整构建的 JDK ZIP 为基础，受控替换兼容应用 ABI provider，形成新的不可变候选。

原 ZIP、sidecar 和冻结输入保持原字节。先核全部文件、权限、实际 ELF/依赖及内外构建身份，
再替换一个确定路径并重跑完整 image 门禁。派生来源明确记录此次重打包，不冒称 OpenJDK 重编。
本工具不赋予设备资格、不上传、不签名、不改变 catalog；CLI 执行许可仍需目标设备验证。
"""
import argparse
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import stat
import struct
import sys
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'docker/scripts'))
from package_runtime import elf_facts, validate_image, validate_native_temp_contract
from sync_jdk_jmods import sync as sync_jdk_jmods
from lib.workspace_paths import external_output_path


def sha(data):
    """对已经读取并固定在内存中的字节计算身份，避免同一验证阶段二次读取被改写源文件。"""
    return hashlib.sha256(data).hexdigest()


def regular_mode(name):
    """沿用完整打包器的真实权限策略：工具和 helper 可执行，库/配置/类数据为0644。"""
    return 0o100755 if name.startswith(('bin/', 'jre/bin/')) or name.endswith('/jspawnhelper') else 0o100644


def safe_name(name):
    """ZIP 路径必须在 Linux 与 Windows 都能按原名物化，不对输入做静默改名。

    每个组件独立检查：Win32 会处理首尾 ASCII 空格与尾点，设备名即使带扩展名也保留
    特殊语义；只检查整个路径末尾会遗漏父目录别名。COM/LPT 的上标1/2/3同样保留。
    禁止这些名字后，后续大小写折叠检查才能证明条目身份不会在宿主落盘时合并。
    规则依据 Microsoft Naming Files/Paths 和 Whitespace Characters 官方说明。
    """
    if (not isinstance(name, str) or not name or len(name) >= 1024
            or re.search(r'[\\:<>"|?*\x00-\x1f\x7f]', name)):
        return False
    for part in name.split('/'):
        if part in ('', '.', '..') or part.startswith(' ') or part.endswith((' ', '.')):
            return False
        # 扩展名不能把设备名变为普通文件；设备名前缀中的尾空格也不用于绕过校验。
        stem = part.split('.', 1)[0].rstrip(' ').upper()
        if re.fullmatch(r'(?:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³]|CONIN\$|CONOUT\$)', stem):
            return False
    return True


def unpack_verified(source, receipt_raw, destination):
    """全包流式读回，内外收据绑定后才物化；任何额外/重复条目和模式漂移均失败。

    失败留下专属工作目录供调查，不能复用半解包目录继续发布。ZIP 的完整 SHA 先由 sidecar
    核对，内部每个文件仍独立核验；sidecar 被一起改动也不能掩盖正文与包内清单不一致。
    """
    receipt = json.loads(receipt_raw)
    size, digest = 0, hashlib.sha256()
    with source.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            size += len(chunk)
            digest.update(chunk)
    if (receipt.get('bytes') != size or receipt.get('sha256') != digest.hexdigest()
            or str(receipt.get('file', '')).replace('\\', '/').split('/')[-1] != source.name):
        raise ValueError('source archive/sidecar identity mismatch')
    with zipfile.ZipFile(source) as archive:
        entries = archive.infolist()
        if not entries or len(entries) > 50000 or sum(i.file_size for i in entries) > 4 * 1024 ** 3:
            raise ValueError('source ZIP inventory exceeds bounds')
        names, folded = set(), set()
        for entry in entries:
            name = entry.filename
            if (not safe_name(name) or name.lower() in folded or entry.flag_bits & 1
                    or entry.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED)
                    or entry.external_attr >> 16 != regular_mode(name)):
                raise ValueError('source ZIP path/type/mode is not canonical: ' + name)
            names.add(name)
            folded.add(name.lower())
        if 'amcl-runtime.json' not in names or archive.getinfo('amcl-runtime.json').file_size > 16 * 1024 ** 2:
            raise ValueError('source ZIP missing bounded runtime manifest')
        manifest_raw = archive.read('amcl-runtime.json')
        manifest = json.loads(manifest_raw)
        if manifest.get('schema') != 1 or manifest.get('build') != receipt.get('build'):
            raise ValueError('source ZIP inner/outer build identity mismatch')
        inventory = manifest.get('files')
        if not isinstance(inventory, dict) or names != set(inventory) | {'amcl-runtime.json'}:
            raise ValueError('source ZIP entry set differs from manifest')
        for name, expected in inventory.items():
            entry = archive.getinfo(name)
            if (not isinstance(expected, dict) or expected.get('bytes') != entry.file_size
                    or ('mode' in expected and expected['mode'] != regular_mode(name))
                    or ('type' in expected and expected['type'] != 'file')):
                raise ValueError('source ZIP file size/mode/type mismatch: ' + name)
            target = destination.joinpath(*name.split('/'))
            target.parent.mkdir(parents=True, exist_ok=True)
            digest = hashlib.sha256()
            with archive.open(entry) as incoming, target.open('xb') as outgoing:
                for chunk in iter(lambda: incoming.read(1024 * 1024), b''):
                    digest.update(chunk)
                    outgoing.write(chunk)
            if digest.hexdigest() != expected.get('sha256'):
                raise ValueError('source ZIP file hash mismatch: ' + name)
            # Windows 不具有 POSIX executable 位；归档 mode 作为权威输入已先逐项核对。
            target.chmod(regular_mode(name) & 0o777)
    return receipt, manifest, manifest_raw


def soname(data):
    """在已通过 elf_facts 的有界节表中取得唯一 DT_SONAME，不能以文件名代替链接身份。"""
    elf_facts(data)
    shoff = struct.unpack_from('<Q', data, 40)[0]
    count = struct.unpack_from('<H', data, 60)[0]
    sections = [struct.unpack_from('<IIQQQQIIQQ', data, shoff + i * 64) for i in range(count)]
    values = []
    for section in sections:
        if section[1] != 6:
            continue
        strings = sections[section[6]]
        table = data[strings[4]:strings[4] + strings[5]]
        for offset in range(section[4], section[4] + section[5], 16):
            tag, value = struct.unpack_from('<qQ', data, offset)
            if tag == 14:
                end = table.find(b'\0', value)
                if value >= len(table) or end < 0:
                    raise ValueError('provider SONAME out of bounds')
                values.append(table[value:end].decode('utf-8'))
    if len(values) != 1:
        raise ValueError('provider requires exactly one SONAME')
    return values[0]


def verify_provider(original, candidate, provenance_raw):
    """按 provider 构建收据锁定字节，核原 SDK 身份、完整导出兼容和系统依赖不变。

    HAP 的二次 strip 摘要不适用于 CLI 包；此处使用收据 artifactSha256 对应的已审核输入。
    原SDK完整导出必须保留，新增仅限已审核的整映像登记API。此静态门不替代真实ABI行为测试。
    """
    provenance = json.loads(provenance_raw)
    if (provenance.get('schemaVersion') != 1 or provenance.get('artifactSha256') != sha(candidate)
            or provenance.get('artifactBytes') != len(candidate)
            or provenance.get('sdk', {}).get('originalSharedSha256') != sha(original)):
        raise ValueError('provider artifact/original SDK provenance mismatch')
    if soname(original) != 'libc++_shared.so' or soname(candidate) != 'libc++_shared.so':
        raise ValueError('provider SONAME mismatch')
    old, new = elf_facts(original), elf_facts(candidate)
    removed = set(old['resolvableExports']) - set(new['resolvableExports'])
    added = set(new['resolvableExports']) - set(old['resolvableExports'])
    if removed or added != {'amcl_unwind_register_image', 'amcl_unwind_unregister_image'} or old['needed'] != new['needed']:
        raise ValueError('provider export/dependency compatibility mismatch')
    return provenance


def font_file(path, expected=None):
    """只读显式字体输入；拒绝链接/非普通文件并按原字节摘要绑定，不隐式追随别名。"""
    path = Path(path)
    if any(p.is_symlink() or (hasattr(p, 'is_junction') and p.is_junction()) for p in (path, *path.parents)):
        raise ValueError('font input link forbidden: ' + str(path))
    if not path.is_file():
        raise ValueError('font input is not a regular file: ' + str(path))
    data = path.read_bytes()
    if expected is not None and sha(data) != expected:
        raise ValueError('font input SHA256 mismatch: ' + str(path))
    return data


def replay_font_patch(originals, patch):
    """只读重放统一 diff 的精确上下文，不调用 Git 或执行来源包脚本。"""
    result, lines, at = {}, patch.decode('utf-8').splitlines(keepends=True), 0
    while at < len(lines):
        match = re.fullmatch(r'diff --git a/(\S+) b/\1\n', lines[at])
        if not match or match[1] not in originals or match[1] in result:
            raise ValueError('font adaptation unexpected patch path/header')
        name = match[1]
        if lines[at + 1:at + 3] != ['--- a/' + name + '\n', '+++ b/' + name + '\n']:
            raise ValueError('font adaptation unsupported patch form')
        before, after, cursor = originals[name].decode('utf-8').splitlines(keepends=True), [], 0
        at += 3
        while at < len(lines) and not lines[at].startswith('diff --git '):
            hunk = re.fullmatch(r'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@[^\n]*\n', lines[at])
            if not hunk:
                raise ValueError('font adaptation invalid hunk header')
            first, count, next_first, next_count = [int(value or 1) for value in hunk.groups()]
            start = first - 1 if count else first
            if start < cursor or start > len(before):
                raise ValueError('font adaptation hunk position outside original')
            after.extend(before[cursor:start]); cursor = start; at += 1
            if (next_first - 1 if next_count else next_first) != len(after):
                raise ValueError('font adaptation resulting hunk position mismatch')
            old_count, new_count = 0, 0
            while at < len(lines) and not lines[at].startswith(('@@ ', 'diff --git ')):
                line = lines[at]
                if not line or line[0] not in ' +-':
                    raise ValueError('font adaptation unsupported hunk body')
                if line[0] in ' -':
                    if cursor >= len(before) or before[cursor] != line[1:]:
                        raise ValueError('font adaptation context differs from locked archive')
                    cursor += 1; old_count += 1
                if line[0] in ' +':
                    after.append(line[1:]); new_count += 1
                at += 1
            if (old_count, new_count) != (count, next_count):
                raise ValueError('font adaptation hunk counts mismatch')
        result[name] = ''.join(after + before[cursor:]).encode('utf-8')
    if set(result) != set(originals):
        raise ValueError('font adaptation incomplete source patch')
    return result


def verify_font_adaptation(source, proof, build_root):
    """新默认适配必须能由原 Git 归档逐字节重建；旧未适配 provider 继续按旧链校验。"""
    key = 'prebuilt/fontconfig/ohos-defaults.json'
    record = source.get('sourceAdaptation')
    index_record = proof['sources']['fontconfig'].get('adaptation')
    if record is None and index_record is None and key not in proof['recipes']:
        return
    if not isinstance(record, dict) or record != index_record or key not in proof['recipes']:
        raise ValueError('font adaptation missing independent frozen/source binding')
    frozen = Path(build_root) / 'inputs/project'
    declared = json.loads(font_file(frozen / key, proof['recipes'][key]))
    names = {'src/fccfg.c', 'src/fcinit.c'}
    if (set(declared['before']) != names or set(declared['after']) != names
            or declared['commit'] != proof['sources']['fontconfig']['commit']
            or any(record.get(name) != value for name, value in declared.items())
            or record.get('genericHeader') != 'prebuilt/fontconfig/ohos-generic-fonts.h'
            or record.get('compiledHeader') != 'src/amcl-generic-fonts.h'):
        raise ValueError('font adaptation source/header identity mismatch')
    patch_name = 'prebuilt/fontconfig/patches/0001-ohos-default-fonts-and-context-cache.patch'
    series_name = 'prebuilt/fontconfig/patches/series'
    if any(not re.fullmatch(r'[0-9a-f]{64}', proof['recipes'].get(name, ''))
           for name in (key, patch_name, series_name, record['genericHeader'])):
        raise ValueError('font adaptation inputs missing from frozen recipe closure')
    patch = font_file(frozen / patch_name, proof['recipes'].get(patch_name))
    series = font_file(frozen / series_name, proof['recipes'].get(series_name)).decode('utf-8')
    if (proof['recipes'].get(patch_name) != declared['patchSha256']
            or [line.strip() for line in series.splitlines() if line.strip() and not line.lstrip().startswith('#')]
            != [Path(patch_name).name]):
        raise ValueError('font adaptation patch/series mismatch')
    originals = {}
    archive_path = Path(build_root) / 'out/sources' / proof['sources']['fontconfig']['archive']
    with tarfile.open(archive_path) as archive:
        if archive.pax_headers.get('comment') != declared['commit']:
            raise ValueError('font adaptation archive commit identity mismatch')
        for name in names:
            members = [member for member in archive.getmembers() if member.name == name]
            if len(members) != 1 or not members[0].isfile():
                raise ValueError('font adaptation base source not a unique ordinary member')
            originals[name] = archive.extractfile(members[0]).read()
    if ({name: sha(data) for name, data in originals.items()} != declared['before'] or
            {name: sha(data) for name, data in replay_font_patch(originals, patch).items()} != declared['after']):
        raise ValueError('font adaptation replay differs from claimed compiled source')
    header = font_file(frozen / record['genericHeader'], record['genericHeaderSha256'])
    if proof['recipes'].get(record['genericHeader']) != sha(header):
        raise ValueError('font adaptation generic header outside frozen closure')
    generic = re.search(r'^#define AMCL_FONTCONFIG_GENERIC_RULES (".*")$', header.decode('utf-8'), re.M)
    if not generic:
        raise ValueError('font adaptation generic macro missing')
    markers = {'genericXml': json.loads(generic[1]).encode('utf-8'),
               'contextApi': b'OH_AbilityRuntime_ApplicationContextGetCacheDir', 'contextLibrary': b'libability_runtime.so',
               'outsideRuntimeCache': b'.amcl-fontconfig-cache', 'classicLayout': b'/jre/lib/aarch64/libfontconfig.so',
               'modernLayout': b'/lib/libfontconfig.so'}
    compiled = source.get('compiledOhosDefaults', {})
    library = font_file(Path(build_root) / 'out/reference/libfontconfig-original.so', source['sourceLibrarySha256'])
    if (set(compiled.get('markers', {})) != set(markers) or compiled.get('hardContextApiImport') is not False
            or any(name.startswith('OH_AbilityRuntime_') for name in elf_facts(library)['strongImports'])):
        raise ValueError('font adaptation compiled default dependency/marker set mismatch')
    for name, data in markers.items():
        actual = compiled['markers'][name]
        if (not isinstance(actual.get('offset'), int) or actual['offset'] < 0 or actual['sizeBytes'] != len(data)
                or actual['sha256'] != sha(data) or library[actual['offset']:actual['offset'] + len(data)] != data):
            raise ValueError('font adaptation marker differs from actual compiled ELF')


def font_producer(proof_raw, build_root):
    """核对真实成功的 provider 构建、冻结配方、源码归档与许可证来源。

    这条链与 JDK 编译输入独立；参考 FreeType 只参与构建/链接，不在这里交付。
    原构建可以早于当前配方修复，故只消费该次 inputs/project 的冻结字节。
    """
    proof = json.loads(proof_raw)
    if proof.get('schemaVersion') != 1:
        raise ValueError('unsupported font provenance schema')
    build_root = Path(build_root)
    outer_raw = font_file(build_root / 'build-manifest.json', proof['buildManifestSha256'])
    outer = json.loads(outer_raw)
    source_raw = font_file(build_root / 'out/fontconfig-provenance.json', proof['providerProvenanceSha256'])
    source = json.loads(source_raw)
    if (outer.get('state') != 'completed' or outer.get('exitCode') != 0 or outer.get('component') != 'fontconfig'
            or outer['runId'] != proof['buildId'] or outer['imageId'] != proof['builderImageId']
            or outer['inputs']['digest'] != proof['buildInputDigest'] or outer['inputs']['files'] != proof['recipes']
            or source['specSha256'] != proof['specSha256'] or source['variants'] != proof['variants']
            or source['requiredFreeTypeSymbols'] != proof['requiredFreeTypeSymbols']):
        raise ValueError('font provider build/provenance identity mismatch')
    sdk = outer['inputs']['nativeSdk']
    sdk_index = json.dumps(sdk['files'], sort_keys=True, separators=(',', ':')).encode()
    if (proof['sdk']['resourceVersion'] != sdk['resourceVersion']
            or proof['sdk']['sentinels'] != outer['inputs']['sdk']
            or proof['sdk']['completeIndexSha256'] != sha(sdk_index)):
        raise ValueError('font provider SDK provenance differs from complete build input index')
    font_file(build_root / 'build.log', proof['buildLogSha256'])
    for name, expected in proof['recipes'].items():
        if not safe_name(name) or not name.startswith(('docker/', 'prebuilt/', 'deps.lock')):
            raise ValueError('unexpected frozen font recipe path')
        font_file(build_root / 'inputs/project' / name, expected)
    # 明确原 spec，不能只依赖可自行改写的版本名称或23这个数量。
    spec_raw = font_file(build_root / 'inputs/project/prebuilt/fontconfig/build-inputs.json', proof['specSha256'])
    if json.loads(spec_raw) != source['spec']:
        raise ValueError('font spec differs from frozen build')
    source_index_raw = font_file(build_root / 'out/sources/source-identities.json')
    if json.loads(source_index_raw) != proof['sources'] or set(proof['sources']) != {'fontconfig', 'expat', 'freetype'}:
        raise ValueError('font upstream source index mismatch')
    licenses = {}
    for name, item in proof['sources'].items():
        locked = source['spec']['sources'][name]
        if (item['commit'] != locked['commit'] or item['repository'] != locked['repository']
                or not re.fullmatch(r'[0-9a-f]{40}', item['commit'])
                or item['archive'] != name + '-' + item['commit'] + '.tar'):
            raise ValueError('font upstream source identity mismatch')
        archive_path = build_root / 'out/sources' / item['archive']
        font_file(archive_path, item['archiveSha256'])
        if name in ('fontconfig', 'expat'):
            with tarfile.open(archive_path) as archive:
                hits = [entry for entry in archive if entry.name == 'COPYING']
                if len(hits) != 1 or not hits[0].isfile():
                    raise ValueError('font upstream license missing or ambiguous')
                licenses[name] = archive.extractfile(hits[0]).read()
            license_info = proof['licenses'][name]
            if (sha(licenses[name]) != license_info['sha256'] or license_info['sourceCommit'] != item['commit']
                    or license_info['sourceFile'] != 'COPYING'):
                raise ValueError('font license does not match locked upstream source')
    for name, item in [('meson.whl', source['spec']['meson']),
                       ('gperf-' + source['spec']['gperf']['version'] + '.tar.gz', source['spec']['gperf'])]:
        font_file(build_root / 'out/sources' / name, item['sha256'])
    verify_font_adaptation(source, proof, build_root)
    return proof, source, licenses


def verify_freetype_notice(bundle, major, build, compiled_inputs):
    """把派生 notice 与原 JDK 已冻结的新增源码/许可逐字节关联，不修改编译收据。"""
    if not build or compiled_inputs is None:
        raise ValueError('modern font notices require original compiled input closure and explicit --compiled-inputs')
    declared = bundle.get('notices')
    if not isinstance(declared, dict) or major not in declared or not set(declared) <= {'17', '21', '25'}:
        raise ValueError('font bundle must declare version-matched notices for the selected modern JDK')
    provenance_raw = font_file(bundle['noticeManifest']['path'], bundle['noticeManifest']['sha256'])
    provenance = json.loads(provenance_raw)
    if (provenance.get('schemaVersion') != 1 or provenance.get('kind') != 'version-matched-freetype-notices'
            or provenance.get('scope') != 'derived-distribution-supplement' or provenance.get('compiledInput') is not False):
        raise ValueError('FreeType notices must be explicit derived supplements, not compiled inputs')
    generator_path = ROOT / 'scripts/freetype-notices.py'
    generator_raw = font_file(generator_path, provenance['generatorSha256'])
    specification = importlib.util.spec_from_file_location('runtime_freetype_notices', generator_path)
    generator = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(generator)
    frozen = build['inputClosure']['files']
    def source(name, expected):
        if not safe_name(name) or frozen.get(name) != expected:
            raise ValueError('FreeType notice source is not the original frozen compiler input: ' + name)
        return font_file(Path(compiled_inputs) / name, expected)
    completion_raw = source('prebuilt/fontconfig/freetype-completion.json', provenance['completionManifestSha256'])
    completion = json.loads(completion_raw)
    original = completion['runtimes'][major]
    if build['commit'] != original['jdkCommit']:
        raise ValueError('FreeType notice belongs to another JDK source commit')
    patch = source(original['patch'], original['patchSha256'])
    licenses = {name: source(item['path'], item['sha256']) for name, item in original['licenses'].items()}
    declaration = declared[major]
    target = 'legal/amcl-freetype-completion/NOTICE.txt'
    if declaration.get('target') != target or declaration.get('mode') != 0o100644:
        raise ValueError('FreeType notice destination/mode outside derived allowlist')
    actual = font_file(declaration['path'], declaration['sha256'])
    if declaration.get('bytes') != len(actual):
        raise ValueError('FreeType notice byte length mismatch')
    generator.verify_record(major, completion_raw, patch, licenses, provenance['runtimes'][major], actual)
    audit = {'schemaVersion': 1, 'scope': 'derived-distribution-supplement', 'compiledInput': False,
             'manifestSha256': sha(provenance_raw), 'generatorSha256': sha(generator_raw),
             'completionManifestSha256': sha(completion_raw), 'major': major,
             'path': target, 'sha256': sha(actual), 'bytes': len(actual), 'mode': 0o100644}
    evidence = {'freetype-notices-manifest.json': provenance_raw, 'freetype-runtime-NOTICE.txt': actual,
                'freetype-notices-generator.py': generator_raw}
    return target, actual, audit, evidence


def verify_font_bundle(manifest_path, major, files, build=None, compiled_inputs=None):
    """仅允许显式清单中的库、许可和现代 notice；FreeType 必须来自原完整 JDK ZIP。

    清单同时声明两种依赖名变体和两份许可；选定 JDK 只加入对应 provider 及许可。
    不接收替换 FreeType、任意配置、脚本或其他原文件的入口。
    """
    raw = font_file(manifest_path)
    bundle = json.loads(raw)
    if bundle.get('schemaVersion') not in (1, 2):
        raise ValueError('unsupported font bundle schema')
    if major != '8' and bundle['schemaVersion'] != 2:
        raise ValueError('modern font derivative requires v2 bundle with exact added-driver notices')
    proof_raw = font_file(bundle['provenance']['path'], bundle['provenance']['sha256'])
    proof, source, licenses = font_producer(proof_raw, bundle['producerRoot'])
    declared = bundle['additions']
    targets = {'classic': 'jre/lib/aarch64/libfontconfig.so', 'modern': 'lib/libfontconfig.so',
               'fontconfig-license': 'legal/amcl-fontconfig/COPYING', 'expat-license': 'legal/amcl-expat/COPYING'}
    if not isinstance(declared, dict) or set(declared) != set(targets):
        raise ValueError('font bundle must explicitly declare two providers and two licenses')
    payloads = {}
    for kind, target in targets.items():
        item = declared[kind]
        if item.get('target') != target or item.get('mode') != 0o100644:
            raise ValueError('font addition path/mode outside allowlist')
        data = font_file(item['path'], item['sha256'])
        if item.get('bytes') != len(data):
            raise ValueError('font addition byte length mismatch')
        if kind in ('classic', 'modern'):
            variant = proof['variants'][kind]
            built = font_file(Path(bundle['producerRoot']) / 'out' / variant['path'], variant['sha256'])
            if data != built or len(data) != variant['sizeBytes']:
                raise ValueError('font addition differs from actual provider build')
        elif data != licenses[kind.removesuffix('-license')]:
            raise ValueError('font addition differs from upstream license')
        payloads[kind] = data
    variant = 'classic' if major == '8' else 'modern'
    native = 'jre/lib/aarch64/' if major == '8' else 'lib/'
    freetype_name = 'libfreetype.so.6' if major == '8' else 'libfreetype.so'
    freetype_path = native + freetype_name
    if freetype_path not in files:
        raise ValueError('font bundle requires original JDK FreeType')
    freetype = files[freetype_path].read_bytes()
    library = payloads[variant]
    facts = elf_facts(library)
    required = sorted(name for name in facts['strongImports'] if name.startswith('FT_'))
    if (soname(library) != 'libfontconfig.so' or facts['needed'] != sorted(['libc.so', freetype_name])
            or required != proof['requiredFreeTypeSymbols'] or len(required) != 23
            or any(name.startswith(('FT_', 'XML_')) for name in facts['resolvableExports'])):
        raise ValueError('font provider actual ELF surface differs from reviewed closure')
    if soname(freetype) != freetype_name or set(required) - set(elf_facts(freetype)['resolvableExports']):
        raise ValueError('original JDK FreeType cannot satisfy all 23 font provider imports; rebuild JDK')
    additions = {targets[kind]: payloads[kind] for kind in (variant, 'fontconfig-license', 'expat-license')}
    notice_audit, notice_evidence = None, {}
    if major != '8':
        target, data, notice_audit, notice_evidence = verify_freetype_notice(bundle, major, build, compiled_inputs)
        additions[target] = data
    if any(name in files for name in additions):
        raise ValueError('font additions would overwrite an original archive entry')
    audit = {'inputManifestSha256': sha(raw), 'provenanceSha256': sha(proof_raw),
             'producerBuildManifestSha256': proof['buildManifestSha256'],
             'providerSourceProvenanceSha256': proof['providerProvenanceSha256'],
             'variant': variant, 'freeTypePath': freetype_path, 'freeTypeSha256': sha(freetype),
             'requiredFreeTypeSymbols': required,
             'additions': {name: {'sha256': sha(data), 'bytes': len(data), 'mode': 0o100644}
                           for name, data in sorted(additions.items())},
             'referenceFreeTypeDelivered': False,
             'qualification': 'static provider/source/dependency closure only; standalone CLI execution/cache and Java font behavior remain separate'}
    if notice_audit:
        audit['derivedNotices'] = notice_audit
    return additions, audit, {'font-bundle.json': raw, 'font-provider-provenance.json': proof_raw, **notice_evidence}


def verify_font_dependency_closure(font_path, files, system_library_dir):
    """逐个走真实 DT_NEEDED 并核强符号，额外记录目标包和 SDK 供应者的精确身份。"""
    by_name = {}
    for path in files:
        if '.so' in Path(path).name:
            by_name.setdefault(Path(path).name, []).append(path)
    visited, available, suppliers = set(), set(), {}
    def visit(name):
        if name in visited:
            return
        visited.add(name)
        if name in by_name:
            paths = by_name[name]
            if len(paths) != 1:
                raise ValueError('ambiguous font dependency supplier: ' + name)
            data = files[paths[0]].read_bytes()
            record = {'kind': 'bundled', 'path': paths[0], 'sha256': sha(data)}
        else:
            data = font_file(Path(system_library_dir) / name)
            record = {'kind': 'sdk', 'sha256': sha(data)}
        facts = elf_facts(data)
        if name != 'libc.so' and soname(data) != name:
            raise ValueError('font dependency SONAME mismatch: ' + name)
        suppliers[name] = record
        available.update(facts['resolvableExports'])
        for dependency in facts['needed']:
            visit(dependency)
    visit(Path(font_path).name)
    required = set(elf_facts(files[font_path].read_bytes())['strongImports'])
    if required - available:
        raise ValueError('font provider unresolved strong symbols: ' + ', '.join(sorted(required - available)))
    return {'requiredSymbolCount': len(required), 'suppliers': suppliers}


def repack(source, manifest_path, provider_path, provenance_path, system_library_dir, build_id, output, work_dir,
           font_bundle=None, compiled_inputs=None):
    """独占外置工作目录内执行完整验证与重打包；候选/sidecar 均使用新名称且拒绝覆盖。"""
    output = external_output_path(output)
    work_dir = external_output_path(work_dir)
    sidecar = output.with_suffix('.manifest.json')
    partial = output.with_suffix('.zip.partial')
    if not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,95}', build_id):
        raise ValueError('invalid new buildId')
    if output.name == source.name or any(p.exists() for p in (output, sidecar, partial)):
        raise ValueError('new immutable output identity required; existing files are preserved')
    work_dir.parent.mkdir(parents=True, exist_ok=True)
    work_dir.mkdir()  # 已有目录视为活动/失败现场，不清空或接续。
    image = work_dir / 'image'
    image.mkdir()
    original_receipt_raw = manifest_path.read_bytes()
    receipt, old_manifest, old_manifest_raw = unpack_verified(source, original_receipt_raw, image)
    major = str(receipt['build']['major'])
    native = 'jre/lib/aarch64/' if major == '8' else 'lib/'
    provider_name = native + 'libc++_shared.so'
    files, libraries = validate_image(image, major, system_library_dir)
    validate_native_temp_contract(libraries, major, receipt['build'])
    if libraries != old_manifest.get('nativeLibraries'):
        raise ValueError('source actual ELF/dependency audit differs from embedded manifest')
    original = files[provider_name].read_bytes()
    candidate, provenance_raw = provider_path.read_bytes(), provenance_path.read_bytes()
    provenance = verify_provider(original, candidate, provenance_raw)
    files[provider_name].write_bytes(candidate)
    # provider 再封包同样会改变 jlink 的原生输入；不能只更新外层 image。
    # 标准闭包已经由完整构建提供，此处同步同一个新 provider，并明确记录 JMOD 派生身份。
    jmod_audit = None
    font_audit, font_evidence = None, {}
    if font_bundle is not None:
        additions, font_audit, font_evidence = verify_font_bundle(font_bundle, major, files, receipt['build'], compiled_inputs)
        for name, data in additions.items():
            target = image / name
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open('xb') as handle:
                handle.write(data)
    # 字体附加项完成后再同步 java.desktop；它与 java.base 的 ABI 属于不同模块闭包。
    jmod_audit = sync_jdk_jmods(image) if major != '8' else None
    files, libraries = validate_image(image, major, system_library_dir)
    validate_native_temp_contract(libraries, major, receipt['build'])
    if font_audit:
        font_audit['linkAudit'] = verify_font_dependency_closure(native + 'libfontconfig.so', files, system_library_dir)
    # 独立核对变化集合，不能仅依赖新 manifest 对自身的读回来掩盖原文件意外漂移。
    allowed_new = set(font_audit['additions']) if font_audit else set()
    if set(files) != set(old_manifest['files']) | allowed_new:
        raise ValueError('derived image changed the allowed original/addition entry set')
    for name, previous in old_manifest['files'].items():
        changed_paths = {provider_name} | ({'jmods/' + module for module in jmod_audit['modules']} if jmod_audit else set())
        if name not in changed_paths and sha(files[name].read_bytes()) != previous['sha256']:
            raise ValueError('derived image modified unrelated original bytes: ' + name)
    build = copy.deepcopy(receipt['build'])
    build['cxxAbi']['providerSha256'] = sha(candidate)
    derivation = {'schemaVersion': 1, 'kind': 'compatible-cxx-provider-repack', 'buildId': build_id,
                  'originalArchive': {'fileName': source.name, 'bytes': receipt['bytes'], 'sha256': receipt['sha256']},
                  'originalReceiptSha256': sha(original_receipt_raw), 'originalInnerManifestSha256': sha(old_manifest_raw),
                  'providerPath': provider_name, 'providerProvenanceSha256': sha(provenance_raw),
                  'providerSha256': sha(candidate), 'originalProviderSha256': sha(original),
                  'recipeSha256': sha(Path(__file__).read_bytes()),
                  'qualification': 'complete archive/image and provider static compatibility only; device qualification remains separate'}
    if jmod_audit:
        helper = ROOT / 'docker/scripts/sync_jdk_jmods.py'
        derivation['jmodClosure'] = dict(jmod_audit, recipeSha256=sha(helper.read_bytes()))
    if font_audit:
        derivation.update(kind='compatible-cxx-font-provider-repack', fontBundle=font_audit)
    new_manifest = copy.deepcopy(old_manifest)
    new_manifest.update(build=build, buildId=build_id, derivation=derivation, nativeLibraries=libraries)
    new_manifest['files'] = {name: {'bytes': path.stat().st_size, 'sha256': sha(path.read_bytes()),
                                   'mode': regular_mode(name), 'type': 'file'} for name, path in sorted(files.items())}
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(partial, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, path in sorted(files.items()):
            info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = regular_mode(name) << 16
            archive.writestr(info, path.read_bytes())
        info = zipfile.ZipInfo('amcl-runtime.json', (1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
        archive.writestr(info, json.dumps(new_manifest, ensure_ascii=False, sort_keys=True, indent=2).encode())
    # 回读精确集合/正文/mode，包括新 manifest。原文件身份留在派生记录中，不修改原收据。
    with zipfile.ZipFile(partial) as archive:
        if set(archive.namelist()) != set(files) | {'amcl-runtime.json'} or len(archive.namelist()) != len(files) + 1:
            raise ValueError('repacked ZIP entry set mismatch')
        if json.loads(archive.read('amcl-runtime.json')) != new_manifest:
            raise ValueError('repacked manifest readback mismatch')
        for name, expected in new_manifest['files'].items():
            actual = archive.read(name)
            if len(actual) != expected['bytes'] or sha(actual) != expected['sha256'] or archive.getinfo(name).external_attr >> 16 != expected['mode']:
                raise ValueError('repacked ZIP file readback mismatch: ' + name)
    # 输出占位使用独占创建后复制，避免 POSIX rename 静默覆盖同时产生的同名候选。
    with partial.open('rb') as incoming, output.open('xb') as outgoing:
        for chunk in iter(lambda: incoming.read(1024 * 1024), b''):
            outgoing.write(chunk)
    final = {'file': str(output), 'bytes': output.stat().st_size, 'sha256': sha(output.read_bytes()),
             'buildId': build_id, 'build': build, 'derivation': derivation}
    with sidecar.open('x', encoding='utf-8') as handle:
        handle.write(json.dumps(final, ensure_ascii=False, indent=2) + '\n')
    # 后续公开源码包需要这两份原始输入；本地专属工作目录保存精确原字节，不泄漏私钥。
    (work_dir / 'original-build-receipt.json').write_bytes(original_receipt_raw)
    (work_dir / 'provider-provenance.json').write_bytes(provenance_raw)
    for name, data in font_evidence.items():
        (work_dir / name).write_bytes(data)
    # 保存此次实际执行配方，后续源码导出无需依赖可能已继续演进的工作树。
    (work_dir / 'repack-runtime-provider.py').write_bytes(Path(__file__).read_bytes())
    if jmod_audit:
        (work_dir / 'sync_jdk_jmods.py').write_bytes((ROOT / 'docker/scripts/sync_jdk_jmods.py').read_bytes())
    return {'file': str(output), 'bytes': final['bytes'], 'sha256': final['sha256'], 'receipt': str(sidecar), 'buildId': build_id}


def main():
    """所有路径显式给出，尤其系统库目录必须来自本轮构建 SDK，不能隐式取另一套工具链。"""
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'manifest', 'provider', 'provider-provenance', 'system-library-dir', 'output', 'work-dir'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--build-id', required=True)
    parser.add_argument('--font-bundle', type=Path, help='optional explicit font provider/license bundle; original FreeType is never replaced')
    parser.add_argument('--compiled-inputs', type=Path, help='modern font notices: exact original build inputs/project; read only, not rewritten')
    args = parser.parse_args()
    result = repack(args.source, args.manifest, args.provider, args.provider_provenance, args.system_library_dir,
                    args.build_id, args.output, args.work_dir, font_bundle=args.font_bundle, compiled_inputs=args.compiled_inputs)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
