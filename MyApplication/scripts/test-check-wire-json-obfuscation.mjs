#!/usr/bin/env node
// check-wire-json-obfuscation.mjs 的定向自测。
//
// 这道门禁的失败方式是**静默放行**：有人把 -enable-property-obfuscation 加回去，
// 而扫描因为漏掉某种 DTO 写法算出空的 wire 字段集，于是报 ok。所以每条性质都双向测。
//
// 每条用例都对应 2026-08-22 那次真实事故的一个环节：
//   · 单行 interface（version_manifest 的形状）曾被"闭括号自成一行"的近似正则整条漏掉；
//   · `JSON.parse(x) as T` 与 `parseJson<T>()` 是本仓实际用的两种写法，都要认；
//   · Record<string,Object> 走方括号取值，不该被算成风险；
//   · 混淆关闭时即便有未 keep 的字段也必须放行，否则门禁一上线就全红、下一轮被忽略。

import {
  parseRules,
  collectWireTypeNames,
  indexInterfaces,
  collectWireFields,
  evaluate,
  collectDeclaredIdentifiers,
  deriveCanaries,
  evaluateArtifact,
  evaluateArtifactPresence,
} from './check-wire-json-obfuscation.mjs';

let failures = 0;

function check(label, ok, detail) {
  if (ok) {
    console.log(`[test-check-wire-json-obfuscation] PASS: ${label}`);
    return;
  }
  failures += 1;
  console.error(`[test-check-wire-json-obfuscation] FAIL: ${label}`);
  if (detail !== undefined) console.error(`  ${detail}`);
}

// ---- parseRules --------------------------------------------------------------

const rulesOff = [
  '# -enable-property-obfuscation  <- 注释掉的不算开启',
  '-enable-toplevel-obfuscation',
  '-keep-property-name',
  'downloadFetchText',
  'statusCode',
  '-keep-global-name',
  'EntryAbility',
].join('\n');
const parsedOff = parseRules(rulesOff);
check('注释里的 flag 不算开启', parsedOff.propertyObfuscationEnabled === false);
check('keep 清单在下一个 -keep-* 处收尾',
  parsedOff.kept.has('downloadFetchText') && parsedOff.kept.has('statusCode')
  && !parsedOff.kept.has('EntryAbility'),
  [...parsedOff.kept].join(','));

const parsedOn = parseRules('-enable-property-obfuscation\n-keep-property-name\nbody\n');
check('未注释的 flag 判为开启', parsedOn.propertyObfuscationEnabled === true);

// ---- collectWireTypeNames ----------------------------------------------------

const src = `
  let a = JSON.parse(cached) as McVersionManifestRaw
  let b = this.parseJson<ModrinthSearchResponseRaw>(body);
  let c = JSON.parse(txt) as Record<string, Object>;
  let d = JSON.parse(txt) as Object;
  let e = this.parseJson<CFFilesResponseRaw>(body);
`;
const names = collectWireTypeNames(src);
check('认 `JSON.parse(x) as T`', names.has('McVersionManifestRaw'));
check('认 `parseJson<T>()`',
  names.has('ModrinthSearchResponseRaw') && names.has('CFFilesResponseRaw'));
check('Record / Object 不算 DTO',
  !names.has('Record') && !names.has('Object'), [...names].join(','));

// ---- indexInterfaces ---------------------------------------------------------

// 单行 DTO：真实事故里被漏掉的那种形状。
const oneLine = 'interface VersionManifest { latest: VersionLatest; versions: VersionEntry[]; }\n'
  + 'interface VersionLatest { release: string; snapshot: string; }\n';
const idxOneLine = indexInterfaces(oneLine);
check('单行 interface 被索引到',
  idxOneLine.has('VersionManifest') && idxOneLine.has('VersionLatest'),
  [...idxOneLine.keys()].join(','));
check('单行 interface 的字段按 `;` 切出',
  idxOneLine.get('VersionManifest').fields.join(',') === 'latest,versions',
  idxOneLine.get('VersionManifest').fields.join(','));

// 多行 + 嵌套内联对象：不得因为内层花括号错位而吞掉后一个 interface。
const multi = [
  'export interface Outer {',
  '  // 注释行不算字段',
  '  head: string;',
  '  nested: { inner: number };',
  '}',
  'interface After { tail: boolean; }',
].join('\n');
const idxMulti = indexInterfaces(multi);
check('嵌套花括号之后的 interface 仍被索引到',
  idxMulti.has('Outer') && idxMulti.has('After'), [...idxMulti.keys()].join(','));
