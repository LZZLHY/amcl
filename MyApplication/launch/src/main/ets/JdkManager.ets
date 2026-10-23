import { validateRuntimeTree } from './JdkTreeValidation';
import { JdkDirectoryLease } from './JdkDirectoryLease';
import { DiagnosticPolicy } from 'commons';
import { RuntimeCatalogRepository } from './RuntimeCatalogRepository';
import { RuntimeBuild, RuntimeDefinition, RuntimeDownload, RuntimeInstallReceipt } from './RuntimeCatalogTypes';
import { runtimeReceiptStamp, runtimeRecommendationApplies } from './RuntimeUpdatePolicy';
/**
 * JDK 只读管理与安装工厂。版本和包身份来自 RuntimeCatalogRepository 的可信 JSON，
 * 旧 release-tag、用户导入和新的受管 receipt 分开识别；已安装不等于有新版。
 * 数字槽位映射与布局/架构检查固定在客户端，远程目录不能提供本地路径或脚本。
 * 游戏清单/加载器要求决定选择区间，新增最高主版本不改变未知游戏的保守兜底。
 * 每个任务从工厂取得独立且冻结的 installer，目录刷新不改动正在进行的下载。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { removeDirRecursive } from 'commons';
import { AppLogger } from 'commons';
import { LogTags } from 'commons';
import { LOG_DOMAIN_LAUNCH } from 'commons';
import {
  SUPPORTED_JDK_VERSION, SUPPORTED_JDK_VERSIONS, JDK_AUTO,
  JDK21_MIN_MC_VERSION, isJdkSlotVersion,
} from 'commons';
import { isMcVersionAtLeast, detectMcEra, McEra } from 'commons';
import { requiredJdkMajorForMc } from 'commons';
import { extractGameVersionFromId } from 'mods';
import { JdkInstaller } from './JdkInstaller';
import { VersionParser } from 'feature_core';
// JDK 选择策略（纯函数）。**路由与 Phase 0 自检共用它** —— 它自己只消费契约表，
// 世代判定仍然唯一在 LoaderGenerationResolver（规范 §1.1 纪律 1）。
import {
  resolveJdkPolicy, resolveJdkRange, JdkPolicyDecision, JdkRange,
} from './LaunchJdkPolicy';
import {
  JdkTagState, JdkTagInput, classifyJdkTag, isUsableState, shouldOfferUpdate, describeJdkTagState,
} from './JdkUpdatePolicy';

const TAG = LogTags.SVC_JDK

export interface JdkStatus {
  ready: boolean;
  progress: string;
}

export interface JdkVersionInfo {
  rollback?: boolean;
  version: string;        // 可信目录或本地安装中的规范数字主版本
  installed: boolean;
  available: boolean;     // 是否已发布可下载
  sizeMB: number;         // 当前推荐的下载包体积（MB），不冒充解压后的磁盘占用
  path: string;           // filesDir/jdk/<version>/
  // ---- 2026-08-29 新增：把「已装」与「是否最新」分开表达（旧实现压成一个 installed
  //      布尔值，导致"过期"在 UI 上只能显示成"未安装"）----
  /** `<jdkDir>/.amcl_release_tag` 的内容；无戳为 `''`。 */
  installedTag: string;
  /** 当前目录推荐的构建身份或旧发行 tag。 */
  expectedTag: string;
  /** 要不要显示「更新」按钮。 */
  updateAvailable: boolean;
  /** 是否用户自己导入的包（永不参与更新检查）。 */
  userImported: boolean;
  /** 给用户看的一行状态说明；无内容时为 `''`（此时 UI 不渲染该行）。 */
  stateText: string;
}

/** `JdkManager.inspect()` 的返回：一个版本的完整状态。 */
export interface JdkInspection {
  rollback?: boolean;
  version: string;
  /** 能不能拿它启动游戏（= `isInstalled()`）。 */
  installed: boolean;
  available: boolean;
  dir: string;
  installedTag: string;
  expectedTag: string;
  state: JdkTagState;
  usable: boolean;
  offerUpdate: boolean;
  stateText: string;
}

export interface JdkDownloadProgress {
  version: string;
  phase: string;          // "downloading" | "extracting" | "verifying"
  percent: number;        // 0-100
  speedKBs: number;       // 下载速度 KB/s
  message: string;
}

export type JdkStatusCallback = (status: JdkStatus) => void;
export type JdkDownloadCallback = (progress: JdkDownloadProgress) => void;

// GitHub Releases 下载地址配置
export const RELEASE_BASE_URL = 'https://github.com/LZZLHY/mc-ohos-resources/releases/download'

