#!/usr/bin/env node
// 门禁：属性名混淆与"用接口读 JSON"不能同时成立。
//
// -enable-property-obfuscation 改写 ArkTS 源码里的属性名，但 JSON 文本里的键名不跟着改：
//   · HTTP 响应（BMCLAPI / Mojang / Modrinth / CurseForge / 微软 / Xbox / Yggdrasil…）
//   · Java / C++ 写出的文件
//   · 本应用自己 stringify 出去的文件 —— 混淆名按遍历顺序分配且未启用 -apply-name-cache，
//     跨版本会漂移，于是新版读不出旧版写的账号 / 布局 / 任务日志。
// 于是 release 包里 `raw.latest` 读的是不存在的 `raw.n84`，恒为 undefined，而 debug 全绿。
//
// 判定：属性名混淆关闭 → 通过；开启 → 所有 wire 字段必须在 -keep-property-name 里。
//
// ============================ 它不能证明什么 ============================
// 静态扫描只认 `JSON.parse(...) as T` 与 `parseJson<T>(...)` 两种写法，因此 wire 字段集是
// **下界**，不是全集。看不见的至少有：Record<string,Object> 的方括号取值（本来就安全）、
// 经 NAPI 过来的对象（那是 check-napi-obfuscation.mjs 的判据）、以及把解析结果先存成
// Object 再逐层 as 的写法。所以本门禁绿不等于"打开属性名混淆是安全的"——它只在
// 混淆已关闭这一前提下提供"决定没被人默默改回去"的保证。

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
const RULES = path.join(ROOT, 'entry', 'obfuscation-rules.txt');
const PROPERTY_FLAG = '-enable-property-obfuscation';
// 混淆映射表落在 entry/build/<product>/cache/<...>/release/obfuscation/nameCache.json。
// ⚠️ 不要把路径按 product=default 写死：本仓有 default/store/sideload/desktop 四条产品轨
// （build-hap.ps1 -Product），写死会让另外三条轨恒查不到产物 → 判据空真。改为递归找。
const BUILD_DIR_REL = 'entry/build';

const SOURCE_ROOTS = [
  'entry/src/main/ets',
  'feature_core/src/main/ets',
  'feature_system/src/main/ets',
  'mods/src/main/ets',
  'account/src/main/ets',
  'update/src/main/ets',
  'launch/src/main/ets',
  'commons/src/main/ets',
  'gamecontrol/src/main/ets',
];

// 这些不是具名 DTO：Object / Record 走方括号取值，泛型形参与内建数组没有字段可混淆。
const NOT_A_DTO = new Set([
  'Object', 'object', 'Record', 'Array', 'Map', 'Set', 'Promise',
  'T', 'string', 'number', 'boolean', 'void', 'null', 'undefined', 'unknown', 'any',
]);

// ─────────────────────────────────────────────
// 规则文件解析（keep 清单的切分口径与 check-napi-obfuscation.mjs 保持一致）
export function parseRules(text) {
  const kept = new Set();
  let propertyObfuscationEnabled = false;
  let inPropertyNames = false;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line.startsWith('#') || line === '') continue;
    if (line === PROPERTY_FLAG) propertyObfuscationEnabled = true;
    if (line === '-keep-property-name') { inPropertyNames = true; continue; }
    if (line.startsWith('-keep-') && line !== '-keep-property-name') { inPropertyNames = false; continue; }
    if (line.startsWith('-')) { inPropertyNames = false; continue; }
    if (inPropertyNames) kept.add(line);
  }
  return { propertyObfuscationEnabled, kept };
}

// ─────────────────────────────────────────────
// 从一份源码里挖出"被当成 JSON 形状用"的类型名
const CAST_RE = /JSON\s*\.\s*parse\s*\([\s\S]{0,300}?\)\s*as\s+([A-Za-z_$][\w$]*)/g;
const GENERIC_RE = /parseJson\s*<\s*([A-Za-z_$][\w$]*)/g;

export function collectWireTypeNames(text) {
  const names = new Set();
  for (const re of [CAST_RE, GENERIC_RE]) {
    re.lastIndex = 0;
    for (let m; (m = re.exec(text));) {
      if (!NOT_A_DTO.has(m[1])) names.add(m[1]);
    }
  }
  return names;
}

