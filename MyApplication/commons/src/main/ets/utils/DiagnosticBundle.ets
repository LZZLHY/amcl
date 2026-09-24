/**
 * DiagnosticBundle.ets — 统一诊断包组装（日志系统 v2 · P2）
 *
 * 把分散的几路诊断信息拼成**一个**可复制/上传的文本：
 *   1. 环境头：时间 + 设备 + 系统 + 应用版本 + 当前 MC 版本 + JDK（由调用方传入版本信息）
 *   2. 启动器日志（amcl_launcher.log 尾部，调用方经 NAPI amclLogRead 读出后传入）
 *   3. 游戏日志（mc_output.log 尾部，调用方经 NAPI mcReadLog / SessionMarker 读出后传入）
 *
 * 背景：app 日志（amcl_launcher.log）与游戏日志（mc_output.log）是两个独立文件、两套机制，
 * 且 JVM 子进程的 native 日志（fork 后 amcl_log 关闭）只进 mc_output.log。排障常需两者一起看。
 * 本类提供"一键拿全"的组装出口，供"复制日志""上传崩溃日志"复用。
 *
 * 约束（commons 层）：无 native、无业务。设备/系统信息走 @ohos.deviceInfo（与 DeviceProfile 同源）；
 * 应用版本号等需要 bundleManager 的信息由调用方（entry/products 层）读出后通过参数传入。
 */

import deviceInfo from '@ohos.deviceInfo';

/** 环境头可选字段（调用方按需提供，缺省即省略该行）。 */
export interface DiagnosticEnv {
  appVersion?: string;   // 形如 "1.0.0-beta.4 (1000188)"，由调用方经 bundleManager 拼好
  mcVersion?: string;    // 当前选中的 MC 版本（目录名）
  jdk?: string;          // 实际生效的 JDK 版本
  note?: string;         // 额外备注（如错误摘要）
}

export class DiagnosticBundle {
  /** 组装环境信息头。设备/系统自动取；版本类信息由调用方传入。 */
  static buildEnvHeader(env?: DiagnosticEnv): string {
    let lines: string[] = [];
    lines.push('===== AMCL 诊断信息 =====');
    lines.push('时间: ' + new Date().toISOString());
    try {
      let dev = (deviceInfo.marketName && deviceInfo.marketName.length > 0)
        ? deviceInfo.marketName : deviceInfo.productModel;
      lines.push('设备: ' + dev);
      lines.push('系统: ' + deviceInfo.osFullName);
    } catch (e) {
      lines.push('设备/系统: (读取失败)');
    }
    if (env !== undefined) {
      if (env.appVersion !== undefined && env.appVersion.length > 0) lines.push('应用版本: ' + env.appVersion);
      if (env.mcVersion !== undefined && env.mcVersion.length > 0) lines.push('游戏版本: ' + env.mcVersion);
      if (env.jdk !== undefined && env.jdk.length > 0) lines.push('JDK: ' + env.jdk);
      if (env.note !== undefined && env.note.length > 0) lines.push('备注: ' + env.note);
    }
    return lines.join('\n');
  }

  /**
   * 组装完整诊断包：环境头 + 启动器日志 + 游戏日志。
   * 任一日志为空则用占位说明（不省略小标题，便于一眼看出"哪路没拿到"）。
   */
  static assemble(env: DiagnosticEnv | undefined, launcherLog: string, gameLog: string): string {
    let s = DiagnosticBundle.buildEnvHeader(env);
    s += '\n\n===== AMCL 启动器日志 (amcl_launcher.log) =====\n';
    s += (launcherLog && launcherLog.length > 0) ? launcherLog : '(无启动器日志)';
    s += '\n\n===== MC 游戏日志 (mc_output.log) =====\n';
    s += (gameLog && gameLog.length > 0) ? gameLog : '(无游戏日志 / 本次未启动游戏)';
    return s;
  }
}