// Gitee 国内镜像（v7.10）：Gitee 国内直连、单连接就快，但**单文件≤100MB 且不支持 Range**。
// 为叠加单连接带宽并避免不等分长尾，JDK 8 使用 2 个等大小分卷，JDK 17/21/25 使用 3 个
// 等大小分卷；新附件名与旧单卷/.001/.002 共存，避免破坏已发布客户端。
// 下载走「优先 Gitee 单连接（分卷则各卷单连接下完拼接）→ 失败回退 GitHub 代理多段」。
// 直链格式：<base>/<tag>/<attachName>
//
// ⚠️ 2026-08-29：镜像库从 `mc-ohos-resources` 换成 **`mc-ohos-resources-2`**。
// 起因不是重命名，而是 **Gitee 每个仓库的 Release 附件配额只有 1 GB**，旧库已用到
// 1006 MB，第四个新分卷集（JDK 25，113 MB）直接被 `HTTP 400 已超出仓库附件配额` 拒了。
// 为什么不删旧库里的东西腾地方：用真产物核对过（下 v1.0.0/v1.0.1/v1.0.2 三个已发布 HAP
// grep `modules.abc`），旧库里那 375 MB 的 `.001`/`.002`/单卷附件**仍被 v1.0.0 引用**，
// 而三个旧 tag 上的 `.partNNof03` **被 v1.0.1 与 v1.0.2（当前正式版）引用** ——
// 删任何一组都会让那些已发布客户端丢掉 Gitee 快路径（会回退 GitHub，不坏但慢）。
// ⇒ 换库是唯一「谁都不受影响」的做法：旧 HAP 各自硬编码着旧库地址，继续照旧工作。
// 📌 代价与后续：本常量是**全局单值**，所以换库之后本 HAP 的四个版本都必须在新库里齐备
// （已齐备）。新库同样是 1 GB 配额、当前占约 369 MB ⇒ 大约还能放一轮半 JDK 升级，
// 再满时要么再开一库，要么届时清掉那时已无受支持客户端引用的分卷。
export const GITEE_RELEASE_BASE = 'https://gitee.com/dhao12345/mc-ohos-resources-2/releases/download'

// JDK 版本信息接口
// ELF loader 绕过签名验证后，完整 JDK（含 .so）可以从网上下载
export interface JdkVersionConfig {
  /** 保留可展示槽位时说明下载暂停原因；不能把目录未就绪误写成“即将支持”。 */
  unavailableReason?: string;
  /** 受信目录描述；每个 installer 使用深拷贝，刷新不会中途替换包。 */
  runtime?: RuntimeDefinition;
  build?: RuntimeBuild;
  downloads?: RuntimeDownload[];
  webEnabled?: boolean;
  downloadSource?: string;
  tag: string;
  dataFile: string;
  dataSizeMB: number;
  markerFile: string;
  minMcVersion: string;
  maxMcVersion: string;
  available: boolean;    // 是否已在 GitHub Releases 上发布
  // 可下载项必须有完整 ZIP SHA-256；可用但已下架的本地保留项可省略。
  // 安装器在联网前拒绝缺失/非法值，校验失败不发布、不触碰旧安装。
  // 获取方式：sha256sum <file>  或 Get-FileHash -Algorithm SHA256 <file>
  // 建议在 GitHub Release 说明中发布官方校验和。
  sha256?: string;
  // 可选：下载 zip 的准确字节数。填了后 DownloadManager 会在引擎层校验。
  // 可下载项必须提供正整数；与 sha256 互补，size mismatch 在下载期间失败，
  // 避免“全量下载完才发现 SHA-256 不对”的浪费。
  sizeBytes?: number;

  // Gitee 国内镜像的发行版附件名列表（按拼接顺序）。单文件 = [dataFile]；大包切分卷 =
  // ['xxx.zip.001','xxx.zip.002',...]。为空/未配置 = 该版本无 Gitee 镜像，直接走 GitHub 代理。
  giteeParts?: string[];
  // 与 giteeParts 一一对应的各卷精确字节数（供 Gitee 单连接下载时算进度——引擎对无 Range 的
  // 全量 GET 报 bytesTotal=-1，故用已知大小算百分比 + 跨卷平滑累计）。未配置则退化为不精确进度。
  giteePartSizes?: number[];

  /**
   * 已知**有害**、必须强制换掉的旧 release tag。
   *
   * ⚠️ 这是唯一会让「已装但 tag 不匹配」重新变成"判定未安装 + 拒绝启动 + 强制整包重下"的开关。
   * 判据是「装着这个 tag 的用户会遇到实际故障」，例如 `v8u452-ohos-1`（clang 把 JDK8 的 UB
   * 利用坏，C2 会崩）。
   *
   * ⛔ **不要**为了"让大家都升到最新"往里加 tag。往里加一个 = 对所有装着它的用户强制收一次
   * 整包流量（17/21/25 约 110 MB），并在升级完成前禁止开游戏。默认留空，让用户自己点「更新」。
   */
  harmfulTags?: string[];
}

// 运行时配置是已验证目录的内存投影。包摘要、分卷和版本列表的事实源在发布仓 JSON；
// HAP 中只保留生成的可信快照。禁止在此重新追加版本/hash 条目。
let JDK_VERSIONS: Record<string, JdkVersionConfig> = {};

// ============================================================
//  镜像源配置
// ============================================================

// GitHub Release URL 镜像列表（按初始优先级排序；运行时 SourceProber 会按 RTT/吞吐重排）。
// v7.5（hdc 日志实测）：删掉已死的 mirror.ghproxy.com；新增实测存活且支持 Range(206) 的
// ghproxy.net / gh.ddlc.top；保留 ghfast.top / gh-proxy.com；再备 github.moeyy.xyz 作候补。
// 公共代理可用性随地域/时间波动，故多备源 + 交给引擎运行时探测选最快。
// ⚠️ v7.6（2026-07-29）：GitHub 代理镜像已被 net_file.cpp 的 isMultiThreadUnfriendlyHost
//   判为「多线程不友好」→ 全部候选源都是代理时强制**单段全量 GET**（借鉴 PCL2 ModNet.vb
//   对 github.com/bmclapi/optifine 直接 Return Nothing 不开多线程）。因此这里的**顺序变得
//   关键**：单段模式下首选源就是全程唯一下载源（首次选源无样本 → computeScore 同分 → 取
//   最小 id）。下面顺序按真机实测单流吞吐重排（各源实测下载 3MB）：
//     gh.ddlc.top 2903 KB/s > ghfast.top 1099 > gh-proxy.com 563 > ghproxy.net 489
//     > github.moeyy.xyz（SSL handshake 失败，已死，压最后）
//   最后一条 '{url}' 为 GitHub 直连兜底，仅 auto 模式会用（mirror 模式显式跳过）。
export const MIRROR_TEMPLATES: string[] = [
  'https://gh.ddlc.top/{url}',           // 实测最快（~2.9MB/s，支持 Range）
  'https://ghfast.top/{url}',            // ghfast（cf 加速，~1.1MB/s，支持 Range）
  'https://gh-proxy.com/{url}',          // gh-proxy（~560KB/s）
  'https://ghproxy.net/{url}',           // ghproxy.net（~490KB/s）
  'https://github.moeyy.xyz/{url}',      // moeyy（实测 SSL 失败，仅作候补）
  '{url}',                               // GitHub 直连（最后兜底）
]

