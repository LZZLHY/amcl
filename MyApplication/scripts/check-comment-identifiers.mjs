#!/usr/bin/env node
// scripts/check-comment-identifiers.mjs
//
// ============================ 它做什么 ============================
//
// 机械穷举**类型 A** 缺陷：注释里用现在时提到一个标识符，而那个标识符在代码里不存在。
//
// 这是 `docs/refactor/实体键鼠输入架构重构计划.md` 反复付学费的那一类。最贵的一次
// （§51.1）：`GameControls.isControlVisible` 的头注释声称自己包含 capability 判定，
// 而 `shouldHideForInputMode` / `forceShowAll` 两个标识符**两个月前就随功能一起删了**。
// 那段注释被当成规格读了一遍，变成一条错误的真机复测判据，用户照着测了一整轮才发现。
//
// 此前八轮的类型 A 排查**全部是从已知事故反推**的 —— 先出问题，再回去找注释。
// 覆盖因此是抽样的。本脚本把它变成机械全量：每一个反引号包起来的标识符都要在代码里
// 找得到，找不到就报出来。
//
// ============================ 为什么只看反引号 ============================
//
// 本仓注释有一条一致的约定：凡是指代码里的东西就写成 `Foo` / `foo()` / `A::b`。
// 只取反引号内的 token，精度高到可以当门禁用；不做自然语言分词，那会产出一堆噪声，
// 而"一个会误报的门禁"下一轮就会被当噪声忽略（规范 §八.5 的教训）。
//
// ============================ 刻意的排除：描述历史的注释 ============================
//
// 规范 §52.3 的排除规则：明确写着"曾有 / 已删除 / ⚠️ 这里曾"的注释是**刻意保留**的墓碑，
// 不算命中。判据是**是否在用现在时描述一个不存在的东西**。
// 本脚本据此把同一注释块里带历史标记的命中降级为 advisory，不作为硬错 ——
// 方向刻意选成"宁可漏报也不误报"，理由同上。
//
// ============================ 允许清单 ============================
//
// `scripts/comment-identifier-allowlist.json` 收录**确实不在本仓**的外部标识符
// （官方 API、SDK 宏、GLFW 常量、第三方符号）。每条必须写 why —— 否则下一个人无法判断
// 它是"外部的"还是"我们删掉忘了改注释的"，允许清单本身就会变成新的假注释。
//
// 用法：
//   node scripts/check-comment-identifiers.mjs            # 硬错 → exit 1
//   node scripts/check-comment-identifiers.mjs --json     # 机器可读
//   node scripts/check-comment-identifiers.mjs --advisory # 连 advisory 一起打印

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');

// 扫注释的文件集 = 输入子系统。刻意不扫全仓：本脚本的价值来自"注释被当规格读"的
// 那些地方，而输入链路是本项目唯一有过这种代价的地方。扩大范围之前先想清楚谁会读它。
const COMMENT_ROOTS = [
  'entry/src/main/cpp/input',
  'entry/src/main/cpp/platform',
  'entry/src/main/cpp/napi',
  'entry/src/main/cpp/glfw',
  'entry/src/main/cpp/tests/host',
  'gamecontrol/src/main/ets',
];
const COMMENT_FILES = [
  'entry/src/main/cpp/types/libentry/index.d.ts',
  'entry/src/main/ets/pages/McGamePage.ets',
  'entry/src/main/ets/components/GameControls.ets',
  'entry/src/main/ets/components/ChatInputBridge.ets',
  'entry/src/main/ets/components/LayoutEditor.ets',
];

// 符号宇宙 = 这些位置的**非注释**代码 token。比注释集合宽：注释可以合法地提到
// 别处的符号（ArkTS 注释提 native 符号是常态，反过来也是）。
const UNIVERSE_ROOTS = [
  'entry/src/main/cpp',
  'entry/src/main/ets',
  'gamecontrol/src/main/ets',
  'feature_core/src/main/ets',
  'feature_system/src/main/ets',
  'account/src/main/ets',
  'update/src/main/ets',
  'mods/src/main/ets',
  'launch/src/main/ets',
];
const UNIVERSE_FILES = [
  'entry/obfuscation-rules.txt',
  'entry/src/main/module.json5',
  'gamecontrol/Index.ets',
];

