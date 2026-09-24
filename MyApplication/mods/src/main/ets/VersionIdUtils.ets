/**
 * VersionIdUtils.ets — 已装 MC 版本目录名解析（纯函数 / 0 依赖）
 *
 * 用户在 .minecraft/versions/ 下的目录名格式多样：
 *   - "1.20.4"                       原版
 *   - "1.20.4-fabric-0.16.10"        Fabric（HMCL/AMCL 推荐命名）
 *   - "fabric-loader-0.16.10-1.20.4" Fabric Loader 原始命名
 *   - "1.16.5-forge-36.2.39"         Forge（HMCL 推荐命名）
 *   - "forge-1.20.4-49.0.30"         Forge 安装器原始命名
 *   - "1.20.4-neoforge-20.4.196"     NeoForge
 *   - "1.20.4-quilt-0.27.0"          Quilt
 *   - "24w14a"                       快照
 *   - "1.21-rc1"                     候选发布
 *   - "23w13a_or_b"                  愚人节版本（含字母后缀）
 *
 * 本模块提供两个纯函数：
 *   - extractGameVersionFromId(id) → "1.20.4" / "24w14a" / "1.21-rc1"
 *   - detectLoaderFromId(id)        → 'fabric' / 'forge' / 'neoforge' / 'quilt' / ''
 *
 * 设计目标：覆盖 HMCL / PCL2 / AMCL / Modrinth Launcher / 官方启动器
 * 的常见目录命名，保证 ModBrowsePage 默认筛选条件正确。
 *
 * 创建日期：2026-05-11（P0 审查修复）
 */

import { detectMcEra, McEra } from 'commons';

// ============================================================
//  Loader 推断
// ============================================================

/**
 * 从已装版本目录名推断 loader。
 *
 * 规则（先 neoforge 后 forge，避免 'neoforge' 命中 'forge' 子串）：
 *   1. 含 'neoforge' / 'neo-forge' → 'neoforge'
 *   2. 含 'forge'                  → 'forge'
 *   3. 含 'fabric'                 → 'fabric'
 *   4. 含 'quilt'                  → 'quilt'
 *   5. 其他                         → '' （原版，调用方默认 fabric）
 *
 * 大小写不敏感。
 */
export function detectLoaderFromId(versionId: string): string {
  if (versionId.length === 0) return '';
  let lower = versionId.toLowerCase();
  if (lower.indexOf('neoforge') >= 0 || lower.indexOf('neo-forge') >= 0) return 'neoforge';
  if (lower.indexOf('forge') >= 0) return 'forge';
  if (lower.indexOf('fabric') >= 0) return 'fabric';
  if (lower.indexOf('quilt') >= 0) return 'quilt';
  return '';
}

// ============================================================
//  Loader 推断（基于 version.json 内容，纯函数）
// ============================================================

interface VersionJsonLibEntry { name?: string; }
interface VersionJsonLoaderShape { mainClass?: string; libraries?: VersionJsonLibEntry[]; }

/**
 * 从 version.json **内容**推断 loader（不靠版本名）——用于整合包 / 重命名后的自定义版本名,
 * 这类版本名里不含 loader 关键字, `detectLoaderFromId` 会误判为原版。
 *
 * 判定依据（与 LaunchProfileBuilder 同源, 以实际启动信号为准）：
 *   - mainClass 含 fabricmc / Knot          → 'fabric'
 *   - mainClass 含 quilt                     → 'quilt'
 *   - libraries 含 net.neoforged             → 'neoforge'
 *   - libraries 含 net.minecraftforge / mainClass 含 fml/modlauncher/forge → 'forge'
 *   - 否则                                    → ''（原版）
 *
 * @param jsonText versions/<id>/<id>.json 文本内容
 */
