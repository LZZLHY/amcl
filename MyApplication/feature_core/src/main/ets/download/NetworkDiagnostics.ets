/**
 * NetworkDiagnostics.ets — 完整网络环境检测
 *
 * 背景：应用商店审核 / 部分用户环境中，「有网络」（系统浏览器能开网页）不代表
 * 应用需要的下载服务器可达——审核实验室 / 公司网 / 代理常只放行白名单域名，导致
 * 版本清单（Mojang）、模组源（MCIM）、JDK 镜像（GitHub 代理）三个不相关的境外/公网
 * 端点同时不可达。本模块做一次「分层」检测，明确区分：
 *
 *   ① 设备是否连着网络（系统网络层，connection kit）
 *   ② 能否访问公网（基础连通性，NetworkKit 打百度，走系统 CA）
 *   ③ 应用安全证书（CA bundle）是否就绪（所有 HTTPS 下载的前置）
 *   ④ 各关键下载源是否可达（复用真正的下载引擎 fetchTextEx，走 cacert + libcurl，
 *      与真实下载完全同路，避免「探测通但下载不通」的错位）
 *
 * 所有探测都带较短超时并可并行；结果汇总成一个可读结论 + 建议，供 UI 展示。
 */

import { connection, http } from '@kit.NetworkKit';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_DOWNLOAD } from 'commons';
import { DownloadManager } from './DownloadManager';

const TAG = 'NetworkDiagnostics';

/** 单项探测状态 */
export enum ProbeStatus {
  OK = 'ok',
  FAIL = 'fail',
  SKIP = 'skip',
}

/** 探测分类（决定图标/分组） */
export enum ProbeCategory {
  SYSTEM = 'system',       // 系统网络层
  BASELINE = 'baseline',   // 基础公网连通性
  SECURITY = 'security',   // CA bundle
  SOURCE = 'source',       // 下载源
}

/** 单项探测结果 */
export interface NetworkProbe {
  id: string;
  name: string;
  category: ProbeCategory;
  status: ProbeStatus;
  rttMs: number;         // -1 表示不适用
  detail: string;        // 成功=状态/类型，失败=错误摘要
  critical: boolean;     // 是否核心项（影响总体结论）
}

/** 总体结论 */
export enum NetworkVerdict {
  OK = 'ok',                       // 一切正常
  NO_SYSTEM_NET = 'no_system_net', // 设备未连接网络
  NO_INTERNET = 'no_internet',     // 连着网但上不了公网
  CA_NOT_READY = 'ca_not_ready',   // 安全证书未就绪
  DOWNLOAD_BLOCKED = 'blocked',    // 能上网但连不上下载服务器
  PARTIAL = 'partial',             // 部分源不可用
}

/** 完整诊断报告 */
export interface NetworkReport {
  verdict: NetworkVerdict;
  title: string;
  summary: string;
  suggestions: string[];
  probes: NetworkProbe[];
  finishedAt: number;
}

// ============================================================
//  探测端点（选小/可 2xx 的路径，尽量不拉大文件）
// ============================================================

const URL_BAIDU = 'https://www.baidu.com/';
const URL_AMCL = 'https://amcl.lovedhy.cn/api/health';
const URL_MOJANG = 'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json';
const URL_JDK_MIRROR = 'https://ghfast.top/https://raw.githubusercontent.com/LZZLHY/mc-ohos-resources/main/README.md';
const URL_GITHUB = 'https://raw.githubusercontent.com/LZZLHY/mc-ohos-resources/main/README.md';
const URL_MCIM = 'https://mod.mcimirror.top/modrinth/v2/search?limit=1';

const PROBE_TIMEOUT_S = 8;

// ============================================================
//  系统网络层（connection kit）
// ============================================================

interface SystemNetInfo {
  online: boolean;
  typeText: string;
}

function checkSystemNet(): SystemNetInfo {
  try {
    let net = connection.getDefaultNetSync();
    // netId < 100 视为无有效默认网络（0 = 无网络）
    if (!net || net.netId < 100) {
      return { online: false, typeText: '未连接任何网络' };
    }
    let typeText = '已连接';
    try {
      let caps = connection.getNetCapabilitiesSync(net);
      let bearers = caps.bearerTypes !== undefined ? caps.bearerTypes : [];
      let names: string[] = [];
      for (let b of bearers) {
        if (b === connection.NetBearType.BEARER_WIFI) names.push('WiFi');
        else if (b === connection.NetBearType.BEARER_CELLULAR) names.push('蜂窝');
        else if (b === connection.NetBearType.BEARER_ETHERNET) names.push('以太网');
      }
      if (names.length > 0) typeText = names.join(' / ');
    } catch (e) {
      // 拿不到能力（权限/版本）不致命，仍视为在线
    }
    return { online: true, typeText };
  } catch (e) {
    AppLogger.warn(TAG, 'checkSystemNet failed', e as Object, LOG_DOMAIN_DOWNLOAD);
    // 拿不到系统网络信息时不武断判无网，交给后续连通性探测
    return { online: true, typeText: '未知' };
  }
}