const CODE_EXT = new Set([
  '.h', '.hpp', '.c', '.cpp', '.cc',
  '.ets', '.ts', '.d.ts',
  '.cmake', '.txt', '.json5', '.mjs', '.js',
]);
const SKIP_DIRS = new Set([
  '.git', 'node_modules', 'build', 'oh_modules', '.hvigor', '.idea',
  'build-ohos-verify',
]);

// 历史标记：同一注释块里出现任一个，命中降级为 advisory（§52.3 排除规则）。
const HISTORICAL_MARKERS = [
  '曾', '此前', '已删', '删掉', '原本', '旧实现', '旧版', '过去', '历史遗留', '不再',
  'used to', 'no longer', 'previously', 'formerly', 'former', 'historical',
  'has been removed', 'was removed', 'were removed', 'deleted', 'obsolete',
  'renamed', 'replaced by', 'superseded',
];

const ALLOWLIST_PATH = 'scripts/comment-identifier-allowlist.json';

function walk(dir, out) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const entry of entries) {
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name)) continue;
      walk(path.join(dir, entry.name), out);
    } else if (entry.isFile()) {
      const ext = path.extname(entry.name);
      if (CODE_EXT.has(ext)) out.push(path.join(dir, entry.name));
    }
  }
  return out;
}

function resolveFileSet(roots, files) {
  const out = [];
  for (const rel of roots) walk(path.join(ROOT, rel), out);
  for (const rel of files) {
    const full = path.join(ROOT, rel);
    if (fs.existsSync(full)) out.push(full);
  }
  return [...new Set(out)];
}

// 导出扫描面，供 `check-comment-layering.mjs` 复用。**刻意不在那边再抄一份清单** ——
// 两份文件集必然漂移，而"某个文件被一道门禁扫、被另一道漏掉"是静默失效（规范 §4.0：
// 能消掉镜像就不要只声明镜像）。
export function resolveCommentScopeFiles() {
  return resolveFileSet(COMMENT_ROOTS, COMMENT_FILES);
}