// ─────────────────────────────────────────────
// interface 索引：名字 -> { fields, refs }
//
// ⚠️ 花括号必须真的配对着数，不能用 `\{([\s\S]*?)\n\}` 这种"闭括号自成一行"的近似：
// 本仓有一批**单行** DTO（`interface VersionManifest { latest: VersionLatest; ... }`），
// 近似写法会整条漏掉 —— 而漏掉的恰好是 version_manifest 这种最典型的 wire 形状。
const INTERFACE_HEAD_RE = /(?:^|[\s;})])(?:export\s+)?interface\s+([A-Za-z_$][\w$]*)[^{;]*\{/g;
// 字段声明按 `;` 与换行同时切分（单行 DTO 用 `;` 分隔）。嵌套内联对象会把内层字段一起
// 收进来：对"必须 keep"的判据来说多收是安全方向，少收才会漏。
const FIELD_RE = /^\s*(?:readonly\s+)?([A-Za-z_$][\w$]*)\s*\??\s*:\s*(.*)$/;

export function indexInterfaces(text, into = new Map()) {
  INTERFACE_HEAD_RE.lastIndex = 0;
  for (let m; (m = INTERFACE_HEAD_RE.exec(text));) {
    const bodyStart = m.index + m[0].length;
    let depth = 1;
    let i = bodyStart;
    while (i < text.length && depth > 0) {
      const ch = text[i];
      if (ch === '{') depth += 1;
      else if (ch === '}') depth -= 1;
      i += 1;
    }
    const body = text.slice(bodyStart, Math.max(bodyStart, i - 1));
    INTERFACE_HEAD_RE.lastIndex = i;

    const fields = [];
    const refs = new Set();
    for (const chunk of body.split(/[;\n]/)) {
      if (/^\s*(?:\/\/|\/\*|\*)/.test(chunk)) continue;
      const f = chunk.match(FIELD_RE);
      if (!f) continue;
      fields.push(f[1]);
      for (const t of f[2].match(/[A-Za-z_$][\w$]*/g) || []) {
        if (!NOT_A_DTO.has(t)) refs.add(t);
      }
    }
    // 同名 interface 在多模块重复声明时合并，避免后者覆盖前者的字段
    const prev = into.get(m[1]);
    if (prev) {
      for (const f of fields) prev.fields.push(f);
      for (const r of refs) prev.refs.add(r);
    } else {
      into.set(m[1], { fields, refs });
    }
  }
  return into;
}

/** 从 wire 根类型出发，传递闭包收集所有字段名。 */
export function collectWireFields(rootTypeNames, interfaces) {
  const fields = new Set();
  const seen = new Set();
  const queue = [...rootTypeNames];
  const unresolved = new Set();
  while (queue.length > 0) {
    const name = queue.pop();
    if (seen.has(name)) continue;
    seen.add(name);
    const decl = interfaces.get(name);
    if (!decl) { if (rootTypeNames.has(name)) unresolved.add(name); continue; }
    for (const f of decl.fields) fields.add(f);
    for (const r of decl.refs) if (!seen.has(r)) queue.push(r);
  }
  return { fields, unresolved };
}

export function evaluate({ propertyObfuscationEnabled, kept, wireFields }) {
  const unkept = [...wireFields].filter((f) => !kept.has(f)).sort();
  return { ok: !propertyObfuscationEnabled || unkept.length === 0, unkept };
}

// 顶层声明：-enable-toplevel-obfuscation / -enable-export-obfuscation 能改名的东西。
// 它们和属性名混淆共用 nameCache 的 PropertyCache 表，所以判读产物时必须先把它们排除。
const DECLARED_RE =
  /(?:^|\n)\s*(?:export\s+)?(?:declare\s+)?(?:function|class|const|let|var|enum|namespace|type|interface)\s+([A-Za-z_$][\w$]*)/g;

export function collectDeclaredIdentifiers(text, into = new Set()) {
  DECLARED_RE.lastIndex = 0;
  for (let m; (m = DECLARED_RE.exec(text));) into.add(m[1]);
  return into;
}

/**
 * 「只可能是属性」的 wire 字段 —— 产物级判据的探针。
 *
 * PropertyCache **非空是正常的**：实测属性名混淆关闭后它仍有 2308 条，来自 toplevel /
 * export 混淆。判据若写成"wire 字段出现在 PropertyCache 就算坏"会误报 —— 实测误报过
 * baseName / errorMessage / fileSize：这三个既是 DTO 字段、又各自存在同名的顶层函数或
 * 局部声明，而且前两个还在 keep 清单里（被 keep 的属性名根本不可能被属性名混淆改掉，
 * 这正是判定它们属于误报的依据）。
 *
 * 所以探针只取"在全仓找不到同名顶层声明、且不在 keep 清单里"的字段：这些名字出现在
 * PropertyCache 里就只能是属性名混淆干的。宁可探针少，不可判据不成立。
 */
export function deriveCanaries(wireFields, kept, declaredIdentifiers) {
  return new Set([...wireFields].filter(
    (f) => !kept.has(f) && !declaredIdentifiers.has(f)));
}

/**
 * 产物级判据：上次 release 编译留下的映射表里，探针字段一个都不许被改名。
 *
 * 为什么规则文件对了还要看产物：规则文件是**输入**，nameCache 是**结果**。两者能脱钩 ——
 * IDE 用了旧的 CompileArkTS 缓存、或别处又把 flag 带回来，都会让"规则写对了"与
 * "产物是干净的"不是一回事。
 */
export function evaluateArtifact(propertyCache, canaries) {
  if (propertyCache === null) return { present: false, ok: true, mangled: [] };
  const mangled = [...canaries]
    .filter((f) => Object.prototype.hasOwnProperty.call(propertyCache, f))
    .sort()
    .map((f) => `${f}=>${propertyCache[f]}`);
  return { present: true, ok: mangled.length === 0, mangled };
}

/**
 * 「查不到产物」该不该算失败。
 *
 * CI 的 runner 没有构建产物，那里必须放行；出货路径（build-hap.ps1 在 assembleHap 之后）
 * 必须当失败 —— 否则"没有产物 ⇒ 判据空真"会让这半检查恰好在最需要它的地方沉默。
 * 单独抽成函数是为了让这条判定可被自测：它自己就是最容易写成"不可能失败"的那一行。
 */
export function evaluateArtifactPresence(requireArtifact, artifactCount) {
  return { ok: !requireArtifact || artifactCount > 0 };
}

// ─────────────────────────────────────────────
function walkEts(dir, out = []) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === 'oh_modules' || entry.name === 'build') continue;
      walkEts(full, out);
    } else if (entry.isFile() && /\.ets$/.test(entry.name)) {
      out.push(full);
    }
  }
  return out;
}

