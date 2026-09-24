/**
 * ModpackPostProcessor.ets — 整合包特殊脚本 / 推荐启动参数处理（P6）
 *
 * 文档：docs/guides/modpack-install-plan.md §七.6
 *
 * 背景（决策5：必须解析处理整合包附带的特殊脚本/配置）：
 *   整合包除了 mod，还常附带**影响运行/启动**的特殊文件。多数（CraftTweaker `scripts/`、
 *   KubeJS `kubejs/`、`config/`、`defaultconfigs/`、`servers.dat`、`options.txt`）属于
 *   **游戏运行期数据**——只要随 overrides 原样落地即可（游戏内自行加载），启动器无需解析。
 *   这部分已由 ModpackInstaller 的 overrides 全量保真复制保证（不丢、不改）。
 *
 *   真正需要启动器**解析并生效**的是「推荐启动参数」：
 *     - Forge 整合包的 `user_jvm_args.txt`（Forge 官方放推荐 JVM 参数的标准位置，
 *       游戏靠 `@user_jvm_args.txt` 读取；但 AMCL 用自己的启动链路，需主动解析后
 *       写入该版本的启动配置才能生效）。
 *
 * 本模块为**纯解析**（读 versionDir 下的文本文件），不写偏好（写入由 entry 层用
 * PreferenceManager 完成，避免 mods → feature_system 的层级反向依赖）。
 *
 * 创建日期：2026-06-15
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_DOWNLOAD } from 'commons';

const TAG = 'ModpackPostProcessor';

/** 解析结果：推荐启动参数 + 提示。 */
export interface ModpackPostResult {
  /** 推荐 JVM 参数（已去注释、合并为空格分隔串）。空串表示无。 */
  recommendedJvmArgs: string;
  /** 从 -Xmx 解析出的推荐最大内存（MB）；0 表示未指定。 */
  recommendedMaxMemMb: number;
  /** 处理过程中的提示（写入 install 结果 warnings）。 */
  notes: string[];
}

/**
 * 处理已落地版本目录下的特殊启动配置。当前解析 Forge `user_jvm_args.txt`。
 * @param versionDir 版本目录绝对路径（overrides 已铺好）。
 */
export function processModpackLaunchConfig(versionDir: string): ModpackPostResult {
  let result: ModpackPostResult = { recommendedJvmArgs: '', recommendedMaxMemMb: 0, notes: [] };

  let jvmArgsPath = versionDir + '/user_jvm_args.txt';
  let content = '';
  try {
    if (fs.statSync(jvmArgsPath).isFile()) {
      content = fs.readTextSync(jvmArgsPath);
    }
  } catch (e) {
    return result;  // 无该文件（多数 Fabric 包），正常
  }
  if (content.length === 0) return result;

  let args = parseJvmArgsText(content);
  if (args.length === 0) return result;

  result.recommendedMaxMemMb = extractXmxMb(args);
  // -Xmx 单独走 xmx 字段，从参数串里剔除避免重复
  let filtered: string[] = [];
  for (let a of args) {
    if (a.startsWith('-Xmx') || a.startsWith('-xmx')) continue;
    filtered.push(a);
  }
  result.recommendedJvmArgs = filtered.join(' ');
  if (result.recommendedJvmArgs.length === 0 && result.recommendedMaxMemMb === 0) return result;
  result.notes.push('已解析整合包推荐 JVM 参数（user_jvm_args.txt）并应用到该版本');
  AppLogger.info(TAG, `parsed user_jvm_args.txt: args="${result.recommendedJvmArgs}" xmx=${result.recommendedMaxMemMb}MB`, LOG_DOMAIN_DOWNLOAD);
  return result;
}

/**
 * 解析 user_jvm_args.txt：按行读，**忽略以 # 开头的注释行与空行**，
 * 收集每行的非空 token（一行可有多个参数）。
 */
export function parseJvmArgsText(text: string): string[] {
  let out: string[] = [];
  let lines = text.split('\n');
  for (let raw of lines) {
    let line = raw.replace(/\r/g, '').trim();
    if (line.length === 0) continue;
    if (line.startsWith('#')) continue;
    let tokens = line.split(/\s+/);
    for (let t of tokens) {
      if (t.length > 0) out.push(t);
    }
  }
  return out;
}

/** 从参数列表里找 -Xmx 并换算成 MB（支持 G/M/K 后缀）；找不到返回 0。 */
export function extractXmxMb(args: string[]): number {
  for (let a of args) {
    if (a.length > 4 && (a.startsWith('-Xmx') || a.startsWith('-xmx'))) {
      let v = a.substring(4);
      return parseMemToMb(v);
    }
  }
  return 0;
}

/** 把 "4G" / "4096M" / "1048576K" / "4294967296" 解析为 MB。 */
export function parseMemToMb(v: string): number {
  if (v.length === 0) return 0;
  let last = v.charAt(v.length - 1).toLowerCase();
  let numPart = (last === 'g' || last === 'm' || last === 'k' || last === 'b')
    ? v.substring(0, v.length - 1) : v;
  let n = Number.parseFloat(numPart);
  if (Number.isNaN(n) || n <= 0) return 0;
  if (last === 'g') return Math.round(n * 1024);
  if (last === 'm') return Math.round(n);
  if (last === 'k') return Math.round(n / 1024);
  // 无后缀：按字节
  return Math.round(n / (1024 * 1024));
}
