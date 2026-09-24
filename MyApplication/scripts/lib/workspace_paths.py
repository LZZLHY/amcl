"""Python/WSL 宿主工具的路径策略；与 workspace-paths.mjs 等价，不要求 Linux 安装 Node。"""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import os
import re
import tempfile

PROJECT_ROOT = Path(__file__).resolve().parents[2]
RUN_STAMP = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + str(os.getpid())


def external_output_path(value, root=None):
    """解析链接后核验仓库边界；公开仓内的嵌套 MyApplication 也不得把输出放到外层仓库。"""
    candidate, project = Path(value).resolve(), Path(root or PROJECT_ROOT).resolve()
    if candidate == project or project in candidate.parents:
        raise ValueError("Output must be outside the project: " + str(value))
    if any((parent / ".git").exists() for parent in [candidate, *candidate.parents]):
        raise ValueError("Output must be outside Git repositories: " + str(value))
    return candidate


def workspace_path(kind, task_id, *parts):
    """返回外部输出位置，不创建目录；配置优先、标记发现其次，独立克隆退回仓外系统临时目录。"""
    if kind not in ("run", "build", "wt"):
        raise ValueError("Invalid workspace kind: " + kind)
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9-]{0,47}", task_id) or re.fullmatch(r"con|prn|aux|nul|com[1-9]|lpt[1-9]", task_id, re.I):
        raise ValueError("Invalid short workspace id: " + task_id)
    for part in parts:
        if Path(part).is_absolute() or ".." in Path(part).parts:
            raise ValueError("输出子路径不得越过任务目录")
    workspace = os.environ.get("AMCL_WORKSPACE_ROOT")
    if workspace:
        if not Path(workspace).is_absolute():
            raise ValueError("AMCL_WORKSPACE_ROOT must be absolute")
        workspace = Path(workspace)
    else:
        workspace = next((parent for parent in PROJECT_ROOT.parents if (parent / ".workspace").exists()
            and ((parent / "AGENTS.md").exists() or (parent / "WORKSPACE-ORGANIZATION-PLAN.md").exists())), None)
    identity = str(PROJECT_ROOT).lower() if os.name == "nt" else str(PROJECT_ROOT)
    checkout = hashlib.sha256(identity.encode("utf-8")).hexdigest()[:8]
    container = workspace / ".workspace" if workspace else Path(tempfile.gettempdir()) / "amcl-workspace"
    run = os.environ.get("AMCL_RUN_DIR") if kind == "run" else None
    if run:
        if not Path(run).is_absolute():
            raise ValueError("AMCL_RUN_DIR must be absolute")
        result = Path(run) / task_id
    else:
        result = container / kind / (task_id + "-" + checkout + ("-" + RUN_STAMP if kind == "run" else ""))
    return external_output_path(result.joinpath(*parts))


def temporary_directory(*args, **kwargs):
    """临时测试保留 tempfile 的自动回收语义，但将默认父目录收口到外部宿主测试区。"""
    if "dir" not in kwargs:
        directory = workspace_path("build", "host-tests")
        directory.mkdir(parents=True, exist_ok=True)
        kwargs["dir"] = directory
    else:
        # 显式 tempfile 父目录也不能绕过外置规则；只有原子文件替换可使用目标同级暂存文件。
        kwargs["dir"] = external_output_path(kwargs["dir"])
    return tempfile.TemporaryDirectory(*args, **kwargs)


if __name__ == "__main__":
    # Bash/无 Node 的 Linux 测试镜像共用此入口；只解析路径，mkdir/生命周期仍由调用者管理。
    import argparse
    parser = argparse.ArgumentParser(description="Resolve AMCL host output outside source repositories")
    parser.add_argument("kind", choices=("run", "build", "wt"))
    parser.add_argument("task_id")
    parser.add_argument("--explicit", default="")
    arguments = parser.parse_args()
    try:
        print(external_output_path(arguments.explicit) if arguments.explicit else workspace_path(arguments.kind, arguments.task_id))
    except ValueError as error:
        parser.exit(1, str(error) + "\n")
