/**
 * ModTranslation.ets — AMCL 社区资源中文译名 / 中文搜索库（译名库格式 + 解析 + 查询）
 *
 * 设计动机：
 *   - Modrinth / CurseForge 的搜索接口只索引英文，用户输入中文会搜不到。
 *   - 列表只显示英文名，中文用户辨识困难。
 *
 * 本模块提供：
 *   1) 解析 **AMCL 译名库格式** 的数据文件（数据源：mcmod.cn 百科导出的 `moddata.txt`，
 *      以及我们自维护的同格式补充文件 `moddata-amcl.txt`，补充库覆盖优先）。
 *   2) ModTranslationStore：按 slug 反查中文名（展示翻译），
 *      以及把"中文搜索词"解析为英文关键词（中文搜索）。
 *
 * **纯逻辑、零 IO**：本文件不引入 resourceManager / fileIo，
 * 文件读取由 UI 层（entry）完成后把文本喂进 parseModData，便于 hvigor test 直接单测。
 *
 * AMCL 译名库格式（每行一个"百科条目"，可含多个用 `¨` 分隔的别名条目）：
 *   <slug 段>|<中文名>
 *   slug 段写法：
 *     `cf-slug`            仅 CurseForge
 *     `@mr-slug`           仅 Modrinth
 *     `cf-slug@`           两边同名
 *     `cf-slug@mr-slug`    两边不同名
 *   中文名里的 `*` 占位符展开为 ` (Slug 首字母大写)`。
 *   mcmod 主库（hasRanks=true）最后一行是各行的人气排名（`|` 分隔，数字越大越热门）。
 *
 * 创建日期：2026-05-12
 */

import { ModSource, RemoteProject } from './ModTypes';

// ============================================================
//  数据条目
// ============================================================

export interface ModTranslationEntry {
  /** CurseForge slug，空串表示无 */
  curseforgeSlug: string;
  /** Modrinth slug，空串表示无 */
  modrinthSlug: string;
  /** 中文译名（可能形如 "工业时代2 (Industrial Craft 2)"）；空串表示无翻译 */
  chineseName: string;
  /** 行号（1-based），仅用于调试 / 稳定排序 */
  id: number;
  /** 人气排名，数字越大越热门；无则 0 */
  popularity: number;
}

// ============================================================
//  纯函数：辅助
// ============================================================

/** 字符串是否含中文字符（CJK 统一表意文字基本区） */
export function isChineseText(s: string): boolean {
  if (s.length === 0) return false;
  return /[\u4e00-\u9fff]/.test(s);
}

/** 去掉字符串结尾连续的某个字符 */
function trimEndChar(s: string, ch: string): string {
  let end = s.length;
  while (end > 0 && s.charAt(end - 1) === ch) end--;
  return s.substring(0, end);
}

/** 把 "the camping mod" 这样的串每个词首字母大写 → "The Camping Mod" */
function capitalizeWords(s: string): string {
  let words = s.split(' ');
  let out: string[] = [];
  for (let w of words) {
    if (w.length === 0) { out.push(w); continue; }
    out.push(w.charAt(0).toUpperCase() + w.substring(1));
  }
  return out.join(' ');
}

// ============================================================
//  解析器
// ============================================================

/**
 * 解析一份 moddata 文本为条目数组。
 *
 * @param text      文件全文（UTF-8 解码后的字符串）
 * @param hasRanks  true=最后一行是人气排名（mcmod 主库）；false=无排名行（我们的补充库）
 */