// 一次遍历同时切出注释与代码。必须自己走状态机而不是用正则：字符串字面量里的 `//`
// 不是注释，而把它当注释会让符号宇宙缺掉真实存在的 token（假命中的主要来源）。
// `hashComments` 必须对 .txt / .cmake / .json5 打开。不打开的后果是实测过的：
// `entry/obfuscation-rules.txt` 的 `#` 注释里记着「clearButtons / clearJoystick /
// registerButton / registerJoystick 已随…删除」，于是**四个已删除的 NAPI 名**被当成
// 代码 token 注入符号宇宙，任何提到它们的假注释都会被判为"解析成功"。
// 一个把已删符号当成存在的宇宙，正好让本门禁在最该报警的地方沉默。
export function splitCommentsAndCode(text, { hashComments = false } = {}) {
  const comments = [];   // { line, text }
  const codeChunks = [];
  const literalChunks = [];
  let line = 1;
  let i = 0;
  const n = text.length;
  let codeStart = 0;

  const pushCode = (end) => {
    if (end > codeStart) codeChunks.push(text.slice(codeStart, end));
  };

  while (i < n) {
    const c = text[i];
    const next = text[i + 1];
    if (c === '\n') { line += 1; i += 1; continue; }
    // `#` 行注释（obfuscation-rules.txt / CMake / json5）
    if (hashComments && c === '#') {
      pushCode(i);
      const stop = text.indexOf('\n', i);
      const end = stop === -1 ? n : stop;
      comments.push({ line, text: text.slice(i + 1, end) });
      i = end;
      codeStart = i;
      continue;
    }
    // 行注释
    if (c === '/' && next === '/') {
      pushCode(i);
      const stop = text.indexOf('\n', i);
      const end = stop === -1 ? n : stop;
      comments.push({ line, text: text.slice(i + 2, end) });
      i = end;
      codeStart = i;
      continue;
    }
    // 块注释
    if (c === '/' && next === '*') {
      pushCode(i);
      const stop = text.indexOf('*/', i + 2);
      const end = stop === -1 ? n : stop + 2;
      const body = text.slice(i + 2, stop === -1 ? n : stop);
      let bodyLine = line;
      for (const part of body.split('\n')) {
        comments.push({ line: bodyLine, text: part });
        bodyLine += 1;
      }
      line += (body.match(/\n/g) || []).length;
      i = end;
      codeStart = i;
      continue;
    }
    // 字符串 / 字符字面量：切出来单独归一类，**不混进代码 token**。
    //
    // 为什么要分开而不是二选一 —— 两个方向都试过，都不对：
    //   · 混进代码 token：hilog tag、NAPI 导出名、JSON key 与真符号无从区分，于是
    //     提到**已删除的 tag** 的注释也会解析成功，零区分度；
    //   · 整体丢弃：`AMCL_INSRC` / `heldBalance` / `untagged` 这类**现行**的 tag 名与
    //     日志字段名只以字面量存在，会立刻变成一批假命中（实测 19 条）。
    // 所以分成两个集合：仍然算解析成功（不误报），但报告里单独给出"只靠字面量解析"
    // 的条数，让这条区分度缺口**可见**而不是静默。
    if (c === '"' || c === '\'' || c === '`') {
      pushCode(i);
      const quote = c;
      const start = i;
      i += 1;
      while (i < n) {
        if (text[i] === '\\') { i += 2; continue; }
        if (text[i] === '\n') { line += 1; i += 1; continue; }
        if (text[i] === quote) { i += 1; break; }
        i += 1;
      }
      literalChunks.push(text.slice(start + 1, Math.max(start + 1, i - 1)));
      codeStart = i;
      continue;
    }
    i += 1;
  }
  pushCode(n);
  return {
    comments,
    code: codeChunks.join('\n'),
    literals: literalChunks.join('\n'),
  };
}

const TOKEN_RE = /[A-Za-z_][A-Za-z0-9_]*/g;

const HASH_COMMENT_EXT = new Set(['.txt', '.cmake', '.json5']);

export function buildUniverse(files) {
  const code = new Set();
  const literals = new Set();
  for (const file of files) {
    let text;
    try { text = fs.readFileSync(file, 'utf8'); } catch { continue; }
    const hashComments = HASH_COMMENT_EXT.has(path.extname(file));
    const split = splitCommentsAndCode(text, { hashComments });
    for (const m of split.code.matchAll(TOKEN_RE)) code.add(m[0]);
    for (const m of split.literals.matchAll(TOKEN_RE)) literals.add(m[0]);
  }
  return { code, literals };
}

// 反引号里的内容看起来像不像"代码标识符"。宁严勿宽：判不准就不报。
const REJECT_CHARS = /[\s/\\<>=!+%"',;#$?|~^[\]{}]/;
const FILE_SUFFIX =
  /\.(?:cpp|cc|h|hpp|c|ets|ts|mjs|js|md|json5?|txt|cmake|ps1|so|hap|json|lock|d\.ts)$/i;

export function normalizeClaim(raw) {
  let token = raw.trim();
  // `a->b` 先归一成 `a.b`：`>` 在 REJECT_CHARS 里，不先换掉的话下面那句会把整条
  // 箭头成员访问直接拒掉，而本函数的注释声称它支持 `->`（自测抓到的自相矛盾）。
  token = token.replace(/->/g, '.');
  if (!token || REJECT_CHARS.test(token)) return null;
  if (FILE_SUFFIX.test(token)) return null;
  token = token.replace(/\(\s*\)$/, '');          // foo() -> foo
  // 通配写法 `AMCL_LOCK_STATE_*` 指一族常量，不是一个符号。按**前缀**判定：族里
  // 只要有一个成员存在就算解析成功。不这么做的话它会被剥成尾部下划线，
  // 变成本脚本自己的假命中 —— 而一个会误报的门禁下一轮就会被当噪声忽略。
  // 前缀通配 `AMCL_LOCK_STATE_*` 与**后缀**通配 `*Transaction` 都要认。后者漏掉的
  // 后果实测过：`*Transaction` 被剥成 `Transaction`，而那不是任何符号 ⇒ 纯脚本假命中。
  const prefixWildcard = /[*]$/.test(token) && !/^[*]/.test(token);
  const suffixWildcard = /^[*]/.test(token) && !/[*]$/.test(token);
  token = token.replace(/[*]+$/, '');
  token = token.replace(/^[*&]+/, '');            // *ptr / &ref
  token = token.replace(/[&]+$/, '');
  token = token.replace(/^\.+/, '').replace(/\.+$/, '');
  if (!token) return null;
  if (prefixWildcard || suffixWildcard) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(token)) return null;
    if (token.length < 4) return null;
    return {
      token, symbol: token,
      prefix: prefixWildcard, suffix: suffixWildcard,
    };
  }
  // A::b / A.b / a->b：取最后一段做判定（保守：只要末段存在就算解析成功）
  const segments = token.split(/::|->|\./).filter(Boolean);
  if (segments.length === 0) return null;
  const last = segments[segments.length - 1];
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(last)) return null;
  if (last.length < 3) return null;               // 单/双字符噪声太多
  if (/^\d/.test(last)) return null;
  return { token, symbol: last, prefix: false, suffix: false };
}