export function detectLoaderFromVersionJson(jsonText: string): string {
  let mainClass = '';
  let libNames: string[] = [];
  try {
    let obj = JSON.parse(jsonText) as VersionJsonLoaderShape;
    mainClass = (obj.mainClass !== undefined) ? obj.mainClass : '';
    let libs = obj.libraries;
    if (libs !== undefined) {
      for (let l of libs) {
        if (l.name !== undefined && l.name.length > 0) libNames.push(l.name.toLowerCase());
      }
    }
  } catch (e) {
    return '';
  }
  let mc = mainClass.toLowerCase();
  // Quilt 自己的入口同样叫 KnotClient，必须先判更具体的 Quilt 命名空间。
  // 否则会把 Quilt 实例错选成 Fabric，再用错误 loader 筛选模组与提取版本。
  if (mc.indexOf('quilt') >= 0) return 'quilt';
  if (mc.indexOf('fabricmc') >= 0 || mc.indexOf('knot') >= 0) return 'fabric';
  // neoforge / forge 现代版 mainClass 都是 cpw.mods.bootstraplauncher, 用 libraries 区分
  for (let n of libNames) {
    if (n.indexOf('net.neoforged') >= 0) return 'neoforge';
  }
  for (let n of libNames) {
    if (n.indexOf('net.minecraftforge') >= 0) return 'forge';
  }
  if (mc.indexOf('fml') >= 0 || mc.indexOf('modlauncher') >= 0 || mc.indexOf('forge') >= 0) return 'forge';
  return '';
}

// ============================================================
//  GameVersion 提取
// ============================================================

/**
 * Minecraft 数字版本号正则：
 *   1.20、1.20.4、1.20.4.1（pre-release 用）
 *   "1.21-rc1" / "1.21-pre1" 仍然取 "1.21"（mod 仓库一般按 release 索引；如需精确匹配，
 *   用户手动改输入框）
 */
const RE_MC_NUMERIC = /(\d+\.\d+(?:\.\d+)*)/;

/**
 * 快照命名：22w14a / 1.20-pre1 / 1.20-rc1
 *   - 周快照：YYwWWx[_suffix]（24w14a / 23w13a_or_b）
 *   - pre / rc：1.20-pre1 / 1.20-rc1 — 这两个其实能被 RE_MC_NUMERIC 处理，
 *     这里仅用于 fallback。
 */
const RE_MC_SNAPSHOT = /^(\d+w\d+[a-z]+(?:_[a-z]+)*)$/i;

/**
 * 从版本目录名提取 MC 游戏版本号（mod 仓库筛选 / JDK 纪元路由 / 详情页展示共用）。
 *
 * 优先级：
 *   1. 快照命名整体匹配（24w14a / 23w13a_or_b）
 *   2. `^` 开头的数字版本号（MC-first 命名，最常见且无歧义）：
 *      "1.20.4" / "1.20.4-fabric-X" / "26.1.1-fabric-X" / "1.16.5-forge-X" …
 *   3. loader 前缀命名（id 以 loader 名开头，MC 版本夹在中间/尾部）：
 *      3a. 【纪元感知消歧，首选】用 detectMcEra 判断哪些候选是真实 MC 版本
 *          （CLASSIC=1.x / YEARLY=YY.D.H）。恰好一个被识别 → 它就是答案，与位置无关。
 *      3b. 多个/零个候选都"像 MC 版本"时按 loader 命名惯例定位（见函数内注释）。
 *   4. 失败回退原字符串。
 *
 * ⚠️ 之前的 bug（2026-06）："fabric-0.19.3-26.1.1"（fabric-<loaderVer>-<mcVer> 写法）
 *   旧逻辑只特判 "fabric-loader-" 前缀，其余一律取第一个数字 → 误把 loader 版本
 *   0.19.3 当成 MC 版本。3a 的纪元感知消歧修复了它：0.19.3 是 UNKNOWN 纪元、
 *   26.1.1 是 YEARLY → 唯一被识别的就是 26.1.1。
 *
 * 单一事实源：纪元判定全部委托 McVersionUtils.detectMcEra。将来再换新纪元时
 * 只改 detectMcEra（及其 YEARLY_ERA_MIN_FIRST_SEGMENT 阈值）一处，本函数自动跟随。
 */
