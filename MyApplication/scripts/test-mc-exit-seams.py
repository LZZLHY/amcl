#!/usr/bin/env python3
"""编译执行 mc_launcher 的真实退出接缝；仅系统/模块边界使用可计数桩。

源码直接抽取生产函数，既不抄写其判定，也不把 marker 当成 JVM 退出事实。
变异仅写入 TemporaryDirectory：移除 Authorized 或 ACK 保护后必须被同组断言拒绝。
"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

# 与其余宿主测试使用同一包入口，使 host_cpp 的相对 helper import 在直接执行时也成立。
from lib.host_cpp import compile_cpp

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'entry/src/main/cpp/jvm/mc_launcher.cpp'


def extract(text, signature):
    """当前两段函数均是顶层定义；顶格闭括号限定边界，缺失时硬失败而非测到替代逻辑。"""
    match = re.search(re.escape(signature) + r'\s*\{.*?^\}', text, re.S | re.M)
    if match is None:
        raise AssertionError('无法抽取生产函数：' + signature)
    return match.group(0)


PREFIX = r'''
#include <atomic>
#include <cstdio>
#include <string>

// 桩只替代外部模块与系统副作用；所有判断顺序来自下面原样插入的生产函数。
static std::atomic<bool> g_mcRunning{true};
static std::string g_markerPath = "/synthetic/window-destroy.flag";
static bool authorized, pending, marker, rendererMarker, ack;
static int statReads, rendererReads, taints, acknowledgements, exits, exitCode;
// 会话日志仅替换模块边界，原 ACK/授权判定仍来自生产函数；计数用来验证强制退出不伪封账。
static int ledgerEnds, rawFinishes;
static long long amclLedgerGetLaunchActivity() { return 101; }
static void amclLedgerEnd(long long) { ++ledgerEnds; }
namespace amcl::sessionlog { static void finish() { ++rawFinishes; } }
static bool amclGameExitAuthorizedForCurrentProcess() { return authorized; }
static bool amclGameExitPendingForCurrentProcess() { return pending; }
static bool rendererRestartMarkerPresent() { ++rendererReads; return rendererMarker; }
static void markRendererProcessTainted(const char*) { ++taints; }
static bool amclGameExitAcknowledgeRequested() { ++acknowledgements; return ack; }
struct stub_stat {};
static int stub_stat(const char*, struct stub_stat*) { ++statReads; return marker ? 0 : -1; }
static void stub_exit(int code) { ++exits; exitCode = code; }
#define stat stub_stat
#define _exit stub_exit
#define AMCL_LOG_I(...) ((void)0)
'''

SUFFIX = r'''
#undef stat
#undef _exit
static int assertions = 0, failures = 0;
static void expect(bool value, const char* message) {
    ++assertions;
    if (!value) { ++failures; std::fprintf(stderr, "FAIL: %s\n", message); }
}
static void reset() {
    authorized = pending = marker = rendererMarker = ack = false;
    statReads = rendererReads = taints = acknowledgements = exits = 0;
    ledgerEnds = rawFinishes = 0;
    exitCode = -999;
    g_mcRunning = true;
}
int main() {
    reset(); authorized = true; marker = true;
    expect(mcIsRunning() == 1, "authorized+window-marker before JVM hook must stay running");
    expect(statReads == 0, "authorized interval must not even stat the window marker");
    expect(g_mcRunning, "early marker must not overwrite running state");

    // 核心写盘阶段可能已经不是 Armed，但 Authorized 必须覆盖整个区间。
    reset(); authorized = true; marker = true; pending = false;
    expect(mcIsRunning() == 1, "record-writing authorized interval must stay running");
    expect(statReads == 0, "record-writing gap cannot consume window marker");

    reset(); authorized = true; marker = true; pending = true; rendererMarker = true;
    expect(mcIsRunning() == 0, "real exit pending must wake existing UI exit poll");
    expect(statReads == 0, "pending does not inspect stale window marker");
    expect(rendererReads == 0, "pending does not query rendering state during JVM shutdown");

    reset(); authorized = true; marker = true; g_mcRunning = false;
    expect(mcIsRunning() == 0, "actual main return remains a terminal event");
    expect(statReads == 0, "actual main return does not inspect marker");

    reset(); authorized = true; rendererMarker = true; marker = true;
    expect(mcIsRunning() == 1, "renderer taint alone cannot change isolated JVM exit code");
    expect(taints == 1, "renderer taint observability remains intact");
    expect(statReads == 0, "renderer taint does not bypass authorized protection");

    reset(); marker = true;
    expect(mcIsRunning() == 0, "non-isolated route retains old window-marker termination");
    expect(statReads == 1, "non-isolated route checks its original marker");
    expect(!g_mcRunning, "non-isolated marker clears running state");
    reset(); marker = false;
    expect(mcIsRunning() == 1, "non-isolated missing marker remains running");
    expect(statReads == 1, "non-isolated absent marker is still queried");

    reset(); ack = true;
    mcForceExit();
    expect(acknowledgements == 1, "UI force-exit tries the pending ACK exactly once");
    expect(exits == 0, "accepted ACK must not call _exit(0) and destroy saved nonzero code");
    reset(); ack = false;
    mcForceExit();
    expect(acknowledgements == 1, "nonpending route still checks ACK boundary");
    expect(exits == 1 && exitCode == 0, "nonpending force-exit retains original _exit(0)");
    expect(ledgerEnds == 0 && rawFinishes == 0, "forced active game cannot fabricate orderly capture close");
    reset(); pending = true; ack = true;
    mcForceExit();
    expect(ledgerEnds == 1 && rawFinishes == 1, "real pending shutdown finalizes ledger and raw output");
    expect(acknowledgements == 1 && exits == 0, "capture finalization preserves original ACK exit path");
    reset(); g_mcRunning = false;
    mcForceExit();
    expect(ledgerEnds == 1 && rawFinishes == 1, "main returned can finalize raw output in ordinary UI thread");

    std::printf("mc-exit seams: %d assertions, %d failures\n", assertions, failures);
    return failures ? 1 : 0;
}
'''


def compile_and_run(directory, name, body):
    """编译产物和生成源码只落在本次临时目录，退出时由 TemporaryDirectory 回收。"""
    source = directory / (name + '.cpp')
    binary = directory / (name + ('.exe' if os.name == 'nt' else ''))
    source.write_text(PREFIX + '\n' + body + '\n' + SUFFIX, encoding='utf-8')
    compile_cpp(source, binary)
    return subprocess.run([str(binary)], capture_output=True, text=True, check=False)


def main():
    """正向执行真实函数，再用同组断言拒绝仅临时副本上的两种保护丢失。"""
    text = SOURCE.read_text(encoding='utf-8')
    body = extract(text, 'extern "C" int mcIsRunning()') + '\n' + extract(text, 'extern "C" void mcForceExit()')
    with workspace_temporary_directory(prefix='amcl-mc-exit-seams-') as temporary:
        directory = Path(temporary)
        result = compile_and_run(directory, 'production', body)
        print(result.stdout, end='')
        if result.returncode != 0:
            raise AssertionError(result.stderr)
        mutations = [
            ('missing_authorized', 'if (amclGameExitAuthorizedForCurrentProcess()) return 1;',
             'authorized+window-marker before JVM hook must stay running'),
            ('missing_ack', 'if (amclGameExitAcknowledgeRequested()) return;',
             'accepted ACK must not call _exit(0)'),
        ]
        for name, guard, expected_error in mutations:
            if body.count(guard) != 1:
                raise AssertionError('变异锚点不唯一：' + guard)
            mutated = body.replace(guard, '/* 临时变异：删除受测保护 */', 1)
            failed = compile_and_run(directory, name, mutated)
            if failed.returncode == 0 or expected_error not in failed.stderr:
                raise AssertionError('未捕获指定变异 ' + name + '\n' + failed.stdout + failed.stderr)
            print('PASS: temporary mutation rejected: ' + name)


if __name__ == '__main__':
    main()
