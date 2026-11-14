"""固定 CF 资格策略 v2；只用于独立测试，不修改产品公共 JVM 参数。

现代 Oracle 的 exclude 是有顺序的 bool。固定实验先显式添加 broad，再追加同 pattern
的 false，才能同时恢复 CF 自身编译和其他调用者对 CF 的正常内联。仅在 CF
编译根设置 IgnoreCompileCommands 无法解除外部调用者的旧禁内联，旧文件保留
作为历史反例。C2-only 另通过固定两条 directive 关闭 CF 的 C2 独立编译/内联，
C1 使用默认 directive；本固定资格不接受其它自定义 compiler 规则。
"""
from pathlib import Path
import shutil

BASE = Path(__file__).resolve().parent
POLICY = 'cf-compiler-oracle-v2'
BROAD = '-XX:CompileCommand=exclude,java/util/concurrent/CompletableFuture.*'
RESTORE = BROAD + ',false'
C2_FILE = 'cf_c2_only_v2_directives.json'


def compiler_options(arm, legacy, directory):
    """为已知三臂返回真实选项；只将固定 JSON 复制到本轮独占目录。

    JDK8 仍只做 broad/full，full 不追加 broad，目标端Fresh TestHooks省略自动项并显式装配本固定臂。
    不尝试用 bool=false 或全局 C1 模拟 JDK8 不存在的每 compiler 控制。
    """
    if arm not in ('broad', 'c2-only', 'full') or (legacy and arm == 'c2-only'):
        raise ValueError('Unsupported fixed CF arm')
    if legacy:
        return [BROAD] if arm == 'broad' else []
    options = [BROAD, '-XX:+CompilerDirectivesPrint']
    if arm != 'broad':
        options.append(RESTORE)
    if arm == 'c2-only':
        destination = Path(directory) / 'directives.json'
        if destination.exists():
            raise ValueError('Per-run directives already exist')
        shutil.copyfile(BASE / C2_FILE, destination)
        options.append('-XX:CompilerDirectivesFile=' + str(destination))
    return options
