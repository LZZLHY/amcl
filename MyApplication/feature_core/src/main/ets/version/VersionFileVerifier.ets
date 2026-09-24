/**
 * VersionFileVerifier.ets — 版本文件【哈希级】完整性校验
 *
 * 背景：原 LaunchProfileBuilder.build() 的"版本文件完整性"只验"存在 + size>0 + ZIP 头"，
 * 抓不到"版本错配 / 内容损坏但 ZIP 合法 / 被篡改"的 jar。本模块对齐成熟启动器（PCL2 /
 * 官方启动器）的做法，按 version.json 自带的 sha1/size 元数据做真正的哈希校验。
 *
 * 三类对象（数据全部来自 version.json）：
 *   - 主 jar    ：downloads.client.{sha1,size}
 *   - 依赖库    ：libraries[].downloads.artifact.{path,sha1,size}
 *   - 资源对象  ：assets/indexes/<assetIndex>.json → objects{name:{hash,size}}
 *                 资源对象的【文件名本身就是 sha1】（assets/objects/<hash前2位>/<hash>），
 *                 因此"存在 + size 匹配"已等价于内容校验，无需再 hash（省掉数千次哈希）。
 *
 * 性能取向（关键）：
 *   - sha1 计算【昂贵】（主 jar 几十 MB、依赖库累计上百 MB），故：
 *       · 启动前校验（每次启动都跑）：只 hash【主 jar 一个文件】+ assets 存在性，
 *         其余库走 LaunchProfileBuilder 的存在/ZIP 头快检（见 PreLaunchValidator）。
 *       · 全量 sha1（主 jar + 全部库 + assets）：作为版本详情里【用户手动触发】的
 *         "校验文件完整性"动作，带进度，不进启动热路径。
 *   - assets 一律走存在 + size（不 hash），无论快检还是全量。
 *
 * 纯逻辑、无 UI：UI 编排在 PreLaunchCheckSheet（启动前）/ Index.verifyVersionFilesFull（详情）。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { formatError } from 'commons';

const TAG = 'VersionFileVerifier';

/** 单个依赖库的校验元数据（仅含 version.json 声明了 downloads.artifact 的库）。 */
export interface LibVerifyMeta {
  path: string;   // 相对 libraries/ 的路径
  sha1: string;
  size: number;
  generated: boolean;  // true = Forge 安装器本地生成产物（磁盘 sha1 与 json 声明天然不一致，只验存在 + ZIP 头）
}

/** 从 version.json 提取的可校验元数据。字段缺失（如自定义/模组版本无 downloads）时为空。 */
export interface VersionVerifyMeta {
  clientSha1: string;     // 主 jar 期望 sha1（'' = json 未声明，跳过 hash）
  clientSize: number;     // 主 jar 期望大小（<=0 = 未声明）
  assetIndexId: string;   // assets 索引 id（'' = 无 assets）
  libs: LibVerifyMeta[];  // 带 sha1 的库列表
}

/** assets 存在性检查结果。 */
export interface AssetsCheckResult {
  indexExists: boolean;   // assets/indexes/<id>.json 是否存在且可解析
  total: number;          // 索引声明的对象总数
  missing: number;        // 缺失（不存在 / size 不符）的对象数
}

/** 全量校验报告。 */
export interface VerifyReport {
  hadMeta: boolean;       // version.json 是否含可校验元数据（否则无法判定，按"通过+提示"处理）
  total: number;          // 实际校验的文件总数（主 jar + 库 + assets 对象）
  missing: string[];      // 缺失文件的可读名（截断展示）
  corrupted: string[];    // sha1/size 不符的可读名（截断展示）
  assetsTotal: number;
  assetsMissing: number;
}

/** 全量校验进度回调：done=已校验数，total=总数，label=当前文件短名。 */
export type VerifyProgress = (done: number, total: number, label: string) => void;

export class VersionFileVerifier {
  /**
   * library rules 判定（与 VersionParser.checkLibraryRules 等价，HarmonyOS 伪装为 linux）。
   * 在原始 JSON 对象上评估，避免类型耦合。返回 true = 该库应包含（应在磁盘上）。
   *
   * 为什么必须有这个：版本详情的完整性校验若不过滤 rules，会把【平台专属、本就不该下载】
   * 的库（如 natives-macos / natives-windows，1.19+ 原版 json 里以独立 artifact + rules 出现）
   * 当成"缺失" → 明明完整的版本被误报不完整。这是本次修复的核心。
   */
  private static libRulesPass_(rulesObj: Object | undefined): boolean {
    if (!Array.isArray(rulesObj)) return true;
    let rules = rulesObj as Object[];
    if (rules.length === 0) return true;
    let dominated = false;
    let dominatedByAllow = false;
    for (let r of rules) {
      let rule = r as Record<string, Object>;
      let action = typeof rule['action'] === 'string' ? rule['action'] as string : '';
      let os = rule['os'] as Record<string, Object>;
      if (os && typeof os['name'] === 'string') {
        let osMatch = (os['name'] as string) === 'linux';
        if (action === 'allow') {
          if (osMatch) dominatedByAllow = true;
          dominated = true;
        } else if (action === 'disallow') {
          if (osMatch) return false;
        }
      } else {
        if (action === 'allow') dominatedByAllow = true;
        dominated = true;
      }
    }
    return dominated ? dominatedByAllow : true;
  }