export function parseModData(text: string, hasRanks: boolean): ModTranslationEntry[] {
  let entries: ModTranslationEntry[] = [];
  if (text.length === 0) return entries;

  // 归一化换行 + 去掉行尾 \r；**整行剔除注释行（# 开头）**，使注释不计入行号/排名编号
  // —— 这样注释可放在文件任意位置（尤其文件头），而不会移动数据行的 mcmod class id / 人气下标。
  // 注意：空行**保留**（mcmod 的行号编号把空行也算在内，剔除会破坏 class id 对齐）。
  let raw = text.split('\n');
  let lines: string[] = [];
  for (let k = 0; k < raw.length; k++) {
    let line = raw[k];
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    if (line.startsWith('#')) continue;
    lines.push(line);
  }

  let ranks: string[] = [];
  if (hasRanks && lines.length > 0) {
    // 丢弃末尾空行（文件末尾换行符产生的空串），保证最后一行确为人气排名行
    // ——否则排名行会被当成数据行解析、且 ranks 取到空串使所有人气为 0。
    while (lines.length > 0 && lines[lines.length - 1].length === 0) {
      lines.pop();
    }
    if (lines.length > 0) {
      // 主库约定：最后一行是人气排名，按 `|` 拆，并从数据行移除
      ranks = lines[lines.length - 1].split('|');
      lines = lines.slice(0, lines.length - 1);
    }
  }

  // 注意：i 对每一行（含空行）自增，使其与 ranks 的下标严格对齐（行号即 mcmod class id）
  let i = 0;
  for (let line of lines) {
    i++;
    if (line.length === 0) continue;
    let aliasGroups = line.split('¨');
    for (let entryData of aliasGroups) {
      if (entryData.length === 0) continue;
      let seg = entryData.split('|');
      let slugSpec = seg[0];

      let cf = '';
      let mr = '';
      if (slugSpec.startsWith('@')) {
        mr = slugSpec.replace(/@/g, '');
      } else if (slugSpec.endsWith('@')) {
        cf = trimEndChar(slugSpec, '@');
        mr = cf;
      } else if (slugSpec.indexOf('@') >= 0) {
        let two = slugSpec.split('@');
        cf = two[0];
        mr = two.length > 1 ? two[1] : '';
      } else {
        cf = slugSpec;
      }

      let pop = 0;
      if (hasRanks && i - 1 < ranks.length) {
        let v = parseInt(ranks[i - 1], 10);
        pop = Number.isNaN(v) ? 0 : v;
      }

      let chineseName = '';
      if (seg.length >= 2) {
        chineseName = seg[seg.length - 1];
        if (chineseName.indexOf('*') >= 0) {
          let base = cf.length > 0 ? cf : mr;
          let expanded = capitalizeWords(base.replace(/-/g, ' '));
          chineseName = chineseName.replace(/\*/g, ' (' + expanded + ')');
        }
      }

      entries.push({
        curseforgeSlug: cf,
        modrinthSlug: mr,
        chineseName,
        // 仅主库（hasRanks）的行号 = 真实 mcmod class id；补充库无法获知真实 id，置 0
        // （避免与主库 class id 撞号 → 错误的 mcmod 链接 / 错误的跨源折叠）。
        id: hasRanks ? i : 0,
        popularity: pop,
      });
    }
  }
  return entries;
}

// ============================================================
//  中文模糊搜索（移植 PCL ModBase.Search / SearchSimilarity）
// ============================================================

/** 取首个分隔符之前的子串；无分隔符则返回整串。 */
function beforeFirst(s: string, sep: string): string {
  let i = s.indexOf(sep);
  return i < 0 ? s : s.substring(0, i);
}
/** 取首个分隔符之后的子串；无分隔符则返回空串。 */
function afterFirst(s: string, sep: string): string {
  let i = s.indexOf(sep);
  return i < 0 ? '' : s.substring(i + sep.length);
}
/** 取最后一个分隔符之后的子串；无分隔符则返回整串。 */
function afterLast(s: string, sep: string): string {
  let i = s.lastIndexOf(sep);
  return i < 0 ? s : s.substring(i + sep.length);
}
/** 去掉结尾连续的、属于 chars 的任意字符。 */
function trimEndChars(s: string, chars: string): string {
  let end = s.length;
  while (end > 0 && chars.indexOf(s.charAt(end - 1)) >= 0) end--;
  return s.substring(0, end);
}
/** 去掉开头连续的、属于 chars 的任意字符。 */
function trimStartChars(s: string, chars: string): string {
  let start = 0;
  while (start < s.length && chars.indexOf(s.charAt(start)) >= 0) start++;
  return s.substring(start);
}
/** 去掉字符串里所有空格。 */
function stripSpaces(s: string): string {
  return s.split(' ').join('');
}

