"""以真实文件/子进程核对 Python 测试夹具生命周期，不启动 SDK、Java 或设备。

故意失败、keep 和链接替换现场都位于本回归亲建的外置域内；回归成功后只留下小汇总。
同时调用实际 build-dependencies 入口，证明 runner 根据真实测试结果回收或保现场。
"""
import json
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
from lib.host_test_lifecycle import HostTestScope
from lib.workspace_paths import PROJECT_ROOT, workspace_path

ROOT = workspace_path("run", "python-test-lifecycle")
ROOT.mkdir(parents=True, exist_ok=True)
SCOPE = HostTestScope("regression-", parent=ROOT)


def directory_link(target, link):
    """Windows 用不要求符号链接权限的 junction；POSIX 用目录符号链接。"""
    if os.name == "nt":
        import _winapi
        _winapi.CreateJunction(str(target), str(link))
    else:
        link.symlink_to(target, target_is_directory=True)


class LifecycleTests(unittest.TestCase):
    """每项测试独占外置父目录，所有有意保留的坏现场由外层成功域统一收尾。"""

    def setUp(self):
        """使用测试名建立互不覆盖的父目录；它不属于被测 scope 的删除权限。"""
        self.parent = SCOPE.directory / ("case-" + hashlib.sha256(self.id().encode("utf-8")).hexdigest()[:8])
        self.parent.mkdir()

    def test_success_preserves_parent_summary_and_sibling(self):
        """成功回收真实文件，且句柄已关闭；父目录的小汇总和无关兄弟文件仍存在。"""
        summary = self.parent / "summary.json"
        summary.write_text('{"state":"PASS"}', encoding="utf-8")
        scope = HostTestScope("case-", parent=self.parent)
        with (scope.directory / "open.txt").open("w", encoding="utf-8") as stream:
            stream.write("real file closed before cleanup")
        self.assertTrue(scope.close())
        self.assertFalse(scope.directory.exists())
        self.assertEqual(summary.read_text(encoding="utf-8"), '{"state":"PASS"}')
        self.assertTrue(scope.close(), "重复关闭不能误删父目录或其他运行")

    def test_failed_scope_keeps_original_bytes(self):
        """失败路径不取消业务、不改写 journal，实际文件保持断言结束时的内容。"""
        scope = HostTestScope("case-", parent=self.parent)
        journal = scope.directory / "journal.json"
        journal.write_bytes(b"failed original journal")
        self.assertFalse(scope.close(success=False))
        self.assertEqual(journal.read_bytes(), b"failed original journal")

    def test_rejects_repository_and_relative_parent(self):
        """输出边界在创建前拒绝仓内与相对路径，不创建仓内临时目录。"""
        for value in (PROJECT_ROOT, Path("relative-parent")):
            with self.assertRaises(ValueError):
                HostTestScope("case-", parent=value)
        for prefix in ("", "../case", "a\\b"):
            with self.assertRaises(ValueError):
                HostTestScope(prefix, parent=self.parent)

    def test_replaced_root_is_not_deleted(self):
        """根被换成链接后即使指向普通目录也拒绝回收，原域和目标原件均保留。"""
        scope = HostTestScope("case-", parent=self.parent)
        original = scope.directory.with_name(scope.directory.name + "-original")
        target = self.parent / "external"
        target.mkdir()
        (target / "keep.txt").write_bytes(b"protected")
        scope.directory.rename(original)
        directory_link(target, scope.directory)
        with self.assertRaisesRegex(ValueError, "identity changed"):
            scope.close()
        self.assertTrue(original.is_dir())
        self.assertEqual((target / "keep.txt").read_bytes(), b"protected")

    def test_nested_link_never_deletes_target(self):
        """内部目录链接仅删除链接本身，不递归进入其他运行的目录。"""
        target = self.parent / "external"
        target.mkdir()
        (target / "keep.txt").write_bytes(b"protected")
        scope = HostTestScope("case-", parent=self.parent)
        directory_link(target, scope.directory / "link")
        self.assertTrue(scope.close())
        self.assertEqual((target / "keep.txt").read_bytes(), b"protected")

    def test_real_dependency_runner_success_failure_and_keep(self):
        """真实 runner 的同一项生产回归覆盖成功、故意失败和显式保留三种退出结果。"""
        entry = Path(__file__).with_name("test-build-dependencies.py")
        code = """
import runpy, sys, unittest
from pathlib import Path
from unittest import mock
entry, parent, mode = sys.argv[1:]
sys.path.insert(0, str(Path(entry).parent))
namespace = runpy.run_path(entry, run_name='dependency_lifecycle_consumer')
Case = namespace['DependencyTests']
if mode == 'failure':
    class Failure(Case):
        def runTest(self):
            self.assertEqual('actual failure', 'expected pass', 'intentional fixture failure')
    suite = unittest.TestSuite([Failure('runTest')])
else:
    suite = unittest.TestSuite([Case('test_missing_local_supports_independent_clone')])
sys.argv = [entry, '--out', parent]
with mock.patch.object(unittest.defaultTestLoader, 'loadTestsFromTestCase', return_value=suite):
    status = namespace['main']()
raise SystemExit(status)
"""
        for mode, exit_code, retained in (("success", 0, False), ("failure", 1, True), ("keep", 0, True)):
            parent = self.parent / mode
            environment = {**os.environ, "AMCL_KEEP_TEST_OUTPUT": "1" if mode == "keep" else ""}
            result = subprocess.run([sys.executable, "-B", "-c", code, str(entry), str(parent), mode],
                                    capture_output=True, text=True, timeout=30, env=environment)
            self.assertEqual(result.returncode, exit_code, result.stdout + result.stderr)
            invocations = list(parent.glob("invocation-*"))
            self.assertEqual(len(invocations), 1)
            report = json.loads((invocations[0] / "summary.json").read_text(encoding="utf-8"))
            self.assertEqual(report["fixtureRetained"], retained)
            self.assertEqual(Path(report["output"]).exists(), retained)
            self.assertEqual(report["state"], "FAIL" if mode == "failure" else "PASS")


if __name__ == "__main__":
    # 小汇总在被测域之外。若断言或安全收尾失败，外层域也保留，不能用清理掩盖失败。
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(LifecycleTests))
    report = {"state": "PASS" if result.wasSuccessful() else "FAIL", "testsRun": result.testsRun,
              "failed": len(result.failures), "errors": len(result.errors), "fixture": str(SCOPE.directory)}
    (ROOT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    SCOPE.close(success=result.wasSuccessful())
    raise SystemExit(0 if result.wasSuccessful() else 1)