// ============================================================
//  JDK 下载源偏好（模块级，避免 launch HAR 反向依赖 feature_system）
// ============================================================
//
// 由 entry 层（Index.loadPreferences / SettingsTab 回调）在启动时 & 用户切换时注入。
// JdkInstaller.downloadJdkArchive 读取此值决定源排序：
//   'auto'   Gitee 优先 → 失败回退 GitHub 镜像/直连（默认，国内最稳）
//   'github' GitHub 源站直连优先（开代理/VPN 用户满速，比镜像快），镜像作回退
//   'gitee'  强制 Gitee（失败仍回退 GitHub 保证可用）
//   'mirror' 只走 GitHub 代理镜像（跳过 Gitee），交给引擎按 RTT 选最快
let g_jdkDownloadSource: string = 'auto'
// 自有 JDK 来源独立 opt-in；关闭时目录和安装器都在创建网络任务前排除该来源。
let g_jdkWebEnabled: boolean = false;
export function setJdkWebEnabled(enabled: boolean): void { g_jdkWebEnabled = enabled; }
export function isJdkWebEnabled(): boolean { return g_jdkWebEnabled; }

/**
 * 加速下载是否生效（由 entry 层在握手成功/失败时注入）。
 *
 * 为什么用注入而不是直接调 feature_core：launch 这个 HAR 不能反向依赖 feature_core，
 * 否则会形成循环依赖（feature_core 里的 JdkInstallTask 已经依赖 launch）。
 * 所以沿用本文件既有的"模块级全局 + entry 注入"模式。
 */
let g_accelActive: boolean = false

/** 设置全局 JDK 下载源偏好（entry 层注入）。非法值归一到 'auto'。 */
export function setJdkDownloadSource(src: string): void {
  g_jdkDownloadSource = (src === 'github' || src === 'gitee' || src === 'mirror' || src === 'web') ? src : 'auto'
}

/** 注入「加速下载是否真的可用」（握手成功且票据有效才为 true）。 */
export function setAccelActive(active: boolean): void {
  g_accelActive = active
}

/** 加速是否生效。 */
export function isAccelActive(): boolean {
  return g_accelActive
}

/**
 * 读取当前 JDK 下载源偏好。JdkInstaller 内部使用。
 *
 * 加速生效时把 **'auto'** 提升为 'github'（官方源直连）：官方 URL 会被 native 改写成
 * 经加速网关，而 Gitee / GitHub 代理镜像不在网关白名单里（也没必要——网关到 GitHub
 * 本身就快），走镜像等于放弃加速。握手失败时 g_accelActive 为 false，行为不变。
 *
 * ⚠️ 2026-08-04 修正：原实现在加速生效时**无条件**返回 'github'，把用户显式选的
 * gitee / mirror / github 一起吞掉了。用户明确选了源却不生效，是"换源没用"这类
 * 反馈的一个来源。现在只覆盖 'auto'（"你来决定"），显式选择一律照办 ——
 * 与版本下载源（SourceProber.shouldUseBmclapiFirst）保持同一条原则：
 * **用户选了就用用户的**。
 */
export function getJdkDownloadSource(): string {
  if (g_accelActive && g_jdkDownloadSource === 'auto') return 'github'
  return g_jdkDownloadSource
}

// 下载超时 / 线程调度由 DownloadManager / libcurl 引擎接管，不再需要 ArkTS 层超时常量。

// 2026-05-26 重构（B-1 修复，详见 docs/self-inspection/2026-05-26_AMCL_多任务下载并发缺陷诊断.md §B-1）：
// JdkManager 退化为 **只读 facade**：只负责安装状态探测、磁盘清理、版本元数据查询。
// 任务状态（downloading / cancel token / DM taskId / 进度回调）全部下放到 JdkInstaller。
// 通过 createInstaller(version) 工厂为每个 JdkInstallTask 发一个独立 installer，
// 多 JDK 真正并发互不影响。
export class JdkManager {
  private context: Context;
  private catalog: RuntimeCatalogRepository;
  private onStatus: JdkStatusCallback | null = null;

  constructor(context: Context) {
    this.context = context;
    this.catalog = RuntimeCatalogRepository.instance(context);
    this.synchronizeCatalog();
  }

