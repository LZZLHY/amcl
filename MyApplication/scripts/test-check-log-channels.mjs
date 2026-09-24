#!/usr/bin/env node
// scripts/test-check-log-channels.mjs
//
// check-log-channels.mjs 的定向自测。
//
// ⚠️ 本门禁的判据是「扫源码找疑似日志 sink」，这**正是最容易写成恒真的那一类**：
// 正则失效 / 作用域改窄 ⇒ 一个都扫不到 ⇒ 0 个违规 ⇒ 通过。
// 所以 §4 专门钉阳性对照：检测器在已知 sink 上必须真的命中，命中数为 0 一律硬失败。
//
// §2 是本门禁存在的理由本身：新长出来一条没登记的通道必须红。
// 它上线第一次运行就抓到两条（forge-installer.log 与 vendored openal-soft），
// 其中 forge-installer.log 是**调研报告与真机目录普查都没发现**的第 11 条通道。

import { analyze, readSources, findSinkSites } from './check-log-channels.mjs';


let failed = 0;
function check(name, cond, extra) {
  if (cond) {
    console.log(`  ok   ${name}`);
  } else {
    failed += 1;
    console.error(`  FAIL ${name}${extra ? `\n       ${extra}` : ''}`);
  }
}

const real = readSources();
/** 深拷贝一份 sources，避免用例之间互相污染。 */
const clone = (s) => ({ registryText: s.registryText, texts: new Map(s.texts) });

// ── 1. 正向：真实仓库通过
{
  const r = analyze(clone(real));
  check('real repo: 门禁通过', r.ok === true,
    r.fatal ?? JSON.stringify({ schema: r.schema, unregistered: r.unregistered, pc: r.positiveControl }));
  check('real repo: 通道数与 sink 数非零', r.channels > 0 && r.sites > 0, `${r.channels} / ${r.sites}`);
}

// ── 2. ⭐ 承重：新长出来一条没登记的日志落点 ⇒ 必须红
{
  const s = clone(real);
  s.texts.set('commons/src/main/ets/utils/NewThing.ets',
    'const p = ctx.filesDir + "/logs/newthing.log";\nlet f = fileIo.open(p, 0o102);\n');
  const r = analyze(s);
  check('新增未登记的 sink ⇒ 不通过', r.ok === false);
  check('新增未登记的 sink ⇒ 点名到文件与行号',
    r.unregistered.some((x) => x.rel.endsWith('NewThing.ets') && x.line === 2),
    JSON.stringify(r.unregistered));
}

// ── 3. 同样的调用点，若文件已被登记为 writer ⇒ 放行
{
  const s = clone(real);
  s.texts.set('commons/src/main/ets/utils/NewThing.ets',
    'let f = fileIo.open(ctx.filesDir + "/logs/newthing.log", 0o102);\n');
  s.registryText = s.registryText.replace(
    '"writers": ["entry/src/main/cpp/utils/amcl_log.cpp"],',
    '"writers": ["entry/src/main/cpp/utils/amcl_log.cpp", "commons/src/main/ets/utils/NewThing.ets"],');
  const r = analyze(s);
  check('登记之后同一个调用点 ⇒ 放行',
    !r.unregistered.some((x) => x.rel.endsWith('NewThing.ets')), JSON.stringify(r.unregistered));
}

// ── 3b. 路径存在变量里（回看 3 行）也要能命中 —— 这是检测器第一版漏掉的形状
{
  const sites = findSinkSites(
    'const p = ctx.filesDir + "/logs/newthing.log";\nlet f = fileIo.open(p, 0o102);\n', 'x.ets');
  check('路径在前一行的变量里 ⇒ 仍然命中', sites.length === 1 && sites[0].line === 2,
    JSON.stringify(sites));
}
{
  // 但回看不许过头：变量与日志无关时不该误报
  const sites = findSinkSites(
    'const p = ctx.filesDir + "/cache/blob.bin";\nlet f = fileIo.open(p, 0o102);\n', 'x.ets');
  check('变量与日志无关 ⇒ 不误报', sites.length === 0, JSON.stringify(sites));
}