/**
 * 单段文本相似度（移植 PCL SearchSimilarity）：基于"贪心最长公共子串多次抽取"，
 * 按命中长度指数加成 + 位置加成，最后按源长度归一。返回值越大越相似（非 [0,1] 归一）。
 */
export function searchSimilarity(source: string, query: string): number {
  if (source.length === 0 || query.length === 0) return 0;
  let q = stripSpaces(query.toLowerCase());
  let queryLength = q.length;
  if (queryLength === 0) return 0;
  // 源转成可变字符数组（命中片段会被移除，模拟 PCL 的 StringBuilder.Remove）
  let arr: string[] = [];
  let srcNorm = stripSpaces(source.toLowerCase());
  let sourceLength = srcNorm.length;
  for (let i = 0; i < srcNorm.length; i++) arr.push(srcNorm.charAt(i));

  let qp = 0;
  let lenSum = 0;
  while (qp < queryLength) {
    let sp = 0;
    let lenMax = 0;
    let spMax = 0;
    let currentSourceLength = arr.length;
    while (sp < currentSourceLength) {
      let len = 0;
      while ((qp + len) < queryLength && (sp + len) < currentSourceLength
             && arr[sp + len] === q.charAt(qp + len)) {
        len++;
      }
      if (len > lenMax) { lenMax = len; spMax = sp; }
      sp += len > 0 ? len : 1;
    }
    if (lenMax > 0) {
      arr.splice(spMax, lenMax);
      let incWeight = Math.pow(1.4, 3 + lenMax) - 3.6;
      incWeight *= 1 + 0.3 * Math.max(0, 3 - Math.abs(qp - spMax));
      lenSum += incWeight;
    }
    qp += lenMax > 0 ? lenMax : 1;
  }
  return (lenSum / queryLength) * (3 / Math.sqrt(sourceLength + 15))
    * (queryLength <= 2 ? (3 - queryLength) : 1);
}

/** 搜索文本源：一组别名（内部取相似度最高者）+ 权重。 */
interface WeightedSource {
  aliases: string[];
  weight: number;
}

/** 多段加权相似度（对每个源取其别名最高相似度 × 权重，再按总权重归一）。 */
function searchSimilarityWeighted(sources: WeightedSource[], query: string): number {
  let total = 0;
  let sum = 0;
  for (let p of sources) {
    if (p.aliases.length > 0) {
      let best = 0;
      for (let a of p.aliases) {
        let s = searchSimilarity(a, query);
        if (s > best) best = s;
      }
      sum += best * p.weight;
    }
    total += p.weight;
  }
  return total > 0 ? sum / total : 0;
}

/** 一个可搜索的 wiki 条目（含预构建的加权文本源 + 本次搜索算出的分数）。 */
interface WikiSearchEntry {
  entry: ModTranslationEntry;
  sources: WeightedSource[];
  similarity: number;
  absoluteRight: boolean;
}

/**
 * 多段加权模糊搜索（移植 PCL Search）。返回按"完全匹配优先、其次相似度降序"排序的候选，
 * 完全匹配项全部保留，模糊项最多 maxBlur 个且相似度须 ≥ minSim。
 */