  /** 将当前已验签推荐与磁盘已装槽位合并；目录下架不会删除用户可用安装。 */
  synchronizeCatalog(): void {
    const next: Record<string, JdkVersionConfig> = {};
    for (const runtime of this.catalog.definitions()) {
      const major = runtime.javaMajor.toString();
      const build = this.catalog.buildFor(major);
      if (build === undefined) {
        // 目录暂不可用于下载时仍生成槽位。期望戳留空，避免展示旧稳定推荐或伪造更新结论；
        // inspect 仍核对已有安装，用户导入和合法已装包不会因网络/缓存状态消失。
        next[major] = { tag:'',dataFile:'',dataSizeMB:0,
          markerFile:runtime.javaMajor === 8 ? 'jre/lib/rt.jar' : 'release',
          minMcVersion:'',maxMcVersion:'',available:false,
          unavailableReason:this.catalog.recommendationUnavailableReason() || '当前通道暂无可下载构建' };
        continue;
      }
      const config: JdkVersionConfig = {
        runtime:runtime, build:build, downloads:build.downloads, webEnabled:g_jdkWebEnabled,
        downloadSource:getJdkDownloadSource(),
        tag:build.legacyTags.length > 0 ? build.legacyTags[0] : build.id,
        dataFile:build.archive.fileName, dataSizeMB:Math.ceil(build.archive.sizeBytes / 1048576),
        markerFile:runtime.javaMajor === 8 ? 'jre/lib/rt.jar' : 'release',
        minMcVersion:'', maxMcVersion:'', available:true,
        sha256:build.archive.sha256, sizeBytes:build.archive.sizeBytes
      };
      next[major] = config;
    }
    try {
      for (const major of fs.listFileSync(this.context.filesDir + '/jdk')) {
        if (!isJdkSlotVersion(major) || next[major] !== undefined) continue;
        const dir = this.context.filesDir + '/jdk/' + major;
        if (validateRuntimeTree(dir,major) !== '') continue;
        // 本地保留项没有下载描述，不能自动认领用户导入或恢复已经下架的远程包。
        const local: JdkVersionConfig = { tag:this.readStamp_(dir),dataFile:'',dataSizeMB:0,
          markerFile:major === '8' ? 'jre/lib/rt.jar' : 'release',minMcVersion:'',maxMcVersion:'',available:false,
          unavailableReason:'当前通道未提供此槽位的下载；保留本地安装' };
        next[major] = local;
      }
    } catch (e) { /* 首次启动尚无 jdk 目录。 */ }
    JDK_VERSIONS = next;
    const versions = Object.keys(next).sort((a: string,b: string): number => Number(a) - Number(b));
    SUPPORTED_JDK_VERSIONS.length = 0;
    for (const version of versions) SUPPORTED_JDK_VERSIONS.push(version);
  }

  setStatusCallback(cb: JdkStatusCallback) {
    this.onStatus = cb;
  }

  private report(ready: boolean, progress: string) {
    if (this.onStatus) {
      this.onStatus({ ready, progress });
    }
  }

  // ============================================================
  //  路径工具
  // ============================================================

  getJdkDir(version: string): string {
    if (!isJdkSlotVersion(version)) throw new Error('无效 JDK 槽位');
    return this.context.filesDir + '/jdk/' + version
  }

  // ============================================================
  //  状态检测
  // ============================================================

  /**
   * 已安装判定读取共同文件/架构/主版本契约，再独立判断发行戳。
   * 不执行候选代码，不把已有用户导入包误判为官方最新能力。
   */
  isInstalled(version: string): boolean {
    const info = JDK_VERSIONS[version]
    if (!isJdkSlotVersion(version)) return false
    let dir = this.getJdkDir(version)
    // 短头部校验与 staging 一致：文件存在不代表 native/boot 内容可用。
    const contentError = validateRuntimeTree(dir, version)
    if (contentError.length > 0) {
      AppLogger.warn(TAG, `JDK ${version} content invalid: ${contentError}`, null, LOG_DOMAIN_LAUNCH)
      return false
    }
    // release-tag 戳：**只有已知有害的旧包才判不可用**，其余一律容忍为可用。
    //
    // ⚠️ 2026-08-29 语义变更（判定抽到 JdkUpdatePolicy.ets，理由写在那个文件开头）：
    // 旧实现把**任何** tag 不一致都 return false ⇒ 启动前自检 fail ⇒ 拒绝开游戏。
    // 后果是「新 HAP 先于 JDK Release 发布」会让所有已装用户瞬间变成「JDK 未安装」+
    // 下载 404 —— 磁盘上那份能用的 JDK 还在，却玩不了。
    // 现在：`stale-advisory` 仍返回 true（可用），由 JDK 管理页显示「更新」让用户自己决定；
    // 只有 `JdkVersionConfig.harmfulTags` 里显式列出的旧 tag 才 `stale-blocking`。
    if (!info) return true; // 下架/离线时已安装的合法数字槽位仍能使用。
    const state = classifyJdkTag(this.tagInputFor_(version, dir, info))
    if (!isUsableState(state)) {
      AppLogger.warn(TAG,
        `JDK ${version} blocked: installed tag=${this.readStamp_(dir)} expected=${info.tag} `
        + `is listed as harmful — will re-download`, null, LOG_DOMAIN_LAUNCH)
      return false
    }
    return true
  }

  /** 读 release-tag 戳；读不到/异常一律返回空串（"无戳"），绝不让一次读失败弄坏可用的安装。 */
  private readStamp_(dir: string): string {
    try {
      return fs.readTextSync(dir + '/.amcl_release_tag').trim()
    } catch (e) {
      return ''
    }
  }