export function extractGameVersionFromId(versionId: string): string {
  if (versionId.length === 0) return '';

  // 1. 整体快照命名
  let snap = RE_MC_SNAPSHOT.exec(versionId);
  if (snap !== null) return snap[1];

  // 2. ^数字版本号（HMCL/AMCL 推荐命名 "1.20.4-fabric-..." / 原版 / 26.1.1-...）
  let head = /^(\d+\.\d+(?:\.\d+)*)/.exec(versionId);
  if (head !== null) return head[1];

  // 3. loader 前缀命名：先收集串里所有 \d+\.\d+(\.\d+)* 候选，再两级判定。
  let all: string[] = collectNumericVersions(versionId);
  if (all.length === 0) return versionId;

  // 3a. 纪元感知消歧（首选）：loader 版本号大多落在 UNKNOWN 纪元
  //     （Fabric loader 0.x、旧 Forge 14.x、NeoForge 20.x 首段都不是 1、也不到纪元年阈值），
  //     真实 MC 版本则是 CLASSIC（1.x）或 YEARLY（YY.D.H）。若恰好只有一个候选被
  //     detectMcEra 识别为 MC 版本，它就是答案——与它在串里的前后位置无关。
  //     例："fabric-0.19.3-26.1.1" → 0.19.3=UNKNOWN、26.1.1=YEARLY → 取 26.1.1。
  let recognized: string[] = [];
  for (let v of all) {
    if (detectMcEra(v) !== McEra.UNKNOWN) recognized.push(v);
  }
  if (recognized.length === 1) return recognized[0];

  // 3b. 多个/零个候选都"像 MC 版本"时（典型：新版 Forge 主版本号 47/49/62 首段
  //     ≥ 纪元年阈值，会和 YEARLY 撞车，无法靠纪元区分）→ 退回 loader 命名惯例：
  //       · fabric* / quilt* ："loader 在前、MC 在后" → 取最后一个候选
  //         （兼容 fabric-loader-<L>-<MC> 与 fabric-<L>-<MC> 两种写法）
  //       · forge* / neoforge*："MC 在前、loader 在后" → 取第一个候选（forge-<MC>-<L>）
  //       · 其它未知前缀          ：兜底取第一个
  let lower = versionId.toLowerCase();
  if (lower.startsWith('fabric') || lower.startsWith('quilt')) {
    return all[all.length - 1];
  }
  return all[0];
}

/** 收集字符串中所有 `\d+\.\d+(\.\d+)*` 形式的子串（用于 fallback 版本号解析）。 */
function collectNumericVersions(s: string): string[] {
  let result: string[] = [];
  let re = new RegExp(RE_MC_NUMERIC.source, 'g');
  while (true) {
    let m = re.exec(s);
    if (m === null) break;
    result.push(m[1]);
    if (m.index === re.lastIndex) re.lastIndex = re.lastIndex + 1;  // 防御零宽匹配
  }
  return result;
}

// ============================================================
//  辅助：是否快照
// ============================================================

/** 用于 UI 提示：当前选中版本是不是快照 */
export function isSnapshotVersion(versionId: string): boolean {
  if (versionId.length === 0) return false;
  if (RE_MC_SNAPSHOT.test(versionId)) return true;
  let lower = versionId.toLowerCase();
  // pre / rc / experimental / snapshot 关键字直接挂在版本号后：
  //   "1.20.4-pre1" / "1.20-rc1" / "26.2-snapshot-8" / "1.21-snapshot-1"
  // 与 classifyVersion 同一套识别规则，保持两者一致。
  if (/^\d+\.\d+(?:\.\d+)?[\-_](?:pre|rc|experimental|snapshot)/.test(lower)) return true;
  return false;
}

// ============================================================
//  版本类别（用于版本前的方块图标）
// ============================================================

/**
 * 版本"大类"，覆盖 PCL2 / HMCL 同款图标语义。
 * 顺序给到优先级：detectLoader 先（fabric/forge/quilt/neoforge 命中即定），
 * 否则按版本号 / 目录名特征推断 vanilla 子类型。
 */
export type VersionCategory =
  | 'release'      // 正式版（草方块）
  | 'snapshot'     // 快照（命令方块）
  | 'aprilfools'   // 愚人节版（金块）
  | 'old'          // 远古版（圆石）—— Beta / Alpha / 1.0~1.5
  | 'fabric'       // Fabric loader
  | 'forge'        // Forge loader
  | 'neoforge'     // NeoForge loader
  | 'quilt'        // Quilt loader

/**
 * 已知愚人节版本 id 列表（精确匹配）。
 * 来自 wiki.minecraft.net 的 April Fools 列表 + Mojang version_manifest 实际命名。
 */
const APRIL_FOOLS_IDS: Set<string> = new Set<string>([
  '15w14a',               // 2015 - Love and Hugs
  '1.rv-pre1',            // 2016 - The Trendy Update
  '3d shareware v1.34',   // 2019
  '20w14infinite',        // 2020 - Infinite Snapshot（mojang 实际写法）
  '20w14∞',               // 同上的 unicode 形式
  '22w13oneblockatatime', // 2022 - One Block at a Time
  '23w13a_or_b',          // 2023 - The Vote Update
  '24w14potato',          // 2024 - Poisonous Potato
  '25w14craftmine',       // 2025 - Craftmine
]);

