"""Python/WSL 宿主工具的路径策略；与 workspace-paths.mjs 等价，不要求 Linux 安装 Node。"""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import os
import re
import subprocess
import sys
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


def _native_storage_root(value, name):
    """WSL 使用实际 wslpath 转换共享盘符清单，不把 D: 当相对路径或猜 /mnt/d。"""
    if not isinstance(value, str):
        raise ValueError(name + ' must be absolute')
    if Path(value).is_absolute():
        return Path(os.path.abspath(value))
    if sys.platform != 'linux' or not re.match(r'^[a-zA-Z]:[\\/]', value):
        raise ValueError(name + ' must be a native absolute path')
    try:
        converted = subprocess.run(['wslpath', '-u', value], capture_output=True, text=True, timeout=5, check=True).stdout.strip()
    except (OSError, subprocess.SubprocessError) as error:
        raise ValueError(name + ': Windows drive routing requires working wslpath: ' + str(error)) from error
    if not converted or '\n' in converted or '\r' in converted or not Path(converted).is_absolute():
        raise ValueError(name + ': wslpath did not return one native absolute path')
    return Path(os.path.abspath(converted))


def _route_new_output(value, workspace):
    """仅路由本次新路径，绝不搬旧资料或改环境；坏配置明确失败，不回流 canonical。

    最近工作区管理 canonical 的物理位置。显式外部环境目录不在 canonical 内则
    保持原样；external_output_path/显式 --out 不经过此映射，继续执行原边界检查。
    """
    if workspace is None:
        return value
    filename = workspace / '.workspace/storage-routing.json'
    # 不把权限错误/损坏链接等同于无配置，避免新输出静默回到旧物理根。
    try:
        filename.lstat()
    except FileNotFoundError:
        return value
    except OSError as error:
        raise ValueError('Invalid storage routing (' + str(filename) + '): ' + str(error)) from error
    try:
        routing = json.loads(filename.read_text(encoding='utf-8-sig'))
        if not isinstance(routing, dict) or type(routing.get('schemaVersion')) is not int or routing['schemaVersion'] != 1:
            raise ValueError('invalid schema')
        status = routing.get('status')
        if not isinstance(status, str) or not status.strip():
            raise ValueError('invalid status')
        if status == 'INACTIVE' or status.startswith('INACTIVE_'):
            return value
        if status != 'ACTIVE' and not status.startswith('ACTIVE_'):
            raise ValueError('unknown routing status')
        # abspath 消解 .. 但不追随旧目录里的链接；只把同一相对新路径映射到新根。
        canonical = _native_storage_root(routing.get('canonicalStorageRoot'), 'canonicalStorageRoot')
        destination = _native_storage_root(routing.get('newStorageRoot'), 'newStorageRoot')
        canonical_physical, destination_physical = canonical.resolve(), destination.resolve()
        if canonical_physical != (workspace / '.workspace').resolve():
            raise ValueError('canonicalStorageRoot does not match workspace')
        if destination_physical.is_relative_to(canonical_physical) or canonical_physical.is_relative_to(destination_physical):
            raise ValueError('storage roots must be disjoint')
        external_output_path(destination)
        candidate = Path(os.path.abspath(value))
        if not candidate.is_relative_to(canonical):
            return value
        mapped = destination / candidate.relative_to(canonical)
        if not mapped.resolve().is_relative_to(destination_physical):
            raise ValueError('routed output escapes newStorageRoot')
        return mapped
    except (OSError, ValueError, TypeError) as error:
        raise ValueError('Invalid storage routing (' + str(filename) + '): ' + str(error)) from error


def workspace_path(kind, task_id, *parts, _task_scoped=True):
    """返回外部输出位置，不创建目录；配置优先、标记发现其次，独立克隆退回仓外系统临时目录。"""
    if kind not in ("run", "build", "wt"):
        raise ValueError("Invalid workspace kind: " + kind)
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9-]{0,47}", task_id) or re.fullmatch(r"con|prn|aux|nul|com[1-9]|lpt[1-9]", task_id, re.I):
        raise ValueError("Invalid short workspace id: " + task_id)
    for part in parts:
        if Path(part).is_absolute() or ".." in Path(part).parts:
            raise ValueError("输出子路径不得越过任务目录")
    discovered = next((parent for parent in PROJECT_ROOT.parents if (parent / ".workspace").exists()
        and ((parent / "AGENTS.md").exists() or (parent / "WORKSPACE-ORGANIZATION-PLAN.md").exists())), None)
    workspace = os.environ.get("AMCL_WORKSPACE_ROOT")
    if workspace:
        if not Path(workspace).is_absolute():
            raise ValueError("AMCL_WORKSPACE_ROOT must be absolute")
        workspace = Path(workspace)
    else:
        workspace = discovered
    identity = str(PROJECT_ROOT).lower() if os.name == "nt" else str(PROJECT_ROOT)
    checkout = hashlib.sha256(identity.encode("utf-8")).hexdigest()[:8]
    container = workspace / ".workspace" if workspace else Path(tempfile.gettempdir()) / "amcl-workspace"
    # 与Node入口一致：本轮输出集中到任务容器，未声明任务时保持旧路径和CI退路。
    task_root = os.environ.get('AMCL_TASK_ROOT') if _task_scoped else None
    if task_root and not Path(task_root).is_absolute():
        raise ValueError('AMCL_TASK_ROOT must be absolute')
    build_root = (os.environ.get('AMCL_BUILD_DIR') if _task_scoped else None) or (str(Path(task_root) / 'build') if task_root else None)
    if not _task_scoped and workspace:
        # 与Node一致：按真实源码所属容器定位，不因换一次调用环境而换控制状态或缓存。
        try:
            relative = PROJECT_ROOT.relative_to(Path(workspace) / '.workspace' / 'tasks')
        except ValueError:
            relative = None
        if relative and relative.parts:
            group = relative.parts[0]
            if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9-]{0,47}', group) or re.fullmatch(r'con|prn|aux|nul|com[1-9]|lpt[1-9]', group, re.I):
                raise ValueError('Invalid source task container')
            task_root = str(Path(workspace) / '.workspace' / 'tasks' / group)
            build_root = str(Path(task_root) / 'build' / 'shared')
    if build_root and not Path(build_root).is_absolute():
        raise ValueError('AMCL_BUILD_DIR must be absolute')
    run = os.environ.get("AMCL_RUN_DIR") if kind == "run" and _task_scoped else None
    if run:
        if not Path(run).is_absolute():
            raise ValueError("AMCL_RUN_DIR must be absolute")
        result = Path(run) / task_id
    elif kind == 'build' and build_root:
        result = Path(build_root) / (task_id + '-' + checkout)
    elif task_root:
        result = Path(task_root) / ('worktrees' if kind == 'wt' else 'runs') / (
            task_id + '-' + checkout + ('-' + RUN_STAMP if kind == 'run' else ''))
    else:
        result = container / kind / (task_id + "-" + checkout + ("-" + RUN_STAMP if kind == "run" else ""))
    if task_root and not result.joinpath(*parts).resolve().is_relative_to(Path(task_root).resolve()):
        raise ValueError('Task output escapes AMCL_TASK_ROOT')
    routed = _route_new_output(result.joinpath(*parts), discovered or workspace)
    return external_output_path(routed)


def shared_workspace_path(kind, task_id, *parts):
    """共享状态按源码位置稳定归属：固定槽保留原路径，临时源码缓存留所属任务。"""
    if kind != 'build':
        raise ValueError('Shared workspace paths are only for fixed build/control caches')
    return workspace_path(kind, task_id, *parts, _task_scoped=False)


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