  private tagInputFor_(version: string, dir: string, info: JdkVersionConfig): JdkTagInput {
    let stamp = this.readStamp_(dir);
    // 新 receipt 绑定 build/hash/推荐代次。用户导入优先，决不因为包恰好相同就自动托管。
    if (!stamp.startsWith('imported:') && info.build !== undefined && info.runtime !== undefined) {
      let receiptFound = false;
      try {
        const path = dir + '/.amcl-runtime-receipt.json';
        const stat = fs.statSync(path); receiptFound = true;
        if (!stat.isFile() || stat.size > 65536 || stat.size === 0) throw new Error('receipt 内容无效');
        const receipt = JSON.parse(fs.readTextSync(path)) as RuntimeInstallReceipt;
        if (receipt.schemaVersion === 1 && receipt.origin === 'catalog' && receipt.javaMajor.toString() === version &&
          receipt.runtimeId === info.runtime.id) {
          stamp = runtimeReceiptStamp(receipt, info.build, info.tag);
        } else stamp = 'identity-mismatch:invalid-receipt';
      } catch (e) {
        // 不存在是旧安装的正常情况；存在但损坏不能退回同名戳冒充“当前已校验”。
        if (receiptFound) stamp = 'identity-mismatch:invalid-receipt';
      }
    }
    return {
      installedTag: stamp,
      expectedTag: info.tag,
      harmfulTags: info.harmfulTags !== undefined ? info.harmfulTags : [],
    }
  }

  /**
   * 查一个版本的完整状态（供 UI 用）。
   *
   * 与 `isInstalled()` 的分工：`isInstalled()` 回答"能不能拿它启动游戏"（一个布尔值，
   * 启动链路只需要这个）；本方法回答"它是什么情况"（结构是否完整、戳是什么、要不要提示更新）。
   * 把两件事分开，是因为旧实现把它们压成一个布尔值之后，"过期"在 UI 上只能显示成"未安装"（J-b）。
   */
  inspect(version: string): JdkInspection {
    const info = JDK_VERSIONS[version]
    const dirPath = this.getJdkDir(version)
    if (!info) {
      return {
        version, installed: false, available: false, dir: dirPath,
        installedTag: '', expectedTag: '', state: 'current', usable: false, offerUpdate: false,
        stateText: '未知版本',
      }
    }
    const installed = this.isInstalled(version)
    const input = this.tagInputFor_(version, dirPath, info)
    const state = classifyJdkTag(input)
    // ⚠️ 目录不存在时不要报「有新版本」：那会让一个**没装**的版本显示成"待更新"。
    const structurallyPresent = installed || state === 'stale-blocking'
    const rollback = info.runtime !== undefined && info.runtime.rollback !== undefined;
    const applies = runtimeRecommendationApplies(info.runtime,input.installedTag,rollback ? this.catalog.snapshot().builds : []);
    const stateText = info.unavailableReason !== undefined
      ? (state === 'user-import' ? '本地导入（不参与更新检查）；' : '') + info.unavailableReason
      : rollback && structurallyPresent && state !== 'user-import'
      ? (applies ? '回退修复：' + info.runtime!.rollback!.reason : '当前安装不在此次回退范围内')
      : (structurallyPresent ? describeJdkTagState(state,input) : '推荐构建：' + info.tag);
    return {
      version,
      installed,
      available: info.available,
      dir: dirPath,
      installedTag: input.installedTag,
      expectedTag: input.expectedTag,
      state,
      usable: installed,
      offerUpdate: info.available && structurallyPresent && shouldOfferUpdate(state) && applies,
      stateText: stateText,
      rollback: rollback && applies,
    }
  }

  listVersions(): JdkVersionInfo[] {
    this.synchronizeCatalog();
    let result: JdkVersionInfo[] = []
    // 暴露所有上线版本；available=true 由 JDK_VERSIONS map 控制
    for (let ver of SUPPORTED_JDK_VERSIONS) {
      let info = JDK_VERSIONS[ver]
      if (!info) continue
      let ins = this.inspect(ver)
      let sizeMB = info.dataSizeMB
      result.push({
        version: ver,
        installed: ins.installed,
        available: info.available,
        sizeMB,
        path: ins.dir,
        installedTag: ins.installedTag,
        expectedTag: ins.expectedTag,
        updateAvailable: ins.offerUpdate,
        rollback: ins.rollback,
        userImported: ins.state === 'user-import',
        stateText: ins.stateText,
      })
    }
    return result
  }

  /** 无法识别游戏版本时保留已有 25/21/17 路由，不让目录新增的最高主版本接管。 */
  private fallbackJdkVersion(): string {
    for (const version of ['25','21','17']) {
      const info = JDK_VERSIONS[version];
      if (info !== undefined && info.available) return version;
    }
    return SUPPORTED_JDK_VERSION;
  }

