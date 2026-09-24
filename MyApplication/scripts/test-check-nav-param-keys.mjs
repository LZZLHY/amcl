#!/usr/bin/env node
// check-nav-param-keys.mjs 的定向自测。
//
// 这道门禁写错的失败方式是**静默放行**：写读口径不一致照旧漏过去，而检查说 PASS。
// 另一种同样贵的写法错误是**误报**：把 6 处自洽的"标识符写 + 标识符读"判成违规，
// 那会逼人去改正确代码，下一轮这道门禁就会被忽略。所以每条性质都双向测。
//
// 每条用例对应 2026-08-22 那次审计里的一个真实形态。

import {
  topLevelKeys,
  collectSubscriptReadKeys,
  collectNavParamSites,
  evaluate,
} from './check-nav-param-keys.mjs';

let failures = 0;
function check(label, ok, detail) {
  if (ok) { console.log(`[test-check-nav-param-keys] PASS: ${label}`); return; }
  failures += 1;
  console.error(`[test-check-nav-param-keys] FAIL: ${label}`);
  if (detail !== undefined) console.error(`  ${detail}`);
}

// ---- topLevelKeys ------------------------------------------------------------

check('引号键与标识符键都能识别且带 quoted 标记',
  JSON.stringify(topLevelKeys("'a': 1, b: 2"))
  === JSON.stringify([{ name: 'a', quoted: true }, { name: 'b', quoted: false }]));

// 嵌套对象里的键不算一级键 —— 否则会把内层无关键名拉进判定。
check('嵌套对象内部的键不算一级键',
  JSON.stringify(topLevelKeys('outer: { inner: 1 }, tail: 2').map((k) => k.name))
  === JSON.stringify(['outer', 'tail']));

check('注释里的伪键不算键',
  topLevelKeys('// fake: 1\nreal: 2').map((k) => k.name).join(',') === 'real');

// ---- collectSubscriptReadKeys -------------------------------------------------

const readSide = [
  "let params = this.getUIContext().getRouter().getParams() as Record<string, string>",
  "let a = (params?.['filesDir'] as string) || ''",
  "let b = params['mcDir']",
].join('\n');
const readKeys = collectSubscriptReadKeys(readSide);
check('绑定到 getParams() 的变量上的字符串下标被收集',
  readKeys.has('filesDir') && readKeys.has('mcDir'), [...readKeys].join(','));

// 关键：不能把无关变量上的下标收进来，否则会误伤正确的标识符写法。
const unrelated = collectSubscriptReadKeys("let cfg = loadCfg()\nlet v = cfg['src']");
check('无关变量上的字符串下标不进集合（否则会误报）',
  !unrelated.has('src'), [...unrelated].join(','));

check('want.parameters 直接下标也被收集',
  collectSubscriptReadKeys("let raw = want.parameters['amclSessionKey']").has('amclSessionKey'));

// ---- collectNavParamSites ----------------------------------------------------

const inlineSite = collectNavParamSites(
  "pushUrl({ url: 'pages/X', params: { filesDir: a, 'mcDir': b } })");
check('内联 params 对象的一级键被取出',
  inlineSite.length === 1
  && JSON.stringify(inlineSite[0].keys) === JSON.stringify(
    [{ name: 'filesDir', quoted: false }, { name: 'mcDir', quoted: true }]),
  JSON.stringify(inlineSite));

// 一层间接：本仓 Index.ets 的 startAbility 就是 `parameters: wantParams` 这种形状。
const indirect = collectNavParamSites(
  "let wantParams: Record<string, string> = { 'filesDir': a }\nlet w = { parameters: wantParams }");
check('parameters: 变量 能跟一层找到对象字面量',
  indirect.length === 1 && indirect[0].keys[0].name === 'filesDir'
  && indirect[0].keys[0].quoted === true, JSON.stringify(indirect));

const unresolvable = collectNavParamSites('let w = { parameters: buildParams() }');
check('跟不到的间接引用如实记为 unresolved 而不是当成没有键',
  unresolvable.length === 1 && unresolvable[0].unresolvedRef !== null,
  JSON.stringify(unresolvable));

// ---- evaluate（双向）--------------------------------------------------------

const bad = evaluate(
  [{ file: 'Index.ets', line: 1, api: 'params', keys: [{ name: 'filesDir', quoted: false }] }],
  new Set(['filesDir']));
check('标识符写 + 字符串下标读 → 失败（真缺陷）',
  bad.ok === false && bad.violations[0].key === 'filesDir', JSON.stringify(bad));

const quotedOk = evaluate(
  [{ file: 'Index.ets', line: 1, api: 'params', keys: [{ name: 'filesDir', quoted: true }] }],
  new Set(['filesDir']));
check('引号写 + 字符串下标读 → 放行', quotedOk.ok === true);

// 这条是防误报的承重用例：DocWebPage 的 src/title/fallback 就是这个形态。
const identBothSides = evaluate(
  [{ file: 'SettingsTab.ets', line: 1, api: 'params', keys: [{ name: 'src', quoted: false }] }],
  new Set(['filesDir']));
check('标识符写 + 无字符串下标读法 → 放行（两侧自洽，不得误报）',
  identBothSides.ok === true, JSON.stringify(identBothSides));

if (failures > 0) {
  console.error(`[test-check-nav-param-keys] ${failures} case(s) failed`);
  process.exitCode = 1;
} else {
  console.log('[test-check-nav-param-keys] ALL PASS');
}
