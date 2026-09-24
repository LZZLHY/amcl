#!/usr/bin/env node
// check-empty-catch-napi.mjs 的定向自测。
//
// 这道门禁写错的失败方式是**静默放行**：有人新加一处 `try { testNapi.foo() } catch {}`
// 而检查说 PASS。它同时是棘轮，所以"变少"必须被识别为偿还而不是问题 ——
// 否则偿还的人会被自己的门禁挡住，那样没人会去偿还。
//
// 每条用例对应实现里一个**真会写错**的地方：
//   · 掩码必须同时吃掉字符串（字符串里的 `//` 被当注释起点会读错整段结构）；
//   · 模板串的 `${...}` **不能**掩掉（里面是真代码，掩掉就漏报，而少报是唯一致命方向）；
//   · 注释-only 与裸 `{}` 都算空 —— 实测 51/51 全是注释-only，只查 `{}` 一条都拦不住；
//   · `.catch()` promise 处理器不是 try/catch，不能算进来（全仓 95 个，会把总数虚高一倍）。

import {
  maskCode,
  findEmptyNapiCatches,
  compareToBaseline,
} from './check-empty-catch-napi.mjs';

let failures = 0;
function check(label, ok, detail) {
  if (ok) { console.log(`[test-check-empty-catch-napi] PASS: ${label}`); return; }
  failures += 1;
  console.error(`[test-check-empty-catch-napi] FAIL: ${label}`);
  if (detail !== undefined) console.error(`  ${detail}`);
}

// ---- maskCode ----------------------------------------------------------------

check('掩码保持长度与偏移',
  maskCode('let a = 1; // x').length === 'let a = 1; // x'.length);

check('行注释内容被抹平',
  maskCode('a; // testNapi.foo()').includes('testNapi') === false);

check('块注释内容被抹平（跨行仍保留换行）',
  maskCode('a;\n/* testNapi.foo()\n   more */\nb;').includes('testNapi') === false
  && maskCode('a;\n/* x\ny */\nb;').split('\n').length === 4);

// 承重：字符串里的 `//` 不是注释。若被当注释，后面整行结构都读错。
check('字符串里的 // 不被当注释起点',
  maskCode(`let u = "https://x"; testNapi.foo()`).includes('testNapi') === true);

check('字符串内容被抹平（避免把字面量当代码）',
  maskCode(`let s = "testNapi.foo"`).includes('testNapi') === false);

// 承重：模板串的 ${} 里是真代码，掩掉就会漏报。
check('模板串的 ${} 内部保留为代码',
  maskCode('let s = `a${testNapi.foo()}b`').includes('testNapi') === true);

check('模板串的文本部分被抹平',
  maskCode('let s = `testNapi.zzz`').includes('testNapi') === false);

// ---- findEmptyNapiCatches ----------------------------------------------------

check('注释-only 的 catch 算空（51/51 都是这种形态）',
  findEmptyNapiCatches('try { testNapi.foo() } catch (e) { /* 老 native 兼容 */ }').length === 1);

const bare = findEmptyNapiCatches('try { testNapi.foo() } catch (e) {}');
check('裸 {} 算空且被标记 bare',
  bare.length === 1 && bare[0].bare === true, JSON.stringify(bare));

check('catch 里有语句 → 不算（有内容即放行）',
  findEmptyNapiCatches("try { testNapi.foo() } catch (e) { log(e) }").length === 0);

check('try 里没有 testNapi → 不算（这道门禁只管跨语言调用）',
  findEmptyNapiCatches('try { other() } catch (e) { /* ignore */ }').length === 0);

// 承重：全仓 95 个 .catch() promise 处理器，算进来会让总数虚高一倍。
check('.catch() promise 处理器不算 try/catch',
  findEmptyNapiCatches('testNapi.foo().catch((e) => { /* ignore */ })').length === 0);

check('捕获到多个 NAPI 名并去重排序',
  findEmptyNapiCatches(
    'try { testNapi.b(); testNapi.a(); testNapi.b() } catch (e) { /* x */ }'
  )[0].napiNames.join(',') === 'a,b');

check('嵌套 try/catch 各自计入',
  findEmptyNapiCatches(
    'try { try { testNapi.a() } catch (e) { /* x */ } testNapi.b() } catch (e2) { /* y */ }'
  ).length === 2);

check('行号是 catch 关键字所在行',
  findEmptyNapiCatches('\n\ntry { testNapi.a() }\ncatch (e) { /* x */ }')[0].line === 4);

// ---- compareToBaseline（棘轮，双向）------------------------------------------

const baseline = { emptyCatchPerFile: { 'a.ets': 3, 'b.ets': 1 } };

check('数字不变 → 放行',
  (() => { const d = compareToBaseline({ 'a.ets': 3, 'b.ets': 1 }, baseline);
    return d.grew.length === 0 && d.added.length === 0; })());

check('某文件变多 → 失败并给出前后值',
  (() => { const d = compareToBaseline({ 'a.ets': 4, 'b.ets': 1 }, baseline);
    return d.grew.length === 1 && d.grew[0].before === 3 && d.grew[0].now === 4; })());

// 偿还必须被识别为改善，否则没人会去偿还。
check('某文件变少 → 记为偿还且不失败',
  (() => { const d = compareToBaseline({ 'a.ets': 1, 'b.ets': 1 }, baseline);
    return d.shrank.length === 1 && d.grew.length === 0 && d.added.length === 0; })());

// 与注释块棘轮不同：空 catch 包 NAPI 没有"新文件本来就需要"的情形，一处都不许有。
check('基线里没有的新文件出现 1 处即失败',
  (() => { const d = compareToBaseline({ 'a.ets': 3, 'b.ets': 1, 'new.ets': 1 }, baseline);
    return d.added.length === 1 && d.added[0].file === 'new.ets'; })());

check('文件从基线消失（被删/被清零）不算失败',
  (() => { const d = compareToBaseline({ 'a.ets': 3 }, baseline);
    return d.grew.length === 0 && d.added.length === 0; })());

if (failures > 0) {
  console.error(`[test-check-empty-catch-napi] ${failures} case(s) failed`);
  process.exitCode = 1;
} else {
  console.log('[test-check-empty-catch-napi] ALL PASS');
}