function runFuzzySearch(entries: WikiSearchEntry[], query: string,
  maxBlur: number, minSim: number): WikiSearchEntry[] {
  if (entries.length === 0) return [];
  let queryParts: string[] = query.toLowerCase().split(' ').filter((x: string) => x.length > 0);
  let candidates: WikiSearchEntry[] = [];
  for (let e of entries) {
    e.similarity = searchSimilarityWeighted(e.sources, query);
    // 完全匹配：按空格分割的每一段都能在某个别名（去空格）里被包含
    e.absoluteRight = queryParts.length > 0 && queryParts.every((qp: string) =>
      e.sources.some((src: WeightedSource) => src.aliases.some((a: string) =>
        stripSpaces(a.toLowerCase()).indexOf(qp) >= 0)));
    if (e.absoluteRight || e.similarity >= minSim) candidates.push(e);
  }
  candidates.sort((a: WikiSearchEntry, b: WikiSearchEntry): number => {
    if (a.absoluteRight !== b.absoluteRight) return a.absoluteRight ? -1 : 1;
    return b.similarity - a.similarity;
  });
  let result: WikiSearchEntry[] = [];
  let blur = 0;
  for (let e of candidates) {
    if (e.absoluteRight) {
      result.push(e);
    } else {
      if (blur === maxBlur) break;
      result.push(e);
      blur++;
    }
  }
  return result;
}

/** 英文关键词提取时剔除的常见词（loader 名 / 冠词等）。 */
const EXTRACT_STOPWORDS: string[] = ['the', 'of', 'mod', 'and', 'forge', 'fabric', 'for', 'quilt', 'neoforge'];

/**
 * 从一个 wiki 条目提取干净的英文候选词（移植 PCL ExtractWords）：
 * 来源 = 对应源 slug（-/→空格）+ 中文名括号里的英文名；清洗后剔除停用词/数字/单字，
 * 再去掉"可由其他词拼接而成"的冗余词（如 enderio → 只留 ender / io）。
 */
function extractWords(entry: ModTranslationEntry, source: ModSource): string[] {
  let candidates: string[] = [];
  if (source === ModSource.CURSEFORGE && entry.curseforgeSlug.length > 0) {
    candidates.push(entry.curseforgeSlug.split('-').join(' ').split('/').join(' '));
  }
  if (source === ModSource.MODRINTH && entry.modrinthSlug.length > 0) {
    candidates.push(entry.modrinthSlug.split('-').join(' ').split('/').join(' '));
  }
  // 中文名里的英文段：AfterLast(" (") → 去尾 ") " → BeforeFirst(" - ") → 清标点
  let paren = afterLast(entry.chineseName, ' (');
  paren = trimEndChars(paren, ') ');
  paren = beforeFirst(paren, ' - ');
  paren = paren.split('-').join(' ').split('/').join(' ').split(':').join(' ')
    .split('(').join(' ').split(')').join('');
  candidates.push(paren);

  let words: string[] = [];
  let seen: Set<string> = new Set<string>();
  for (let c of candidates) {
    for (let w of c.split(' ')) {
      let cleaned = trimStartChars(w, '{[(');
      cleaned = trimEndChars(cleaned, '}])').toLowerCase();
      if (cleaned.length <= 1) continue;
      if (EXTRACT_STOPWORDS.indexOf(cleaned) >= 0) continue;
      let num = parseFloat(cleaned);
      if (!Number.isNaN(num) && num > 0) continue;
      if (seen.has(cleaned)) continue;
      seen.add(cleaned);
      words.push(cleaned);
    }
  }
  // 去掉"可由其他词拼接而成"的词
  let canForm = (s: string): boolean => {
    if (words.indexOf(s) >= 0) return true;
    for (let c of words) {
      if (s.length > c.length && s.startsWith(c) && canForm(s.substring(c.length))) return true;
    }
    return false;
  };
  return words.filter((w: string) => !words.some((c: string) =>
    c.length < w.length && w.startsWith(c) && canForm(w.substring(c.length))));
}

/**
 * 中文搜索解析结果：给 Modrinth / CurseForge 各自的英文关键词，
 * 以及 Modrinth 可直接按 slug 批量拉取的工程列表（保证命中的 mod 一定出现）。
 */