/**
 * 已知愚人节版本 id 前缀（前缀匹配）。
 *   - "2.0" 版（2013）实际有 2.0_blue / 2.0_purple / 2.0_red 三色，前缀都是 "2.0"
 *   - 前缀匹配比 startsWith() 多一道"必须是完整前缀或 followed by 分隔符" 的检查，
 *     避免误把 "2.0.4" 也算进去
 */
const APRIL_FOOLS_PREFIXES: string[] = [
  '2.0_',  // 2013 红蓝紫三色
];

/**
 * 从版本 id 推断大类。
 *
 * 决策顺序：
 *   1. 愚人节版列表精确命中
 *   2. detectLoaderFromId 命中 fabric/forge/neoforge/quilt → 直接返回
 *   3. 快照命名（YYwWWx）→ snapshot
 *   4. pre/rc/experimental/snapshot 关键字后缀 → snapshot
 *      （含 "26.2-snapshot-8" 这种裸 snapshot 关键字，2026-05-23 修）
 *   5. 远古版：1.0~1.5 / b1.x / a1.x / Indev / Infdev / Classic → old
 *   6. 兜底 release
 */
export function classifyVersion(versionId: string): VersionCategory {
  if (versionId.length === 0) return 'release';
  let lower = versionId.toLowerCase().trim();

  // 1. 愚人节版（精确 id 匹配 + 前缀匹配，避免被快照规则误吞）
  if (APRIL_FOOLS_IDS.has(lower)) return 'aprilfools';
  for (let prefix of APRIL_FOOLS_PREFIXES) {
    if (lower.startsWith(prefix)) return 'aprilfools';
  }

  // 2. loader 优先 —— loader 版本不分 release/snapshot，统一显示 loader 图标
  let loader = detectLoaderFromId(versionId);
  if (loader === 'fabric')   return 'fabric';
  if (loader === 'forge')    return 'forge';
  if (loader === 'neoforge') return 'neoforge';
  if (loader === 'quilt')    return 'quilt';

  // 3. 周快照（YYwWWx 形式：24w14a / 23w45c）
  if (RE_MC_SNAPSHOT.test(lower)) return 'snapshot';

  // 4. 关键字快照命名 —— 紧跟在版本号后的 pre / rc / experimental / snapshot：
  //    "1.20.4-pre1"        老式预发布
  //    "1.21-rc1"           候选发布
  //    "26.2-snapshot-8"    Mojang 内部测试格式（裸 'snapshot' 关键字，
  //                         之前会被误判为 release → 草方块图标 bug 的根因）
  //    "1.21-snapshot-1"    同上
  //
  //  锚定 ^\d+\.\d 是为了不命中 "snapshothard-1.0" 这类伪版本名；
  //  loader 后缀（fabric/forge/...）已在第 2 步先行返回，不会落到这里。
  if (/^\d+\.\d+(?:\.\d+)?[\-_](?:pre|rc|experimental|snapshot)/.test(lower)) return 'snapshot';

  // 5. 远古版前缀
  //    Beta:   "b1.7.3" / "1.7.3 beta"
  //    Alpha:  "a1.2.6"
  //    Indev:  "in-20100110" / "indev"
  //    Infdev: "inf-20100630" / "infdev"
  //    Classic:"c0.0.23a"
  //    早期 release（1.0 ~ 1.5）也算"远古版"——视觉上统一圆石
  if (lower.startsWith('b1.') || lower.startsWith('a1.')
      || lower.startsWith('c0.') || lower.startsWith('rd-')
      || lower.indexOf('infdev') >= 0 || lower.indexOf('indev') >= 0
      || lower === 'classic' || lower === 'beta' || lower === 'alpha') {
    return 'old';
  }
  // 1.0 ~ 1.5：算"远古版"（PCL2 同样把 1.5 之前归为旧版本）
  let head = /^(\d+)\.(\d+)/.exec(lower);
  if (head !== null) {
    let major = parseInt(head[1], 10);
    let minor = parseInt(head[2], 10);
    if (major === 1 && minor <= 5) return 'old';
    if (major === 0) return 'old';
  }

  // 6. 兜底：现代正式版
  return 'release';
}