const BACKTICK_RE = /`([^`\n]{1,120})`/g;

function isHistorical(blockText) {
  const lowered = blockText.toLowerCase();
  return HISTORICAL_MARKERS.some(marker =>
    marker === marker.toLowerCase()
      ? lowered.includes(marker)
      : blockText.includes(marker));
}

function loadAllowlist() {
  const full = path.join(ROOT, ALLOWLIST_PATH);
  if (!fs.existsSync(full)) return { symbols: new Map(), raw: null };
  const parsed = JSON.parse(fs.readFileSync(full, 'utf8'));
  const symbols = new Map();
  for (const entry of parsed.external ?? []) {
    if (!entry.symbol) continue;
    symbols.set(entry.symbol, entry.why ?? '');
  }
  return { symbols, raw: parsed };
}

export function scanCommentIdentifiers(root = ROOT) {
  const prevRoot = ROOT;
  void prevRoot;
  const commentFiles = resolveFileSet(COMMENT_ROOTS, COMMENT_FILES);
  const { code: universe, literals } = buildUniverse(
    resolveFileSet(UNIVERSE_ROOTS, UNIVERSE_FILES));
  const { symbols: allowlist } = loadAllowlist();
  const codeList = [...universe];
  const literalList = [...literals];
  const matches = (names, normalized) => {
    if (normalized.prefix) {
      return names.some(name => name.startsWith(normalized.symbol));
    }
    if (normalized.suffix) {
      return names.some(name => name.endsWith(normalized.symbol));
    }
    return names.includes(normalized.symbol);
  };
  let literalOnly = 0;
  // 返回 true = 已解析。刻意先查代码 token，只有代码里没有才退到字面量集合 ——
  // 这样"只靠字面量解析"的条数是可计数的，那就是本门禁区分度缺口的大小。
  const resolves = (normalized) => {
    if (normalized.prefix || normalized.suffix) {
      if (matches(codeList, normalized)) return true;
      if (matches(literalList, normalized)) { literalOnly += 1; return true; }
      return false;
    }
    if (universe.has(normalized.symbol)) return true;
    if (literals.has(normalized.symbol)) { literalOnly += 1; return true; }
    return false;
  };

  const hard = [];
  const advisory = [];
  let claims = 0;
  // 分母必须透明。`claims` 只数**归一化成功**的反引号内容，被 normalizeClaim 拒掉的
  // （含空格 / 路径 / 文件后缀 / 长度 < 3）不计入 —— 不单独数一下的话，"701 条已全查"
  // 这句话无法回答"漏了多少"，而那正是本项目对计数器的既有要求。
  let rejected = 0;
  const rejectedSamples = [];

  for (const file of commentFiles) {
    let text;
    try { text = fs.readFileSync(file, 'utf8'); } catch { continue; }
    const rel = path.relative(root, file).replace(/\\/g, '/');
    const { comments } = splitCommentsAndCode(text);
    // 把连续行的注释视为一个块：历史标记常常写在块头，而命中在块中间。
    const blocks = [];
    let current = null;
    for (const entry of comments) {
      if (current && entry.line <= current.endLine + 1) {
        current.endLine = entry.line;
        current.text += '\n' + entry.text;
        current.lines.push(entry);
      } else {
        current = {
          startLine: entry.line, endLine: entry.line,
          text: entry.text, lines: [entry],
        };
        blocks.push(current);
      }
    }
    for (const block of blocks) {
      const historical = isHistorical(block.text);
      for (const entry of block.lines) {
        for (const m of entry.text.matchAll(BACKTICK_RE)) {
          const normalized = normalizeClaim(m[1]);
          if (!normalized) {
            rejected += 1;
            if (rejectedSamples.length < 40) {
              rejectedSamples.push(`${rel}:${entry.line}  \`${m[1]}\``);
            }
            continue;
          }
          claims += 1;
          if (resolves(normalized)) continue;
          const record = {
            file: rel,
            line: entry.line,
            raw: m[1],
            symbol: normalized.symbol,
            historical,
            allowlisted: allowlist.has(normalized.symbol),
            why: allowlist.get(normalized.symbol) ?? null,
          };
          if (record.allowlisted) continue;
          (historical ? advisory : hard).push(record);
        }
      }
    }
  }

  return {
    filesScanned: commentFiles.length,
    universeSize: universe.size,
    literalUniverseSize: literals.size,
    claims,
    literalOnly,
    rejected,
    rejectedSamples,
    hard,
    advisory,
  };
}

