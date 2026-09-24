/**
 * VersionMetaService.ets — 版本说明（intro 段落）抓取
 *
 * 目标：给"版本下载详情"页提供一段中性的版本介绍文本，覆盖正式版 / 快照 /
 * 愚人节 / 远古 Alpha+Beta 等所有类别。
 *
 * 数据源：minecraft.wiki MediaWiki Action API
 *   https://minecraft.wiki/api.php?action=query&prop=extracts&exintro=1&explaintext=1&titles=...
 *
 * ⚠️ 协议合规（必须严格遵守）：
 *   - 内容协议：CC BY-NC-SA 3.0
 *     https://creativecommons.org/licenses/by-nc-sa/3.0/
 *   - 三条要求：
 *     1) **署名 (BY)**：UI 上必须可见 "© minecraft.wiki"，并提供回链
 *        （VersionConfigPanel 的描述卡片底部一行小字 + URL）
 *     2) **非商用 (NC)**：本启动器目前 GitHub 开源 / 不上架商店 / 无内购 / 无广告。
 *        如未来商业化（应用市场付费、广告 SDK、企业授权等），**必须移除本服务**
 *        或换源。详见 docs/CREDITS.md 与 ROADMAP。
 *     3) **相同方式共享 (SA)**：派生作品按 CC BY-NC-SA 3.0 授权 —
 *        本服务获取的 extract 文本属于"派生 / 嵌入"使用，本启动器主代码仍按
 *        项目原协议（开源），仅在 docs/CREDITS.md 标注"该数据子集 CC BY-NC-SA 3.0"。
 *
 * 工程约束：
 *   - 不阻塞 UI：调用方拿 Promise<VersionMetaResult>，加载中显示骨架屏
 *   - 礼貌的 User-Agent：声明项目身份 + 联系方式（Wiki API 礼仪）
 *   - 缓存：复用 MetadataCacheStore，TTL = 7 天（版本描述罕有更新，给宽松 TTL）
 *   - 离线 / 失败：返回 null，调用方降级到不显示该卡片，不影响下载流程
 *   - 速率：单版本单请求，本身就稀疏；不做主动批量预热
 *
 * 标题命名规则（基于 minecraft.wiki 实际页面命名）：
 *   - 现代版：       Java_Edition_<id>             如 Java_Edition_1.20.4
 *   - 周快照：       Java_Edition_<id>             如 Java_Edition_24w04a
 *   - 愚人节版：     Java_Edition_<id>             如 Java_Edition_24w14potato
 *   - 远古 Beta：    Java_Edition_Beta_<num>       如 Java_Edition_Beta_1.7.3
 *   - 远古 Alpha：   Java_Edition_Alpha_v<num>     如 Java_Edition_Alpha_v1.2.6
 *   - 2013 玩具版：  Java_Edition_2.0              （含 _blue/_purple/_red 子页面）
 *   - 其它：         按原 id，找不到时返回 null
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { http } from '@kit.NetworkKit';
import { getMetadataCacheStore, MetadataCacheStore } from './MetadataCacheStore';
import { APP_NAME, APP_VERSION } from 'commons';

const TAG = 'VersionMetaService';

/**
 * MediaWiki API endpoint。HTTPS-only（其它协议会被 wiki 拒）。
 *
 * 不走 BMCLAPI / MCIM 等启动器镜像 —— 那些只镜像 piston-meta 等 Mojang 资源，
 * 不镜像 minecraft.wiki。直连即可，wiki 站本身国内访问稳定。
 */
const WIKI_API_BASE = 'https://minecraft.wiki/api.php';

/** 7 天 TTL —— 版本描述基本不变，给宽松缓存 */
const CACHE_TTL_MS = 7 * 24 * 60 * 60 * 1000;

/** HTTP 超时（ms）—— 描述文字不是关键路径，超时果断降级 */
const FETCH_TIMEOUT_MS = 12000;

// ============================================================
//  对外结果类型
// ============================================================

export interface VersionMetaResult {
  /** 调用方传进来的版本 id（透传，便于异步回调时识别） */
  versionId: string;
  /**
   * intro 段落纯文本（已剥离 wikitext / HTML），一两句到一段不等。
   * null = 文章不存在 / 抓取失败 / 已禁用网络。
   */
  description: string | null;
  /** 数据来源 wiki 页面 URL，UI 用来做署名链接 */
  sourceUrl: string;
  /** 是否来自缓存（诊断用，UI 通常不展示） */
  fromCache: boolean;
}

// ============================================================
//  Public API
// ============================================================

/**
 * 取版本介绍。失败时 description=null，调用方按"不显示卡片"降级。
 *
 * 所有失败路径（网络 / JSON 损坏 / 文章 missing）都返回带 description=null 的
 * 结果，绝不抛异常 —— UI 拿到 null 就隐藏说明卡片即可。
 */
