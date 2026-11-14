"""Fontconfig 新默认来源链正负例；合成字节仅测试校验规则，不授予目标 ELF 编译资格。"""
import copy
import difflib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tarfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from lib.workspace_paths import temporary_directory
spec = importlib.util.spec_from_file_location('font_repack', ROOT / 'scripts/repack-runtime-provider.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)


class AdaptationTest(unittest.TestCase):
    def setUp(self):
        self.temp = temporary_directory(prefix='font-source-')
        self.root = Path(self.temp.name)
        self.commit = '1' * 40
        self.old = {name: b'original\nkeep\n' for name in ('src/fccfg.c', 'src/fcinit.c')}
        self.new = {name: b'changed\nkeep\n' for name in self.old}
        self.patch = ''.join('diff --git a/' + name + ' b/' + name + '\n' + ''.join(difflib.unified_diff(
            self.old[name].decode().splitlines(True), self.new[name].decode().splitlines(True),
            fromfile='a/' + name, tofile='b/' + name)) for name in self.old).encode()
        self.metadata = {'commit': self.commit, 'patchSha256': module.sha(self.patch),
                         'before': {name: module.sha(data) for name, data in self.old.items()},
                         'after': {name: module.sha(data) for name, data in self.new.items()}}
        self.header = b'#define AMCL_FONTCONFIG_GENERIC_RULES "<alias/>"\n'
        self.adaptation = dict(self.metadata, genericHeader='prebuilt/fontconfig/ohos-generic-fonts.h',
                               genericHeaderSha256=module.sha(self.header), compiledHeader='src/amcl-generic-fonts.h')
        self.markers = {'genericXml': b'<alias/>', 'contextApi': b'OH_AbilityRuntime_ApplicationContextGetCacheDir',
                        'contextLibrary': b'libability_runtime.so', 'outsideRuntimeCache': b'.amcl-fontconfig-cache',
                        'classicLayout': b'/jre/lib/aarch64/libfontconfig.so', 'modernLayout': b'/lib/libfontconfig.so'}
        self.library = b'fixture bytes, not ELF\0' + b'\0'.join(self.markers.values())
        markers = {name: {'offset': self.library.index(data), 'sha256': module.sha(data), 'sizeBytes': len(data)}
                   for name, data in self.markers.items()}
        self.source = {'sourceAdaptation': self.adaptation, 'sourceLibrarySha256': module.sha(self.library),
                       'compiledOhosDefaults': {'markers': markers, 'hardContextApiImport': False}}
        self.proof = {'recipes': {}, 'sources': {'fontconfig': {'commit': self.commit, 'archive': 'source.tar',
                                                              'adaptation': copy.deepcopy(self.adaptation)}}}
        archive = self.root / 'out/sources/source.tar'; archive.parent.mkdir(parents=True)
        with tarfile.open(archive, 'w', format=tarfile.PAX_FORMAT, pax_headers={'comment': self.commit}) as output:
            for name, data in self.old.items():
                entry = tarfile.TarInfo(name); entry.size = len(data); output.addfile(entry, io.BytesIO(data))
        lib = self.root / 'out/reference/libfontconfig-original.so'; lib.parent.mkdir()
        lib.write_bytes(self.library)
        self.freeze('prebuilt/fontconfig/ohos-defaults.json', json.dumps(self.metadata).encode())
        self.freeze('prebuilt/fontconfig/patches/0001-ohos-default-fonts-and-context-cache.patch', self.patch)
        self.freeze('prebuilt/fontconfig/patches/series', b'0001-ohos-default-fonts-and-context-cache.patch\n')
        self.freeze('prebuilt/fontconfig/ohos-generic-fonts.h', self.header)

    def tearDown(self):
        self.temp.cleanup()

    def freeze(self, name, data):
        path = self.root / 'inputs/project' / name; path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data); self.proof['recipes'][name] = module.sha(data)

    def verify(self):
        # 这里只测来源重放；actual ELF 的逐符号检查保留在完整四包集成验证。
        with mock.patch.object(module, 'elf_facts', return_value={'strongImports': []}):
            module.verify_font_adaptation(self.source, self.proof, self.root)

    def test_precise_replay_and_full_chain(self):
        self.assertEqual(module.replay_font_patch(self.old, self.patch), self.new)
        self.verify()

    def test_old_unadapted_provider_compatible(self):
        module.verify_font_adaptation({}, {'recipes': {}, 'sources': {'fontconfig': {}}}, self.root)

    def test_missing_adaptation_cannot_downgrade(self):
        self.source.pop('sourceAdaptation')
        with self.assertRaisesRegex(ValueError, 'binding'): self.verify()

    def test_wrong_claimed_after_rejected_after_outer_rehash(self):
        self.metadata['after']['src/fccfg.c'] = '0' * 64
        self.adaptation['after'] = self.metadata['after']
        self.proof['sources']['fontconfig']['adaptation'] = copy.deepcopy(self.adaptation)
        self.freeze('prebuilt/fontconfig/ohos-defaults.json', json.dumps(self.metadata).encode())
        with self.assertRaisesRegex(ValueError, 'replay differs'): self.verify()

    def test_context_line_and_hunk_counts_are_not_ignored(self):
        for patch in (self.patch.replace(b'-original\n', b'-unrelated\n'),
                      self.patch.replace(b'@@ -1,2 +1,2 @@', b'@@ -1,3 +1,2 @@'),
                      self.patch.replace(b'+1,2 @@', b'+2,2 @@')):
            with self.subTest(patch=patch):
                with self.assertRaises(ValueError): module.replay_font_patch(self.old, patch)

    def test_missing_or_extra_source_patch_rejected(self):
        with self.assertRaises(ValueError): module.replay_font_patch(self.old, self.patch + self.patch)
        with self.assertRaises(ValueError): module.replay_font_patch(self.old, b'')

    def test_extra_series_entry_rejected(self):
        self.freeze('prebuilt/fontconfig/patches/series', b'0001-ohos-default-fonts-and-context-cache.patch\nunknown.patch\n')
        with self.assertRaisesRegex(ValueError, 'series'): self.verify()

    def test_marker_must_be_in_exact_actual_bytes(self):
        self.source['compiledOhosDefaults']['markers']['genericXml']['offset'] += 1
        with self.assertRaisesRegex(ValueError, 'actual compiled ELF'): self.verify()

    def test_frozen_header_and_closure_not_optional(self):
        self.proof['recipes'].pop('prebuilt/fontconfig/ohos-generic-fonts.h')
        with self.assertRaisesRegex(ValueError, 'frozen recipe closure'): self.verify()


if __name__ == '__main__':
    unittest.main()
