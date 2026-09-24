#!/usr/bin/env node
// scripts/check-log-domains.mjs
//
// 日志系统重构 · P4「域注册表」门禁。
//
// 管一件事：**tag 必须是被登记的，不能是随手取的字符串。**
//
// 背景（方案 §一）：真机 `amcl_launcher.log` 里有 29 个 distinct tag，全部是各调用点
// 自由取的字符串，没有任何注册表。后果有两条：
//   1. 没法按模块设策略（级别、份额上限）—— 策略要有一个稳定的键才挂得上去；
//   2. 「谁在刷屏」只能靠正则事后统计，而不是查一次表。
//
// ⭐ **刻意不改调用点。** 早先设想是把 tag 换成 `(domain, tag)` 二元组，那要动 900+ 处。
// P2 已经教过一次同样的道理（合并根本不需要事件类别，施工记录 §S05.1）：
// **能用一张映射表解决的，不要做成一次全局重构。**
// tag 字面量原样保留，注册表负责 tag → domain 的映射 —— 三条收益一条不少，改动面接近零。
//
// 用法：
//   node scripts/check-log-domains.mjs              # 校验
//   node scripts/check-log-domains.mjs --inventory  # 列出源码里实际存在的 tag（建表用）
//   node scripts/test-check-log-domains.mjs

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
const REGISTRY_PATH = 'config/log-domains.json';

const SOURCE_ROOTS = [
  'account', 'commons', 'entry', 'feature_core', 'feature_system',
  'gamecontrol', 'launch', 'mods', 'update',
];
const SKIP_DIRS = new Set([
  'build', '.hvigor', '.cxx', 'oh_modules', 'node_modules',
  'test', '.test', 'ohosTest', 'mock', '.preview',
  // vendored 第三方与诊断构建专用目录不参与域治理
  'openal', 'openal-soft', 'tests',
]);

/**
 * tag 的声明形态。
 *
 * ⚠️ **本仓有三种约定并存**，这是 2026-09-06 用真机产物交叉验证才发现的（施工记录 §S08.2）：
 *   1. `const TAG = 'Literal'`                —— 最常见
 *   2. `const TAG = LogTags.X`                —— commons/common/LogTags.ets 是一份
 *                                                **2026-05-10 就建好的部分注册表**，但没铺开
 *   3. `AppLogger.info('Literal', …)`          —— 内联字面量，连常量都没有
 *
 * 抽取器第一版只认第 1 种，于是「155 个 tag 全部有归属」这个绿是**假的** ——
 * 真机日志里的 `McGamePage` / `EntryAbility` / `LWJGL` / `MG_RENDER_PROBE` 它一个都没看见。
 * 这正是「源码扫描类判据静默恒绿」的实例，而抓住它的是**运行时产物**，不是另一条静态规则。
 * ⇒ 判据：静态门禁至少要与一份真实产物对过一次账。
 */
const TAG_DECLS = [
  /const\s+TAG\s*(?::\s*string\s*)?=\s*'([^']+)'/g,           // ① ArkTS: const TAG = 'X'
  /const\s+TAG\s*(?::\s*string\s*)?=\s*"([^"]+)"/g,
  /#define\s+LOG_TAG\s+"([^"]+)"/g,                            // native: #define LOG_TAG "X"
  /static\s+const\s+char\s*\*\s*(?:const\s+)?LOG_TAG\s*=\s*"([^"]+)"/g,
  /constexpr\s+const\s+char\s*\*\s*LOG_TAG\s*=\s*"([^"]+)"/g,
  // ② LogTags.ets 的集中常量：static readonly NAME: string = 'X'
  /static\s+readonly\s+[A-Z0-9_]+\s*:\s*string\s*=\s*'([^']+)'/g,
];

/** ③ 内联字面量：直接把 tag 写在调用里。 */
const INLINE_TAG_CALLS = [
  /\bAppLogger\.(?:debug|info|warn|error|fatal)\s*\(\s*'([^']+)'/g,
  /\bAppLogger\.(?:debug|info|warn|error|fatal)\s*\(\s*"([^"]+)"/g,
  // 活动绑定 logger 同样持久化；不能因从静态门面迁到显式 scope 就漏掉内联 tag。
  /\bthis\.(?:alog|launchLogger_\(\))\.(?:debug|info|warn|error|fatal)\s*\(\s*['"]([^'"]+)['"]/g,
  /\bAMCL_LOG_[DIWEF]\s*\(\s*"([^"]+)"/g,
  // 显式活动归属和独立 DSO 桥也是正式持久化入口，不能漏掉结构化环境观测的 tag。
  /\bamclLogWriteFor\s*\(\s*[^,\n]+,\s*[^,\n]+,\s*"([^"]+)"/g,
  /\bamclExternalLogWrite\s*\(\s*\d+\s*,\s*"([^"]+)"/g,
];

