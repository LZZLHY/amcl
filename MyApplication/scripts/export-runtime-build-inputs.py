"""导出运行时的可公开源码输入：白名单目录、精确 patch/recipe 摘要、固定 ZIP 元数据。

只收集构建所需的自有配方和补丁；上游 OpenJDK/FreeType 通过固定 commit 取源。
不会读取凭据、应用源码、签名材料或 Docker 数据卷。可从指定 Git revision 恢复旧候选
对应输入，不用当前已变化的打包器冒充旧候选的生成配方。
"""
import argparse
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import stat
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def source_name(name):
    """只接受可公开的规范源码相对路径；不跟随链接，也不把凭据/制品当源码导出。"""
    parts = name.split('/')
    if (not name or '\\' in name or ':' in name or any(p in ('', '.', '..') for p in parts)
            or any(p in ('.secrets', '.git', 'output', 'node_modules') for p in parts)
            or name.endswith(('.pem', '.p12', '.zip', '.key'))):
        raise ValueError('non-source path in export: ' + name)
    allowed = name in ('deps.lock', 'scripts/repack-runtime-provider.py', 'scripts/freetype-notices.py') or name.startswith(('docker/', 'prebuilt/jdk/', 'prebuilt/stubs/src/',
                                                    'prebuilt/abi/', 'prebuilt/fontconfig/', 'scripts/lib/', 'tests/runtime-abi/'))
    if not allowed:
        raise ValueError('source path outside public build scope: ' + name)
    return name


def read_regular(root, name):
    """校验每个路径组件，防止冻结目录中的链接跳到 SDK、凭据或其他工作树。"""
    source_name(name)
    root = root.resolve(strict=True)
    path = root
    for part in name.split('/'):
        path = path / part
        if path.is_symlink() or (hasattr(path, 'is_junction') and path.is_junction()):
            raise ValueError('source link forbidden: ' + name)
    if not stat.S_ISREG(path.stat().st_mode) or not path.resolve().is_relative_to(root):
        raise ValueError('source is not a regular in-root file: ' + name)
    return path.read_bytes()


def write_archive(output, files, identity):
    """排好序的固定 ZIP 元数据；写完逐项读回，包括清单自身，已有输出绝不覆盖。"""
    if 'source-inputs.json' in files:
        raise ValueError('reserved source-inputs.json entry')
    identity['files'] = {n: hashlib.sha256(b).hexdigest() for n, b in sorted(files.items())}
    contents = dict(files)
    contents['source-inputs.json'] = (json.dumps(identity, indent=2) + '\n').encode()
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(contents.items()):
            info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data)
    with zipfile.ZipFile(output) as archive:
        if archive.namelist() != sorted(contents) or archive.testzip() is not None:
            raise ValueError('source ZIP directory/CRC readback mismatch')
        for name, data in contents.items():
            if archive.read(name) != data or archive.getinfo(name).external_attr >> 16 != 0o100644:
                raise ValueError('source ZIP bytes/mode readback mismatch: ' + name)
    return {'file': str(output), 'sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
            'bytes': output.stat().st_size, 'verifiedInputs': len(identity['files'])}


