"""真实仓外会话生命周期与共享收据判据负控；不修改工程输入，目录/子进程证据保存在本轮外置会话。"""
import argparse
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
from lib.game_compat_inputs import prepare
from lib.game_compat_sessions import new_compat_session
from lib.game_compat_validation import capture_host_inputs, validate_identity_sections, validate_output_inventory
from lib.workspace_paths import external_output_path


def session_controls(output=None):
    """真实调用分配器证明相同环境可重复/并发使用，且不会覆写旧classes或explicit目录。

    全部证据保留在本次仓外控制目录；.git只是E/系统临时区内的边界测试标记，不初始化
    真实仓库。不在主工程内尝试写拒绝路径，也不删除已有目录来掩盖生命周期问题。
    """
    control = new_compat_session("compat-session-controls", output)
    saved = os.environ.get("AMCL_RUN_DIR")
    run_root = control / "configured-run"
    os.environ["AMCL_RUN_DIR"] = str(run_root)
    children = []
    try:
        observed = []
        for task in ("game-compat-build", "game-compat-tests", "create-thread-device-probe"):
            first = new_compat_session(task)
            classes = first / "classes"; classes.mkdir()
            sentinel = classes / "sentinel.txt"; sentinel.write_text("first invocation must survive", encoding="utf-8")
            second = new_compat_session(task)
            if (first == second or first.parent != run_root / task or second.parent != run_root / task
                or (second / "classes").exists() or sentinel.read_text(encoding="utf-8") != "first invocation must survive"):
                raise AssertionError("Default compatibility calls reused or destroyed a session: " + task)
            observed.extend((first, second))
        # 两个独立Python进程使用完全相同AMCL_RUN_DIR，不能靠模块PID/时间戳碰巧不同。
        child_command = [sys.executable, "-B", str(Path(__file__).resolve()), "--allocate-only", "game-compat-build"]
        for index in range(2):
            children.append(subprocess.Popen(child_command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                             text=True, encoding="utf-8", errors="replace",
                                             creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0))
        parallel = []
        for child in children:
            stdout, stderr = child.communicate(timeout=10)
            if child.returncode != 0:
                raise AssertionError("Default allocation child failed: " + stderr)
            allocated = Path(json.loads(stdout)["directory"]).resolve()
            if allocated.parent != run_root / "game-compat-build" or not allocated.is_dir():
                raise AssertionError("Child session escaped configured external route")
            parallel.append(allocated)
        if len(set([*observed, *parallel])) != len(observed) + len(parallel):
            raise AssertionError("Same-environment parallel invocations collided")
        explicit = new_compat_session("game-compat-build", control / "explicit")
        sentinel = explicit / "sentinel.txt"; sentinel.write_text("do not overwrite", encoding="utf-8")
        try:
            new_compat_session("game-compat-build", explicit)
            raise AssertionError("Existing explicit output was accepted")
        except FileExistsError:
            if sentinel.read_text(encoding="utf-8") != "do not overwrite":
                raise AssertionError("Explicit conflict changed existing evidence")
        # 仓外限制用外置.git标记检验；若分配器回归，也只会在控制目录内产生失败证据。
        boundary = control / "repository-boundary"; (boundary / ".git").mkdir(parents=True)
        try:
            new_compat_session("game-compat-build", boundary / "rejected")
            raise AssertionError("Explicit Git boundary output was accepted")
        except ValueError:
            if (boundary / "rejected").exists():
                raise AssertionError("Rejected explicit boundary was written")
        os.environ["AMCL_RUN_DIR"] = str(boundary)
        try:
            new_compat_session("game-compat-tests")
            raise AssertionError("Default Git boundary output was accepted")
        except ValueError:
            if (boundary / "game-compat-tests").exists():
                raise AssertionError("Rejected default boundary was written")
        for directory in [control, *observed, *parallel, explicit]:
            if external_output_path(directory) != directory:
                raise AssertionError("Session did not resolve to its declared external route")
        report = {"schema": 1, "controlRoot": str(control), "configuredRunRoot": str(run_root),
            "sameProcessSessions": list(map(str, observed)), "parallelSessions": list(map(str, parallel)),
            "explicitConflictPreserved": True, "repositoryBoundaryRejected": True, "oldOutputsDeleted": False}
        (control / "session-controls.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print("[compat-session-controls] PASS three entrypoint domains, sequential+parallel defaults isolated, explicit conflict preserved, external route=" + str(control))
    finally:
        for child in children:
            if child.poll() is None:
                child.kill(); child.wait(timeout=5)
        if saved is None:
            os.environ.pop("AMCL_RUN_DIR", None)
        else:
            os.environ["AMCL_RUN_DIR"] = saved


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs")
    parser.add_argument("--sessions-only", action="store_true", help="Only run real directory lifecycle controls; no Java/build/input downloads")
    parser.add_argument("--output", help="New external control directory, otherwise allocate a unique default invocation")
    parser.add_argument("--allocate-only", help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    if arguments.allocate_only:
        print(json.dumps({"directory": str(new_compat_session(arguments.allocate_only))}))
        return
    session_controls(arguments.output)
    if arguments.sessions_only:
        return
    expected = capture_host_inputs(prepare(arguments.inputs, include_create=True))
    validate_identity_sections(copy.deepcopy(expected), expected)
    controls = []
    def rejects(label, receipt, current=expected):
        """调用最终门实际共用的函数；接受变异即使测试失败，而非复制一份比较算法。"""
        try:
            validate_identity_sections(receipt, current)
        except RuntimeError:
            controls.append(label); return
        raise AssertionError("Receipt gate accepted " + label)
    changed_current = copy.deepcopy(expected); changed_current["sources"].append({"path": "prebuilt/runtime-compat/test/new-required.java", "sha256": "0" * 64})
    rejects("new current source", copy.deepcopy(expected), changed_current)
    changed_current = copy.deepcopy(expected); changed_current["sources"].pop()
    rejects("deleted current source", copy.deepcopy(expected), changed_current)
    altered = copy.deepcopy(expected)
    fixture = next(item for item in altered["sources"] if item["path"].endswith("test-fixtures/create-fly-level.jar"))
    fixture["sha256"] = "0" * 64; rejects("fixture JAR drift", altered)
    changed_current = copy.deepcopy(expected)
    fixture = next(item for item in changed_current["sources"] if item["path"].endswith("test-fixtures/create-fly-level.json"))
    fixture["sha256"] = "0" * 64; rejects("current fixture metadata drift", copy.deepcopy(expected), changed_current)
    for section in ("sources", "classpath", "extraInputs"):
        altered = copy.deepcopy(expected); altered[section].pop(); rejects(section + " truncated", altered)
        altered = copy.deepcopy(expected); altered[section].reverse(); rejects(section + " reordered", altered)
        altered = copy.deepcopy(expected); altered[section][0]["sha256"] = "0" * 64; rejects(section + " bytes changed", altered)
        altered = copy.deepcopy(expected); altered[section].append(copy.deepcopy(altered[section][0])); rejects(section + " duplicate", altered)
    output = [{"path": "transformed/coverage.tsv", "sha256": "1" * 64}]
    validate_output_inventory(output, output)
    try:
        validate_output_inventory(output, output + [{"path": "transformed/new-output", "sha256": "2" * 64}])
        raise AssertionError("Receipt gate accepted newly required output")
    except RuntimeError:
        controls.append("new output")
    print("[host-receipt-contract] PASS actual shared identity/output predicates positive and " + str(len(controls)) + " drift/omission/order controls")


if __name__ == "__main__":
    main()