export interface ChineseSearchResolution {
  /** CurseForge 关键词（多词，可空）。 */
  cfKeyword: string;
  /** Modrinth 关键词（单词，可空）。 */
  mrKeyword: string;
  /** Modrinth 直取 slug 列表（最多 100，可空）。 */
  mrSlugs: string[];
}

// ============================================================
//  ModTranslationStore
// ============================================================

/**
 * AMCL 译名 / 中文搜索库。线程内单例，由 UI 层加载**单一**数据文件后构造一次，注入 ModSourceRouter。
 *
 * 单文件设计：注释（含格式说明 + 自定义条目）与数据同处一个 `moddata-amcl.txt`。
 * 解析器会先剔除 `#` 注释行再编号，故注释不影响数据行的 mcmod class id / 人气对齐。
 * 同 slug 多次出现时**后写覆盖先写**（要覆盖某条，把自定义行写在该 mod 原行之后即可）。
 */
export class ModTranslationStore {
  private cf_: Map<string, ModTranslationEntry> = new Map<string, ModTranslationEntry>();
  private mr_: Map<string, ModTranslationEntry> = new Map<string, ModTranslationEntry>();
  private entries_: ModTranslationEntry[];

  constructor(entries: ModTranslationEntry[]) {
    this.entries_ = entries;
    for (let e of entries) {
      // **精确**键（仅小写化，不做 normalizeSlug 模糊化）：译名/双源映射必须精确，
      // 否则 "X-fabric" 会误命中 "X"、不同 mod 的 slug 也可能被剥成同一 key。
      if (e.curseforgeSlug.length > 0) {
        this.cf_.set(e.curseforgeSlug.toLowerCase(), e);
      }
      if (e.modrinthSlug.length > 0) {
        this.mr_.set(e.modrinthSlug.toLowerCase(), e);
      }
    }
  }

  /**
   * 便利构造：从单一 AMCL 译名库文本构造。
   * @param hasRanks  主库（moddata-amcl.txt）末行是人气排名 → true；
   *                  整合包库（modpackdata-amcl.txt）无排名行 → false。
   */
  static fromText(text: string, hasRanks: boolean = true): ModTranslationStore {
    return new ModTranslationStore(parseModData(text, hasRanks));
  }

  /** 条目总数（调试 / 健康检查用） */
  size(): number {
    return this.entries_.length;
  }

  /**
   * 按来源 + slug **精确**反查条目；未命中返回 null。
   *
   * 关键：**只在对应源的表里查，绝不跨源兜底**。Modrinth 工程的 slug 只能匹配
   * 库里登记的 Modrinth slug，CurseForge 同理。曾经的"跨源兜底"会让 CF 工程的 slug
   * 误命中某个**不同 mod** 的 Modrinth slug（如 CF 某 mod slug 恰为 "iris"，被误判成
   * Iris Shaders），导致 wikiId / 双源 alt 解析到别的模组。
   */
  lookup(source: ModSource, slug: string): ModTranslationEntry | null {
    if (slug.length === 0) return null;
    let key = slug.toLowerCase();
    let m = source === ModSource.CURSEFORGE ? this.cf_ : this.mr_;
    let hit = m.get(key);
    return hit !== undefined ? hit : null;
  }

  /**
   * 取中文展示名：命中且有中文译名 → 中文名；否则回退 rawName。
   */
  translatedName(source: ModSource, slug: string, rawName: string): string {
    let e = this.lookup(source, slug);
    if (e !== null && e.chineseName.length > 0) return e.chineseName;
    return rawName;
  }

