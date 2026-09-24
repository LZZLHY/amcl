#!/usr/bin/env node
// scripts/test-audit-logging.mjs
//
// audit-logging.mjs 的定向自测。
//
// ⚠️ 只证明「当前是绿的」不够 —— 那种检查在它坏掉之后也一样是绿的。
// 本门禁尤其危险，因为它的失效形态是**静默变绿**：扫描面缩小会让裸调用计数变小，
// 而「漏扫一个模块」与「真的把裸日志改完了」在计数上完全一样。
// §4 就是钉这一条的。
//
// 另一条（§2）钉的是**作用域**：这个脚本在 2026-09-06 之前把 `.tmp-build/`、
// `docker/output/`、`prebuilt/` 也数了进去，导致计数差一个数量级、`--strict` 恒红、
// 最终没人接它。作用域一旦回退，本门禁又会变成摆设。

import path from 'node:path';
import { analyze, evaluate } from './audit-logging.mjs';

let failed = 0;
function check(name, cond, extra) {
  if (cond) {
    console.log(`  ok   ${name}`);
  } else {
    failed += 1;
    console.error(`  FAIL ${name}${extra ? `\n       ${extra}` : ''}`);
  }
}

const real = analyze();

// ── 1. 正向：真实仓库能扫出东西
{
  check('real repo: 扫到 .ets 与 native 文件', real.scannedEts > 100 && real.scannedNative > 100,
    `${real.scannedEts} / ${real.scannedNative}`);
  check('real repo: 门面调用非零', real.arktsFacade > 0 && real.nativeFacade > 0,
    `${real.arktsFacade} / ${real.nativeFacade}`);
  check('real repo: 无 testTag 占位', real.testTagHits.length === 0,
    JSON.stringify(real.testTagHits.slice(0, 5)));
}

// ── 2. ⭐ 作用域：脚手架 / 第三方 / 测试目录一律不许出现在结果里
{
  const all = [...real.arktsBareByFile, ...real.nativeBareByFile].map((x) => x.rel);
  const forbidden = ['.tmp-build/', 'docker/', 'artifacts/', 'prebuilt/', 'node_modules/',
    'oh_modules/', 'validation-packages/', 'diagnostics/', '/build/', '/.test/', '/ohosTest/'];
  const leaked = all.filter((p) => forbidden.some((f) => p.includes(f)));
  check('作用域: 脚手架/第三方/测试目录不出现在计数里', leaked.length === 0,
    JSON.stringify(leaked.slice(0, 8)));

  const outsideRoots = all.filter((p) => {
    const root = p.split('/')[0];
    return !['account', 'commons', 'entry', 'feature_core', 'feature_system',
      'gamecontrol', 'launch', 'mods', 'update', 'JavaApp'].includes(root);
  });
  check('作用域: 所有命中都落在已登记的模块根里', outsideRoots.length === 0,
    JSON.stringify(outsideRoots.slice(0, 8)));
}

// ── 3. 门面内部实现被豁免（否则门面自己会被算成反模式）
{
  const all = [...real.arktsBareByFile, ...real.nativeBareByFile].map((x) => x.rel);
  check('豁免: AppLogger 自身不计入裸调用',
    !all.includes('commons/src/main/ets/utils/AppLogger.ets'));
  check('豁免: amcl_log.cpp 自身不计入裸调用',
    !all.includes('entry/src/main/cpp/utils/amcl_log.cpp'));
}

// ── 4. ⭐ 承重：缩水守卫。漏扫必须红，不许静默变绿
{
  const baseline = { arktsBare: real.arktsBare, nativeBare: real.nativeBare, scannedEts: real.scannedEts };

  const shrunk = { ...real, scannedEts: Math.floor(real.scannedEts * 0.5), arktsBare: 0, nativeBare: 0 };
  const v = evaluate(shrunk, baseline, true);
  check('扫描面腰斩且计数归零 ⇒ 仍然红（不许静默变绿）', v.fail === true,
    JSON.stringify(v.reasons));
  check('扫描面腰斩 ⇒ 明确报 scope-shrink',
    v.reasons.some((x) => x.startsWith('scope-shrink')), JSON.stringify(v.reasons));

  // 小幅波动（正常增删文件）不该误报
  const jitter = { ...real, scannedEts: real.scannedEts - 1 };
  check('扫描面小幅波动 ⇒ 不误报', evaluate(jitter, baseline, true).fail === false);
}

// ── 5. 超基线必须红
{
  const baseline = { arktsBare: real.arktsBare, nativeBare: real.nativeBare, scannedEts: real.scannedEts };
  const worseArk = { ...real, arktsBare: real.arktsBare + 1 };
  const vA = evaluate(worseArk, baseline, true);
  check('新增一处裸 hilog ⇒ 红', vA.fail === true && vA.reasons.some((x) => x.startsWith('arktsBare')),
    JSON.stringify(vA.reasons));

  const worseNative = { ...real, nativeBare: real.nativeBare + 1 };
  const vN = evaluate(worseNative, baseline, true);
  check('新增一处裸 OH_LOG ⇒ 红', vN.fail === true && vN.reasons.some((x) => x.startsWith('nativeBare')),
    JSON.stringify(vN.reasons));

  check('计数持平 ⇒ 绿', evaluate(real, baseline, true).fail === false);
}

// ── 6. testTag 占位必须红
{
  const withTag = { ...real, testTagHits: ['entry/src/main/ets/Foo.ets:12'] };
  const v = evaluate(withTag, null, true);
  check('出现 testTag ⇒ 红（不依赖基线）', v.fail === true && v.reasons[0].startsWith('testTag'),
    JSON.stringify(v.reasons));
}

// ── 7. 非 strict 一律不失败（informational 语义没有被改掉）
{
  const bad = { ...real, arktsBare: 99999, testTagHits: ['x:1'] };
  check('非 strict ⇒ 永远不失败', evaluate(bad, { arktsBare: 0, nativeBare: 0, scannedEts: 1 }, false).fail === false);
}

console.log(failed === 0 ? `\n✅ ALL PASS` : `\n❌ ${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
