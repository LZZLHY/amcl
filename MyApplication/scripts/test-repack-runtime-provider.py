"""兼容 provider 再封包负例；LLVM 编译真实 AArch64 ELF，仅验证身份/结构而非模拟ABI语义。"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock
import warnings
import zipfile

from lib.workspace_paths import temporary_directory

SPEC = importlib.util.spec_from_file_location('provider_repack', Path(__file__).with_name('repack-runtime-provider.py'))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
CLANG = None


class ProviderRepackTests(unittest.TestCase):
    """各用例在独立外置目录构造原 ZIP，所有失败都必须阻止新候选和 sidecar 出现。"""
    @classmethod
    def setUpClass(cls):
        options = {'dir': os.environ['AMCL_TEST_TMP']} if os.environ.get('AMCL_TEST_TMP') else {}
        cls.temp = temporary_directory(prefix='provider-elf-', **options)
        cls.addClassCleanup(cls.temp.cleanup)
        base = Path(cls.temp.name)
        cls.providers = {}
        for kind, extra, soname in [('old', '', 'libc++_shared.so'),
                                    ('new', 'void amcl_unwind_register_image(void) {}\nvoid amcl_unwind_unregister_image(void) {}', 'libc++_shared.so'),
                                    ('wrong', '', 'wrong.so')]:
            source = base / (kind + '.c')
            source.write_text('/* 仅结构测试，禁止作为运行ABI供应者。 */\nint original_api(void) { return 1; }\n' + extra, encoding='utf-8')
            output = base / (kind + '.so')
            subprocess.run([CLANG, '--target=aarch64-linux-ohos', '-fuse-ld=lld', '-shared', '-nostdlib',
                            '-Wl,-soname,' + soname, str(source), '-o', str(output)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            cls.providers[kind] = output.read_bytes()
        # 结构用例使用真实 AArch64 ELF；函数体不是字体实现，绝不进入交付包。
        cls.ft_symbols = json.loads((MODULE.ROOT / 'prebuilt/fontconfig/build-provenance.json').read_text())['requiredFreeTypeSymbols']
        def compile_library(name, code, soname, dependencies=()):
            source = base / (name + '.c')
            source.write_text('/* AMCL：仅用于 ELF 导入与闭包门禁，不执行。 */\n' + code, encoding='utf-8')
            output = base / name
            subprocess.run([CLANG, '--target=aarch64-linux-ohos', '-fuse-ld=lld', '-shared', '-nostdlib',
                            '-Wl,-soname,' + soname, str(source), '-L' + str(base), *dependencies,
                            '-o', str(output)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            return output.read_bytes()
        compile_library('libc.so', 'int libc_fixture(void) { return 0; }', 'libc.so')
        definitions = '\n'.join('int ' + symbol + '(void) { return 0; }' for symbol in cls.ft_symbols)
        cls.providers['ft-modern'] = compile_library('libfreetype.so', definitions, 'libfreetype.so')
        cls.providers['ft-classic'] = compile_library('libfreetype.so.6', definitions, 'libfreetype.so.6')
        cls.providers['ft-missing'] = compile_library('ft-missing.so', definitions.replace(
            'int FT_Get_BDF_Property(void) { return 0; }', ''), 'libfreetype.so')
        imports = '\n'.join('extern int ' + symbol + '(void);' for symbol in cls.ft_symbols)
        references = ','.join('&' + symbol for symbol in cls.ft_symbols)
        font_code = imports + '\nvoid *references[] = {' + references + '};\nint FcGetVersion(void) { return 21701; }'
        for variant, needed in [('classic', 'libfreetype.so.6'), ('modern', 'libfreetype.so')]:
            cls.providers['font-' + variant] = compile_library('font-' + variant + '.so', font_code,
                'libfontconfig.so', ['-Wl,--no-as-needed', '-l:' + needed, '-lc'])

    def setUp(self):
        options = {'dir': os.environ['AMCL_TEST_TMP']} if os.environ.get('AMCL_TEST_TMP') else {}
        self.temp = temporary_directory(prefix='provider-repack-', **options)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'original.zip'
        self.sidecar = self.root / 'original.manifest.json'
        self.output = self.root / 'new-runtime.zip'
        self.payload = {'release': b'JAVA_VERSION="17.0.1"\n', 'lib/libc++_shared.so': self.providers['old']}
        self.build = {'major': '17', 'cxxAbi': {'providerSha256': MODULE.sha(self.providers['old'])}}

    def archive(self, *, extra=None, missing=None, mode=None, duplicate=False, inner_build=None):
        """可改变内表或 ZIP 正文；外层 SHA 同步更新，确保测到内层门禁而非只测最外层摘要。"""
        manifest = {'schema': 1, 'build': inner_build or self.build,
                    'files': {name: {'bytes': len(data), 'sha256': MODULE.sha(data)} for name, data in self.payload.items()}}
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with zipfile.ZipFile(self.source, 'w') as archive:
                entries = list(self.payload.items()) + [('amcl-runtime.json', json.dumps(manifest).encode())]
                if duplicate:
                    entries.append(entries[0])
                if extra:
                    entries.append(extra)
                for name, data in entries:
                    if name == missing:
                        continue
                    info = zipfile.ZipInfo(name)
                    info.external_attr = (mode or MODULE.regular_mode(name)) << 16
                    archive.writestr(info, data)
        receipt = {'file': str(self.source), 'bytes': self.source.stat().st_size,
                   'sha256': MODULE.sha(self.source.read_bytes()), 'build': self.build}
        self.sidecar.write_text(json.dumps(receipt), encoding='utf-8')
        return self.sidecar.read_bytes()

    def unpack(self, receipt):
        destination = self.root / 'unpacked'
        destination.mkdir()
        return MODULE.unpack_verified(self.source, receipt, destination)

    def test_real_aarch64_provider_surface_and_soname(self):
        old, new = self.providers['old'], self.providers['new']
        provenance = {'schemaVersion': 1, 'artifactSha256': MODULE.sha(new), 'artifactBytes': len(new),
                      'sdk': {'originalSharedSha256': MODULE.sha(old)}}
        raw = json.dumps(provenance).encode()
        MODULE.verify_provider(old, new, raw)
        self.assertEqual(MODULE.soname(new), 'libc++_shared.so')
        for bad in (old, new[:-1], self.providers['wrong']):
            with self.assertRaises(ValueError):
                MODULE.verify_provider(old, bad, raw)
        provenance['artifactSha256'] = MODULE.sha(self.providers['wrong'])
        provenance['artifactBytes'] = len(self.providers['wrong'])
        with self.assertRaisesRegex(ValueError, 'SONAME'):
            MODULE.verify_provider(old, self.providers['wrong'], json.dumps(provenance).encode())

    def test_exact_zip_bytes_and_permissions_are_read_back(self):
        _, manifest, _ = self.unpack(self.archive())
        self.assertEqual(manifest['build'], self.build)
        for name, data in self.payload.items():
            self.assertEqual((self.root / 'unpacked' / name).read_bytes(), data)

    def test_same_outer_identity_cannot_hide_inner_build_drift(self):
        with self.assertRaisesRegex(ValueError, 'inner/outer'):
            self.unpack(self.archive(inner_build={'major': '25'}))

    def test_duplicate_entry_fails(self):
        with self.assertRaisesRegex(ValueError, 'canonical'):
            self.unpack(self.archive(duplicate=True))

    def test_extra_entry_fails(self):
        with self.assertRaisesRegex(ValueError, 'entry set'):
            self.unpack(self.archive(extra=('extra.txt', b'x')))

    def test_missing_entry_fails(self):
        with self.assertRaisesRegex(ValueError, 'entry set'):
            self.unpack(self.archive(missing='release'))

    def test_wrong_permission_fails(self):
        with self.assertRaisesRegex(ValueError, 'mode'):
            self.unpack(self.archive(mode=0o100666))

    def test_traversal_fails_before_materialization(self):
        with self.assertRaisesRegex(ValueError, 'canonical'):
            self.unpack(self.archive(extra=('../outside', b'x')))
        self.assertFalse((self.root / 'outside').exists())

    def test_windows_aliases_fail_before_materialization(self):
        """每种别名都走真实 ZIP 预检；拒绝发生在任何普通条目写入之前，不触发设备文件。"""
        bad_names = ['lib/name.', 'lib/name ', 'lib/ name', 'lib./normal', 'lib /normal',
                     'CON', 'lib/nul.txt', 'lib/NUL.tar.gz', 'lib/PRN', 'lib/aux.bin',
                     'lib/COM1', 'lib/com9.txt', 'lib/LPT1', 'lib/lpt9.txt',
                     'lib/COM¹', 'lib/COM².txt', 'lib/LPT³', 'NUL/normal',
                     'lib/CON .txt', 'lib/CONIN$', 'lib/CONOUT$',
                     'lib/a<b', 'lib/a>b', 'lib/a"b', 'lib/a|b', 'lib/a?b', 'lib/a*b']
        for index, name in enumerate(bad_names):
            with self.subTest(name=name):
                receipt = self.archive(extra=(name, b'x'))
                destination = self.root / ('windows-alias-' + str(index))
                destination.mkdir()
                with self.assertRaisesRegex(ValueError, 'canonical'):
                    MODULE.unpack_verified(self.source, receipt, destination)
                self.assertEqual(list(destination.iterdir()), [])

    def test_ordinary_names_are_not_normalized_or_over_rejected(self):
        """保留正常点文件、内部空格和非设备编号；拒绝规则不篡改合法文件身份。"""
        for name in ('lib/libc++_shared.so', '.metadata', 'legal/my license.txt', 'lib/COM10',
                     'lib/LPT0.txt', 'lib/console.txt', 'lib/auxiliary.so'):
            with self.subTest(name=name):
                self.assertTrue(MODULE.safe_name(name))

    def test_full_image_gate_is_not_bypassed_for_small_fixture(self):
        self.archive()
        provider, proof = self.root / 'provider.so', self.root / 'provider.json'
        provider.write_bytes(self.providers['new'])
        proof.write_text('{}', encoding='utf-8')
        with self.assertRaisesRegex(ValueError, '缺少关键文件'):
            MODULE.repack(self.source, self.sidecar, provider, proof, self.root, '17-test', self.output, self.root / 'work')
        self.assertFalse(self.output.exists())
        self.assertFalse(self.output.with_suffix('.manifest.json').exists())

    def font_bundle(self, major='17'):
        """构造明确的四条输入声明；只隔离生产收据读盘，ELF/23导出/模式检查仍真实运行。"""
        native = 'jre/lib/aarch64/' if major == '8' else 'lib/'
        ft_name = 'libfreetype.so.6' if major == '8' else 'libfreetype.so'
        consumer = self.root / 'image' / (native + ft_name)
        consumer.parent.mkdir(parents=True)
        consumer.write_bytes(self.providers['ft-classic' if major == '8' else 'ft-modern'])
        licenses = {'fontconfig': b'fontconfig fixture license', 'expat': b'expat fixture license'}
        proof = {'variants': {}, 'requiredFreeTypeSymbols': self.ft_symbols,
                 'buildManifestSha256': 'a' * 64, 'providerProvenanceSha256': 'b' * 64}
        additions = {}
        for variant, target in [('classic', 'jre/lib/aarch64/libfontconfig.so'), ('modern', 'lib/libfontconfig.so')]:
            output = self.root / 'producer/out' / variant / 'libfontconfig.so'
            output.parent.mkdir(parents=True)
            output.write_bytes(self.providers['font-' + variant])
            record = {'path': str(output), 'target': target, 'sha256': MODULE.sha(output.read_bytes()),
                      'bytes': output.stat().st_size, 'mode': 0o100644}
            additions[variant] = record
            proof['variants'][variant] = {'path': variant + '/libfontconfig.so', 'sha256': record['sha256'],
                                          'sizeBytes': record['bytes']}
        for name, data in licenses.items():
            path = self.root / (name + '-COPYING')
            path.write_bytes(data)
            additions[name + '-license'] = {'path': str(path), 'target': 'legal/amcl-' + name + '/COPYING',
                'sha256': MODULE.sha(data), 'bytes': len(data), 'mode': 0o100644}
        proof_path = self.root / 'font-provenance.json'
        proof_path.write_text(json.dumps(proof))
        bundle = {'schemaVersion': 1 if major == '8' else 2, 'producerRoot': str(self.root / 'producer'),
                  'provenance': {'path': str(proof_path), 'sha256': MODULE.sha(proof_path.read_bytes())},
                  'additions': additions}
        # 这里独立验证 ELF 和增补集合；notice 的真实重算/冻结来源在下面专用用例验证。
        if major != '8':
            patcher = mock.patch.object(MODULE, 'verify_freetype_notice', return_value=(
                'legal/amcl-freetype-completion/NOTICE.txt', b'notice fixture',
                {'scope': 'derived-distribution-supplement', 'compiledInput': False}, {}))
            patcher.start()
            self.addCleanup(patcher.stop)
        manifest = self.root / 'font-bundle.json'
        manifest.write_text(json.dumps(bundle))
        return manifest, bundle, {native + ft_name: consumer}, (proof, {}, licenses)

    def test_font_bundle_restores_only_declared_library_and_licenses(self):
        manifest, bundle, files, producer = self.font_bundle()
        with mock.patch.object(MODULE, 'font_producer', return_value=producer):
            additions, audit, evidence = MODULE.verify_font_bundle(manifest, '17', files)
        self.assertEqual(set(additions), {'lib/libfontconfig.so', 'legal/amcl-fontconfig/COPYING', 'legal/amcl-expat/COPYING',
                                         'legal/amcl-freetype-completion/NOTICE.txt'})
        self.assertEqual(len(audit['requiredFreeTypeSymbols']), 23)
        self.assertFalse(audit['referenceFreeTypeDelivered'])
        self.assertIn('font-provider-provenance.json', evidence)
        self.assertEqual(files['lib/libfreetype.so'].read_bytes(), self.providers['ft-modern'])

    def test_font_classic_selects_existing_so6_not_modern_freetype(self):
        manifest, bundle, files, producer = self.font_bundle('8')
        with mock.patch.object(MODULE, 'font_producer', return_value=producer):
            additions, audit, _ = MODULE.verify_font_bundle(manifest, '8', files)
        self.assertEqual(audit['variant'], 'classic')
        self.assertEqual(additions['jre/lib/aarch64/libfontconfig.so'], self.providers['font-classic'])

    def test_font_bundle_rejects_old_incomplete_freetype(self):
        manifest, bundle, files, producer = self.font_bundle()
        files['lib/libfreetype.so'].write_bytes(self.providers['ft-missing'])
        with mock.patch.object(MODULE, 'font_producer', return_value=producer):
            with self.assertRaisesRegex(ValueError, 'rebuild JDK'):
                MODULE.verify_font_bundle(manifest, '17', files)

    def test_font_bundle_rejects_paths_modes_omission_and_overwrite(self):
        manifest, bundle, files, producer = self.font_bundle()
        import copy
        bad_states = []
        for field, value in [('target', 'lib/libfreetype.so'), ('mode', 0o100755), ('bytes', 7), ('sha256', '0' * 64)]:
            bad = copy.deepcopy(bundle)
            bad['additions']['modern'][field] = value
            bad_states.append(bad)
        bad = copy.deepcopy(bundle)
        del bad['additions']['expat-license']
        bad_states.append(bad)
        with mock.patch.object(MODULE, 'font_producer', return_value=producer):
            for index, bad in enumerate(bad_states):
                with self.subTest(index=index):
                    manifest.write_text(json.dumps(bad))
                    with self.assertRaises(ValueError):
                        MODULE.verify_font_bundle(manifest, '17', files)
            manifest.write_text(json.dumps(bundle))
            files['lib/libfontconfig.so'] = self.root / 'pre-existing.so'
            with self.assertRaisesRegex(ValueError, 'overwrite'):
                MODULE.verify_font_bundle(manifest, '17', files)

    def test_font_provenance_digest_is_checked_before_producer_access(self):
        manifest, bundle, files, producer = self.font_bundle()
        bundle['provenance']['sha256'] = '0' * 64
        manifest.write_text(json.dumps(bundle))
        with mock.patch.object(MODULE, 'font_producer', return_value=producer) as checked:
            with self.assertRaisesRegex(ValueError, 'SHA256 mismatch'):
                MODULE.verify_font_bundle(manifest, '17', files)
            checked.assert_not_called()

    def notice_fixture(self, major='17'):
        """使用仓内真实锁定源/补丁/原许可，仅收据外壳为测试构造，不声称编译执行。"""
        root = MODULE.ROOT
        source_path = root / 'prebuilt/fontconfig/freetype-completion.json'
        completion = json.loads(source_path.read_bytes())
        item = completion['runtimes'][major]
        names = {'prebuilt/fontconfig/freetype-completion.json': MODULE.sha(source_path.read_bytes()),
                 item['patch']: item['patchSha256']}
        names.update({value['path']: value['sha256'] for value in item['licenses'].values()})
        build = {'commit': item['jdkCommit'], 'inputClosure': {'files': names}}
        proof_path = root / 'prebuilt/fontconfig/derived-notices/manifest.json'
        proof = json.loads(proof_path.read_bytes())
        bundle = {'noticeManifest': {'path': str(proof_path), 'sha256': MODULE.sha(proof_path.read_bytes())}, 'notices': {}}
        for version, record in proof['runtimes'].items():
            bundle['notices'][version] = {'path': str(proof_path.parent / record['file']),
                'target': 'legal/amcl-freetype-completion/NOTICE.txt', 'sha256': record['sha256'],
                'bytes': record['bytes'], 'mode': 0o100644}
        return bundle, build, proof

    def test_real_three_version_notices_reconstructed_from_frozen_patch_and_licenses(self):
        for major in ('17', '21', '25'):
            with self.subTest(major=major):
                bundle, build, proof = self.notice_fixture(major)
                target, data, audit, evidence = MODULE.verify_freetype_notice(bundle, major, build, MODULE.ROOT)
                self.assertEqual(target, 'legal/amcl-freetype-completion/NOTICE.txt')
                self.assertEqual(len(proof['runtimes'][major]['sourceFiles']), 18)
                self.assertIn(b'Francesco Zappa Nardelli', data)
                self.assertFalse(audit['compiledInput'])
                self.assertEqual(data, evidence['freetype-runtime-NOTICE.txt'])

    def test_notice_text_drift_rejected_even_with_updated_derived_hashes(self):
        bundle, build, proof = self.notice_fixture()
        altered = Path(bundle['notices']['17']['path']).read_bytes().replace(b'Francesco Zappa Nardelli', b'Original author omitted', 1)
        data_path = self.root / 'altered-NOTICE.txt'
        data_path.write_bytes(altered)
        for record in (bundle['notices']['17'], proof['runtimes']['17']):
            record.update(sha256=MODULE.sha(altered), bytes=len(altered))
        bundle['notices']['17']['path'] = str(data_path)
        proof_path = self.root / 'altered-notices.json'
        proof_path.write_text(json.dumps(proof))
        bundle['noticeManifest'] = {'path': str(proof_path), 'sha256': MODULE.sha(proof_path.read_bytes())}
        with self.assertRaisesRegex(ValueError, 'differs from exact compiled source/license'):
            MODULE.verify_freetype_notice(bundle, '17', build, MODULE.ROOT)

    def test_notices_cannot_claim_compilation_or_another_version(self):
        bundle, build, proof = self.notice_fixture()
        build['commit'] = '0' * 40
        with self.assertRaisesRegex(ValueError, 'another JDK source'):
            MODULE.verify_freetype_notice(bundle, '17', build, MODULE.ROOT)
        bundle, build, proof = self.notice_fixture()
        proof['compiledInput'] = True
        path = self.root / 'misclassified-notices.json'
        path.write_text(json.dumps(proof))
        bundle['noticeManifest'] = {'path': str(path), 'sha256': MODULE.sha(path.read_bytes())}
        with self.assertRaisesRegex(ValueError, 'derived supplements'):
            MODULE.verify_freetype_notice(bundle, '17', build, MODULE.ROOT)

    def test_modern_font_bundle_cannot_omit_new_driver_notices(self):
        manifest, bundle, files, producer = self.font_bundle()
        bundle['schemaVersion'] = 1
        manifest.write_text(json.dumps(bundle))
        with self.assertRaisesRegex(ValueError, 'requires v2 bundle'):
            MODULE.verify_font_bundle(manifest, '17', files)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--clang', required=True, help='可编译 AArch64 ELF 的实际 LLVM clang 路径')
    options, remaining = parser.parse_known_args()
    CLANG = options.clang
    unittest.main(argv=[sys.argv[0], *remaining])