export async function fetchVersionMeta(versionId: string): Promise<VersionMetaResult> {
  let title = wikiTitleFor(versionId);
  let url = buildExtractUrl(title);
  let result: VersionMetaResult = {
    versionId: versionId,
    description: null,
    sourceUrl: 'https://minecraft.wiki/w/' + encodeURIComponent(title),
    fromCache: false,
  };
  if (versionId.length === 0) return result;

  // ---- 1. 缓存命中 → 立即返回 ----
  let cache: MetadataCacheStore | null = null;
  try { cache = getMetadataCacheStore(); } catch (e) { /* not init yet */ }
  if (cache !== null && cache.isReady()) {
    let cached = cache.get(url, CACHE_TTL_MS);
    if (cached !== null) {
      let parsed = parseExtract(cached);
      if (parsed !== null) {
        result.description = parsed;
        result.fromCache = true;
        return result;
      }
      // 缓存解析失败（极端情况）→ 当作 cache miss 继续走网络
    }
  }

  // ---- 2. 网络请求 ----
  let body: string | null = null;
  let httpReq: http.HttpRequest | null = null;
  try {
    httpReq = http.createHttp();
    let resp = await httpReq.request(url, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: FETCH_TIMEOUT_MS,
      readTimeout: FETCH_TIMEOUT_MS,
      header: {
        // 礼貌的 UA，含项目名 / 版本 / 联系方式（Wiki API 礼仪）
        'User-Agent': APP_NAME + '/' + APP_VERSION + ' (https://github.com/axecraft/amcl; minecraft launcher)',
        'Accept': 'application/json',
      } as Record<string, string>,
    });
    if (resp.responseCode !== 200) {
      hilog.warn(0x0000, TAG, 'http %{public}d for %{public}s', resp.responseCode, versionId);
      return result;
    }
    let r = resp.result;
    if (typeof r === 'string') body = r;
  } catch (e) {
    let msg = e instanceof Error ? (e as Error).message : String(e);
    hilog.warn(0x0000, TAG, 'fetch failed %{public}s: %{public}s', versionId, msg);
    return result;
  } finally {
    try { httpReq?.destroy(); } catch (e) { /* ignore */ }
  }

  if (body === null || body.length === 0) return result;

  // ---- 3. 解析 ----
  let parsed = parseExtract(body);
  if (parsed === null) {
    hilog.info(0x0000, TAG, 'no extract for %{public}s (page missing or empty)', versionId);
    return result;
  }
  result.description = parsed;

  // ---- 4. 写缓存（best-effort）----
  if (cache !== null && cache.isReady()) {
    try { cache.put(url, body); } catch (e) { /* ignore */ }
  }
  return result;
}

// ============================================================
//  内部 helpers — 纯函数（便于单测）
// ============================================================

/**
 * 版本 id → wiki 页面 title。规则见文件顶部 docstring。
 *
 * 处理：
 *   - 远古 Beta b1.x.y → Beta 1.x.y
 *   - 远古 Alpha a1.x.y → Alpha v1.x.y（wiki 实际命名带 v 前缀）
 *   - 其它原样
 */
export function wikiTitleFor(versionId: string): string {
  let id = versionId.trim();
  let lower = id.toLowerCase();
  // Beta b1.7.3
  if (lower.startsWith('b1.')) {
    return 'Java_Edition_Beta_' + id.substring(1).replace(/\s+/g, '_');
  }
  // Alpha a1.2.6
  if (lower.startsWith('a1.')) {
    return 'Java_Edition_Alpha_v' + id.substring(1).replace(/\s+/g, '_');
  }
  // 其它（含 1.x.y / 24w14potato / 2.0_blue / 1.RV-Pre1 / 3D Shareware v1.34 等）
  // wiki title 用下划线代替空格
  return 'Java_Edition_' + id.replace(/\s+/g, '_');
}

/**
 * 构造 MediaWiki Action API URL（拿 intro 纯文本）。
 *
 * 关键参数：
 *   - prop=extracts        启用 extract 扩展
 *   - exintro=1            只取 intro 段落（=== 第一个 == 二级标题之前）
 *   - explaintext=1        纯文本（去 wikitext / HTML）
 *   - exsectionformat=plain 纯文本格式
 *   - format=json formatversion=2 现代 JSON 输出
 */
export function buildExtractUrl(title: string): string {
  let q = 'action=query'
    + '&format=json&formatversion=2'
    + '&prop=extracts&exintro=1&explaintext=1&exsectionformat=plain'
    + '&redirects=1'  // 跟重定向（如 Java_Edition_1.20 → 1.20）
    + '&titles=' + encodeURIComponent(title);
  return WIKI_API_BASE + '?' + q;
}

/**
 * 解析 wiki API JSON 响应，抽出 extract 文本。
 *
 * formatversion=2 下结构：
 *   {
 *     "query": {
 *       "pages": [
 *         { "pageid": ..., "title": "...", "extract": "..." }
 *         // 或 { "pageid": -1, "title": "...", "missing": true } 表示文章不存在
 *       ]
 *     }
 *   }
 *
 * 任何解析异常 / missing / 空 extract → 返回 null。
 */
export function parseExtract(body: string): string | null {
  if (body.length === 0) return null;
  try {
    let raw = JSON.parse(body) as Object;
    let obj = raw as Record<string, Object>;
    let query = obj['query'] as Record<string, Object> | undefined;
    if (!query) return null;
    let pages = query['pages'];
    if (!Array.isArray(pages) || pages.length === 0) return null;
    let first = pages[0] as Record<string, Object>;
    if (first['missing'] !== undefined) return null;
    let extract = first['extract'];
    if (typeof extract !== 'string') return null;
    let trimmed = (extract as string).trim();
    if (trimmed.length === 0) return null;
    return trimmed;
  } catch (e) {
    return null;
  }
}