check('注释行不算字段',
  !idxMulti.get('Outer').fields.includes('//'),
  idxMulti.get('Outer').fields.join(','));

// ---- collectWireFields（传递闭包）--------------------------------------------

const closure = collectWireFields(new Set(['VersionManifest']), idxOneLine);
check('沿字段类型递归收集嵌套 DTO 的字段',
  closure.fields.has('latest') && closure.fields.has('release') && closure.fields.has('snapshot'),
  [...closure.fields].join(','));
check('找不到声明的根类型被如实报出',
  collectWireFields(new Set(['NoSuchRaw']), idxOneLine).unresolved.has('NoSuchRaw'));

// ---- evaluate（双向）--------------------------------------------------------

const wireFields = new Set(['latest', 'release', 'body']);
const kept = new Set(['body']);

const whenOn = evaluate({ propertyObfuscationEnabled: true, kept, wireFields });
check('混淆开启 + 有未 keep 字段 → 失败，并列出缺哪些',
  whenOn.ok === false && whenOn.unkept.join(',') === 'latest,release',
  JSON.stringify(whenOn));

const whenOnCovered = evaluate({
  propertyObfuscationEnabled: true,
  kept: new Set(['latest', 'release', 'body']),
  wireFields,
});
check('混淆开启 + 全部 keep → 放行', whenOnCovered.ok === true);

const whenOff = evaluate({ propertyObfuscationEnabled: false, kept, wireFields });
check('混淆关闭 → 放行（但仍报出待办数量）',
  whenOff.ok === true && whenOff.unkept.length === 2, JSON.stringify(whenOff));

// ---- 产物级判据：探针推导 + nameCache 判读 ------------------------------------

const declared = collectDeclaredIdentifiers([
  'export function baseName(p: string): string { return p; }',
  'let hits: string[] = [];',
].join('\n'));
check('顶层 function / let 声明都被收进"可被 toplevel 混淆改名"集合',
  declared.has('baseName') && declared.has('hits'), [...declared].join(','));

// 探针必须排除两类：keep 清单里的，以及存在同名顶层声明的。
// 这不是洁癖：实测 baseName / errorMessage / fileSize 三个就是这么误报出来的 ——
// 它们同时是 DTO 字段和顶层函数名，而前两个还在 keep 清单里。
const canaries = deriveCanaries(
  new Set(['latest', 'baseName', 'hits', 'body']),
  new Set(['body']),
  declared);
check('探针剔掉 keep 清单成员与同名顶层声明',
  canaries.size === 1 && canaries.has('latest'), [...canaries].join(','));

check('没构建过 → 不算失败',
  evaluateArtifact(null, canaries).ok === true
  && evaluateArtifact(null, canaries).present === false);

// PropertyCache 非空是正常的：export / toplevel 混淆也往里写名字（实测关闭属性名混淆后
// 仍有 2308 条）。判据写成"表为空"会让这道检查恒红。
check('PropertyCache 非空但不含探针 → 放行',
  evaluateArtifact({ SomeExportedClass: 'a1', baseName: 'g842' }, canaries).ok === true);

const dirty = evaluateArtifact({ latest: 'n84', unrelated: 'z9' }, canaries);
check('探针被改名 → 失败，并给出改成了什么',
  dirty.ok === false && dirty.mangled.join(',') === 'latest=>n84',
  JSON.stringify(dirty));

// --require-artifact 的双向：CI 无产物必须放行，出货路径查不到产物必须失败。
// 这一行本身就是最容易写成"不可能失败"的那种判定，所以双向都钉住。
check('CI（不要求产物）+ 零产物 → 放行',
  evaluateArtifactPresence(false, 0).ok === true);
check('出货路径（要求产物）+ 零产物 → 失败',
  evaluateArtifactPresence(true, 0).ok === false);
check('出货路径 + 有产物 → 放行',
  evaluateArtifactPresence(true, 1).ok === true);

if (failures > 0) {
  console.error(`[test-check-wire-json-obfuscation] ${failures} failure(s)`);
  process.exit(1);
}
console.log('[test-check-wire-json-obfuscation] all green');
