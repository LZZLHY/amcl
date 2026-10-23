"""执行真实L2 JVM/JNI与完整SDL SDK/series/neutral生产闭包，不保留末级owner复制夹具。

SDL实际cache、filter、queue、getter及Poll由完整SDK执行，L2由完整维护JAR/JNI执行。
两个入口都要求显式锁定源/工具材料与外置证据路径，缺失时报错，负控仅接受行为断言。
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
from lib.workspace_paths import temporary_directory

ROOT = Path(__file__).resolve().parents[1]


def java_test(directory):
    """L2委托完整JVM/JNI+neutral生产闭包；已退出的Java owner模型不再作为当前实现。

    锁定ZIP与JDK8由环境显式指定，维持公开克隆可复现性；兼容既有AMCL_JAVAC时
    只从其bin推导JDK，不硬编码维护者磁盘。单独运行新脚本也可直接传三个参数。
    AMCL_LWJGL2_TEST_OUT可把长期证据落在调用者指定外部新目录，缺省随本次外置测试树。
    """
    inputs = os.environ.get('AMCL_LWJGL2_INPUTS')
    # 专属JDK8变量优先，避免CI默认JDK21被误用于-source/-target 1.6；旧名继续兼容。
    jdk = os.environ.get('AMCL_LWJGL2_JDK8') or os.environ.get('AMCL_LWJGL2_JDK')
    if not jdk:
        javac = os.environ.get('AMCL_JAVAC') or shutil.which('javac')
        if javac: jdk = str(Path(javac).resolve().parent.parent)
    if not inputs or not jdk:
        raise FileNotFoundError('L2 production test requires AMCL_LWJGL2_INPUTS and AMCL_LWJGL2_JDK8 (legacy AMCL_LWJGL2_JDK accepted)')
    output = os.environ.get('AMCL_LWJGL2_TEST_OUT') or str(directory / 'l2-control')
    command = [sys.executable, str(ROOT / 'scripts/test-lwjgl2-control-delivery.py'),
        '--inputs', inputs, '--jdk', jdk, '--out', output]
    consumer_jar = os.environ.get('AMCL_LWJGL2_CONSUMER_JAR')
    if consumer_jar: command += ['--consumer-jar', consumer_jar]
    # 完整I11配对要显式给真实旧制品，WT已同步的新JAR不能被静默当作旧baseline。
    baseline_jar = os.environ.get('AMCL_LWJGL2_BASELINE_JAR')
    if baseline_jar: command += ['--baseline-jar', baseline_jar]
    subprocess.run(command, check=True)


def sdl_test(directory):
    """执行锁定SDL完整series+完整SDK+唯一neutral Core，退出旧owner数组夹具。

    显式环境给出含锁定commit的只读Git源与可保留的外置证据目录；公开克隆也可使用
    自己的SDL checkout。缺少源明确失败，不以源码接口相同或Ready代替真实消费。
    """
    source = os.environ.get('AMCL_SDL_TEST_REPO')
    if not source:
        raise FileNotFoundError('SDL production test requires AMCL_SDL_TEST_REPO (Git repo containing deps.lock pin)')
    output = os.environ.get('AMCL_SDL_TEST_OUT') or str(directory / 'sdl-control')
    subprocess.run([sys.executable, str(ROOT / 'scripts/test-sdl-control-delivery.py'),
        '--source-repo', source, '--out', output], check=True)


def main():
    with temporary_directory(prefix='input-consumer-semantics-') as output:
        directory = Path(output)
        java_test(directory)
        sdl_test(directory)
    print('test-input-consumer-semantics: production consumers and negative controls PASS')


if __name__ == '__main__':
    main()