def derived_provider_inputs(receipt, source_root, work_root, provider_root, revision=None, repack_recipe=None):
    """收集兼容 provider 再封包的独立来源链，明确与最初 OpenJDK 构建的冻结输入分开。

    每个路径来自明确参数和固定目录约定；构建/SDK/上游记录必须互相吻合。
    原始 SDK 不公开打入输入包，保留 native-inputs.json 的完整摘要清单和原始供应者身份。
    """
    derivation = receipt['derivation']
    if derivation.get('kind') not in ('compatible-cxx-provider-repack', 'compatible-cxx-font-provider-repack') or not work_root or not provider_root:
        raise ValueError('derived runtime requires explicit repack and provider build inputs')
    original_raw = (work_root / 'original-build-receipt.json').read_bytes()
    provider_raw = (work_root / 'provider-provenance.json').read_bytes()
    if (hashlib.sha256(original_raw).hexdigest() != derivation['originalReceiptSha256']
            or hashlib.sha256(provider_raw).hexdigest() != derivation['providerProvenanceSha256']):
        raise ValueError('derived runtime original/provider receipt mismatch')
    original, provider = json.loads(original_raw), json.loads(provider_raw)
    expected = derivation['originalArchive']
    if (original['bytes'] != expected['bytes'] or original['sha256'] != expected['sha256']
            or original['file'].replace('\\', '/').split('/')[-1] != expected['fileName']
            or provider['artifactSha256'] != derivation['providerSha256']
            or provider['sdk']['originalSharedSha256'] != derivation['originalProviderSha256']):
        raise ValueError('derived runtime source/provider artifact identity mismatch')
    restored_build = copy.deepcopy(receipt['build'])
    restored_build['cxxAbi']['providerSha256'] = derivation['originalProviderSha256']
    if restored_build != original['build']:
        raise ValueError('provider repack changed unrelated original build identity')
    outer_raw = (provider_root / 'build-manifest.json').read_bytes()
    provider_outer = json.loads(outer_raw)
    sdk_raw = (provider_root / 'out/native-inputs.json').read_bytes()
    if (provider_outer.get('state') != 'completed' or provider_outer.get('exitCode') != 0
            or provider_outer.get('unwindInputs') != provider['source']
            or provider_outer.get('imageId') != provider['builderImageId']
            or hashlib.sha256(sdk_raw).hexdigest() != provider['sdk']['inputManifestSha256']):
        raise ValueError('provider build/input manifest mismatch')
    files = {'original-build-receipt.json': original_raw, 'provider-provenance.json': provider_raw,
             'provider-build-manifest.json': outer_raw, 'provider-sdk-inputs.json': sdk_raw}
    for name, expected in provider['source']['files'].items():
        if name not in ('source.tar', 'source.json', 'amcl_unwind_image.h', 'amcl_unwind_images.hpp',
                        '0001-checked-fde-registration.patch'):
            raise ValueError('unknown public provider source input: ' + name)
        path = provider_root / 'unwind-input' / name
        if path.is_symlink() or not path.is_file():
            raise ValueError('provider source input is not regular: ' + name)
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError('provider frozen source mismatch: ' + name)
        files['provider-source/' + name] = data
    for name, expected in provider['recipes'].items():
        source_name(name)
        data = git('show', revision + ':' + name) if revision else read_regular(source_root, name)
        data, _ = recorded_text_bytes(data, expected, read_regular(source_root, name))
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError('provider recipe mismatch; specify actual --provider-recipe-revision: ' + name)
        files[name] = data
    # 新派生保存执行时的配方原件；历史 C++only 审计可以显式提供原配方文件。
    # 两条路都必须命中派生收据中的 SHA，不能以“当前功能相同”代替原来源。
    if repack_recipe is not None:
        if repack_recipe.is_symlink() or not repack_recipe.is_file():
            raise ValueError('explicit original repack recipe must be a regular file')
        recipe = repack_recipe.read_bytes()
    elif (work_root / 'repack-runtime-provider.py').is_file():
        recipe = (work_root / 'repack-runtime-provider.py').read_bytes()
    else:
        recipe = read_regular(source_root, 'scripts/repack-runtime-provider.py')
    if hashlib.sha256(recipe).hexdigest() != derivation['recipeSha256']:
        raise ValueError('repack recipe changed since derivative was created')
    files['scripts/repack-runtime-provider.py'] = recipe
    # JMOD 同步属于派生实际输入，必须携带当次执行的脚本，不能读取后来演进的活文件。
    if derivation.get('jmodClosure'):
        helper = (work_root / 'sync_jdk_jmods.py').read_bytes()
        if hashlib.sha256(helper).hexdigest() != derivation['jmodClosure']['recipeSha256']:
            raise ValueError('JMOD closure recipe changed since derivative was created')
        files['docker/scripts/sync_jdk_jmods.py'] = helper
    return files


