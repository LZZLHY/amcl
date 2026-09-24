#!/usr/bin/env node
// check-obfuscation-rules.mjs 的定向自测。
//
// 失败方式一是**静默放行**（有人加了 flag 或新 ability 而检查说 PASS），二是**抽名不全**
// （只抽到 abilities[*].name、漏掉 usedScene.abilities，改名时漏改一处不会被发现）。
// 每条性质双向测。

import {
  parseRules,
  collectReflectedNames,
  evaluate,
} from './check-obfuscation-rules.mjs';

let failures = 0;
function check(label, ok, detail) {
  if (ok) { console.log(`[test-check-obfuscation-rules] PASS: ${label}`); return; }
  failures += 1;
  console.error(`[test-check-obfuscation-rules] FAIL: ${label}`);
  if (detail !== undefined) console.error(`  ${detail}`);
}

// ---- parseRules --------------------------------------------------------------

const rules = parseRules([
  '# -enable-property-obfuscation  <- 注释里的不算',
  '-enable-toplevel-obfuscation',
  '-keep-property-name',
  'downloadFetchText',
  '-keep-global-name',
  'EntryAbility',
].join('\n'));
check('注释行不算指令',
  rules.directives.length === 3, JSON.stringify(rules.directives));
check('keep 段在下一条指令处收尾',
  rules.sections.get('-keep-property-name').has('downloadFetchText')
  && rules.sections.get('-keep-global-name').has('EntryAbility')
  && !rules.sections.get('-keep-property-name').has('EntryAbility'));
check('指令带行号（报错要能定位）',
  rules.directives[0].line === 2, JSON.stringify(rules.directives[0]));

// ---- collectReflectedNames ---------------------------------------------------

const moduleJson = `{
  "module": {
    "mainElement": "EntryAbility",
    // "process": ":game" 已移除 —— 注释里的历史配置不得被当成现行配置
    "abilities": [
      { "name": "EntryAbility", "srcEntry": "./ets/entryability/EntryAbility.ets" },
      { "name": "GameAbility", "srcEntry": "./ets/gameability/GameAbility.ets" }
    ],
    "requestPermissions": [
      { "name": "ohos.permission.INTERNET",
        "usedScene": { "abilities": ["EntryAbility"], "when": "inuse" } }
    ],
    "extensionAbilities": [
      { "name": "EntryBackupAbility", "srcEntry": "./ets/x/EntryBackupAbility.ets",
        "metadata": [ { "name": "ohos.extension.backup" } ] }
    ]
  }
}`;
const names = collectReflectedNames(moduleJson);
check('mainElement + abilities + extensionAbilities 三处都抽到',
  names.has('EntryAbility') && names.has('GameAbility') && names.has('EntryBackupAbility'),
  [...names].join(','));
// 承重用例：权限名与 metadata 名也叫 "name"，不能被当成类名（否则门禁要求 keep 权限字符串）。
check('权限名与 metadata 名不算反射类名',
  !names.has('ohos.permission.INTERNET') && !names.has('ohos.extension.backup'),
  [...names].join(','));

// usedScene 里的类名是第二处出现，必须进集合。
const usedSceneOnly = collectReflectedNames(
  '{ "requestPermissions": [ { "usedScene": { "abilities": ["SomeAbility"] } } ] }');
check('usedScene.abilities 被抽到（类名的第二处出现）',
  usedSceneOnly.has('SomeAbility'), [...usedSceneOnly].join(','));

// ---- evaluate（双向）--------------------------------------------------------

const base = parseRules('-enable-toplevel-obfuscation\n-keep-global-name\nEntryAbility\n');

check('全部已知指令 + 反射名全 keep → 放行',
  evaluate({ ...base, reflectedNames: new Set(['EntryAbility']) }).ok === true);

const missingName = evaluate({ ...base, reflectedNames: new Set(['EntryAbility', 'NewAbility']) });
check('新增 ability 忘记 keep → 失败并点名',
  missingName.ok === false && missingName.unkeptNames.join(',') === 'NewAbility',
  JSON.stringify(missingName));

const withRejected = parseRules('-enable-property-obfuscation\n-keep-global-name\nEntryAbility\n');
const rejectedVerdict = evaluate({ ...withRejected, reflectedNames: new Set(['EntryAbility']) });
check('明确拒绝的 flag 回来了 → 失败并给出理由',
  rejectedVerdict.ok === false && rejectedVerdict.rejected.length === 1
  && rejectedVerdict.rejected[0].why.length > 0, JSON.stringify(rejectedVerdict));

const withUnknown = parseRules('-enable-something-new\n-keep-global-name\nEntryAbility\n');
const unknownVerdict = evaluate({ ...withUnknown, reflectedNames: new Set(['EntryAbility']) });
check('没见过的指令 → 失败（不是默默放行）',
  unknownVerdict.ok === false && unknownVerdict.unknown.length === 1,
  JSON.stringify(unknownVerdict));

if (failures > 0) {
  console.error(`[test-check-obfuscation-rules] ${failures} case(s) failed`);
  process.exitCode = 1;
} else {
  console.log('[test-check-obfuscation-rules] ALL PASS');
}