function main() {
  const args = process.argv.slice(2);
  const result = scanCommentIdentifiers();
  if (args.includes('--json')) {
    console.log(JSON.stringify(result, null, 2));
    process.exitCode = result.hard.length > 0 ? 1 : 0;
    return;
  }
  console.log('[check-comment-identifiers]');
  console.log(`  comment files scanned: ${result.filesScanned}`);
  console.log(`  code symbols indexed:  ${result.universeSize}`);
  console.log(`  string-literal tokens indexed: ${result.literalUniverseSize}`);
  console.log(
    `  claims resolved only via a string literal: ${result.literalOnly}` +
    '  (log tags / NAPI names / JSON keys -- this gate cannot tell a live tag' +
    ' from a deleted one)');
  console.log(`  backtick claims checked: ${result.claims}`);
  console.log(`  backtick spans rejected as non-identifiers: ${result.rejected}`);
  console.log(`  unresolved (hard):     ${result.hard.length}`);
  console.log(`  unresolved (historical, advisory): ${result.advisory.length}`);

  if (args.includes('--rejected')) {
    console.log('\n  --- sample of rejected spans (NOT checked by this gate) ---');
    for (const sample of result.rejectedSamples) console.log(`  ${sample}`);
  }

  if (args.includes('--advisory') && result.advisory.length > 0) {
    console.log('\n  --- advisory: tombstone comments naming a removed symbol ---');
    console.log('  (deliberate per spec §52.3; listed only so the list stays honest)');
    for (const hit of result.advisory) {
      console.log(`  ${hit.file}:${hit.line}  \`${hit.raw}\``);
    }
  }

  if (result.hard.length > 0) {
    console.error('\n  --- present-tense references to symbols that do not exist ---');
    for (const hit of result.hard) {
      console.error(`  ${hit.file}:${hit.line}  \`${hit.raw}\`  (symbol: ${hit.symbol})`);
    }
    console.error(
      '\n  Each one is either a comment describing something that was deleted, or an\n' +
      '  external identifier that belongs in ' + ALLOWLIST_PATH + ' with a `why`.\n' +
      '  Do not silence one by adding a tombstone marker unless it really is history.');
    process.exitCode = 1;
    return;
  }
  console.log('  PASS');
}

if (import.meta.url === url.pathToFileURL(process.argv[1] ?? '').href) {
  main();
}
