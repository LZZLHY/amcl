#!/usr/bin/env node
// scripts/check-nav-param-keys.mjs
//
// ============================ 它挡的是什么 ============================
//
// 导航/跨 Ability 传参时，**写侧键名与读侧取值口径不一致**。
//
// 属性名混淆改写标识符，不改写字符串字面量。所以两种写法各自自洽、混着用就断链：
//   写 `params: { filesDir: x }`（标识符，会被改名）+ 读 `params?.['filesDir']`（字符串，不改名）
//     ⇒ release 下恒 undefined，debug 恒正常。
// 2026-08-22 实测过这一处（Index.performLaunch ↔ McGamePage.startMC 的 6 个启动参数），
// 与同一天那次 latest→n84 事故同源：键名跨越了 ArkTS 编译单元的边界。
//
// ============================ 为什么不是"一律要求引号键" ============================
//
// 因为那会误伤正确代码。本仓 7 个带 params 的 pushUrl 里有 6 个是"标识符写 + 接口标识符读"
// （DocWebPage 的 src/title/fallback、LayoutEditorPage 的 profileName 等），两侧共用同一张
// 重命名表，自洽且安全。强推引号键要连读侧一起改 6 个页面，换不到任何正确性。
//
// 所以判据取**一致性**而不是**风格**：只有当某个键名确实存在"字符串下标读法"时，
// 写侧才必须是引号键。
//
// ============================ 它不能证明什么 ============================
//
// ❌ 不检查读侧是否存在。写了没人读的键（如 AppNotifier 的 amclMessageId）它不管。
// ❌ 只跟一层间接：`parameters: wantParams` 会去同文件找 `wantParams = { ... }`，
//    再深一层（函数返回、跨文件常量）就解析不到，计入 unresolved 并如实报出。
// ❌ 读侧口径靠"变量绑定到 getParams()/want.parameters"识别。若有人把 params 先存进字段
//    再在别处下标取值，这里看不见。
// ❌ 它只覆盖导航传参。其它跨边界对象（HTTP JSON / NAPI / 落盘 JSON）分别由
//    check-wire-json-obfuscation.mjs 与 check-napi-obfuscation.mjs 负责。

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');

const SOURCE_ROOTS = [
  'entry/src/main/ets',
  'entry/src/desktop',
  'feature_core/src/main/ets',
  'feature_system/src/main/ets',
  'mods/src/main/ets',
  'account/src/main/ets',
  'update/src/main/ets',
  'launch/src/main/ets',
  'commons/src/main/ets',
  'gamecontrol/src/main/ets',
];

/** 取 `{` 起始处配对的 `}`，返回体内文本与结束下标。 */
function readBracedBody(text, openBraceIndex) {
  let depth = 0;
  for (let i = openBraceIndex; i < text.length; i += 1) {
    if (text[i] === '{') depth += 1;
    else if (text[i] === '}') {
      depth -= 1;
      if (depth === 0) return { body: text.slice(openBraceIndex + 1, i), end: i };
    }
  }
  return null;
}

function lineOf(text, index) {
  return text.slice(0, index).split(/\r?\n/).length;
}

