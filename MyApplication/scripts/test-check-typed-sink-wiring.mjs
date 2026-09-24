#!/usr/bin/env node
// scripts/test-check-typed-sink-wiring.mjs
//
// 门禁自身的自测。夹具**不写盘**：读真实仓库文件到内存字符串，再对字符串做定点替换。
// `mutate` 自我校验（命中不了 `from`、或替换后文本没变 ⇒ 抛），因为"夹具悄悄没生效"会让
// 断言变成**空真** —— 那比没有这条断言更糟（计划 §98 的自测踩过一次）。

import { analyze, readSources, parseSinkFields, parseWiredFields, SITES }
  from './check-typed-sink-wiring.mjs';

let failed = 0;
function check(name, cond, extra) {
  if (cond) console.log(`  ok   ${name}`);
  else { failed += 1; console.error(`  FAIL ${name}${extra ? `\n       ${extra}` : ''}`); }
}

function mutate(texts, key, from, to) {
  const before = texts[key];
  const hit = typeof from === 'string' ? before.includes(from) : from.test(before);
  if (!hit) throw new Error(`fixture broken: ${key} 里找不到 ${from}`);
  const after = before.replace(from, to);
  if (after === before) throw new Error(`fixture broken: ${key} 替换没生效`);
  return { ...texts, [key]: after };
}

function site(report, id) {
  return report.sites.find((s) => s.id === id);
}

const real = readSources();

// ── 1. 正向：真实仓库状态必须通过，且数字必须自洽
{
  const r = analyze(real);
  check('real repo: 通过', r.ok === true, r.fatal ?? JSON.stringify(r));
  check('real repo: 字段数非零（解析真的跑了）', r.sinkFields > 0, `${r.sinkFields}`);
  // ⭐ 不变式改成**逐站点**：扩到两个装配点之后，聚合的 wired+declaredUnwired 是槽位数，
  // 而"每个站点各自把 12 个字段都回答了"才是本门禁真正的命题。
  check('real repo: 两个装配点都被解析到',
    r.sites.length === Object.keys(SITES).length, JSON.stringify(r.sites.map((s) => s.id)));
  for (const s of r.sites) {
    check(`real repo: ${s.id} 接线数 + 声明例外数 == 字段总数`,
      s.wired + s.declaredUnwired === r.sinkFields,
      `${s.wired} + ${s.declaredUnwired} != ${r.sinkFields}`);
  }
  check('real repo: 槽位数 == 字段数 × 站点数',
    r.slots === r.sinkFields * r.sites.length, `${r.slots} vs ${r.sinkFields}*${r.sites.length}`);
  // 两个站点接的字段数**不同**是事实（GLFW 全接 / 后端 pull 部分接）。钉住它，否则"两个站点
  // 恰好一样"会让下面那些差异化断言变成恒真。
  check('real repo: GLFW 站点接得比后端 pull 站点多',
    site(r, 'typedInputSink').wired > site(r, 'SinkFor').wired,
    `${site(r, 'typedInputSink').wired} vs ${site(r, 'SinkFor').wired}`);
}

// ── 2. ⭐ 结构长出一个新 sink 字段而没人接 ⇒ 必须红，而且**两个站点都要点名**。
//        这正是扩到两个装配点真正买到的东西：此前只会点名 typedInputSink。
{
  const r = analyze(mutate(real, 'headerText',
    '    GlfwResetSinkFn reset = nullptr;',
    '    GlfwResetSinkFn reset = nullptr;\n    GlfwBrandNewSinkFn brandNew = nullptr;'));
  check('新增未接线字段 ⇒ 不通过', r.ok === false);
  check('新增未接线字段 ⇒ 两个站点都点名到 brandNew',
    r.missing.length === 2
      && r.missing.includes('typedInputSink.brandNew')
      && r.missing.includes('SinkFor.brandNew'), JSON.stringify(r.missing));
}

// ── 3. 已接线的字段被摘掉 ⇒ 必须红（回归保护），两个站点各测一次
{
  const r = analyze(mutate(real, 'wiringText', 'sink.wheel = typedWheelSink;', ''));
  check('摘掉 GLFW 的 sink.wheel ⇒ 点名到 typedInputSink.wheel',
    r.ok === false && r.missing.includes('typedInputSink.wheel'), JSON.stringify(r.missing));
  check('摘掉 GLFW 的 sink.wheel ⇒ **不**牵连后端站点',
    !r.missing.includes('SinkFor.wheel'), JSON.stringify(r.missing));
}
{
  const r = analyze(mutate(real, 'bridgeText', 'sink.wheel = WheelSink;', ''));
  check('摘掉后端 pull 的 sink.wheel ⇒ 点名到 SinkFor.wheel',
    r.ok === false && r.missing.includes('SinkFor.wheel'), JSON.stringify(r.missing));
  check('摘掉后端 pull 的 sink.wheel ⇒ **不**牵连 GLFW 站点',
    !r.missing.includes('typedInputSink.wheel'), JSON.stringify(r.missing));
}

// ── 4. 赋 nullptr **不算**接线：那与不写这一行等价，而"看起来接了"更糟
{
  const r = analyze(mutate(real, 'wiringText',
    'sink.focus = typedFocusSink;', 'sink.focus = nullptr;'));
  check('赋 nullptr 不算接线 ⇒ 点名到 typedInputSink.focus',
    r.ok === false && r.missing.includes('typedInputSink.focus'), JSON.stringify(r.missing));
}