// ── 4. ⭐ 承重：检测器失效必须硬失败，不许静默变绿
{
  // 把两个已知 sink 文件的内容抽空 ⇒ 阳性对照必须开火
  const s = clone(real);
  s.texts.set('entry/src/main/cpp/utils/amcl_log.cpp', '// nothing here\n');
  s.texts.set('entry/src/main/cpp/jvm/mc_launcher.cpp', '// nothing here\n');
  const r = analyze(s);
  check('已知 sink 文件扫不到东西 ⇒ 不通过', r.ok === false);
  check('已知 sink 文件扫不到东西 ⇒ 阳性对照点名',
    r.positiveControl.length >= 2, JSON.stringify(r.positiveControl));
}
{
  // 全仓一个都扫不到 ⇒ 更要硬失败
  const s = { registryText: real.registryText, texts: new Map([['a.ets', '// x\n']]) };
  const r = analyze(s);
  check('全仓零 sink ⇒ 不通过（不许当成"没有违规"）', r.ok === false);
  check('全仓零 sink ⇒ 明确说检测器坏了',
    r.positiveControl.some((x) => x.includes('检测器必然是坏的')), JSON.stringify(r.positiveControl));
}

// ── 5. schema：第一方通道必须有 writers
{
  const s = clone(real);
  s.registryText = s.registryText.replace(
    '"writers": ["entry/src/main/cpp/jvm/fork_run_java.cpp"]', '"writers": []');
  const r = analyze(s);
  check('第一方通道 writers 为空 ⇒ 不通过',
    r.ok === false && r.schema.some((x) => x.includes('forge_installer')), JSON.stringify(r.schema));
}

// ── 6. schema：writer 指向不存在的文件
{
  const s = clone(real);
  s.registryText = s.registryText.replace(
    'entry/src/main/cpp/jvm/fork_run_java.cpp', 'entry/src/main/cpp/jvm/does_not_exist.cpp');
  const r = analyze(s);
  check('writer 指向不存在的文件 ⇒ 不通过',
    r.ok === false && r.schema.some((x) => x.includes('does_not_exist')), JSON.stringify(r.schema));
}

// ── 7. schema：缺 gap / retention 字段（逼迫登记者显式回答「有没有缺口」）
//    用改名而不是删除：删掉最后一个字段会连带留下多余逗号 ⇒ 变成 JSON fatal，
//    那测的就不是 schema 判据了（第一版就是这么写错的）。
{
  const s = clone(real);
  s.registryText = s.registryText.replace('"gap": null', '"gapTypo": null');
  const r = analyze(s);
  check('缺 gap 字段 ⇒ 不通过', r.ok === false && r.schema.some((x) => x.includes('gap')),
    JSON.stringify(r.schema));
}
{
  const s = clone(real);
  s.registryText = s.registryText.replace('"retention": null', '"retentionTypo": null');
  const r = analyze(s);
  check('缺 retention 字段 ⇒ 不通过',
    r.ok === false && r.schema.some((x) => x.includes('retention')), JSON.stringify(r.schema));
}

// ── 8. 注册表损坏 ⇒ fatal
{
  const r = analyze({ registryText: '{ not json', texts: real.texts });
  check('注册表不是合法 JSON ⇒ fatal', r.ok === false && r.fatal !== null, String(r.fatal));
}
{
  const r = analyze({ registryText: '{"channels":[]}', texts: real.texts });
  check('注册表为空 ⇒ fatal', r.ok === false && r.fatal !== null, String(r.fatal));
}

// ── 9. 检测器不许把非日志的 fopen 拖进来（噪声会让门禁被摘掉）
{
  const cases = [
    ['FILE* f = fopen("/proc/meminfo", "r");', '/proc 读取'],
    ['FILE* f = fopen(optPath.c_str(), "w");', 'jvm.options 写入'],
    ['FILE *file = std::fopen(path.c_str(), "rb");', 'benchmark cache 读取'],
    ['// FILE* f = fopen(logPath, "w");  历史写法', '注释掉的例子'],
    ['FILE* f = fopen(logPath.c_str(), "r");', '读日志而不是创建'],
  ];
  for (const [line, why] of cases) {
    check(`不误报: ${why}`, findSinkSites(line + '\n', 'x.cpp').length === 0, line);
  }
  // 反过来，真的创建日志必须命中
  const positives = [
    'g_logFile = fopen(g_logPath.c_str(), "a");',
    'int fd = open(logFile, O_WRONLY | O_CREAT | O_TRUNC, 0644);',
    'freopen(logFile.c_str(), "a", stdout);',
  ];
  for (const line of positives) {
    check(`能命中: ${line.slice(0, 44)}`, findSinkSites(line + '\n', 'x.cpp').length === 1, line);
  }
}

console.log(failed === 0 ? `\n✅ ALL PASS` : `\n❌ ${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