  /**
   * 是否为 Forge 安装器【本地生成产物】（forge -client/-universal、mc -extra/-srg）。
   * 这类文件由安装器在设备上处理生成，磁盘 sha1 与 version.json 声明的 sha1【天然不一致】
   * （json 里的 sha1 是上游 Maven 件的，设备上是 binpatch/合并后的产物）。因此只验"存在 +
   * 合法 ZIP 头"，不做 sha1/size 比对——否则会把完整安装误判为损坏。
   * 与 LaunchProfileBuilder.filterForgeGeneratedArtifacts 保持同一判定口径。
   */
  private static isGeneratedArtifact_(path: string): boolean {
    let p = path.replace(/\\/g, '/');
    let isForgeClient = p.indexOf('net/minecraftforge/forge/') >= 0 && p.indexOf('-client.jar') >= 0;
    let isForgeUniversal = p.indexOf('net/minecraftforge/forge/') >= 0 && p.indexOf('-universal.jar') >= 0;
    let isMcExtra = p.indexOf('net/minecraft/client/') >= 0 && p.indexOf('-extra.jar') >= 0;
    let isMcSrg = p.indexOf('net/minecraft/client/') >= 0 && p.indexOf('-srg.jar') >= 0;
    return isForgeClient || isForgeUniversal || isMcExtra || isMcSrg;
  }

  /** 读 jar 前两字节判断是否为合法 ZIP（"PK"）。用于生成产物的存在性+完整性快检。 */
  private static zipHeaderOk_(path: string): boolean {
    let file: fs.File | null = null;
    try {
      let st = fs.statSync(path);
      if (st.size < 4) return false;
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      let buf = new ArrayBuffer(2);
      let n = fs.readSync(file.fd, buf, { offset: 0, length: 2 });
      if (n < 2) return false;
      let h = new Uint8Array(buf);
      return h[0] === 0x50 && h[1] === 0x4B;   // 'P' 'K'
    } catch (e) {
      return false;
    } finally {
      if (file) { try { fs.closeSync(file) } catch (_) { /* ignore */ } }
    }
  }