// ============================================================
//  基础连通性（NetworkKit，走系统 CA，区别于下载引擎）
// ============================================================

async function probeBaseline(): Promise<NetworkProbe> {
  let start = Date.now();
  let req = http.createHttp();
  try {
    let resp = await req.request(URL_BAIDU, {
      method: http.RequestMethod.GET,
      connectTimeout: PROBE_TIMEOUT_S * 1000,
      readTimeout: PROBE_TIMEOUT_S * 1000,
      expectDataType: http.HttpDataType.STRING,
    });
    let rtt = Date.now() - start;
    let code = resp.responseCode;
    let ok = code >= 200 && code < 400;
    return {
      id: 'baseline', name: '基础互联网连接', category: ProbeCategory.BASELINE,
      status: ok ? ProbeStatus.OK : ProbeStatus.FAIL, rttMs: rtt,
      detail: ok ? ('可访问公网 · ' + rtt + 'ms') : ('HTTP ' + code), critical: true,
    };
  } catch (e) {
    return {
      id: 'baseline', name: '基础互联网连接', category: ProbeCategory.BASELINE,
      status: ProbeStatus.FAIL, rttMs: -1,
      detail: '无法访问公网（' + summarizeErr(e) + '）', critical: true,
    };
  } finally {
    try { req.destroy(); } catch (e) { /* ignore */ }
  }
}

// ============================================================
//  下载源探测（复用真实下载引擎 fetchTextEx）
// ============================================================

async function probeSource(
  id: string, name: string, url: string, critical: boolean, headers?: Record<string, string>,
): Promise<NetworkProbe> {
  let start = Date.now();
  try {
    await DownloadManager.instance().fetchTextEx(url, [], PROBE_TIMEOUT_S, headers);
    let rtt = Date.now() - start;
    return {
      id, name, category: ProbeCategory.SOURCE, status: ProbeStatus.OK,
      rttMs: rtt, detail: '可达 · ' + rtt + 'ms', critical,
    };
  } catch (e) {
    return {
      id, name, category: ProbeCategory.SOURCE, status: ProbeStatus.FAIL,
      rttMs: -1, detail: summarizeErr(e), critical,
    };
  }
}

function summarizeErr(e: Object): string {
  let msg = (e as Error).message !== undefined ? (e as Error).message : String(e);
  if (msg.length > 80) msg = msg.substring(0, 80) + '…';
  return msg;
}

// ============================================================
//  对外：完整诊断
// ============================================================

/**
 * 跑一次完整网络诊断。约 1~8 秒（并行探测，取决于最慢的超时）。
 */
export async function runNetworkDiagnostics(): Promise<NetworkReport> {
  let probes: NetworkProbe[] = [];

  // ① 系统网络层
  let sys = checkSystemNet();
  probes.push({
    id: 'system', name: '设备网络连接', category: ProbeCategory.SYSTEM,
    status: sys.online ? ProbeStatus.OK : ProbeStatus.FAIL, rttMs: -1,
    detail: sys.typeText, critical: true,
  });

  // ③ CA bundle（下载引擎前置）
  let caReady = DownloadManager.instance().isCaBundleInitialized();
  probes.push({
    id: 'ca', name: '应用安全证书 (CA)', category: ProbeCategory.SECURITY,
    status: caReady ? ProbeStatus.OK : ProbeStatus.FAIL, rttMs: -1,
    detail: caReady ? '已就绪' : '未就绪（请重启应用）', critical: true,
  });

  // ② 基础连通性 + ④ 各下载源（并行）
  let rangeHeader: Record<string, string> = { 'Range': 'bytes=0-1023' };
  let tasks: Promise<NetworkProbe>[] = [];
  tasks.push(probeBaseline());
  if (caReady) {
    tasks.push(probeSource('amcl', 'AMCL 服务器', URL_AMCL, false));
    tasks.push(probeSource('mojang', 'Minecraft 版本源 (Mojang)', URL_MOJANG, true, rangeHeader));
    tasks.push(probeSource('jdk', 'JDK 镜像 (国内加速)', URL_JDK_MIRROR, true));
    tasks.push(probeSource('github', 'GitHub 直连', URL_GITHUB, false));
    tasks.push(probeSource('mcim', '模组源 (MCIM)', URL_MCIM, true));
  } else {
    // CA 没就绪，引擎探测必失败，全部标记跳过
    probes.push(skipped('amcl', 'AMCL 服务器'));
    probes.push(skipped('mojang', 'Minecraft 版本源 (Mojang)'));
    probes.push(skipped('jdk', 'JDK 镜像 (国内加速)'));
    probes.push(skipped('github', 'GitHub 直连'));
    probes.push(skipped('mcim', '模组源 (MCIM)'));
  }

  let results = await Promise.all(tasks);
  for (let r of results) probes.push(r);

  let report = buildReport(sys.online, caReady, probes);
  AppLogger.info(TAG, 'diagnostics done: verdict=' + report.verdict, LOG_DOMAIN_DOWNLOAD);
  return report;
}

