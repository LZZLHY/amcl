#!/usr/bin/env python3
"""真实输入冻结与 ABI 审核反例，全部写入外置独占临时目录。"""
import importlib.util
import sys
import unittest
from pathlib import Path
from lib.workspace_paths import temporary_directory

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'docker/scripts'))
from jdk_native_inputs import native_inputs, freeze_files, digest
from verify_jdk_abi import verify, REQUIRED

spec = importlib.util.spec_from_file_location('packaging_fixtures', ROOT / 'scripts/test-runtime-packaging.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class NativeInputs(unittest.TestCase):
    """输入边界不依赖 Docker 或用户 SDK；运行库解析直接调用生产审核函数。"""
    def setUp(self):
        self.area = temporary_directory(prefix='jdk-native-inputs-')
        self.root = Path(self.area.name)
        self.native = self.root / 'native'
        for name, content in {
            'sysroot/usr/include/stdio.h': 'stdio',
            'sysroot/usr/include/unwatched.h': 'not a former sentinel',
            'llvm/include/libcxx-ohos/include/c++/v1/__config_site': '#define _LIBCPP_ABI_NAMESPACE __n1\n',
            'llvm/lib/aarch64-linux-ohos/libc++_shared.so': 'target provider',
            'llvm/lib/clang/15/lib/aarch64-linux-ohos/libclang_rt.builtins.a': 'builtins',
            'llvm/lib/clang/15/lib/aarch64-linux-ohos/clang_rt.crtbegin.o': 'begin',
            'llvm/lib/clang/15/lib/aarch64-linux-ohos/clang_rt.crtend.o': 'end',
            'llvm/lib/clang/15/include/stddef.h': 'compiler header',
            'oh-uni-package.json': '{}',
            'NOTICE.txt': 'SDK license notices'
        }.items():
            path = self.native / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)

    def tearDown(self):
        self.area.cleanup()

    def test_non_sentinel_header_changes_identity(self):
        before = native_inputs(self.native / 'sysroot')
        (self.native / 'sysroot/usr/include/unwatched.h').write_text('changed')
        after = native_inputs(self.native / 'sysroot')
        self.assertNotEqual(before, after)

    def test_frozen_files_do_not_follow_source_changes(self):
        facts = native_inputs(self.native / 'sysroot')
        target = self.root / 'snapshot'
        freeze_files(self.native, facts['files'], target)
        source = self.native / 'sysroot/usr/include/unwatched.h'
        source.write_text('changed')
        self.assertEqual(digest(target / 'sysroot/usr/include/unwatched.h'),
                         facts['files']['sysroot/usr/include/unwatched.h'])
        with self.assertRaises(FileExistsError):
            freeze_files(self.native, facts['files'], target)

    def test_drift_during_freeze_is_rejected(self):
        facts = native_inputs(self.native / 'sysroot')
        (self.native / 'sysroot/usr/include/unwatched.h').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'changed while freezing'):
            freeze_files(self.native, facts['files'], self.root / 'snapshot')

    def test_system_abi_headers_are_rejected(self):
        (self.native / 'llvm/include/libcxx-ohos/include/c++/v1/__config_site').write_text(
            '#define _LIBCPP_ABI_NAMESPACE __h\n')
        with self.assertRaisesRegex(ValueError, '__n1'):
            native_inputs(self.native / 'sysroot')

    def test_facade_cannot_shadow_real_abi(self):
        """名字相同的导出不构成实现证明；外壳定义一个 guard 也必须拒绝。"""
        provider = fixture.synthetic_elf([(name, 1, 1, 0, 256)
                         for name in sorted(REQUIRED | {'_ZNSt4__n1example'})])
        good = fixture.synthetic_elf([], ['libc++_shared.so'])
        self.assertEqual(verify(provider, good)['behaviorQualification'], 'not-claimed')
        for bad in (fixture.synthetic_elf([('__cxa_guard_acquire', 1, 1, 0, 256)],
                                         ['libc++_shared.so']), fixture.synthetic_elf([])):
            with self.assertRaisesRegex(ValueError, 'shadows'):
                verify(provider, bad)
        incomplete = fixture.synthetic_elf([(name, 1, 1, 0, 256)
                               for name in REQUIRED - {'_Unwind_Resume'}])
        with self.assertRaisesRegex(ValueError, '_Unwind_Resume'):
            verify(incomplete, good)


if __name__ == '__main__':
    unittest.main(verbosity=2)
