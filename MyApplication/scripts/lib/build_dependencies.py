"""DevEco 与命令行共用的本机依赖位置；只读配置，不下载、不扫描、不修改进程环境。

维护者在工程根放置被 Git 忽略的 build-dependencies.local.json。公开克隆无此文件时
保持原有环境/工作区默认行为；AMCL_BUILD_DEPENDENCIES 可显式选择仓外配置，供 CI
和隔离测试使用。本模块只提供路径，实际输入摘要、JDK 版本与输出边界仍由调用方检查。
"""
from pathlib import Path
import json
import os

PROJECT_ROOT = Path(__file__).resolve().parents[2]
FIELDS = frozenset(("gameCompatInputs", "compatJavaHome", "compatRunRoot"))


def dependency_path(name, root=None, environment=None):
    """返回一个已配置的绝对路径或 None；显式坏配置直接报错，不静默借用其他材料。

    root/environment 只供调用方和测试指定读取上下文，不改全局状态。相对路径不接受，
    避免 IDE 的 cwd 或 daemon 启动位置改变依赖身份。普通本机文件缺失可继续原默认，
    显式 AMCL_BUILD_DEPENDENCIES 指向不存在的文件则视为配置错误。
    """
    if name not in FIELDS:
        raise RuntimeError("Unknown build dependency: " + str(name))
    env = os.environ if environment is None else environment
    selected = env.get("AMCL_BUILD_DEPENDENCIES")
    config = Path(selected) if selected else Path(root or PROJECT_ROOT) / "build-dependencies.local.json"
    if not config.is_absolute():
        raise RuntimeError("Build dependency configuration must be absolute: " + str(config))
    if not config.exists() and not selected:
        return None
    try:
        values = json.loads(config.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as error:
        raise RuntimeError("Cannot read build dependency configuration " + str(config) + ": " + str(error)) from error
    if not isinstance(values, dict) or type(values.get("schemaVersion")) is not int or values["schemaVersion"] != 1:
        raise RuntimeError("Unsupported build dependency schemaVersion in " + str(config))
    unknown = values.keys() - FIELDS - {"schemaVersion"}
    if unknown:
        raise RuntimeError("Unknown build dependency fields in " + str(config) + ": " + ", ".join(sorted(unknown)))
    for field in FIELDS & values.keys():
        value = values[field]
        if not isinstance(value, str) or not value.strip() or not Path(value).is_absolute():
            raise RuntimeError("Build dependency " + field + " must be a nonempty absolute path in " + str(config))
    return Path(values[name]).resolve() if name in values else None
