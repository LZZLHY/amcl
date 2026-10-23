"""兼容层三个入口共用的调用目录分配；不改变全工作区的路径或清理契约。"""
from pathlib import Path
import os
import tempfile
from lib.workspace_paths import external_output_path, workspace_path
from lib.build_dependencies import dependency_path


def new_compat_session(task_id, explicit_output=None):
    """显式目录要求全新；默认在工作区任务父目录中原子分配独立invocation。

    正常SDK流程会在相同AMCL_RUN_DIR里多次构建兼容JAR。workspace_path返回的是任务
    归档父位置，不能把它误当成每次调用唯一目录。mkdtemp显式指定该父目录，避免全局
    临时目录、PID或秒级时间戳带来的撞名；不删除旧证据，也不共享任何旧classes树。
    """
    if explicit_output is not None:
        directory = external_output_path(explicit_output)
        directory.mkdir(parents=True, exist_ok=False)
        return directory
    # 已有包装器的显式输出环境优先；普通IDE无该环境时才使用本机配置的外置父目录。
    # 只影响兼容层会话，不修改os.environ、全局TEMP或公共JS/Python/PowerShell路由。
    configured = None if os.environ.get("AMCL_RUN_DIR") or os.environ.get("AMCL_WORKSPACE_ROOT") else dependency_path("compatRunRoot")
    if configured is not None:
        # 沿用公共分配器校验task_id，拒绝../等越界；只解析，不在旧默认位置创建文件。
        workspace_path("run", task_id)
        parent = external_output_path(configured / task_id)
    else:
        parent = workspace_path("run", task_id)
    parent.mkdir(parents=True, exist_ok=True)
    # 父路径及最终子路径均经公共仓外/链接边界检查，公共workspace_paths本身不作改动。
    parent = external_output_path(parent)
    directory = Path(tempfile.mkdtemp(prefix="invocation-", dir=parent))
    return external_output_path(directory)