/** 递归找出所有产品轨的 release 混淆映射表。 */
function findNameCaches(dir, out = []) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      findNameCaches(full, out);
    } else if (entry.name === 'nameCache.json'
      && full.replace(/\\/g, '/').includes('/release/obfuscation/')) {
      out.push(full);
    }
  }
  return out;
}

/** 读上次 release 编译产出的映射表；没有构建过返回空数组。 */
function loadArtifacts() {
  return findNameCaches(path.join(ROOT, BUILD_DIR_REL)).map((full) => {
    let propertyCache = {};
    try {
      propertyCache = JSON.parse(fs.readFileSync(full, 'utf8')).PropertyCache ?? {};
    } catch {
      propertyCache = {};
    }
    return { rel: path.relative(ROOT, full).replace(/\\/g, '/'), propertyCache };
  });
}

function main() {
  const jsonOutput = process.argv.includes('--json');
  // --require-artifact：出货路径专用。构建之后必须真的读到映射表才算通过 ——
  // 否则"没有产物 ⇒ 判据空真"会让这半检查在最需要它的地方沉默（CI 无产物是正常的，
  // 所以默认不要求；build-hap.ps1 在 assembleHap 之后带上这个开关）。
  const requireArtifact = process.argv.includes('--require-artifact');
  const { propertyObfuscationEnabled, kept } = parseRules(fs.readFileSync(RULES, 'utf8'));

  const files = SOURCE_ROOTS.flatMap((rel) => walkEts(path.join(ROOT, rel)));
  const rootTypes = new Set();
  const interfaces = new Map();
  const declared = new Set();
  for (const file of files) {
    const text = fs.readFileSync(file, 'utf8');
    for (const n of collectWireTypeNames(text)) rootTypes.add(n);
    indexInterfaces(text, interfaces);
    collectDeclaredIdentifiers(text, declared);
  }
  const { fields, unresolved } = collectWireFields(rootTypes, interfaces);
  const rules = evaluate({ propertyObfuscationEnabled, kept, wireFields: fields });
  const canaries = deriveCanaries(fields, kept, declared);

  const artifacts = loadArtifacts().map((a) => {
    const verdict = evaluateArtifact(a.propertyCache, canaries);
    return { rel: a.rel, mangled: verdict.mangled, ok: verdict.ok };
  });
  const dirtyArtifacts = artifacts.filter((a) => !a.ok);
  const artifactMissing = !evaluateArtifactPresence(requireArtifact, artifacts.length).ok;
  const ok = rules.ok && dirtyArtifacts.length === 0 && !artifactMissing;

  const result = {
    ok,
    propertyObfuscationEnabled,
    scannedFiles: files.length,
    wireRootTypes: rootTypes.size,
    wireFieldCount: fields.size,
    keptCount: kept.size,
    unresolvedRootTypes: [...unresolved].sort(),
    atRiskIfEnabled: rules.unkept.length,
    unkept: rules.unkept,
    canaryCount: canaries.size,
    artifactCount: artifacts.length,
    artifactsChecked: artifacts.map((a) => a.rel),
    artifactMissing,
    artifactMangled: dirtyArtifacts.flatMap((a) => a.mangled),
  };

  if (jsonOutput) {
    process.stdout.write(`${JSON.stringify(result)}\n`);
    process.exit(ok ? 0 : 1);
  }

  if (!rules.ok) {
    console.error(`wire-JSON obfuscation FAIL: ${PROPERTY_FLAG} 已开启，但 ${rules.unkept.length} 个 wire 字段未 keep`);
    console.error('  这些字段在 release 包里读外部 JSON 会恒为 undefined：');
    console.error(`  ${rules.unkept.join(', ')}`);
    console.error(`  修法：移除 ${PROPERTY_FLAG}（推荐），或把上列字段补进 -keep-property-name。`);
  }
  for (const a of dirtyArtifacts) {
    console.error(`wire-JSON obfuscation FAIL: release 产物里有 ${a.mangled.length} 个 wire 字段被改名`);
    console.error(`  ${a.rel}`);
    console.error(`  ${a.mangled.join(', ')}`);
    console.error('  规则文件可能已改对但编译用了旧缓存 —— 清 entry/build 后重新构建再看。');
  }
  if (artifactMissing) {
    console.error('wire-JSON obfuscation FAIL: --require-artifact 但没找到任何 release 混淆映射表');
    console.error(`  查找位置：${BUILD_DIR_REL}/**/release/obfuscation/nameCache.json`);
    console.error('  出货路径上"查不到产物"必须当失败 —— 否则这半检查在最需要它的地方沉默。');
  }
  if (ok) {
    console.log(
      `wire-JSON obfuscation OK: ${PROPERTY_FLAG} ${propertyObfuscationEnabled ? 'ON (all fields kept)' : 'absent'}; ` +
      `${fields.size} wire fields from ${rootTypes.size} root types in ${files.length} files; ` +
      `${artifacts.length} artifact(s) clean (${canaries.size} canaries)`);
    for (const a of artifacts) console.log(`  checked: ${a.rel}`);
    if (!propertyObfuscationEnabled && rules.unkept.length) {
      console.log(`  若重新打开属性名混淆，需先 keep 这 ${rules.unkept.length} 个字段（下界）。`);
    }
  }
  process.exit(ok ? 0 : 1);
}

if (import.meta.url === url.pathToFileURL(process.argv[1]).href) main();