  /**
   * 根据 MC 版本自动选 JDK（三段式纪元路由）：
   *   - 新纪元 YEARLY（26.1+，YY.D.H）        → 25
   *   - 旧纪元 CLASSIC 且 ≥ 1.20.5            → 21
   *   - 旧纪元 CLASSIC 且 ≤ 1.20.4            → 17
   *   - UNKNOWN（周快照 23w14a/26w14a 等）    → 兜底 fallbackJdkVersion()（最新可用，当前 25）
   *
   * 纪元判定见 McVersionUtils.detectMcEra；阈值在 Constants.JDK21_MIN_MC_VERSION。
   *
   * ⚠️ 历史陷阱（2026-05-30 修复）：旧实现只用 isMcVersionAtLeast(mc, '1.20.5')，
   * 会把 26.1 按 26 > 1 误判为 ≥ 1.20.5 → 路由 JDK 21（实际需要 25）。
   * 现在先判纪元，YEARLY 直接走 25，跨纪元不进数字比较。
   *
   * 安全网：若选中的版本在 JDK_VERSIONS 里未 available，降级到 fallbackJdkVersion()
   * （最新可用），避免下载/启动链路命中空版本。
   *
   * 调用方（Index.launchMC / GameAbility / ForgeService）应把这个返回值作为
   * 默认值，但允许用户在 SettingsTab 手动覆盖。
   *
   * 注意：传入的应当是【真实 MC 版本】。resolveLaunchJdk 会先用
   * VersionParser.detectVanillaVersion 从 version.json 内容解析真实版本再调本方法，
   * 因此目录名被改/含中文时仍能正确路由（对齐 PCL McVersion.Version）。
   */
  autoSelectVersion(mcVersion: string): string {
    let chosen: string
    // ⚠️ 2026-06-06 修复：version-id 可能是 "fabric-loader-0.19.3-1.21.8"（MC 版本在末尾），
    //   直接 detectMcEra 会判 UNKNOWN → 回退 JDK → Fabric API（1.21.x 要求 Java≥21）
    //   拒绝启动闪退。先用 extractGameVersionFromId 归一化成真实 MC 版本（"1.21.8"）。
    //   对 "1.21.8-forge-..." / 纯 "1.21.8" / "26.1" 幂等。
    let mc = extractGameVersionFromId(mcVersion)
    let era = detectMcEra(mc)
    if (era === McEra.YEARLY) {
      // MC 26.1+（YY.D.H 新纪元）→ JDK 25
      chosen = '25'
    } else if (era === McEra.CLASSIC) {
      // 旧纪元：1.20.5+ → 21，否则 17
      chosen = isMcVersionAtLeast(mc, JDK21_MIN_MC_VERSION) ? '21' : SUPPORTED_JDK_VERSION
    } else {
      // UNKNOWN（周快照 / 空 / 非法 / 纯中文目录名）→ 兜底最新可用 JDK（向后兼容最稳）
      chosen = this.fallbackJdkVersion()
    }
    // 安全网：如果选中的版本在 JDK_VERSIONS 里未 available（比如某版本未发布），
    // 降级到最新可用 JDK 兜底，避免下载/启动链路命中空版本。
    let info = JDK_VERSIONS[chosen]
    if (!info || !info.available) {
      let fb = this.fallbackJdkVersion()
      AppLogger.warn(TAG, `autoSelectVersion: ${chosen} not available, falling back to ${fb}`, null, LOG_DOMAIN_LAUNCH)
      chosen = fb
    }
    if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'autoSelectVersion(%{public}s) [era=%{public}s] -> %{public}s',
      mcVersion, era, chosen)
    return chosen
  }

  /**
   * 解析【真实 MC 版本号】用于 JDK 路由，对齐 PCL：优先读 version.json 内容
   * （clientVersion / patches / --fml.mcVersion / inheritsFrom / id），而非文件夹名。
   * 这样用户把版本目录改名（含中文）也能正确路由。
   *
   * @param versionId 版本目录名（同时也是 <id>.json 的文件名）
   * @param mcDir     .minecraft 根目录；为空时跳过 json 读取，退化为按目录名解析
   * @returns         真实 MC 版本号（json 解析成功）或原 versionId（兜底）
   */
  private resolveRealMcVersion(versionId: string, mcDir: string): string {
    if (mcDir && mcDir.length > 0) {
      let jsonPath = mcDir + '/versions/' + versionId + '/' + versionId + '.json'
      let detected = VersionParser.detectVanillaVersion(jsonPath)
      if (detected && detected.length > 0) {
        if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG,
          'resolveRealMcVersion: dir="%{public}s" -> json vanilla="%{public}s"',
          versionId, detected)
        return detected
      }
      AppLogger.warn(TAG, `resolveRealMcVersion: json detect failed for "${versionId}", fallback to dir name`, null, LOG_DOMAIN_LAUNCH)    }
    return versionId
  }

  /**
   * 计算运行某 MC 版本所需的【最低 JDK 主版本号】（纪元硬约束）。
   *   - YEARLY（26.1+，YY.D.H）          → 25
   *   - CLASSIC 且 ≥ 1.20.5              → 21
   *   - 其余（≤1.20.4 / UNKNOWN 快照等） → 17
   * 高于此的 JDK 可向后兼容运行（高版本 JDK 能跑低版本字节码）。
   */
  requiredJdkMajor(mcVersion: string): number {
    // 同 autoSelectVersion：先归一化 version-id（fabric-loader-...-1.21.8 → 1.21.8），
    // 再委托 commons.requiredJdkMajorForMc 做纪元判定（单一事实源；commons 不依赖 mods，
    // 故归一化在此完成）。
    let mc = extractGameVersionFromId(mcVersion)
    return requiredJdkMajorForMc(mc)
  }

  /**
   * 某 MC 版本【真正能跑起来的最低 Java 主版本】（区别于 requiredJdkMajor 的 AMCL 纪元理想 17/21/25）。
   * 用于启动前「JDK 版本匹配」校验——只有所选 JDK 低于这个真实下限才算"选错"。
   *   - YEARLY（26.1+）           → 25
   *   - 1.20.5+                   → 21
   *   - 1.18 – 1.20.4             → 17
   *   - 1.17 – 1.17.1             → 16
   *   - ≤ 1.16.x                  → 8（这些老版本原生支持 Java 8，故 JDK 8 启动 1.16.5 不应报不匹配）
   *   - UNKNOWN（快照 / 中文目录名等）→ 0（不校验，避免误报）
   */
  minRuntimeJavaMajor(mcVersion: string): number {
    let mc = extractGameVersionFromId(mcVersion)
    let era = detectMcEra(mc)
    if (era === McEra.YEARLY) return 25
    if (era === McEra.CLASSIC) {
      if (isMcVersionAtLeast(mc, JDK21_MIN_MC_VERSION)) return 21
      if (isMcVersionAtLeast(mc, '1.18')) return 17
      if (isMcVersionAtLeast(mc, '1.17')) return 16
      return 8
    }
    return 0
  }

  /**
   * per-version 纪元路由：为某 MC 版本解析【实际启动用的 JDK 版本】。
   *
   * 背景（2026-06-06 修复）：旧实现 Index.launchMC 直接用全局单一 selectedJdkVersion
   * 套用所有版本，导致按版本纪元的自动路由从不生效（如用户测 26.1 时全局被设成 25，
   * 之后启动 1.21.x 也被塞到 25）。本方法让每个版本按自己的纪元选 JDK。
   *
   * 策略（纪元优先，已安装回退，手动选择仅作兼容内的回退）：
   *   1. 纪元理想 JDK 已安装 → 用它（per-version 正确，且会忽略不匹配的全局选择，
   *      例如 1.20.4 即便全局选了 25 也会正确回到 17）。
   *   2. 否则：用户全局手动选择能跑该版本（major ≥ 纪元最低）且已安装 → 尊重它
   *      （理想 JDK 没装时，优先用用户明确选过的兼容 JDK）。
   *   3. 否则：在已安装的、能跑该版本的 JDK 中选最低的一个（向上兼容回退，
   *      如设备只装了 17/25、跑 1.21.x 时回退到 25）。
   *   4. 都没有 → 返回纪元理想 JDK，让 launchMC 走"未安装，请下载"提示。
   *
   * @param mcVersion    MC 版本号（如 "1.21.8" 或 "26.1"；带 -forge/-fabric 后缀也可，
   *                     detectMcEra/isMcVersionAtLeast 取首段判定）
   * @param userPreferred 全局手动选择的 JDK 版本（Index.selectedJdkVersion）
   */
  /**
   * ⚠️ 墓碑: `isLegacyForgeNeedingJava8` 已删除（它是本仓**第五份** `isForge` 子串判定，
   * 而"老 Forge 必须 JDK 8"这条事实在契约表里已经是 `ModlauncherLegacy.pinnedJdkMajor='8'`），
   * 详见施工记录 §S09.4 与 §S10.7。
   *
   * 那条 `1000154` 的因果（modlauncher 4.x–8.x 对 system CL 调 `getURLs()`，JDK 9+ 返回
   * null ⇒ 启动即崩）现在写在契约表 `ModlauncherLegacy` 那一行的注释里，**只有一份**。
   */

  /**
   * 游戏**纪元**理想的 JDK：`autoSelectVersion` 再叠一条"≤1.12 一律 8"。
   *
   * 这是**游戏版本**的属性（LWJGL2 时代的 MC 1.7–1.12 在 JDK 9+ 上会因反射/内部 API
   * 移除而崩），与**加载器世代**无关 ⇒ 刻意留在 JdkManager 而不是契约表。
   * 契约表只管加载器那一半（钉住值 / 上限）。
   */
  private eraIdealJdk(realVer: string): string {
    if (detectMcEra(realVer) === McEra.CLASSIC && !isMcVersionAtLeast(realVer, '1.13')) {
      return '8'
    }
    return this.autoSelectVersion(realVer)
  }

  /** 已安装**且完整**的 JDK 主版本集合（`isInstalled` 为真的那些）。 */
  private installedMajors(): string[] {
    let out: string[] = []
    for (let v of SUPPORTED_JDK_VERSIONS) {
      if (this.isInstalled(v)) out.push(v)
    }
    return out
  }

  /**
   * 当前产品可下载的 JDK 槽，从既有支持集合与发布配置实读，不复制第二张版本硬表。
   * 该集合不参与安装完整性判定：available=false 只能阻止新的下载推荐，不能作废合法已装包。
   */
  private availableMajors(): string[] {
    const available: string[] = [];
    for (const version of SUPPORTED_JDK_VERSIONS) {
      const config: JdkVersionConfig | undefined = JDK_VERSIONS[version];
      if (config && config.available) available.push(version);
    }
    return available;
  }

  /**
   * ⭐ 该版本的 **JDK 可用区间** `[min, max]` + 推荐值 + 上限依据。
   *
   * **路由与 Phase 0 自检都读这一份**，所以"自检认可的"与"路由选出来的"不可能是两回事
   * —— 那正是 2026-09-04 那次全绿闪退的结构成因。
   *
   * ⚠️ **刻意与"选了哪个 JDK"无关**：单版本硬覆盖会**绕过**整条路由
   * （`LaunchCoordinator.resolveJdk` 第 1 步，那是"选错也能启动"的调试通道），
   * 所以 Phase 0 必须能独立算出区间才拦得住它。
   *
   * 上限从**该版本自己 `libraries` 里声明的 ASM 版本**实读（见 `AsmJavaSupport`），
   * 因此不需要维护"哪个 Forge 带哪个 ASM"那张会腐烂的表。
   */
  jdkRangeFor(mcVersion: string, mcDir: string = ''): JdkRange {
    let realVer = this.resolveRealMcVersion(mcVersion, mcDir)
    let parsed = (mcDir && mcDir.length > 0)
      ? VersionParser.parse(mcDir + '/versions/' + mcVersion + '/' + mcVersion + '.json')
      : null
    return resolveJdkRange({
      mainClass: (parsed && parsed.mainClass) ? parsed.mainClass : '',
      libraryPaths: parsed ? parsed.libraries : [],
      eraIdealJdk: this.eraIdealJdk(realVer),
      minRuntimeMajor: this.minRuntimeJavaMajor(realVer),
      // 官方/合并清单是周快照与自定义实例的下限事实源；缺失时策略才使用纪元回退。
      // 仅传递下限，不把它当成唯一 JDK，从而保留区间内已安装版本的合法替代。
      manifestJavaMajor: parsed ? parsed.javaVersionMajor : undefined,
      availableMajors: this.availableMajors(),
    })
  }

  /** 组装策略输入并选出 JDK。区间来自 `jdkRangeFor`（与自检同源）。 */
  jdkPolicyFor(mcVersion: string, userPreferred: string, mcDir: string = ''): JdkPolicyDecision {
    return resolveJdkPolicy({
      range: this.jdkRangeFor(mcVersion, mcDir),
      userPreferred: (userPreferred === JDK_AUTO) ? '' : (userPreferred || ''),
      installedMajors: this.installedMajors(),
    })
  }

  resolveLaunchJdk(mcVersion: string, userPreferred: string, mcDir: string = ''): string {
    let decision = this.jdkPolicyFor(mcVersion, userPreferred, mcDir)
    AppLogger.info(TAG, `resolveLaunchJdk(${mcVersion}): ${decision.logLine}`, LOG_DOMAIN_LAUNCH)
    return decision.jdk
  }

  deleteVersion(version: string): boolean {
    let dir = this.getJdkDir(version)
    let writerLease: JdkDirectoryLease | null = null
    let useLease: JdkDirectoryLease | null = null
    try {
      writerLease = JdkDirectoryLease.writer(this.context.filesDir, version)
      useLease = JdkDirectoryLease.publication(this.context.filesDir, version)
      removeDirRecursive(dir)
      AppLogger.info(TAG, `Deleted JDK ${version} at ${dir}`, LOG_DOMAIN_LAUNCH)
      return true
    } catch (e) {
      AppLogger.error(TAG, `Failed to delete JDK ${version}`, e, LOG_DOMAIN_LAUNCH)
      return false
    } finally {
      if (useLease !== null) useLease.release()
      if (writerLease !== null) writerLease.release()
    }
  }

  // ============================================================
  //  首次启动检查：JDK 是否已安装
  // ============================================================

  /**
   * 启动时探测受支持版本是否已安装（17 是默认主版本）。
   *
   * 设计要点：
   *   - 仍然只探主版本（17），不探 21；用户首次进 app 都会先看到"安装 JDK 17"
   *     的引导；选了 21 之后切换是另一条入口（SettingsTab + JDK 管理面板）。
   *   - 与 JdkManager.isInstalled('21') 不冲突 — Index.updateJdkReadyState 会
   *     根据当前 selectedJdkVersion 做最终判定。
   */
  async checkAndExtract(): Promise<boolean> {
    const version = SUPPORTED_JDK_VERSION

    if (this.isInstalled(version)) {
      this.report(true, 'JDK ' + version + ' 已就绪 ✅')
      return true
    }

    this.report(false, '未安装 JDK，请点击"JDK 管理"下载')
    return false
  }

  // ============================================================
  //  Installer 工厂（B-1 修复，2026-05-26）
  // ============================================================
  //
  // 把"任务状态"下放到 JdkInstaller per-task 实例，让多 JDK 真正并发。
  // 旧 downloadAndInstall / downloadJdkArchive / completeJdkInstall /
  // verifyArchiveIntegrity / computeFileSha256 / requestCancel /
  // isDownloading / isCancelRequested 全部搬到 JdkInstaller。
  //
  // 调用方（JdkInstallTask）使用：
  //   const inst = manager.createInstaller('17');
  //   if (inst === null) { /* 未知或未发布版本 */ }
  //   inst.setDownloadCallback(handleProgress);
  //   await inst.downloadAndInstall();
  //
  // 详见 docs/self-inspection/2026-05-26_AMCL_多任务下载并发缺陷诊断.md §B-1
  // ============================================================

  /**
   * 给指定版本创建一个独立的安装任务对象。
   * - 未知版本 / 未上线版本 → 返回 null（调用方应给用户对应错误提示）
   * - 已上线版本 → 返回新 JdkInstaller 实例（per-task，多 installer 互不影响）
   */
  /**
   * @param forceReinstall 「更新」路径必须传 true —— 否则会命中 JdkInstaller 里
   *   "已装则跳过下载"的幂等门（新语义下 tag 过期仍算已装），表现为点了瞬间说完成。
   */
  createInstaller(version: string, forceReinstall: boolean = false): JdkInstaller | null {
    this.synchronizeCatalog();
    const config = JDK_VERSIONS[version]
    if (!config) {
      AppLogger.warn(TAG, `createInstaller: unknown JDK ${version}`, null, LOG_DOMAIN_LAUNCH)
      return null
    }
    if (!config.available) {
      AppLogger.warn(TAG, `createInstaller: JDK ${version} not available`, null, LOG_DOMAIN_LAUNCH)
      return null
    }
    return new JdkInstaller({
      context: this.context,
      version: version,
      config: JSON.parse(JSON.stringify(config)) as JdkVersionConfig,
      targetDir: this.getJdkDir(version),
      isInstalledFn: (): boolean => this.isInstalled(version),
      forceReinstall: forceReinstall,
    })
  }
}