def derived_font_inputs(receipt, work_root, font_root, compiled_root=None):
    """独立导出 provider 的冻结配方、完整上游归档及许可，不污染 JDK 编译事实。

    两个组件可能在不同时间消费同名共享脚本，因此字体冻结树放专有命名空间。
    SDK 本体不分发；完整 SDK 输入索引仍保存在原字体构建收据内。
    """
    if not work_root or not font_root:
        raise ValueError('font derivative requires explicit repack and font provider build roots')
    audit = receipt['derivation'].get('fontBundle')
    if not audit or receipt['derivation']['kind'] != 'compatible-cxx-font-provider-repack':
        raise ValueError('missing explicit font derivation')
    bundle_raw = (work_root / 'font-bundle.json').read_bytes()
    bundle = json.loads(bundle_raw)
    proof_raw = (work_root / 'font-provider-provenance.json').read_bytes()
    if (hashlib.sha256(bundle_raw).hexdigest() != audit['inputManifestSha256']
            or hashlib.sha256(proof_raw).hexdigest() != audit['provenanceSha256']):
        raise ValueError('font derivative captured receipt mismatch')
    # 复用同一身份检查规则，源码导出仍独立重新读原构建，不依赖先前“已验证”的布尔值。
    module_spec = importlib.util.spec_from_file_location('font_source_repack_checker', ROOT / 'scripts/repack-runtime-provider.py')
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    proof, source, licenses = module.font_producer(proof_raw, font_root)
    if (proof['buildManifestSha256'] != audit['producerBuildManifestSha256']
            or proof['providerProvenanceSha256'] != audit['providerSourceProvenanceSha256']
            or proof['requiredFreeTypeSymbols'] != audit['requiredFreeTypeSymbols']
            or audit.get('referenceFreeTypeDelivered') is not False):
        raise ValueError('font derived source closure differs from package record')
    expected_variant = 'classic' if str(receipt['build']['major']) == '8' else 'modern'
    native = 'jre/lib/aarch64/' if expected_variant == 'classic' else 'lib/'
    expected_additions = {native + 'libfontconfig.so': proof['variants'][expected_variant]['sha256'],
                          'legal/amcl-fontconfig/COPYING': hashlib.sha256(licenses['fontconfig']).hexdigest(),
                          'legal/amcl-expat/COPYING': hashlib.sha256(licenses['expat']).hexdigest()}
    notice_files = {}
    if bundle.get('schemaVersion') == 2 and expected_variant == 'modern' and not audit.get('derivedNotices'):
        raise ValueError('modern v2 font source requires exact derived driver notices')
    if audit.get('derivedNotices'):
        notice = audit['derivedNotices']
        notice_raw = module.font_file(work_root / 'freetype-notices-manifest.json', notice['manifestSha256'])
        notice_provenance = json.loads(notice_raw)
        generator_raw = module.font_file(work_root / 'freetype-notices-generator.py', notice['generatorSha256'])
        actual = module.font_file(work_root / 'freetype-runtime-NOTICE.txt', notice['sha256'])
        if (notice.get('scope') != 'derived-distribution-supplement' or notice.get('compiledInput') is not False
                or notice_provenance.get('schemaVersion') != 1 or notice_provenance.get('kind') != 'version-matched-freetype-notices'
                or notice_provenance.get('scope') != notice['scope'] or notice_provenance.get('compiledInput') is not False
                or notice_provenance['generatorSha256'] != notice['generatorSha256']
                or notice['major'] != str(receipt['build']['major']) or compiled_root is None):
            raise ValueError('FreeType derived notice classification/provenance mismatch')
        completion_raw = read_regular(compiled_root, 'prebuilt/fontconfig/freetype-completion.json')
        if (hashlib.sha256(completion_raw).hexdigest() != notice['completionManifestSha256']
                or notice_provenance['completionManifestSha256'] != notice['completionManifestSha256']
                or receipt['build']['inputClosure']['files']['prebuilt/fontconfig/freetype-completion.json'] != notice['completionManifestSha256']):
            raise ValueError('FreeType notice completion source is not the original frozen input')
        completion = json.loads(completion_raw)
        item = completion['runtimes'][notice['major']]
        frozen = receipt['build']['inputClosure']['files']
        if (item['jdkCommit'] != receipt['build']['commit'] or frozen.get(item['patch']) != item['patchSha256']
                or any(frozen.get(value['path']) != value['sha256'] for value in item['licenses'].values())):
            raise ValueError('FreeType notice patch/license source is outside original build closure')
        patch = read_regular(compiled_root, item['patch'])
        original_licenses = {name: read_regular(compiled_root, value['path']) for name, value in item['licenses'].items()}
        # 执行当前受信任的格式v1校验器，绝不执行待导出包里捕获的脚本。
        specification = importlib.util.spec_from_file_location('export_freetype_notices', ROOT / 'scripts/freetype-notices.py')
        generator = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(generator)
        generator.verify_record(notice['major'], completion_raw, patch, original_licenses,
                                notice_provenance['runtimes'][notice['major']], actual)
        if notice['path'] != 'legal/amcl-freetype-completion/NOTICE.txt' or notice['bytes'] != len(actual) or notice['mode'] != 0o100644:
            raise ValueError('FreeType derived notice target/size/mode mismatch')
        expected_additions[notice['path']] = notice['sha256']
        notice_files = {'font-provider/derived-notices/manifest.json': notice_raw,
                        'font-provider/derived-notices/generator.py': generator_raw,
                        'font-provider/derived-notices/NOTICE.txt': actual}
    if (audit['variant'] != expected_variant or set(audit['additions']) != set(expected_additions)
            or any(audit['additions'][name]['sha256'] != value for name, value in expected_additions.items())):
        raise ValueError('font derived additions differ from source/license closure')
    files = {'font-provider/input-bundle.json': bundle_raw,
             'font-provider/provenance.json': proof_raw,
             'font-provider/build-manifest.json': (font_root / 'build-manifest.json').read_bytes(),
             'font-provider/source-provenance.json': (font_root / 'out/fontconfig-provenance.json').read_bytes(),
             'font-provider/source-identities.json': (font_root / 'out/sources/source-identities.json').read_bytes()}
    files.update(notice_files)
    for name, expected in proof['recipes'].items():
        data = read_regular(font_root / 'inputs/project', name)
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError('font frozen recipe mismatch: ' + name)
        files['font-provider/frozen/' + name] = data
    for item in proof['sources'].values():
        files['font-provider/sources/' + item['archive']] = module.font_file(
            font_root / 'out/sources' / item['archive'], item['archiveSha256'])
    for name, item in [('meson.whl', source['spec']['meson']),
                       ('gperf-' + source['spec']['gperf']['version'] + '.tar.gz', source['spec']['gperf'])]:
        files['font-provider/sources/' + name] = module.font_file(font_root / 'out/sources' / name, item['sha256'])
    for name, data in licenses.items():
        files['font-provider/licenses/' + name + '/COPYING'] = data
    files['font-provider/README.rebuild.md'] = b'''# Fontconfig provider source closure

This namespace contains the exact successful provider build inputs, not the JDK build recipes.
Run the frozen amcl fontconfig recipe with the recorded toolchain and a legally obtained matching SDK.
The reference FreeType archive is a header/link reference; it is never copied into a JDK runtime.
Each JDK keeps its own FreeType from its complete build; all 23 imports and its SONAME must match.
The two provider variants differ only in audited dynamic names. Fontconfig and private static Expat
licenses accompany every derivative. A successful static repack grants no CLI/cache/device qualification.
When sourceAdaptation is present, the original Git archive stays unchanged. The frozen default patch,
series, adaptation hashes and generated generic header reconstruct the exact compiled source bytes;
the exporter and independent delivery validator replay the patch without executing archived scripts.
input-bundle.json is the exact captured repack input, including producer paths from that build host.
For a new rebuild, point provenance/producerRoot and addition paths to the newly verified outputs,
preserve the two variant paths and two license targets, and pass it with --font-bundle. Changed inputs
require a new immutable buildId and a new derivative; never rewrite this captured input or old receipts.
'''
    return files


