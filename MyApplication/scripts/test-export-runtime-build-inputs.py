"""冻结来源导出回归：运行真实导出器并核对 ZIP，拒绝缺项、漂移及旁路 legacy 导出。"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock
import zipfile

from lib.workspace_paths import temporary_directory

SCRIPT = Path(__file__).with_name('export-runtime-build-inputs.py')
SPEC = importlib.util.spec_from_file_location('runtime_exporter', SCRIPT)
EXPORTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXPORTER)


def digest(data):
    """夹具身份总是从真实字节计算，不能使用仅形似摘要的固定占位值。"""
    return hashlib.sha256(data).hexdigest()


class FrozenInputTests(unittest.TestCase):
    """每个测试只在显式仓外目录构造自己的收据，不读取真实 SDK 或签名。"""
    def setUp(self):
        options = {'dir': os.environ['AMCL_TEST_TMP']} if os.environ.get('AMCL_TEST_TMP') else {}
        self.temp = temporary_directory(prefix='source-export-', **options)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.frozen = self.root / 'frozen'
        self.supplement = self.root / 'supplement'
        files = {'prebuilt/jdk/build-inputs.json': b'{}', 'docker/scripts/build.sh': b'echo fixture\n',
                 'prebuilt/jdk/17/patches/series': b'fixture.patch\n',
                 'prebuilt/jdk/17/patches/fixture.patch': b'fixture patch\n',
                 'prebuilt/stubs/src/abi.cpp': b'fixture ABI\n'}
        for name, data in files.items():
            target = self.frozen / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        helper = self.supplement / 'scripts/lib/workspace_paths.py'
        helper.parent.mkdir(parents=True)
        helper.write_bytes(b'# fixture only\n')
        inputs = {'component': 'jdk17', 'files': {name: digest(data) for name, data in files.items()}}
        self.outer = {'state': 'completed', 'exitCode': 0, 'component': 'jdk17', 'inputs': inputs}
        self.receipt = {'file': '/output/test.zip', 'bytes': 3, 'sha256': digest(b'abc'), 'build': {
            'major': '17', 'inputsSha256': digest(files['prebuilt/jdk/build-inputs.json']),
            'patches': {'series': digest(files['prebuilt/jdk/17/patches/series']),
                        'fixture.patch': digest(files['prebuilt/jdk/17/patches/fixture.patch'])},
            'recipes': {'build.sh': digest(files['docker/scripts/build.sh'])}, 'inputClosure': inputs}}
        self.manifest = self.root / 'package.manifest.json'
        self.outer_path = self.root / 'build-manifest.json'
        self.output = self.root / 'inputs.zip'

    def run_export(self):
        """写入当前故障注入状态，然后调用生产函数；保存文件不代表测试通过。"""
        self.manifest.write_text(json.dumps(self.receipt), encoding='utf-8')
        self.outer_path.write_text(json.dumps(self.outer), encoding='utf-8')
        return EXPORTER.frozen_archive(self.manifest, self.outer_path, self.frozen, self.output, self.supplement)

    def test_complete_zip_binds_frozen_and_supplement_separately(self):
        result = self.run_export()
        self.assertEqual(result['sha256'], digest(self.output.read_bytes()))
        with zipfile.ZipFile(self.output) as archive:
            index = json.loads(archive.read('source-inputs.json'))
            self.assertEqual(index['frozenFiles'], self.outer['inputs']['files'])
            self.assertNotIn('scripts/lib/workspace_paths.py', index['frozenFiles'])
            self.assertIn('scripts/lib/workspace_paths.py', index['supplementaryFiles'])
            self.assertEqual(set(archive.namelist()), set(index['files']) | {'source-inputs.json'})
            for name, expected in index['files'].items():
                self.assertEqual(digest(archive.read(name)), expected)
                self.assertEqual(archive.getinfo(name).external_attr >> 16, 0o100644)
        with self.assertRaises(FileExistsError):
            self.run_export()

    def test_frozen_file_drift_fails_before_output(self):
        (self.frozen / 'prebuilt/stubs/src/abi.cpp').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'frozen source input mismatch'):
            self.run_export()
        self.assertFalse(self.output.exists())

    def test_outer_must_be_successful_and_equal_inner(self):
        self.outer['exitCode'] = 1
        with self.assertRaisesRegex(ValueError, 'must match exactly'):
            self.run_export()
        self.outer['exitCode'] = 0
        self.receipt['build']['inputClosure'] = {'files': {}}
        with self.assertRaisesRegex(ValueError, 'must match exactly'):
            self.run_export()

    def test_path_and_receipt_input_omission_rejected(self):
        for name in ('../secret', 'docker/../secret', 'docker/key.pem', 'scripts/private.py', 'docker/a\\b'):
            with self.assertRaises(ValueError):
                EXPORTER.source_name(name)
        self.receipt['build']['recipes']['missing.sh'] = digest(b'missing')
        with self.assertRaisesRegex(ValueError, 'omits package receipt input'):
            self.run_export()

    def test_modern_receipt_cannot_fall_back_to_legacy_export(self):
        self.manifest.write_text(json.dumps(self.receipt), encoding='utf-8')
        result = subprocess.run([sys.executable, '-B', str(SCRIPT), '--manifest', str(self.manifest), '--output', str(self.output)],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('requires --build-manifest', result.stderr)
        self.assertFalse(self.output.exists())

    def test_freetype_completion_and_licenses_are_frozen_jdk_inputs(self):
        """现代新构建携带版本匹配字体来源；它们属于真实 JDK 冻结集合，不冒充补充材料。"""
        names = {'prebuilt/fontconfig/freetype-completion.json': b'{"fixture":true}\n',
                 'prebuilt/fontconfig/licenses/freetype-2.13.3/FTL.TXT': b'fixture license\n'}
        for name, data in names.items():
            path = self.frozen / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            self.outer['inputs']['files'][name] = digest(data)
        self.run_export()
        with zipfile.ZipFile(self.output) as archive:
            index = json.loads(archive.read('source-inputs.json'))
            for name, data in names.items():
                self.assertEqual(archive.read(name), data)
                self.assertEqual(index['frozenFiles'][name], digest(data))

    def test_font_root_requires_font_derivation(self):
        self.manifest.write_text(json.dumps(self.receipt), encoding='utf-8')
        self.outer_path.write_text(json.dumps(self.outer), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'without font derivation'):
            EXPORTER.frozen_archive(self.manifest, self.outer_path, self.frozen, self.output,
                self.supplement, fontconfig_build_root=self.root / 'unrelated')
        self.assertFalse(self.output.exists())

    def test_historical_cxx_only_recipe_can_be_exported_without_current_script_identity(self):
        """使用收据绑定的原配方；当前工作树继续演进不会让旧 C++only 派生失去来源。"""
        work, provider = self.root / 'repack', self.root / 'provider'
        work.mkdir()
        (provider / 'out').mkdir(parents=True)
        sdk_raw = b'{"fixture": "SDK identities only"}'
        (provider / 'out/native-inputs.json').write_bytes(sdk_raw)
        original = {'file': '/output/original.zip', 'bytes': 3, 'sha256': digest(b'zip'),
                    'build': {'major': '17', 'cxxAbi': {'providerSha256': digest(b'old')}}}
        original_raw = json.dumps(original).encode()
        proof = {'artifactSha256': digest(b'new'), 'source': {'files': {}}, 'recipes': {},
                 'builderImageId': 'sha256:fixture',
                 'sdk': {'originalSharedSha256': digest(b'old'), 'inputManifestSha256': digest(sdk_raw)}}
        proof_raw = json.dumps(proof).encode()
        (work / 'original-build-receipt.json').write_bytes(original_raw)
        (work / 'provider-provenance.json').write_bytes(proof_raw)
        (provider / 'build-manifest.json').write_text(json.dumps({'state': 'completed', 'exitCode': 0,
            'unwindInputs': proof['source'], 'imageId': proof['builderImageId']}))
        original_recipe = b'# recorded original C++only repack recipe\n'
        (work / 'repack-runtime-provider.py').write_bytes(original_recipe)
        current = self.supplement / 'scripts/repack-runtime-provider.py'
        current.parent.mkdir(parents=True, exist_ok=True)
        current.write_bytes(b'# later font-aware recipe\n')
        receipt = {'build': {'major': '17', 'cxxAbi': {'providerSha256': digest(b'new')}},
                   'derivation': {'kind': 'compatible-cxx-provider-repack',
                       'originalReceiptSha256': digest(original_raw), 'providerProvenanceSha256': digest(proof_raw),
                       'originalArchive': {'fileName': 'original.zip', 'bytes': 3, 'sha256': digest(b'zip')},
                       'providerSha256': digest(b'new'), 'originalProviderSha256': digest(b'old'),
                       'recipeSha256': digest(original_recipe)}}
        files = EXPORTER.derived_provider_inputs(receipt, self.supplement, work, provider)
        self.assertEqual(files['scripts/repack-runtime-provider.py'], original_recipe)
        captured = self.root / 'explicit-original.py'
        captured.write_bytes(original_recipe)
        files = EXPORTER.derived_provider_inputs(receipt, self.supplement, work, provider, repack_recipe=captured)
        self.assertEqual(files['scripts/repack-runtime-provider.py'], original_recipe)
        captured.write_bytes(b'# drifted\n')
        with self.assertRaisesRegex(ValueError, 'repack recipe changed'):
            EXPORTER.derived_provider_inputs(receipt, self.supplement, work, provider, repack_recipe=captured)

    def test_font_capture_drift_rejected_before_opening_producer(self):
        work = self.root / 'font-work'
        work.mkdir()
        (work / 'font-bundle.json').write_bytes(b'{}')
        (work / 'font-provider-provenance.json').write_bytes(b'{}')
        receipt = {'derivation': {'kind': 'compatible-cxx-font-provider-repack', 'fontBundle': {
            'inputManifestSha256': digest(b'different'), 'provenanceSha256': digest(b'{}')}}}
        with self.assertRaisesRegex(ValueError, 'captured receipt mismatch'):
            EXPORTER.derived_font_inputs(receipt, work, self.root / 'must-not-be-opened')

    def test_notice_outputs_are_derived_and_never_added_to_original_frozen_files(self):
        """只隔离来源读取，直接验证真正导出器的分类、原 frozenFiles 不变及 ZIP 正文。"""
        self.receipt['derivation'] = {'kind': 'compatible-cxx-font-provider-repack',
                                      'fontBundle': {'derivedNotices': {'schemaVersion': 1}}}
        supplied = {'font-provider/derived-notices/manifest.json': b'{"compiledInput":false}',
                    'font-provider/derived-notices/NOTICE.txt': b'captured original notice',
                    'font-provider/derived-notices/generator.py': b'# captured generator; no execution\n'}
        with mock.patch.object(EXPORTER, 'derived_provider_inputs', return_value={}), \
             mock.patch.object(EXPORTER, 'derived_font_inputs', return_value=supplied):
            self.run_export()
        with zipfile.ZipFile(self.output) as archive:
            index = json.loads(archive.read('source-inputs.json'))
            self.assertEqual(index['frozenFiles'], self.outer['inputs']['files'])
            self.assertEqual(set(index['derivedNoticeFiles']), set(supplied) | {'scripts/freetype-notices.py'})
            self.assertFalse(set(index['derivedNoticeFiles']) & set(index['frozenFiles']))
            self.assertEqual(archive.read('scripts/freetype-notices.py'), supplied['font-provider/derived-notices/generator.py'])


if __name__ == '__main__':
    unittest.main()