function skipped(id: string, name: string): NetworkProbe {
  return {
    id, name, category: ProbeCategory.SOURCE, status: ProbeStatus.SKIP,
    rttMs: -1, detail: '证书未就绪，已跳过', critical: false,
  };
}

function buildReport(systemOnline: boolean, caReady: boolean, probes: NetworkProbe[]): NetworkReport {
  let baseline = probes.find((p) => p.id === 'baseline');
  let baselineOk = baseline !== undefined && baseline.status === ProbeStatus.OK;
  let sources = probes.filter((p) => p.category === ProbeCategory.SOURCE);
  let sourceOk = sources.filter((p) => p.status === ProbeStatus.OK).length;
  let sourceTotal = sources.length;

  let verdict: NetworkVerdict;
  let title = '';
  let summary = '';
  let suggestions: string[] = [];

  if (!systemOnline) {
    verdict = NetworkVerdict.NO_SYSTEM_NET;
    title = '设备未连接网络';
    summary = '检测到设备当前没有可用的网络连接。请连接 WiFi 或开启移动数据后重试。';
    suggestions = ['打开系统「设置 → WLAN / 移动网络」连接网络', '连接后回到本页点「重新检测」'];
  } else if (!caReady) {
    verdict = NetworkVerdict.CA_NOT_READY;
    title = '安全证书未就绪';
    summary = '应用的 HTTPS 安全证书（CA）尚未初始化，所有联网下载都会失败。这通常是启动异常导致，重启应用即可恢复。';
    suggestions = ['完全关闭 AMCL 后台后重新打开', '若仍不行，请通过「设置 → 关于」反馈日志'];
  } else if (!baselineOk && sourceOk === 0) {
    verdict = NetworkVerdict.NO_INTERNET;
    title = '无法访问互联网';
    summary = '设备虽连接了网络，但无法访问任何公网站点。可能是网络需要登录认证、路由异常或被拦截。';
    suggestions = ['确认当前 WiFi 无需网页登录认证（如公共/酒店 WiFi）', '尝试切换到其它 WiFi 或移动数据', '关闭可能拦截流量的 VPN / 代理 / 防火墙后重试'];
  } else if (sourceOk === 0) {
    verdict = NetworkVerdict.DOWNLOAD_BLOCKED;
    title = '能上网，但连不上下载服务器';
    summary = '设备可以访问公网，但 AMCL 需要的下载服务器（Minecraft 版本源 / JDK 镜像 / 模组源）全部无法连接。常见于公司网、校园网、审核测试网等只放行白名单域名的受限网络。';
    suggestions = ['切换到无限制的家用 WiFi 或个人热点后重试', '关闭 VPN / 代理 / 网络防火墙', '若在受管控网络（公司/学校/机房），请联系网络管理员放行相关域名'];
  } else if (sourceOk < sourceTotal) {
    verdict = NetworkVerdict.PARTIAL;
    title = '部分下载源不可用';
    summary = '大部分功能可用，但有 ' + (sourceTotal - sourceOk) + ' 个下载源当前连接不上，相关下载可能变慢或失败，可稍后重试。';
    suggestions = ['稍后重试通常可恢复', '可在「设置 → 数据源」切换镜像偏好'];
  } else {
    verdict = NetworkVerdict.OK;
    title = '网络环境正常';
    summary = '设备网络、公网连通性与全部下载源均正常。若仍遇到下载失败，请重试或反馈日志。';
    suggestions = [];
  }

  return { verdict, title, summary, suggestions, probes, finishedAt: Date.now() };
}

// ============================================================
//  对外：轻量快速检测（供横幅触发，不跑全套）
// ============================================================

/**
 * 轻量连通性检测：用于决定是否显示顶部横幅。
 *
 * 语义 = 「AMCL 需要的下载基础设施是否可达」，而非「能否上网」——因为审核/受限网络的
 * 典型症状正是「浏览器能开网页，但连不上下载服务器」。故这里**只探测下载相关端点**
 * （走真实下载引擎），而不是打百度：
 *   - 无系统网络 / CA 未就绪 → 判异常（false）
 *   - 并行探测 AMCL 服务器 + Mojang 版本源，任一可达即视为正常（true）
 *   - 两者都不可达 → 判异常（false），点亮横幅引导用户做完整检测
 *
 * 用「任一可达」而非「全部可达」，避免单个服务器偶发抖动造成误报。
 */
export async function quickConnectivityCheck(): Promise<boolean> {
  let sys = checkSystemNet();
  if (!sys.online) return false;
  if (!DownloadManager.instance().isCaBundleInitialized()) return false;

  let dm = DownloadManager.instance();
  let rangeHeader: Record<string, string> = { 'Range': 'bytes=0-1023' };
  let probeAmcl: Promise<boolean> = dm.fetchTextEx(URL_AMCL, [], 6)
    .then(() => true).catch(() => false);
  let probeMojang: Promise<boolean> = dm.fetchTextEx(URL_MOJANG, [], 6, rangeHeader)
    .then(() => true).catch(() => false);
  let results = await Promise.all([probeAmcl, probeMojang]);
  for (let r of results) {
    if (r) return true;
  }
  return false;
}