  /**
   * 给 RemoteProject 写入 chineseName / wikiId（就地修改）。
   * 由 ModSourceRouter 在 search 拿到结果后统一调用。
   */
  enrich(p: RemoteProject): void {
    let e = this.lookup(p.source, p.slug);
    if (e !== null) {
      p.wikiId = e.id;
      if (e.chineseName.length > 0) p.chineseName = e.chineseName;
      if (e.curseforgeSlug.length > 0) p.cfSlug = e.curseforgeSlug;
      if (e.modrinthSlug.length > 0) p.mrSlug = e.modrinthSlug;
      // 跨源可用性：mcmod 库同时登记了两源 slug → 标记"另一源存在"。
      // merge 已基于本次搜索结果设过 altSource（带真实 altId）则不覆盖，保留更精确的 id。
      // 这里仅在 merge 未命中时补一个"slug-only"的 alt（浏览模式下两源 top 榜不重叠，
      // 但 Sodium/Fabric API 这类热门 mod 在库里两源都有，据此仍能显示双源 + 按源下载）。
      if (p.altSource === undefined) {
        if (p.source === ModSource.MODRINTH && e.curseforgeSlug.length > 0) {
          p.altSource = ModSource.CURSEFORGE;
          p.altSlug = e.curseforgeSlug;
        } else if (p.source === ModSource.CURSEFORGE && e.modrinthSlug.length > 0) {
          p.altSource = ModSource.MODRINTH;
          p.altSlug = e.modrinthSlug;
        }
      }
    }
  }

  /**
   * 把"中文搜索词"解析为可投喂 Modrinth / CurseForge 的英文关键词串。
   *
   * 策略：
   *   1) 在所有条目的中文名里找包含搜索词（或被搜索词包含）的条目；
   *   2) 完全相等优先，其次"中文名含搜索词"，再按人气排名取最高；
   *   3) 用命中条目的 slug（去连字符）作为英文关键词。
   *
   * 未命中返回空串（调用方据此走"无结果，请尝试英文名"提示）。
   */
  resolveChineseQuery(query: string): string {
    let q = query.trim().toLowerCase();
    if (q.length === 0) return '';

    let best: ModTranslationEntry | null = null;
    let bestScore = -1;
    for (let e of this.entries_) {
      if (e.chineseName.length === 0) continue;
      // 中文名常含英文括号部分，取括号前的纯中文别名段做匹配
      let cn = e.chineseName.toLowerCase();
      let cnAlias = cn;
      let parenIdx = cnAlias.indexOf(' (');
      if (parenIdx >= 0) cnAlias = cnAlias.substring(0, parenIdx);

      let score = -1;
      if (cnAlias === q) {
        score = 3.0;
      } else if (cnAlias.indexOf(q) >= 0) {
        // 越短的中文名被命中，匹配越精确
        score = 2.0 + q.length / Math.max(cnAlias.length, 1);
      } else if (q.indexOf(cnAlias) >= 0 && cnAlias.length >= 2) {
        score = 1.0;
      }
      if (score < 0) continue;
      // 人气作为同分时的细微加权（归一到 [0,1) 量级，不喧宾夺主）
      score += Math.min(e.popularity, 100000) / 100000;
      if (score > bestScore) {
        bestScore = score;
        best = e;
      }
    }

    if (best === null) return '';
    let slug = best.curseforgeSlug.length > 0 ? best.curseforgeSlug : best.modrinthSlug;
    return slug.replace(/-/g, ' ').trim();
  }

  // ----------------------------------------------------------
  //  中文模糊搜索（PCL 同款：多候选 + 按 slug 直取 + 关键词提取）
  // ----------------------------------------------------------

  /** 预构建的可搜索条目（懒构建 + 缓存，避免每次搜索重建）。 */
  private cfSearchEntries_: WikiSearchEntry[] | null = null;
  private mrSearchEntries_: WikiSearchEntry[] | null = null;

