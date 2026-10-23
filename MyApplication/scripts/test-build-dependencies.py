"""本机兼容构建依赖的隔离回归；只使用仓外小夹具，不启动 Java、SDK 或下载。

测试通过真实配置解析器及三个消费者验证优先级。生产配方与产物检查器使用合成
class 和受控编译桩走真实收据路径，避免只匹配源码字符串却遗漏实际消费闭包。
所有目录保留在调用方指定的外置 invocation 中，测试不改真实本机配置和环境。
"""
import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
from lib import build_dependencies as dependencies
from lib import game_compat_inputs as inputs
from lib import game_compat_sessions as sessions
from lib import game_compat_validation as validation
from lib.workspace_paths import external_output_path, workspace_path

PROJECT = Path(__file__).resolve().parents[1]
TEST_ROOT = None


def load_script(name, relative):
    """导入带连字符的生产入口；只加载定义，主函数的构建副作用不会执行。"""
    spec = importlib.util.spec_from_file_location(name, PROJECT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DependencyTests(unittest.TestCase):
    """每项测试独占外置子目录，并清空相关环境，防止借用维护者真实材料。"""

    def setUp(self):
        """临时目录不自动删除，失败时仍可复核实际 JSON、收据和目录生命周期。"""
        self.directory = Path(tempfile.mkdtemp(prefix=self._testMethodName + "-", dir=TEST_ROOT))
        self.root = self.directory / "clone"
        self.root.mkdir()
        self.config = self.root / "build-dependencies.local.json"

    def write_config(self, values, target=None):
        """构造 UTF-8 配置；路径解析测试不要求依赖目录已经存在。"""
        target = target or self.config
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(values, ensure_ascii=False), encoding="utf-8")
        return target

    def local_environment(self, config=None, **extra):
        """以显式仓外配置隔离真实 local 文件，返回供 patch.dict 使用的纯字典。"""
        return {"AMCL_BUILD_DEPENDENCIES": str(config or self.config), **extra}

    def test_missing_local_supports_independent_clone(self):
        """没有 AMCL 工作区标记或私有 JSON 的独立克隆仍可使用旧默认值。"""
        for name in ("gameCompatInputs", "compatJavaHome", "compatRunRoot"):
            self.assertIsNone(dependencies.dependency_path(name, root=self.root, environment={}))
        self.assertFalse((self.root / ".workspace").exists())
        self.assertFalse(self.config.exists())
        with mock.patch.object(dependencies, "PROJECT_ROOT", self.root), mock.patch.dict(os.environ, {}, clear=True):
            self.assertIsNone(dependencies.dependency_path("gameCompatInputs"))
            with mock.patch.object(inputs, "workspace_path", return_value=self.directory / "legacy-inputs") as fallback:
                self.assertEqual(inputs.input_directory(), self.directory / "legacy-inputs")
                fallback.assert_called_once_with("build", "game-compat-inputs")
            with mock.patch.object(sessions, "workspace_path", return_value=self.directory / "legacy-run") as fallback:
                result = sessions.new_compat_session("compat-tests")
                self.assertEqual(result.parent, self.directory / "legacy-run")
                fallback.assert_called_once_with("run", "compat-tests")

    def test_valid_config_default_root_and_no_environment_mutation(self):
        """三个可选绝对路径保持完整；注入 environment 既不读写真实进程环境也不改字典。"""
        values = {name: str(self.directory / ("依赖 " + name))
                  for name in ("gameCompatInputs", "compatJavaHome", "compatRunRoot")}
        self.write_config({"schemaVersion": 1, **values})
        supplied = {"UNRELATED": "sentinel"}
        before = dict(os.environ)
        with mock.patch.object(dependencies, "PROJECT_ROOT", self.root):
            for name, value in values.items():
                self.assertEqual(dependencies.dependency_path(name, environment=supplied), Path(value).resolve())
        self.assertEqual(supplied, {"UNRELATED": "sentinel"})
        self.assertEqual(dict(os.environ), before)
        self.write_config({"schemaVersion": 1})
        self.assertIsNone(dependencies.dependency_path("compatRunRoot", root=self.root, environment={}))

    def test_explicit_config_overrides_local_and_missing_override_fails(self):
        """显式 JSON 是完整选择，不与工程 local 混合；不存在时不可悄悄回退。"""
        self.write_config({"schemaVersion": 1, "gameCompatInputs": str(self.directory / "local")})
        alternate = self.write_config({"schemaVersion": 1, "gameCompatInputs": str(self.directory / "selected")},
                                      self.directory / "selected.json")
        self.assertEqual(dependencies.dependency_path("gameCompatInputs", root=self.root,
                         environment=self.local_environment(alternate)), self.directory / "selected")
        with self.assertRaises(RuntimeError):
            dependencies.dependency_path("gameCompatInputs", root=self.root,
                                         environment=self.local_environment(self.directory / "missing.json"))
        with self.assertRaises(RuntimeError):
            dependencies.dependency_path("gameCompatInputs", root=self.root,
                                         environment={"AMCL_BUILD_DEPENDENCIES": "relative.json"})

    def test_malformed_schema_unknown_fields_and_invalid_paths_fail(self):
        """坏配置必须完整验证；即使请求的是另一字段，也不能忽略未知键或坏路径。"""
        invalid = [[], None, {}, {"schemaVersion": 2}, {"schemaVersion": True},
                   {"schemaVersion": "1"}, {"schemaVersion": 1, "typo": str(self.directory)},
                   *[{"schemaVersion": 1, "compatJavaHome": value}
                     for value in ("", "  ", "relative/jdk", None, 25, [])]]
        for value in invalid:
            with self.subTest(value=value):
                self.write_config(value)
                with self.assertRaises(RuntimeError):
                    dependencies.dependency_path("gameCompatInputs", root=self.root, environment={})
        self.config.write_text("{broken", encoding="utf-8")
        with self.assertRaises(RuntimeError):
            dependencies.dependency_path("compatJavaHome", root=self.root, environment={})
        with self.assertRaises(RuntimeError):
            dependencies.dependency_path("unknown", root=self.root, environment={})

    def test_input_precedence_and_lazy_config_read(self):
        """显参、专用环境、本机 JSON、旧工作区默认按顺序选取，已有高优先项不读低优先项。"""
        local = self.directory / "local-inputs"
        self.write_config({"schemaVersion": 1, "gameCompatInputs": str(local)})
        with mock.patch.dict(os.environ, self.local_environment(AMCL_GAME_COMPAT_INPUTS=str(self.directory / "env-inputs")), clear=True):
            before = dict(os.environ)
            with mock.patch.object(inputs, "dependency_path", side_effect=AssertionError("lower priority config read")):
                self.assertEqual(inputs.input_directory(self.directory / "explicit-inputs"), self.directory / "explicit-inputs")
                self.assertEqual(inputs.input_directory(), self.directory / "env-inputs")
            self.assertEqual(dict(os.environ), before)
        with mock.patch.dict(os.environ, self.local_environment(), clear=True):
            self.assertEqual(inputs.input_directory(), local)
        self.config.write_text("bad JSON", encoding="utf-8")
        with mock.patch.dict(os.environ, self.local_environment(), clear=True), mock.patch.object(inputs, "workspace_path") as fallback:
            with self.assertRaises(RuntimeError):
                inputs.input_directory()
            fallback.assert_not_called()

    def fake_jdk(self, name):
        """仅创建占位工具；所有版本探测均由局部 subprocess 桩返回，不执行真实 JDK。"""
        home = self.directory / name
        binary = home / "bin"
        binary.mkdir(parents=True)
        suffix = ".exe" if os.name == "nt" else ""
        for tool in ("java", "javac"):
            (binary / (tool + suffix)).write_bytes(b"fixture tool, never execute")
        return home, binary / ("javac" + suffix)

    def test_local_jdk25_beats_general_jdk21_without_mutating_environment(self):
        """IDE/SDK 使用的 JAVA_HOME=21 不得盖掉兼容编译专用本机 JDK25。"""
        local, javac = self.fake_jdk("local-jdk25")
        general, _ = self.fake_jdk("sdk-jdk21")
        self.write_config({"schemaVersion": 1, "compatJavaHome": str(local)})
        with mock.patch.dict(os.environ, self.local_environment(JAVA_HOME=str(general)), clear=True):
            before = dict(os.environ)
            with mock.patch.object(inputs.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "javac 25.0.1\n", "")) as probe:
                self.assertEqual(inputs.jdk_tool("java"), str(javac.with_name("java" + javac.suffix)))
                self.assertEqual(probe.call_args.args[0], [str(javac), "-version"])
            self.assertEqual(dict(os.environ), before)

    def test_jdk_explicit_environment_then_general_then_path(self):
        """专用环境绕过 local；没有 local 时才允许 JAVA_HOME/PATH，探测始终使用同目录 javac。"""
        dedicated, dedicated_compiler = self.fake_jdk("dedicated")
        general, general_compiler = self.fake_jdk("general")
        _, path_compiler = self.fake_jdk("on-path")
        probe_result = subprocess.CompletedProcess([], 0, "", "javac 25\n")
        with mock.patch.dict(os.environ, {"AMCL_COMPAT_JAVA_HOME": str(dedicated), "JAVA_HOME": str(general)}, clear=True), \
             mock.patch.object(inputs, "dependency_path", side_effect=AssertionError("local must be bypassed")), \
             mock.patch.object(inputs.subprocess, "run", return_value=probe_result):
            self.assertEqual(inputs.jdk_tool("javac"), str(dedicated_compiler))
        with mock.patch.dict(os.environ, {"JAVA_HOME": str(general)}, clear=True), \
             mock.patch.object(inputs, "dependency_path", return_value=None), \
             mock.patch.object(inputs.subprocess, "run", return_value=probe_result):
            self.assertEqual(inputs.jdk_tool("javac"), str(general_compiler))
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(inputs, "dependency_path", return_value=None), \
             mock.patch.object(inputs.shutil, "which", return_value=str(path_compiler)) as which, \
             mock.patch.object(inputs.subprocess, "run", return_value=probe_result):
            self.assertEqual(inputs.jdk_tool("javac"), str(path_compiler))
            which.assert_called_once_with("javac")

    def test_jdk_version_probe_and_bad_config_do_not_silently_fallback(self):
        """保留 class69 的最低 JDK25 门槛；坏配置、缺工具和不可辨版本均直接失败。"""
        home, compiler = self.fake_jdk("configured")
        self.write_config({"schemaVersion": 1, "compatJavaHome": str(home)})
        with mock.patch.dict(os.environ, self.local_environment(), clear=True):
            for version in ("javac 21.0.8", "unrecognized"):
                with self.subTest(version=version), mock.patch.object(inputs.subprocess, "run",
                     return_value=subprocess.CompletedProcess([], 0, version, "")):
                    with self.assertRaises(RuntimeError):
                        inputs.jdk_tool("javac")
            compiler.unlink()
            with self.assertRaises(RuntimeError):
                inputs.jdk_tool("javac")
            self.config.write_text("not JSON", encoding="utf-8")
            with mock.patch.object(inputs.shutil, "which") as fallback:
                with self.assertRaises(RuntimeError):
                    inputs.jdk_tool("javac")
                fallback.assert_not_called()

    def test_explicit_session_bypasses_config_and_preserves_conflict(self):
        """显式输出最高优先且必须全新；配置再坏也不应改变明确选择的外置目录。"""
        explicit = self.directory / "explicit"
        with mock.patch.dict(os.environ, {"AMCL_RUN_DIR": str(self.directory / "run")}, clear=True), \
             mock.patch.object(sessions, "dependency_path", side_effect=AssertionError("must not read local")), \
             mock.patch.object(sessions, "workspace_path", side_effect=AssertionError("must not read workspace")):
            self.assertEqual(sessions.new_compat_session("compat-tests", explicit), explicit)
            sentinel = explicit / "sentinel"
            sentinel.write_text("preserve", encoding="utf-8")
            with self.assertRaises(FileExistsError):
                sessions.new_compat_session("compat-tests", explicit)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve")

    def test_workspace_environment_overrides_local_run_root(self):
        """AMCL_RUN_DIR 或 AMCL_WORKSPACE_ROOT 任一设置时，均保持原公共路由而不读 local。"""
        for variable in ("AMCL_RUN_DIR", "AMCL_WORKSPACE_ROOT"):
            base = self.directory / variable
            with self.subTest(variable=variable), mock.patch.dict(os.environ, {variable: str(base)}, clear=True), \
                 mock.patch.object(sessions, "dependency_path", side_effect=AssertionError("workspace overrides local")):
                before = dict(os.environ)
                result = sessions.new_compat_session("compat-tests")
                self.assertTrue(base in result.parents)
                if variable == "AMCL_RUN_DIR":
                    self.assertEqual(result.parent, base / "compat-tests")
                else:
                    self.assertEqual(result.parent.parent, base / ".workspace/run")
                self.assertEqual(dict(os.environ), before)

    def test_local_sessions_are_unique_external_and_environment_is_unchanged(self):
        """相同任务多次调用在本机外置根下原子分配新 invocation，不借用或清理旧 classes。"""
        run_root = self.directory / "local-runs"
        self.write_config({"schemaVersion": 1, "compatRunRoot": str(run_root)})
        with mock.patch.dict(os.environ, self.local_environment(), clear=True), \
             mock.patch.object(sessions, "workspace_path", wraps=workspace_path) as route:
            before = dict(os.environ)
            first = sessions.new_compat_session("compat-tests")
            (first / "classes").mkdir()
            (first / "classes/sentinel").write_text("old", encoding="utf-8")
            second = sessions.new_compat_session("compat-tests")
            self.assertNotEqual(first, second)
            self.assertEqual(first.parent, run_root / "compat-tests")
            self.assertEqual(second.parent, first.parent)
            self.assertFalse((second / "classes").exists())
            self.assertEqual((first / "classes/sentinel").read_text(encoding="utf-8"), "old")
            self.assertEqual(external_output_path(first), first)
            self.assertEqual(dict(os.environ), before)
            # 实现可调用公共路由仅校验任务名，但返回的默认目录绝不能成为实际输出。
            self.assertEqual(route.call_args_list, [mock.call("run", "compat-tests"), mock.call("run", "compat-tests")])
            if os.name == "nt" and TEST_ROOT.drive.lower() == "e:":
                self.assertEqual(first.drive.lower(), "e:")
        self.config.write_text("broken", encoding="utf-8")
        with mock.patch.dict(os.environ, self.local_environment(), clear=True), mock.patch.object(sessions, "workspace_path") as fallback:
            with self.assertRaises(RuntimeError):
                sessions.new_compat_session("compat-tests")
            fallback.assert_not_called()

    def test_local_session_rejects_task_traversal_and_repository_output(self):
        """配置不能绕过已有任务名/仓外边界；拒绝发生在创建任何 invocation 之前。"""
        run_root = self.directory / "local-runs"
        self.write_config({"schemaVersion": 1, "compatRunRoot": str(run_root)})
        with mock.patch.dict(os.environ, self.local_environment(), clear=True):
            for task in ("../escape", "..", "bad/name", "NUL"):
                with self.subTest(task=task), self.assertRaises(ValueError):
                    sessions.new_compat_session(task)
            self.assertFalse(run_root.exists())
        repository = self.directory / "external-repository"
        (repository / ".git").mkdir(parents=True)
        self.write_config({"schemaVersion": 1, "compatRunRoot": str(repository)})
        with mock.patch.dict(os.environ, self.local_environment(), clear=True), self.assertRaises(ValueError):
            sessions.new_compat_session("compat-tests")
        self.assertFalse((repository / "compat-tests").exists())

    def recipe_fixture(self):
        """建立最小生产源码树；配方包含真实脚本副本，但永远只写本项 fixture。"""
        root = self.root
        for relative in ("scripts/build-game-compat.py", "scripts/lib/game_compat_inputs.py",
                         "scripts/lib/game_compat_sessions.py", "scripts/lib/build_dependencies.py"):
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((PROJECT / relative).read_bytes())
        source = root / "prebuilt/runtime-compat"
        java = source / "src/com/amcl/compat/Dummy.java"
        java.parent.mkdir(parents=True)
        java.write_text("package com.amcl.compat; public class Dummy {}", encoding="utf-8")
        for relative in ("entry/src/main/resources/rawfile", "launch/src/main/ets", "prebuilt/lwjgl3"):
            (root / relative).mkdir(parents=True)
        lock = source / "threading-inputs.json"
        lock.write_text('{"schema":1}', encoding="utf-8")
        lwjgl = root / "prebuilt/lwjgl3/modern-slot.manifest.json"
        lwjgl.write_text('{"schema":1}', encoding="utf-8")
        # 故意有私有配置；即使该配置参与选路，其机器绝对路径也不能写入可复现配方。
        self.write_config({"schemaVersion": 1, "compatRunRoot": str(self.directory / "private")})
        return root, source, lock, lwjgl

    def test_real_producer_checker_and_host_source_bind_module_not_private_json(self):
        """实际生成/检查最小收据；新模块漂移被拒绝，私有 JSON 改动不污染制品身份。"""
        producer = load_script("dependency_fixture_producer", "scripts/build-game-compat.py")
        checker = load_script("dependency_fixture_checker", "scripts/check-game-runtime-compat.py")
        root, source, lock, lwjgl = self.recipe_fixture()
        output = self.directory / "build-output"
        output.mkdir()
        classpath = [{"position": 0, "path": "compile-only/client.jar", "size": 7, "sha256": "0" * 64}]

        def compile_stub(command, **_kwargs):
            """仅模拟 javac 的 class 输出；不启动任何宿主或目标构建进程。"""
            self.assertIn("--release", command)
            self.assertEqual(command[command.index("--release") + 1], "21")
            target = Path(command[command.index("-d") + 1]) / "com/amcl/compat/Dummy.class"
            target.parent.mkdir(parents=True)
            target.write_bytes(b"\xca\xfe\xba\xbe\x00\x00\x00\x41")
            return subprocess.CompletedProcess(command, 0)

        with contextlib.ExitStack() as stack:
            for module in (producer, checker):
                for name, value in (("ROOT", root), ("LWJGL_LOCK", lwjgl), ("VENDORED_LOCKS", ())):
                    stack.enter_context(mock.patch.object(module, name, value))
                stack.enter_context(mock.patch.object(module, "vendored_classpath", return_value=[]))
                stack.enter_context(mock.patch.object(module, "lwjgl_inputs", return_value=[]))
            stack.enter_context(mock.patch.object(producer, "__file__", str(root / "scripts/build-game-compat.py")))
            stack.enter_context(mock.patch.object(producer, "SOURCE", source))
            stack.enter_context(mock.patch.object(producer, "LOCK", lock))
            stack.enter_context(mock.patch.object(producer, "new_compat_session", return_value=output))
            stack.enter_context(mock.patch.object(producer, "prepare", return_value={"classpath": [], "directory": self.directory}))
            stack.enter_context(mock.patch.object(producer, "classpath_receipt", return_value=classpath))
            stack.enter_context(mock.patch.object(checker, "classpath_receipt", return_value=[]))
            stack.enter_context(mock.patch.object(producer, "jdk_tool", return_value="fixture-javac"))
            stack.enter_context(mock.patch.object(producer.subprocess, "run", side_effect=compile_stub))
            stack.enter_context(mock.patch.object(producer.subprocess, "check_output", return_value="javac 25"))
            stack.enter_context(mock.patch.object(checker, "parse_class", return_value={"major": 65, "name": "com/amcl/compat/Dummy", "references": []}))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            producer.build()
            artifact = checker.check_compat_artifact()
            paths = {item["path"] for item in artifact["sources"]}
            self.assertIn("scripts/lib/build_dependencies.py", paths)
            self.assertFalse(any(path.endswith("build-dependencies.local.json") for path in paths))
            self.write_config({"schemaVersion": 1, "compatRunRoot": str(self.directory / "another-private-location")})
            self.assertEqual(checker.check_compat_artifact(), artifact)
            module = root / "scripts/lib/build_dependencies.py"
            module.write_bytes(module.read_bytes() + b"\n# changed dependency resolver\n")
            with self.assertRaisesRegex(RuntimeError, "Stale Fabric compatibility artifact"):
                checker.check_compat_artifact()

        # 与生产/检查器独立的宿主收据也必须列入该模块。无关固定输入的摘要用占位，
        # 只有新模块读取实字节，因而 fixture 无需复制游戏、JAR 或完整源码仓。
        module = root / "scripts/lib/build_dependencies.py"
        def host_hash(path):
            """只替代不相关宿主材料，保留被审查模块的真实字节漂移。"""
            return hashlib.sha256(module.read_bytes()).hexdigest() if Path(path) == module else "0" * 64
        with mock.patch.object(validation, "ROOT", root), mock.patch.object(validation, "LOCK", lock), \
             mock.patch.object(validation, "LWJGL_LOCK", lwjgl), mock.patch.object(validation, "VENDORED_LOCKS", ()), \
             mock.patch.object(validation, "sha", side_effect=host_hash):
            before = validation.source_snapshot()
            self.assertIn("scripts/lib/build_dependencies.py", {item["path"] for item in before})
            self.assertFalse(any(item["path"].endswith("build-dependencies.local.json") for item in before))
            module.write_bytes(module.read_bytes() + b"# changed again\n")
            self.assertNotEqual(validation.source_snapshot(), before)


def main():
    """每次入口原子分配新 invocation，保留结构化结果；默认仍遵循现有外置路由。"""
    global TEST_ROOT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", "--output", dest="output", help="External parent for a new test invocation")
    arguments = parser.parse_args()
    parent = external_output_path(arguments.output) if arguments.output else workspace_path("run", "dependency-tests")
    parent.mkdir(parents=True, exist_ok=True)
    TEST_ROOT = Path(tempfile.mkdtemp(prefix="invocation-", dir=parent))
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(DependencyTests))
    report = {"schema": 1, "state": "PASS" if result.wasSuccessful() else "FAIL", "testsRun": result.testsRun,
              "failed": len(result.failures), "errors": len(result.errors), "output": str(TEST_ROOT),
              "sdkBuildExecuted": False, "realJavaExecuted": False, "deviceOperations": False}
    (TEST_ROOT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("[build-dependencies] " + json.dumps(report))
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
