"""SDL 缓存/生命周期的轻量反例；仅验证元数据决策，不编译或声称验证 SDL 业务。

所有夹具均为本测试新建的仓外小文件。业务正负恢复仍只能来自原三门真实执行；
这里专门证明内容漂移不会命中缓存、排他锁确实跨进程生效、清理不会越过 owner。
"""
from pathlib import Path
import argparse
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
from lib.sdl_host_cache import (STAGES, cleanup_owned_build, content_key, exclusive_lock,
    controlled_environment, external_dependencies, file_identity, publish_manifest, routed_path, validate_cached,
    validate_execution, write_json)

ROOT = Path(__file__).resolve().parents[1]
TEST_ROOT = None


class CachePolicyTests(unittest.TestCase):
    """按会造成假命中或误删的具体风险分组，不为每个 helper 机械补测试。"""

    def setUp(self):
        """每例独占仓外夹具，退出只回收 TemporaryDirectory 自己的新内容。"""
        self.temporary = tempfile.TemporaryDirectory(prefix='policy-', dir=TEST_ROOT)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def fixture(self):
        """构造缓存格式的小文件样本，不伪装真实 SDK、编译或业务运行记录。

        此样本仅送入缓存元数据验证器。整组合入口不提供导入这种样本的参数，生产
        publish 前仍必须通过 validate_execution 的真实正负例收据检查。
        """
        out = self.root / 'evidence'
        out.mkdir()
        inputs = {'schema': 'controlled-cache-metadata-test', 'root': str(self.root)}
        header = self.root / 'external-system.h'
        header.write_bytes(b'header-A')
        dependencies = {'files': {str(header): file_identity(header), sys.executable: file_identity(sys.executable)},
            'compilers': {'C_COMPILER': sys.executable, 'CXX_COMPILER': sys.executable}}
        for name in ('sdk-evidence/summary.json', 'owned/summary.json', 'headers/receipt.json'):
            write_json(out / name, {'scope': 'metadata fixture only'})
        binaries = {}
        for index in range(9):
            path = out / 'retained' / ('fixture-' + str(index))
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(('controlled artifact ' + str(index)).encode())
            binaries[str(index)] = {'retainedPath': path.relative_to(out).as_posix(), **file_identity(path)}
        write_json(out / 'retained/binaries.json', binaries)
        write_json(out / 'retained/sources.json', {'source': {'member': 'controlled-member'}})
        (out / 'retained/sources.tar.gz').write_bytes(b'controlled archive identity fixture')
        write_json(out / 'receipt.json', {'state': 'PASS', 'inputKey': content_key(inputs),
            'commands': [{'command': [sys.executable, '-B', stage], 'exitCode': 0} for stage in STAGES]})
        publish_manifest(out, inputs, dependencies)
        manifest = out / 'cache-manifest.json'
        return out, inputs, header, {'manifest': str(manifest), 'identity': file_identity(manifest)}

    def test_raw_artifact_drift_rejects_even_when_size_and_mtime_match(self):
        """模拟旧 stat 缓存会漏掉的同长度改写，实际 SHA 回读必须拒绝。"""
        out, inputs, _, pointer = self.fixture()
        validate_cached(pointer, inputs)
        artifact = out / 'retained/fixture-0'
        before = artifact.stat()
        data = artifact.read_bytes()
        artifact.write_bytes(b'X' + data[1:])
        os.utime(artifact, ns=(before.st_atime_ns, before.st_mtime_ns))
        with self.assertRaisesRegex(ValueError, 'CACHE_ARTIFACT_DRIFT'):
            validate_cached(pointer, inputs)

    def test_installed_header_drift_and_missing_dependency_proof_reject(self):
        """工具路径和版本没变，实际系统头改了仍必须失效；无闭包不能缓存。"""
        _, inputs, header, pointer = self.fixture()
        header.write_bytes(b'header-B')
        with self.assertRaisesRegex(ValueError, 'CACHE_HOST_DEPENDENCY_DRIFT'):
            validate_cached(pointer, inputs)
        build, project = self.root / 'build', self.root / 'project'
        build.mkdir();project.mkdir()
        with self.assertRaisesRegex(ValueError, 'SDK_EXTERNAL_HEADER_DEPENDENCIES_MISSING'):
            external_dependencies(project, build)
        # 实际解析编译器 read-tlog 的小样本，证明闭包来自依赖记录而非扫描整个 SDK。
        (build / 'CL.read.1.tlog').write_text(str(header) + '\n', encoding='utf-16')
        with self.assertRaisesRegex(ValueError, 'SDK_ACTUAL_COMPILER_DEPENDENCIES_MISSING'):
            external_dependencies(project, build)
        # 路径解析的受控样本用当前 Python 可执行文件作可校验文件，不声称它是真编译器。
        (build / 'CMakeCCompiler.cmake').write_text('set(CMAKE_C_COMPILER "' + Path(sys.executable).as_posix() + '")\n'
            'set(CMAKE_CXX_COMPILER "' + Path(sys.executable).as_posix() + '")\n', encoding='utf-8')
        if os.name == 'nt':
            (build / 'link.read.1.tlog').write_text(str(header) + '\n', encoding='utf-16')
            library = self.root / 'controlled-link-input.lib'
            library.write_bytes(b'controlled link identity only')
            (build / 'link.read.1.tlog').write_text(str(library) + '\n', encoding='utf-16')
            self.assertEqual(external_dependencies(project, build)['files'][str(header)], file_identity(header))
        else:
            with self.assertRaisesRegex(ValueError, 'POSIX_LINK_RUNTIME_CLOSURE_UNAVAILABLE'):
                external_dependencies(project, build)

    def test_empty_execution_commands_cannot_qualify_cache(self):
        """七个空对象或空编译文件不能冒充真实门执行；缺命令在资格入口即拒绝。"""
        out, build = self.root / 'out', self.root / 'build'
        write_json(out / 'headers/receipt.json', {'sourceDrift': [], 'facts': [{}] * 7, 'commands': []})
        with self.assertRaisesRegex(ValueError, 'HEADER_CHECKOUT_PROOF_INCOMPLETE'):
            validate_execution(out, build)

    def test_response_file_injection_is_removed_only_for_child(self):
        """保持 @rsp 文本不变而改文件不能绕过资格；组合门根本不接受此隐式参数入口。"""
        original = dict(os.environ, CL='@external.rsp', _CL_='/FIexternal.h', LINK='@link.rsp',
            _LINK_='/DEBUG', CFLAGS='@cflags.rsp', CXXFLAGS='@cxxflags.rsp', CPPFLAGS='-include external.h', LDFLAGS='@ld.rsp')
        child = controlled_environment(original)
        self.assertEqual(original['CL'], '@external.rsp')
        self.assertEqual(child.get('PATH'), original.get('PATH'))
        self.assertTrue(all(name not in child for name in ('CL', '_CL_', 'LINK', '_LINK_', 'CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS')))

    def test_reused_receipt_cannot_become_original_execution_proof(self):
        """复用链不能把一个零次执行的 REUSED 再包装为原始成功。"""
        out, inputs, header, _ = self.fixture()
        value = json.loads((out / 'receipt.json').read_text())
        value['state'] = 'REUSED'
        write_json(out / 'receipt.json', value)
        publish_manifest(out, inputs, {'files': {str(header): file_identity(header), sys.executable: file_identity(sys.executable)},
            'compilers': {'C_COMPILER': sys.executable, 'CXX_COMPILER': sys.executable}})
        manifest = out / 'cache-manifest.json'
        with self.assertRaisesRegex(ValueError, 'CACHE_SUCCESS_RECEIPT_INCOMPLETE'):
            validate_cached({'manifest': str(manifest), 'identity': file_identity(manifest)}, inputs)

    def test_file_lock_is_exclusive_across_processes_and_releases(self):
        """新进程必须被真实 OS 锁拒绝；原持有者退出上下文后能重新取得。"""
        lock = self.root / 'input.lock'
        command = [sys.executable, '-B', str(Path(__file__).resolve()), '--try-lock', str(lock)]
        with exclusive_lock(lock, timeout=0):
            held = subprocess.run(command, capture_output=True, timeout=15)
            self.assertEqual(held.returncode, 3, held.stderr.decode(errors='replace'))
        released = subprocess.run(command, capture_output=True, timeout=15)
        self.assertEqual(released.returncode, 0, released.stderr.decode(errors='replace'))

    def test_cleanup_requires_current_owner_and_preserves_sibling(self):
        """错误 owner 拒绝清理，正确 owner 只删自己的新树，旁边证据原字节保留。"""
        build = self.root / 'build'
        build.mkdir()
        sentinel = self.root / 'unrelated-evidence'
        sentinel.write_bytes(b'keep')
        readonly = build / 'new-output'
        readonly.write_bytes(b'current run only')
        # Windows 的真实 Git object 使用只读属性；必须覆盖这个实际回收失败形态。
        readonly.chmod(stat.S_IREAD)
        write_json(build / '.sdl-combination-owner.json', {'owner': 'ours', 'path': str(build.resolve())})
        with self.assertRaisesRegex(ValueError, 'BUILD_OWNER_IDENTITY_MISMATCH'):
            cleanup_owned_build(build, 'someone-else')
        self.assertTrue(build.is_dir())
        cleanup_owned_build(build, 'ours')
        self.assertFalse(build.exists())
        self.assertEqual(sentinel.read_bytes(), b'keep')


def main():
    """支持显式 E 盘证据目录；定向组无参数调用仍遵循当前外置路由。"""
    global TEST_ROOT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out')
    parser.add_argument('--try-lock')
    args = parser.parse_args()
    if args.try_lock:
        try:
            with exclusive_lock(Path(args.try_lock), timeout=0):
                return 0
        except TimeoutError:
            return 3
    TEST_ROOT = Path(args.out).resolve() if args.out else routed_path(ROOT, 'run', 'sdl-cache-test-' + str(os.getpid()))
    TEST_ROOT.mkdir(parents=True, exist_ok=False)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(CachePolicyTests))
    write_json(TEST_ROOT / 'summary.json', {'scope': 'cache metadata, host-header drift, process lock and owned cleanup only; no SDL compile/business claim',
        'testsRun': result.testsRun, 'failures': len(result.failures), 'errors': len(result.errors)})
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