  /** 流式计算文件摘要（小写 hex）。分块读，避免大文件 OOM。 */
  private static async digestFile(path: string, algorithm: string): Promise<string> {
    const CHUNK_SIZE = 256 * 1024;
    let file: fs.File | null = null;
    try {
      let md = cryptoFramework.createMd(algorithm);
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      let buffer = new ArrayBuffer(CHUNK_SIZE);
      while (true) {
        let n = fs.readSync(file.fd, buffer);
        if (n <= 0) break;
        let chunk: cryptoFramework.DataBlob = { data: new Uint8Array(buffer, 0, n) };
        md.updateSync(chunk);
      }
      let digest = md.digestSync();
      let hex = '';
      for (let i = 0; i < digest.data.length; i++) {
        let b = digest.data[i];
        hex += (b < 16 ? '0' : '') + b.toString(16);
      }
      return hex;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'digestFile %{public}s failed: %{public}s', path, formatError(e));
      throw e as Error;
    } finally {
      if (file) { try { fs.closeSync(file) } catch (_) { /* ignore */ } }
    }
  }

  /** 流式计算文件 SHA-1（Minecraft 上游元数据校验）。 */
  static async sha1File(path: string): Promise<string> {
    return VersionFileVerifier.digestFile(path, 'SHA1');
  }

  /** 流式计算文件 SHA-256（AMCL 自带第三方运行时制品校验）。 */
  static async sha256File(path: string): Promise<string> {
    return VersionFileVerifier.digestFile(path, 'SHA256');
  }

  /**
   * 从磁盘的 version.json 提取可校验元数据。读取失败 / 缺字段时尽量降级返回空字段，
   * 不抛错（让调用方按"无元数据"处理）。
   */
  static readMeta(mcDir: string, version: string): VersionVerifyMeta {
    let meta: VersionVerifyMeta = { clientSha1: '', clientSize: 0, assetIndexId: '', libs: [] };
    let jsonPath = mcDir + '/versions/' + version + '/' + version + '.json';
    let obj: Record<string, Object>;
    try {
      obj = JSON.parse(fs.readTextSync(jsonPath)) as Record<string, Object>;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'readMeta parse failed %{public}s: %{public}s', jsonPath, formatError(e));
      return meta;
    }

    // 主 jar：downloads.client.{sha1,size}
    let downloads = obj['downloads'] as Record<string, Object>;
    if (downloads) {
      let client = downloads['client'] as Record<string, Object>;
      if (client) {
        if (typeof client['sha1'] === 'string') meta.clientSha1 = client['sha1'] as string;
        if (typeof client['size'] === 'number') meta.clientSize = client['size'] as number;
      }
    }

    // assetIndex.id
    let assetIndex = obj['assetIndex'] as Record<string, Object>;
    if (assetIndex && typeof assetIndex['id'] === 'string') {
      meta.assetIndexId = assetIndex['id'] as string;
    } else if (typeof obj['assets'] === 'string') {
      meta.assetIndexId = obj['assets'] as string;
    }

    // libraries[].downloads.artifact.{path,sha1,size}
    let libraries = obj['libraries'];
    if (Array.isArray(libraries)) {
      for (let l of libraries as Object[]) {
        let lib = l as Record<string, Object>;
        // 关键：先按 rules 过滤（伪装 linux）。平台专属库（natives-macos/windows 等）
        // 本就不该下载到本机，跳过它们，避免误报"缺失"。
        if (!VersionFileVerifier.libRulesPass_(lib['rules'])) continue;
        let dl = lib['downloads'] as Record<string, Object>;
        if (!dl) continue;
        let art = dl['artifact'] as Record<string, Object>;
        if (!art) continue;
        let p = art['path'];
        let s = art['sha1'];
        let sz = art['size'];
        if (typeof p === 'string' && typeof s === 'string' && (p as string).length > 0 && (s as string).length > 0) {
          meta.libs.push({
            path: p as string,
            sha1: s as string,
            size: typeof sz === 'number' ? (sz as number) : -1,
            generated: VersionFileVerifier.isGeneratedArtifact_(p as string),
          });
        }
      }
    }
    return meta;
  }

  /**
   * 检查 assets 资源完整性（存在 + size，不 hash）。
   * @param assetIndexId 资源索引 id（由 readMeta 提供）。空 → 视为无 assets（indexExists=false, total=0）。
   */
  static checkAssets(mcDir: string, assetIndexId: string): AssetsCheckResult {
    let res: AssetsCheckResult = { indexExists: false, total: 0, missing: 0 };
    if (!assetIndexId || assetIndexId.length === 0) return res;
    let indexPath = mcDir + '/assets/indexes/' + assetIndexId + '.json';
    let objects: Record<string, Object>;
    try {
      let root = JSON.parse(fs.readTextSync(indexPath)) as Record<string, Object>;
      objects = root['objects'] as Record<string, Object>;
      if (!objects) return res;   // 索引存在但无 objects 字段
      res.indexExists = true;
    } catch (e) {
      // 索引文件缺失 / 解析失败 → indexExists=false
      return res;
    }
    let objectsDir = mcDir + '/assets/objects';
    let names = Object.keys(objects);
    res.total = names.length;
    for (let name of names) {
      let o = objects[name] as Record<string, Object>;
      let hash = o ? (o['hash'] as string) : '';
      if (typeof hash !== 'string' || hash.length < 2) { res.missing++; continue; }
      let expectSize = (o && typeof o['size'] === 'number') ? (o['size'] as number) : -1;
      let objPath = objectsDir + '/' + hash.substring(0, 2) + '/' + hash;
      try {
        let st = fs.statSync(objPath);
        if (st.size <= 0 || (expectSize >= 0 && st.size !== expectSize)) res.missing++;
      } catch (e) {
        res.missing++;
      }
    }
    return res;
  }

  /**
   * 全量校验：主 jar + 全部依赖库（sha1）+ assets（存在/size）。
   * 用户在版本详情手动触发，带进度回调；不进启动热路径。
   */
  static async verifyAll(mcDir: string, version: string, onProgress?: VerifyProgress): Promise<VerifyReport> {
    let report: VerifyReport = {
      hadMeta: false, total: 0, missing: [], corrupted: [], assetsTotal: 0, assetsMissing: 0,
    };
    let meta = VersionFileVerifier.readMeta(mcDir, version);
    report.hadMeta = meta.clientSha1.length > 0 || meta.libs.length > 0;

    // 待 hash 的文件清单：主 jar + 库
    interface Target { path: string; sha1: string; size: number; label: string; generated: boolean }
    let targets: Target[] = [];
    if (meta.clientSha1.length > 0) {
      let jarPath = mcDir + '/versions/' + version + '/' + version + '.jar';
      targets.push({ path: jarPath, sha1: meta.clientSha1, size: meta.clientSize, label: version + '.jar', generated: false });
    }
    let libDir = mcDir + '/libraries';
    for (let lib of meta.libs) {
      targets.push({
        path: libDir + '/' + lib.path,
        sha1: lib.sha1,
        size: lib.size,
        label: lib.path.substring(lib.path.lastIndexOf('/') + 1),
        generated: lib.generated,
      });
    }

    let total = targets.length;  // assets 统计单独累加
    let done = 0;
    for (let t of targets) {
      done++;
      if (onProgress) onProgress(done, total, t.label);
      // Forge 本地生成产物：磁盘 sha1 与 json 声明天然不一致，只验"存在 + 合法 ZIP 头"。
      if (t.generated) {
        if (!VersionFileVerifier.zipHeaderOk_(t.path)) {
          // 文件不存在或 ZIP 头损坏 → 区分缺失 vs 损坏
          let present = false;
          try { present = fs.statSync(t.path).size > 0; } catch (e) { present = false; }
          if (present) report.corrupted.push(t.label); else report.missing.push(t.label);
        }
        report.total++;
        continue;
      }
      // 存在性 + size
      let exists = false;
      try {
        let st = fs.statSync(t.path);
        exists = st.size > 0;
        if (exists && t.size >= 0 && st.size !== t.size) {
          report.corrupted.push(t.label);
          report.total++;
          continue;
        }
      } catch (e) { exists = false; }
      if (!exists) { report.missing.push(t.label); report.total++; continue; }
      // sha1
      try {
        let actual = (await VersionFileVerifier.sha1File(t.path)).toLowerCase();
        if (actual !== t.sha1.toLowerCase()) report.corrupted.push(t.label);
      } catch (e) {
        report.corrupted.push(t.label);
      }
      report.total++;
    }

    // assets（存在 + size）
    let assets = VersionFileVerifier.checkAssets(mcDir, meta.assetIndexId);
    report.assetsTotal = assets.total;
    report.assetsMissing = assets.missing;
    report.total += assets.total;
    if (meta.assetIndexId.length > 0 && !assets.indexExists) {
      report.missing.push('assets/indexes/' + meta.assetIndexId + '.json');
    }

    hilog.info(0x0000, TAG,
      'verifyAll %{public}s: total=%{public}d missing=%{public}d corrupted=%{public}d assetsMissing=%{public}d/%{public}d',
      version, report.total, report.missing.length, report.corrupted.length, report.assetsMissing, report.assetsTotal);
    return report;
  }

  /**
   * Forge 安装器【生成产物】是否损坏/缺失：检查 libraries 下的
   * `forge-<game>-<loader>-client.jar`（binpatch 客户端）。这是安装器本地生成、
   * version.json 里**没有下载 URL** 的产物——只能重跑安装器重建，统一下载器补不了。
   * 返回 true 表示缺失或 ZIP 头损坏（需走 Forge 重建修复）。
   *
   * ⚠️ **仅对新版 Forge（≥1.13）有意义。** 旧版 Forge（≤1.12，FML legacy）没有
   * binarypatcher、根本不产出 `-client.jar`，本方法对它恒返回 true。调用方必须先用
   * `isNewForgeVersion(loaderVersion)` 过滤，否则旧版 Forge 会被永久判定为"生成产物损坏"
   * → 每次点"修复"都强制走深度修复 + 完整重装安装器。调用点已按此过滤
   * （ForgeRepairTask / LaunchCoordinator.needsForgeDeepRepair）。
   */
  static forgeClientArtifactBroken(mcDir: string, gameVersion: string, loaderVersion: string): boolean {
    let p = mcDir + '/libraries/net/minecraftforge/forge/' + gameVersion + '-' + loaderVersion
      + '/forge-' + gameVersion + '-' + loaderVersion + '-client.jar';
    let file: fs.File | null = null;
    try {
      let st = fs.statSync(p);
      if (st.size < 4) return true;
      file = fs.openSync(p, fs.OpenMode.READ_ONLY);
      let buf = new ArrayBuffer(4);
      let n = fs.readSync(file.fd, buf, { offset: 0, length: 4 });
      if (n < 4) return true;
      let h = new Uint8Array(buf);
      return !(h[0] === 0x50 && h[1] === 0x4B);   // 非 PK → 损坏
    } catch (e) {
      return true;   // 不存在 / 读失败 → 视为损坏
    } finally {
      if (file) { try { fs.closeSync(file) } catch (_) { /* ignore */ } }
    }
  }
}

