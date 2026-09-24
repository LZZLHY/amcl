#!/usr/bin/env python3
"""对生产 JAR 补丁执行跨宿主 ZIP 元数据回归，不修改锁文件或生产制品。"""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location(
    "amcl_module_info_patch", Path(__file__).with_name("patch-lwjgl-module-info.py"))
PATCHER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PATCHER)
ORIGINAL_INFO = zipfile.ZipInfo


def host_zip_info(system):
    """仅模拟新 ZipInfo 的宿主默认值；读取已有条目仍由 ZIP 头恢复其真实字段。"""
    class HostInfo(ORIGINAL_INFO):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.create_system = system
    return HostInfo


class ModuleInfoReproducibilityTest(unittest.TestCase):
    def test_windows_and_unix_produce_identical_bytes(self):
        """同一输入在两种宿主默认值下字节一致，最低版本和原有条目均得到保留。"""
        with tempfile.TemporaryDirectory(prefix="amcl-module-info-") as directory:
            root = Path(directory)
            baseline = root / "upstream.jar"
            with zipfile.ZipFile(baseline, "w") as jar:
                for name, content in [
                    ("META-INF/versions/25/module-info.class", b"version-25"),
                    ("META-INF/versions/11/module-info.class", b"version-11"),
                    ("org/lwjgl/example.class", b"original-class-bytes"),
                ]:
                    info = ORIGINAL_INFO(name, (2000, 1, 1, 0, 0, 0))
                    info.create_system = 3
                    info.external_attr = 0o644 << 16
                    jar.writestr(info, content)
            outputs = []
            for system in (0, 3):
                candidate = root / (str(system) + ".jar")
                shutil.copyfile(baseline, candidate)
                with patch.object(zipfile, "ZipInfo", host_zip_info(system)):
                    status, source = PATCHER.patch_jar(candidate)
                self.assertEqual(status, "patched")
                self.assertEqual(source, "META-INF/versions/11/module-info.class")
                with zipfile.ZipFile(candidate) as jar:
                    self.assertEqual(jar.read("module-info.class"), b"version-11")
                    self.assertEqual(jar.getinfo("module-info.class").create_system, 0)
                    self.assertEqual(jar.getinfo("org/lwjgl/example.class").create_system, 3)
                    self.assertEqual(jar.read("org/lwjgl/example.class"), b"original-class-bytes")
                outputs.append(candidate.read_bytes())
                self.assertEqual(PATCHER.patch_jar(candidate)[0], "skip-has-root")
                self.assertEqual(candidate.read_bytes(), outputs[-1])
            self.assertEqual(outputs[0], outputs[1])


if __name__ == "__main__":
    unittest.main()
