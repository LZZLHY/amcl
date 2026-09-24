#!/usr/bin/env node
// scripts/test-check-log-noise-rules.mjs
//
// check-log-noise-rules.mjs 的定向自测。
//
// ⚠️ 只证明"当前是绿的"是不够的 —— 那种检查**在它坏掉之后也一样是绿的**。
// 所以这里逐条制造分叉，要求门禁真的红；并且要求"解析不出来"走**硬失败**
// 而不是"0 个分歧 ⇒ 通过"。
//
// 其中 §5 与 §6 是本批的**承重用例**：它们把「修复本身」钉住 ——
//   §5 复活旧的子串判据（把 'exception' 当错误信号）⇒ 必须红；
//   §6 删掉那条 ERROR 级噪声规则                    ⇒ 必须红。
// 这两条一旦变绿，说明 1000591 之后那个「健康会话被判 CRASHED」的缺陷又回来了。

import { analyze, readSources } from './check-log-noise-rules.mjs';

let failed = 0;
function check(name, cond, extra) {
  if (cond) {
    console.log(`  ok   ${name}`);
  } else {
    failed += 1;
    console.error(`  FAIL ${name}${extra ? `\n       ${extra}` : ''}`);
  }
}

/** 必须真的替换到东西：夹具本身写错了会让用例变成空真。 */
function mutate(texts, key, from, to) {
  const before = texts[key];
  const hit = typeof from === 'string' ? before.includes(from) : from.test(before);
  if (!hit) throw new Error(`fixture broken: ${key} 里找不到 ${from}`);
  const after = before.replace(from, to);
  if (after === before) throw new Error(`fixture broken: ${key} 替换没生效`);
  return { ...texts, [key]: after };
}

/** 某条语料是否出现在失败列表里。 */
const hasFixture = (r, name) => r.fixtures.some((f) => f.startsWith(name + ':'));

const real = readSources();

// ── 1. 正向：真实仓库状态必须通过
{
  const r = analyze(real);
  check('real repo: 门禁通过', r.ok === true,
    r.fatal ?? JSON.stringify({ schema: r.schema, mirror: r.mirror, fixtures: r.fixtures, structure: r.structure }));
  check('real repo: 规则数与语料数非零', r.ruleCount > 0 && r.caseCount > 0,
    `${r.ruleCount} / ${r.caseCount}`);
}

// ── 2. JSON 侧改一个 needle ⇒ 镜像不一致
{
  const r = analyze(mutate(real, 'jsonText',
    '"needle": "online mod data expired"', '"needle": "online mod data expiredX"'));
  check('JSON 改 needle ⇒ 不通过', r.ok === false);
  check('JSON 改 needle ⇒ 指出是 mod-online-data-expired',
    r.mirror.some((m) => m.includes('mod-online-data-expired') && m.includes('needle')),
    JSON.stringify(r.mirror));
}

// ── 3. ETS 侧把一条规则的 id 改掉 ⇒ 镜像逐条比对必须指出是第几条
//    ⚠️ 这里刻意用单行字面量替换：LogNoiseFilter.ets 是 **CRLF**，而 config/*.json
//    与新建的 .ets 是 LF，跨行的字面量夹具会静默匹配不上（keymap 自测吃过同一个亏）。
{
  const r = analyze(mutate(real, 'noiseEtsText',
    "id: 'log4j-no-tty',", "id: 'log4j-no-tty-renamed',"));
  check('ETS 改一条规则的 id ⇒ 不通过', r.ok === false);
  check('ETS 改一条规则的 id ⇒ 报出两侧 id',
    r.mirror.some((m) => m.includes('id 不等') && m.includes('log4j-no-tty')),
    JSON.stringify(r.mirror));
}

// ── 3b. JSON 侧整条删掉 ⇒ 条数不等
{
  const r = analyze(mutate(real, 'jsonText',
    /    \{\r?\n      "id": "log4j-no-tty",[\s\S]*?\r?\n    \},\r?\n/, ''));
  check('JSON 少一条规则 ⇒ 不通过', r.ok === false);
  check('JSON 少一条规则 ⇒ 报出条数不等',
    r.mirror.some((m) => m.includes('条数不等')), JSON.stringify(r.mirror));
}

// ── 4. NOISE_RULES 改名 ⇒ 硬失败（不许静默放行）
{
  const r = analyze(mutate(real, 'noiseEtsText',
    'const NOISE_RULES: LogNoiseRule[] = [', 'const NOISE_RULES_V2: LogNoiseRule[] = ['));
  check('NOISE_RULES 改名 ⇒ fatal 而不是通过', r.ok === false && r.fatal !== null, String(r.fatal));
}