function relPath(abs) {
  return path.relative(ROOT, abs).replace(/\\/g, '/');
}

function walk(dir, out) {
  let ents;
  try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const ent of ents) {
    if (ent.isDirectory()) {
      if (SKIP_DIRS.has(ent.name)) continue;
      walk(path.join(dir, ent.name), out);
    } else if (ent.isFile() && /\.(ets|cpp|h|hpp|c|cc)$/.test(ent.name)) {
      out.push(path.join(dir, ent.name));
    }
  }
}

export function readSources() {
  const files = [];
  for (const root of SOURCE_ROOTS) {
    const abs = path.join(ROOT, root);
    if (fs.existsSync(abs)) walk(abs, files);
  }
  const texts = new Map();
  for (const f of files) texts.set(relPath(f), fs.readFileSync(f, 'utf8'));
  return {
    registryText: fs.readFileSync(path.join(ROOT, REGISTRY_PATH), 'utf8'),
    texts,
  };
}

/** 集中常量表所在的文件。②号约定只在这里成立。 */
const LOG_TAGS_FILE = 'commons/src/main/ets/common/LogTags.ets';

/**
 * 去掉注释行再匹配。
 *
 * ⚠️ 这不是洁癖：`amcl_log.h` 的文件头注释里写着用法示例
 * `AMCL_LOG_I("MODULE", "message %d", value);`，不去注释就会把 `MODULE`
 * 当成一个真实存在的 tag 要求登记 —— 门禁因为一段**文档**而红，
 * 那是最容易让人把门禁摘掉的那种假阳性。
 */
function stripCommentLines(text) {
  return text.split(/\r?\n/)
    .filter((l) => {
      const t = l.trim();
      return !(t.startsWith('//') || t.startsWith('*') || t.startsWith('/*'));
    })
    .join('\n');
}

/**
 * 从一份源码里抽出它用到的 tag（三种约定全覆盖）。
 *
 * @param rel 文件的仓内相对路径。②号约定（LogTags.ets 的 `static readonly`）
 *            **只在那一个文件里生效** —— 否则会把 `DownloadHistory.ets` 里的
 *            活动类目常量（`download` / `launch` / `repair`）也当成日志 tag。
 *            第一版就是这么误报的。
 */
export function findTags(text, rel = '') {
  const src = stripCommentLines(text);
  const out = new Set();
  const isLogTagsFile = rel.endsWith(LOG_TAGS_FILE) || rel.endsWith('LogTags.ets');

  for (let i = 0; i < TAG_DECLS.length; i++) {
    // 最后一条是 LogTags.ets 专属
    if (i === TAG_DECLS.length - 1 && !isLogTagsFile) continue;
    const re = TAG_DECLS[i];
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(src)) !== null) out.add(m[1]);
  }
  for (const re of INLINE_TAG_CALLS) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(src)) !== null) out.add(m[1]);
  }
  return [...out];
}

/** 只找内联字面量形态的 tag —— 用于报告「有多少 tag 连常量都没有」。 */
export function findInlineTags(text) {
  const src = stripCommentLines(text);
  const out = new Set();
  for (const re of INLINE_TAG_CALLS) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(src)) !== null) out.add(m[1]);
  }
  return [...out];
}

/** 全仓 tag 存量：tag → 声明它的文件列表。 */
export function inventory(texts) {
  const map = new Map();
  for (const [rel, text] of texts) {
    for (const t of findTags(text, rel)) {
      if (!map.has(t)) map.set(t, []);
      map.get(t).push(rel);
    }
  }
  return map;
}