// ── 5. 清单腐烂：后端 pull 的某条例外已经接上 ⇒ 那条理由成了假话，必须红。
{
  const r = analyze(mutate(real, 'bridgeText',
    'sink.reset = ResetSink;', 'sink.reset = ResetSink;\n    sink.absolute = KeySink;'));
  check('后端 pull 例外字段被接上 ⇒ 报 staleAllowlist',
    r.ok === false && r.staleAllowlist.some((s) => s.field === 'SinkFor.absolute'),
    JSON.stringify(r.staleAllowlist));
}

// ── 6. 清单腐烂之二：例外字段从结构里消失了 ⇒ 必须红，且**两个站点**都报
{
  const r = analyze(mutate(real, 'headerText',
    /\s*GlfwCaptureSinkFn capture = nullptr;/, ''));
  check('已接线字段从结构删除 ⇒ 两个站点都报 staleAllowlist',
    r.ok === false
      && r.staleAllowlist.some((s) => s.field === 'typedInputSink.capture')
      && r.staleAllowlist.some((s) => s.field === 'SinkFor.capture'),
    JSON.stringify(r.staleAllowlist));
}

// ── 7. 锚点改名 / 花括号不配对 ⇒ fatal（不是"0 个缺失 ⇒ 通过"）
{
  const r = analyze(mutate(real, 'headerText', 'struct GlfwInputSink', 'struct GlfwInputSinkV2'));
  check('结构改名 ⇒ fatal', r.ok === false && (r.fatal ?? '').includes('GlfwInputSink'),
    r.fatal ?? 'no fatal');
}
{
  const r = analyze(mutate(real, 'wiringText',
    'GlfwInputSink typedInputSink()', 'GlfwInputSink typedInputSinkRenamed()'));
  check('GLFW 装配函数改名 ⇒ fatal', r.ok === false && (r.fatal ?? '').includes('typedInputSink'),
    r.fatal ?? 'no fatal');
}
{
  // ⭐ 第二个装配点的锚点也必须硬失败。少了这一条，`SinkFor` 改名之后门禁会退化成
  // "只检查一个站点然后报全绿" —— 与 §102 那次"门禁在最该说话时沉默"同形。
  const r = analyze(mutate(real, 'bridgeText',
    'GlfwInputSink SinkFor(', 'GlfwInputSink SinkForRenamed('));
  check('后端 pull 装配函数改名 ⇒ fatal',
    r.ok === false && (r.fatal ?? '').includes('SinkFor'), r.fatal ?? 'no fatal');
}
{
  // 源文件整个读不到 ⇒ fatal，而不是"这个站点没有缺失"。
  const r = analyze({ ...real, bridgeText: undefined });
  check('装配点源文件缺失 ⇒ fatal',
    r.ok === false && (r.fatal ?? '').includes('SOURCES.bridge'), r.fatal ?? 'no fatal');
}

// ── 8. 未预期的字段类型 ⇒ fatal。挡的是"结构里混进一个不是函数指针的东西而解析悄悄跳过"。
{
  const r = analyze(mutate(real, 'headerText',
    '    GlfwResetSinkFn reset = nullptr;',
    '    GlfwResetSinkFn reset = nullptr;\n    uint32_t someFlag = nullptr;'));
  check('未预期字段类型 ⇒ fatal',
    r.ok === false && (r.fatal ?? '').includes('未预期的字段类型'), r.fatal ?? 'no fatal');
}

// ── 9. 解析器本身的直接断言
{
  const fields = parseSinkFields(real.headerText);
  check('context 不算 sink 字段', !fields.includes('context'), fields.join(','));
  check('19 个已知 sink 字段都在', ['key', 'button', 'absolute', 'relative', 'wheel', 'focus',
    'enter', 'capture', 'surface', 'reset', 'unsupportedMapping', 'diagnosticDrop', 'device',
    'surfaceContext', 'textSession', 'textCommit', 'textEditing', 'textCandidates', 'textSelection']
    .every((f) => fields.includes(f)), fields.join(','));
  const wired = parseWiredFields(real.wiringText);
  check('GLFW capture 已接线', wired.has('capture'));
  // `SinkFor` 赋 `sink.context`，而 context 不是 sink 字段 ⇒ 解析会收到它，analyze 必须
  // 把它排除掉而不是当成"赋了值但结构里没有"报 stale。
  const bridgeWired = parseWiredFields(real.bridgeText, SITES.SinkFor.marker, 'SinkFor');
  check('SinkFor 解析到 context（因此 analyze 必须显式排除它）', bridgeWired.has('context'));
  check('SinkFor 接 key/button/relative/wheel/focus/capture/device/context/reset 九条（文本扩展另接五条）',
    ['key', 'button', 'relative', 'wheel', 'focus', 'capture', 'device', 'surfaceContext', 'reset']
      .every((f) => bridgeWired.has(f))
      && ['textSession', 'textCommit', 'textEditing', 'textCandidates', 'textSelection']
        .every((f) => bridgeWired.has(f))
      && [...bridgeWired].filter((f) => f !== 'context').length === 14,
    [...bridgeWired].join(','));
}

console.log(failed === 0 ? 'ALL PASS' : `${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