// ── 5. ⭐ 承重：复活旧的子串判据（把 'exception' 当错误信号）
//    旧实现就是 low.indexOf('exception')。它会命中：
//      · Controlify 的 [WARN] 行（行内有 ClassNotFoundException）
//      · MobileGlues 散文里的普通英文单词 "exceptions"
{
  const r = analyze(mutate(real, 'signalEtsText',
    "const ERROR_LEVEL_MARKERS: string[] = ['/error]', '/fatal]', '[error]', '[fatal]'];",
    "const ERROR_LEVEL_MARKERS: string[] = ['/error]', '/fatal]', '[error]', '[fatal]', 'exception'];"));
  check('复活 exception 子串判据 ⇒ 不通过', r.ok === false);
  check('复活 exception 子串判据 ⇒ Controlify 的 WARN 行被误判',
    hasFixture(r, 'survey-6.3-controlify-mixin-target-absent'), JSON.stringify(r.fixtures));
  check('复活 exception 子串判据 ⇒ MG 散文 "exceptions" 被误判',
    hasFixture(r, 'survey-6.3-mobileglues-prose-exceptions'), JSON.stringify(r.fixtures));
}

// ── 6. ⭐ 承重：删掉那条 ERROR 级噪声规则
//    它是 7 行幸存行里唯一带 /ERROR] 的一条 ⇒ 按级别判定救不了它，只能靠噪声规则。
//    这条一旦没了，1000591 之后健康会话会被判成 CRASHED。
//    两侧同时改成一个匹配不到任何东西的 needle：这样镜像仍然一致、规则质量仍然合格，
//    唯一变化就是这条规则**不再命中** —— 把变量隔离到「这条规则有没有生效」这一个上。
{
  const dead = 'zzz-needle-that-matches-nothing';
  let t = mutate(real, 'jsonText', '"needle": "online mod data expired"', `"needle": "${dead}"`);
  t = mutate(t, 'noiseEtsText', "needle: 'online mod data expired',", `needle: '${dead}',`);
  const r = analyze(t);
  check('mod-online-data-expired 失效 ⇒ 不通过', r.ok === false);
  check('mod-online-data-expired 失效 ⇒ 那条 ERROR 级幸存行重新被判成错误',
    hasFixture(r, 'survey-6.3-xaero-versions-error-level'), JSON.stringify(r.fixtures));
}

// ── 7. ⭐ 反向承重：削掉 Fabric 的级别排版 ⇒ 真实启动失败必须漏判并被抓住
//    本批是在**收紧**判定，收紧的失效形态是静默漏报。反向语料就是防这个的。
{
  const r = analyze(mutate(real, 'signalEtsText',
    "'/error]', '/fatal]', '[error]', '[fatal]'", "'/error]', '/fatal]'"));
  check('去掉 [ERROR] 排版 ⇒ 不通过', r.ok === false);
  // 断言必须落在**单行**那条语料上。带 Java 异常顶行的那条同时有两个独立信号，
  // 删掉任一个它都还是绿的 —— 用它做断言等于什么都没证明（本用例第一版就是这么写的）。
  check('去掉 [ERROR] 排版 ⇒ Fabric 单行启动失败被漏判并报出来',
    hasFixture(r, 'reverse-fabric-loader-error-only'), JSON.stringify(r.fixtures));
}

// ── 8. 结构断言：把 hasErrorSignal 从逐行改成整段 ⇒ 等价模型可能失效，必须红
{
  const r = analyze(mutate(real, 'signalEtsText',
    'if (lineLooksLikeError(lines[i])) return true;', 'if (lines[i].length > 0) return true;'));
  check('hasErrorSignal 不再逐行 ⇒ 结构断言红',
    r.ok === false && r.structure.length > 0, JSON.stringify(r.structure));
}

// ── 9. 规则质量：needle 大写
{
  const r = analyze(mutate(real, 'jsonText', '"needle": "libflite"', '"needle": "libFlite"'));
  check('needle 含大写 ⇒ 报规则质量问题',
    r.ok === false && r.schema.some((s) => s.includes('全小写')), JSON.stringify(r.schema));
}

// ── 10. 规则质量：needle 过短（过宽的规则会静默吃掉真实错误）
{
  const r = analyze(mutate(real, 'jsonText', '"needle": "libflite"', '"needle": "flite"'));
  check('needle 过短 ⇒ 报规则质量问题',
    r.ok === false && r.schema.some((s) => s.includes('过宽')), JSON.stringify(r.schema));
}

// ── 11. 语料文件损坏 ⇒ 硬失败
{
  const r = analyze({ ...real, casesText: '{ "cases": [] }' });
  check('语料为空 ⇒ fatal 而不是通过', r.ok === false && r.fatal !== null, String(r.fatal));
}

// ── 12. 判据字面量整个消失 ⇒ 硬失败（不许当成"没有判据 ⇒ 没有分歧"）
{
  const r = analyze(mutate(real, 'signalEtsText',
    'const JAVA_THROWABLE_TOP_LINE =', 'const JAVA_THROWABLE_TOP_LINE_RENAMED ='));
  check('异常顶行正则改名 ⇒ fatal 而不是通过', r.ok === false && r.fatal !== null, String(r.fatal));
}

console.log(failed === 0 ? `\n✅ ALL PASS` : `\n❌ ${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