export function analyze(sources) {
  const r = { ok: false, fatal: null, domains: 0, tags: 0, schema: [], unregistered: [], stale: [], positiveControl: [] };

  let doc;
  try {
    doc = JSON.parse(sources.registryText);
  } catch (e) {
    r.fatal = `${REGISTRY_PATH} 不是合法 JSON：${e.message}`;
    return r;
  }
  if (!Array.isArray(doc.domains) || doc.domains.length === 0) {
    r.fatal = `${REGISTRY_PATH} 里没解析出任何域`;
    return r;
  }
  if (!doc.tags || typeof doc.tags !== 'object') {
    r.fatal = `${REGISTRY_PATH} 缺 tags 映射`;
    return r;
  }

  const domainIds = new Set();
  for (const d of doc.domains) {
    if (!d.id) { r.schema.push('有域缺 id'); continue; }
    if (domainIds.has(d.id)) r.schema.push(`域 id 重复：${d.id}`);
    domainIds.add(d.id);
    if (!d.owner) r.schema.push(`${d.id}: 缺 owner`);
    if (!d.purpose) r.schema.push(`${d.id}: 缺 purpose —— 写不出「这个域管什么」就不该建它`);
  }
  r.domains = doc.domains.length;

  const inv = inventory(sources.texts);
  r.tags = inv.size;

  // — 阳性对照：扫不到 tag 说明抽取器坏了，那是静默恒绿
  if (inv.size === 0) {
    r.positiveControl.push('全仓一个 tag 声明都没扫到 —— 抽取器必然是坏的');
  } else {
    for (const known of ['SessionMarker', 'MC_LAUNCHER']) {
      if (!inv.has(known)) {
        r.positiveControl.push(`已知 tag ${known} 没扫到 —— 抽取器的判据失效了`);
      }
    }
  }

  // — 每个实际存在的 tag 都必须登记，且落在已声明的域里
  for (const [tag, files] of inv) {
    const dom = doc.tags[tag];
    if (dom === undefined) {
      r.unregistered.push(`${tag}（声明于 ${files[0]}${files.length > 1 ? ` 等 ${files.length} 处` : ''}）`);
      continue;
    }
    if (!domainIds.has(dom)) {
      r.schema.push(`tag ${tag} 指向未声明的域 ${dom}`);
    }
  }

  // — 反向：登记了但源码里已经不存在的 tag（重构后没清理，表会慢慢烂掉）
  // staleExempt 放的是**声明在扫描面之外、但确实会出现在真机日志里**的 tag
  // （如 tests/ 下的探针）。单列豁免名单，而不是放宽任一侧的判据。
  const exempt = new Set(Array.isArray(doc.staleExempt) ? doc.staleExempt : []);
  for (const tag of Object.keys(doc.tags)) {
    if (!inv.has(tag) && !exempt.has(tag)) r.stale.push(tag);
  }
  // 豁免名单本身也要防烂：豁免了一个源码里**确实存在**的 tag，说明名单过期了。
  for (const tag of exempt) {
    if (inv.has(tag)) {
      r.schema.push(`staleExempt 里的 ${tag} 在扫描面里已经找得到了，请把它从豁免名单删掉`);
    }
    if (doc.tags[tag] === undefined) {
      r.schema.push(`staleExempt 里的 ${tag} 没有登记域`);
    }
  }

  r.ok = r.schema.length === 0 && r.unregistered.length === 0
    && r.stale.length === 0 && r.positiveControl.length === 0;
  return r;
}

const isMain = process.argv[1]
  && path.resolve(process.argv[1]) === path.resolve(url.fileURLToPath(import.meta.url));

if (isMain) {
  const sources = readSources();

  if (process.argv.includes('--inventory')) {
    const inv = inventory(sources.texts);
    const rows = [...inv.entries()].sort((a, b) => a[0].localeCompare(b[0]));
    console.log(`源码里实际声明的 tag：${rows.length} 个\n`);
    for (const [tag, files] of rows) {
      console.log(`  ${tag.padEnd(30)} ${files[0]}${files.length > 1 ? `  (+${files.length - 1})` : ''}`);
    }
    process.exit(0);
  }

  const r = analyze(sources);
  if (r.fatal) {
    console.error(`❌ check-log-domains: ${r.fatal}`);
    process.exit(1);
  }
  const dump = (label, arr, hint) => {
    if (arr.length === 0) return;
    console.error(`\n--- ${label}（${arr.length}）---`);
    for (const x of arr) console.error(`  ${x}`);
    if (hint) console.error(`  ⇒ ${hint}`);
  };
  dump('注册表 schema', r.schema);
  dump('抽取器阳性对照', r.positiveControl);
  dump('未登记的 tag', r.unregistered,
    `把它加进 ${REGISTRY_PATH} 的 tags 映射，并归到一个已声明的域`);
  dump('已登记但源码里不存在的 tag', r.stale,
    `重构后请从 ${REGISTRY_PATH} 里删掉，否则这张表会慢慢烂成一份历史清单`);

  if (r.ok) {
    console.log(`✅ check-log-domains: ${r.domains} 个域、${r.tags} 个 tag 全部有归属`);
    process.exit(0);
  }
  console.error('\n❌ check-log-domains 未通过');
  process.exit(1);
}