  /** 构建某源（CurseForge / Modrinth）的可搜索条目：只含有该源 slug 且有中文名的条目。 */
  private buildSearchEntries(forCf: boolean): WikiSearchEntry[] {
    let out: WikiSearchEntry[] = [];
    for (let e of this.entries_) {
      let slug = forCf ? e.curseforgeSlug : e.modrinthSlug;
      if (slug.length === 0 || e.chineseName.length === 0) continue;
      // 主源：中文名括号前的部分，按 '/' 拆成多别名（权重 1）
      let aliasPart = beforeFirst(e.chineseName, ' (');
      let aliases: string[] = aliasPart.split('/').map((x: string) => x.trim())
        .filter((x: string) => x.length > 0);
      if (aliases.length === 0) aliases = [aliasPart];
      // 次源：英文名 + slug（权重 0.5），让用户输入部分英文也能命中
      let engPart = afterFirst(e.chineseName, ' (') + slug;
      let sources: WeightedSource[] = [
        { aliases: aliases, weight: 1 },
        { aliases: [engPart], weight: 0.5 },
      ];
      out.push({ entry: e, sources: sources, similarity: 0, absoluteRight: false });
    }
    return out;
  }

  /**
   * 把中文搜索词解析为可投喂两源的英文关键词 + Modrinth 直取 slug 列表。
   *
   * - CurseForge：选最佳目标（完全匹配集/最高相似集里最热门的一个），提取干净英文多词。
   * - Modrinth：跨候选按"相似度 × 人气"给英文词累加权重取最高者作关键词；并收集匹配到的
   *   slug（最多 100）供调用方 `getProjectsByIds` 直取（不依赖源的中文/文本分词）。
   *
   * 全部未命中时三个字段均为空，调用方据此提示"请尝试英文名"。
   */
  resolveChineseSearch(query: string): ChineseSearchResolution {
    let res: ChineseSearchResolution = { cfKeyword: '', mrKeyword: '', mrSlugs: [] };
    let q = query.trim().toLowerCase();
    if (q.length === 0) return res;

    // CurseForge：单目标 → 多词关键词
    if (this.cfSearchEntries_ === null) this.cfSearchEntries_ = this.buildSearchEntries(true);
    let cfResults = runFuzzySearch(this.cfSearchEntries_, q, 100, 0.25);
    if (cfResults.length > 0) {
      let pool: WikiSearchEntry[];
      if (cfResults[0].absoluteRight) {
        pool = cfResults.filter((r: WikiSearchEntry) => r.absoluteRight);
      } else {
        let maxSim = cfResults[0].similarity;
        for (let r of cfResults) if (r.similarity > maxSim) maxSim = r.similarity;
        pool = cfResults.filter((r: WikiSearchEntry) => r.similarity === maxSim);
      }
      let target = pool[0];
      for (let r of pool) if (r.entry.popularity > target.entry.popularity) target = r;
      res.cfKeyword = extractWords(target.entry, ModSource.CURSEFORGE).join(' ');
    }

    // Modrinth：词权重取最优关键词 + 收集直取 slug
    if (this.mrSearchEntries_ === null) this.mrSearchEntries_ = this.buildSearchEntries(false);
    let mrResults = runFuzzySearch(this.mrSearchEntries_, q, 100, 0.25);
    if (mrResults.length > 0) {
      let weights: Map<string, number> = new Map<string, number>();
      for (let r of mrResults) {
        let exact = r.sources.some((s: WeightedSource) =>
          s.aliases.some((a: string) => a.toLowerCase() === q));
        let sim = exact ? 1000 : r.similarity;
        // 人气为 0 时给一个下限 1，避免所有词权重都为 0 而丢失关键词
        let pop = r.entry.popularity > 0 ? r.entry.popularity : 1;
        for (let w of extractWords(r.entry, ModSource.MODRINTH)) {
          let cur = weights.has(w) ? weights.get(w)! : 0;
          weights.set(w, cur + sim * pop);
        }
      }
      let bestWord = '';
      let bestVal = -1;
      weights.forEach((v: number, k: string) => {
        if (v > bestVal) { bestVal = v; bestWord = k; }
      });
      res.mrKeyword = bestWord;
      let slugs: string[] = [];
      for (let r of mrResults) {
        if (r.entry.modrinthSlug.length > 0) slugs.push(r.entry.modrinthSlug);
        if (slugs.length >= 100) break;
      }
      res.mrSlugs = slugs;
    }
    return res;
  }
}