/** 一级键（跳过嵌套对象/数组内部）。返回 [{ name, quoted }]。 */
export function topLevelKeys(body) {
  const keys = [];
  let depth = 0;
  let i = 0;
  let atElementStart = true;
  while (i < body.length) {
    const ch = body[i];
    if (ch === '{' || ch === '[' || ch === '(') { depth += 1; i += 1; atElementStart = false; continue; }
    if (ch === '}' || ch === ']' || ch === ')') { depth -= 1; i += 1; continue; }
    if (ch === ',' && depth === 0) { atElementStart = true; i += 1; continue; }
    if (/\s/.test(ch)) { i += 1; continue; }
    if (body.startsWith('//', i)) { const nl = body.indexOf('\n', i); i = nl < 0 ? body.length : nl; continue; }
    if (body.startsWith('/*', i)) { const e = body.indexOf('*/', i); i = e < 0 ? body.length : e + 2; continue; }
    if (depth === 0 && atElementStart) {
      const quoted = body.slice(i).match(/^(['"])([A-Za-z_$][\w$]*)\1\s*:/);
      if (quoted) { keys.push({ name: quoted[2], quoted: true }); i += quoted[0].length; atElementStart = false; continue; }
      const bare = body.slice(i).match(/^([A-Za-z_$][\w$]*)\s*:/);
      if (bare) { keys.push({ name: bare[1], quoted: false }); i += bare[0].length; atElementStart = false; continue; }
    }
    atElementStart = false;
    i += 1;
  }
  return keys;
}

/**
 * 读侧：哪些键名是用**字符串下标**从导航参数里取的。
 *
 * 先找出绑定到 `getParams()` / `want.parameters` 的变量名，再只收这些变量上的 `['k']`。
 * 刻意不收全仓所有 `['k']`：那会把无关同名键拉进集合，逼正确的写法改成引号键。
 */
export function collectSubscriptReadKeys(text, into = new Set()) {
  const vars = new Set();
  const bind = /(?:let|const|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=\n]*)?=\s*([^\n;]*)/g;
  for (let m; (m = bind.exec(text));) {
    if (/getParams\s*\(\s*\)|\bwant\s*\.\s*parameters\b/.test(m[2])) vars.add(m[1]);
  }
  // ⚠️ 下标前缀必须同时认 `p['k']` / `p?.['k']` / `p?['k']`。本仓读侧主力写法是**可选链**
  // `params?.['filesDir']`；第一版只写了 `\??\s*\[`（认 `p?[` 不认 `p?.[`），于是这道门禁
  // 在最该命中的那个形态上恒不命中 —— 自测直接抓到了它。
  const SUB_PREFIX = "\\s*(?:\\?\\.|\\?|\\.)?\\s*";
  for (const v of vars) {
    const sub = new RegExp(`\\b${v}${SUB_PREFIX}\\[\\s*(['"])([A-Za-z_$][\\w$]*)\\1\\s*\\]`, 'g');
    for (let m; (m = sub.exec(text));) into.add(m[2]);
  }
  // `want.parameters['k']` 直接下标，无中间变量
  const direct = new RegExp(`\\bparameters${SUB_PREFIX}\\[\\s*(['"])([A-Za-z_$][\\w$]*)\\1\\s*\\]`, 'g');
  for (let m; (m = direct.exec(text));) into.add(m[2]);
  return into;
}

/** 写侧：导航传参对象字面量的一级键。返回 [{ api, line, keys, unresolvedRef }]。 */
export function collectNavParamSites(text) {
  const sites = [];
  const head = /\b(params|parameters)\s*:\s*/g;
  for (let m; (m = head.exec(text));) {
    const after = text.slice(m.index + m[0].length);
    const line = lineOf(text, m.index);
    if (after.startsWith('{')) {
      const braced = readBracedBody(text, m.index + m[0].length);
      if (!braced) continue;
      sites.push({ api: m[1], line, keys: topLevelKeys(braced.body), unresolvedRef: null });
      continue;
    }
    // `parameters: wantParams` —— 跟一层同文件的对象字面量声明
    const ref = after.match(/^([A-Za-z_$][\w$]*)/);
    if (!ref) continue;
    const decl = new RegExp(`(?:let|const|var)\\s+${ref[1]}\\s*(?::[^=]*)?=\\s*\\{`).exec(text);
    if (!decl) { sites.push({ api: m[1], line, keys: [], unresolvedRef: ref[1] }); continue; }
    const braced = readBracedBody(text, text.indexOf('{', decl.index));
    if (!braced) { sites.push({ api: m[1], line, keys: [], unresolvedRef: ref[1] }); continue; }
    sites.push({ api: m[1], line, keys: topLevelKeys(braced.body), unresolvedRef: null });
  }
  return sites;
}

export function evaluate(sites, subscriptReadKeys) {
  const violations = [];
  for (const s of sites) {
    for (const k of s.keys) {
      if (!k.quoted && subscriptReadKeys.has(k.name)) {
        violations.push({ file: s.file, line: s.line, api: s.api, key: k.name });
      }
    }
  }
  return { ok: violations.length === 0, violations };
}

function walkEts(dir, out = []) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === 'oh_modules' || entry.name === 'build' || entry.name === '.preview') continue;
      walkEts(full, out);
    } else if (entry.isFile() && /\.ets$/.test(entry.name)) {
      out.push(full);
    }
  }
  return out;
}

function main() {
  const jsonOutput = process.argv.includes('--json');
  const files = SOURCE_ROOTS.flatMap((rel) => walkEts(path.join(ROOT, rel)));

  const readKeys = new Set();
  const sites = [];
  for (const file of files) {
    const text = fs.readFileSync(file, 'utf8');
    collectSubscriptReadKeys(text, readKeys);
    const rel = path.relative(ROOT, file).replace(/\\/g, '/');
    for (const s of collectNavParamSites(text)) sites.push({ ...s, file: rel });
  }
  const { ok, violations } = evaluate(sites, readKeys);
  const unresolved = sites.filter((s) => s.unresolvedRef !== null)
    .map((s) => `${s.file}:${s.line} (${s.unresolvedRef})`);

  const result = {
    ok,
    scannedFiles: files.length,
    navSites: sites.length,
    subscriptReadKeyCount: readKeys.size,
    unresolvedSites: unresolved,
    violations,
  };

  if (jsonOutput) {
    process.stdout.write(`${JSON.stringify(result)}\n`);
    process.exit(ok ? 0 : 1);
  }
  if (ok) {
    console.log(
      `nav param keys OK: ${sites.length} 个传参点 / ${readKeys.size} 个字符串下标读法的键; ` +
      `${unresolved.length} 个对象解析不到（未检查）`);
    for (const u of unresolved) console.log(`  unresolved: ${u}`);
  } else {
    console.error(`nav param keys FAIL: ${violations.length} 个键写侧是标识符、读侧是字符串下标`);
    for (const v of violations) {
      console.error(`  ${v.file}:${v.line}  ${v.api}: { ${v.key}: … }  → 应写成 '${v.key}':`);
    }
    console.error('  混淆一旦开启，这些键在读侧恒为 undefined，而 debug 恒正常。');
  }
  process.exit(ok ? 0 : 1);
}

if (import.meta.url === url.pathToFileURL(process.argv[1] ?? '').href) {
  main();
}