def frozen_archive(manifest_path, outer_path, frozen_root, output, supplementary_root=ROOT,
                   derivation_inputs=None, provider_build_root=None, provider_recipe_revision=None,
                   fontconfig_build_root=None, repack_recipe=None):
    """新构建使用构建时冻结文件，绑定内外两层收据；不从发布时 HEAD 猜测编译输入。

    SDK/boot/compiler 字节不公开复制，实际摘要和工具链身份保留在原外层收据里。
    冻结清单之外、重建入口需要的 Compose/路径工具作为补充文件单列，不冒充原编译输入。
    """
    receipt_raw = manifest_path.read_bytes()
    receipt = json.loads(receipt_raw)
    build = receipt['build']
    outer_raw = outer_path.read_bytes()
    outer = json.loads(outer_raw)
    if (outer.get('state') != 'completed' or outer.get('exitCode') != 0
            or outer.get('component') != 'jdk' + str(build['major'])
            or not build.get('inputClosure') or outer.get('inputs') != build['inputClosure']):
        raise ValueError('completed outer manifest and package input closure must match exactly')
    frozen = outer['inputs'].get('files')
    if not isinstance(frozen, dict) or not frozen:
        raise ValueError('missing frozen source input inventory')
    files = {}
    for name, expected in frozen.items():
        data = read_regular(frozen_root, name)
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError('frozen source input mismatch: ' + name)
        files[name] = data
    # 容器入口外的维护者脚本不是本次编译载荷；为可操作的重建入口显式附带并单列身份。
    supplementary = {}
    for name in ('docker/compose.yaml', 'docker/Dockerfile.openjdk-ohos', 'docker/Dockerfile.jdk-toolchain',
                 'docker/Dockerfile.jdk8-toolchain', 'scripts/lib/workspace_paths.py'):
        if name not in files and (supplementary_root / name).is_file():
            files[name] = read_regular(supplementary_root, name)
            supplementary[name] = hashlib.sha256(files[name]).hexdigest()
    if 'scripts/lib/workspace_paths.py' not in files:
        raise ValueError('rebuild entry lacks scripts/lib/workspace_paths.py')
    # 包内早期明确记录的 recipes/patches 同样逐项核验，不能只信外层较大的文件集合。
    required = {'prebuilt/jdk/build-inputs.json': build['inputsSha256']}
    required.update({f"prebuilt/jdk/{build['major']}/patches/{name}": value for name, value in build['patches'].items()})
    for name, value in build['recipes'].items():
        path = 'docker/' + (name[3:] if name.startswith('../') else name)
        if path not in files:
            path = 'docker/scripts/' + name
        required[path] = value
    for name, expected in required.items():
        if name not in files or hashlib.sha256(files[name]).hexdigest() != expected:
            raise ValueError('frozen source omits package receipt input: ' + name)
    files['build-receipt.json'] = receipt_raw
    files['build-manifest.json'] = outer_raw
    provider_files = {}
    if receipt.get('derivation'):
        supplied = derived_provider_inputs(receipt, supplementary_root, derivation_inputs,
                                            provider_build_root, provider_recipe_revision, repack_recipe)
        for name, data in supplied.items():
            if name in files and files[name] != data:
                raise ValueError('provider recipe collides with original frozen input: ' + name)
            files[name] = data
            provider_files[name] = hashlib.sha256(data).hexdigest()
    elif derivation_inputs or provider_build_root or provider_recipe_revision or repack_recipe:
        raise ValueError('provider inputs supplied for non-derived runtime')
    font_files = {}
    derived_notice_files = {}
    if receipt.get('derivation', {}).get('kind') == 'compatible-cxx-font-provider-repack':
        supplied = derived_font_inputs(receipt, derivation_inputs, fontconfig_build_root, frozen_root)
        for name, data in supplied.items():
            if name in files:
                raise ValueError('font source namespace collision: ' + name)
            files[name] = data
            font_files[name] = hashlib.sha256(data).hexdigest()
        if receipt['derivation']['fontBundle'].get('derivedNotices'):
            # 这是派生工具及派生成文的独立输入，不塞进原 build.inputClosure/frozenFiles。
            generator_name = 'scripts/freetype-notices.py'
            if generator_name in files:
                raise ValueError('derived notice generator collides with original build source')
            files[generator_name] = supplied['font-provider/derived-notices/generator.py']
            derived_notice_files = {name: hashlib.sha256(data).hexdigest() for name, data in files.items()
                                    if name.startswith('font-provider/derived-notices/') or name == generator_name}
    elif fontconfig_build_root is not None:
        raise ValueError('font build root supplied for runtime without font derivation')
    files['README.rebuild.md'] = f'''# JDK {build['major']} 冻结构建输入

`source-inputs.json` 的 frozenFiles 对应本轮完整构建时冻结的源码、配方和补丁。
`build-receipt.json` 是运行 ZIP 收据；`build-manifest.json` 是退出0的完整构建收据，
两者 inputClosure 必须完全一致。supplementaryFiles 只补齐重建入口，不冒称原编译输入。

本包不分发 OHOS SDK、boot JDK 或容器镜像。其精确输入摘要保存在原收据内；重建者需要
合法取得对应工具链，或登记不同工具链并重新完整验收，不宣称逐位可复现。
按 docker/project.py 的标准 amcl builder 流程在外置目录完成全量 images 与打包，
新产物使用新 buildId/文件名，再执行设备功能和性能资格。此源码包本身不签发运行资格。
'''.encode('utf-8')
    identity = {'schemaVersion': 2, 'scope': 'frozen build inputs and explicit rebuild-only supplements; excludes SDK binaries',
                'buildManifestSha256': hashlib.sha256(outer_raw).hexdigest(),
                'frozenFiles': frozen, 'supplementaryFiles': supplementary, 'providerFiles': provider_files,
                'fontProviderFiles': font_files, 'derivedNoticeFiles': derived_notice_files}
    return write_archive(output, files, identity)


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
    p.add_argument('--build-manifest', type=Path)
    p.add_argument('--frozen-inputs', type=Path, help='本轮 inputs/project 冻结目录；与 --build-manifest 成对使用')
    p.add_argument('--derivation-inputs', type=Path, help='兼容provider再封包的独占work-dir，含原始收据')
    p.add_argument('--provider-build-root', type=Path, help='已审核provider完整构建目录，含unwind-input和SDK输入清单')
    p.add_argument('--provider-recipe-revision', help='当前配方变化时，显式选择真实构建配方提交并逐项核SHA')
    p.add_argument('--fontconfig-build-root', type=Path, help='字体派生的真实成功构建目录；冻结配方与源码归档独立导出')
    p.add_argument('--repack-recipe', type=Path, help='历史派生的实际再封包配方；必须精确命中原收据SHA')
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    if bool(args.build_manifest) != bool(args.frozen_inputs):
        p.error('--build-manifest and --frozen-inputs must be supplied together')
    if args.build_manifest:
        if args.revision:
            p.error('--revision belongs to legacy export; frozen export reads exact captured bytes')
        print(json.dumps(frozen_archive(args.manifest, args.build_manifest, args.frozen_inputs, args.output,
              derivation_inputs=args.derivation_inputs, provider_build_root=args.provider_build_root,
              provider_recipe_revision=args.provider_recipe_revision, fontconfig_build_root=args.fontconfig_build_root,
              repack_recipe=args.repack_recipe), ensure_ascii=False))
        return
    build = json.loads(args.manifest.read_text(encoding='utf-8'))['build']
    if build.get('inputClosure'):
        p.error('new full input closure requires --build-manifest and --frozen-inputs; legacy exporter is not sufficient')
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
