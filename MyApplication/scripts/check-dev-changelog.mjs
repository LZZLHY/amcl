#!/usr/bin/env node
/** 开发日志轻量检查：只读 Markdown，不加载 SDK、依赖或私有 Git 历史。 */
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

export const LABELS = Object.freeze(['新增', '修复', '优化', '重构', '移除', '回退', '文档']);
// 13512611 时的历史身份集合只锁定编号和原时间，排序、正文、锚点及用户重排不参与摘要。
// 这样公开快照无需私仓提交对象，也不能借旧号段空隙插入新记录绕过单标签规则。
const LEGACY_MAX = 1001026;
const LEGACY_IDENTITIES = 'af6d6b5fa96e46b07e3d007b54cfd6c26718466499211bcea70ef5a774a89ebc';
// 八条原带删除线的退役记录及一条内容丢失占位同样锁定身份，不强制改成普通功能行。
const ANNOTATED_IDENTITIES = '3c749ee1473daa384e3eb96a9795a240689a0d9f75b8b0b3ffbb50e52fb3085e';
const NORMALIZED_BACKFILLS = new Set([1001023, 1001024, 1001025]);
export const DUPLICATE_RECORDS = Object.freeze([
  { id: 1000516, time: '2026-08-22 23:39:12', anchor: 'cl-1000516-20260822-233912' },
  { id: 1000516, time: '2026-08-23 02:02:44', anchor: 'cl-1000516-20260823-020244' },
  { id: 1000517, time: '2026-08-23 00:50:14', anchor: 'cl-1000517-20260823-005014' },
  { id: 1000517, time: '2026-08-23 03:44:25', anchor: 'cl-1000517-20260823-034425' },
]);

/** Markdown 表格中的转义竖线不是分隔符；代码跨度内的裸竖线仍需转义。 */
function cellsOf(line) {
  const cells = []; let start = 1;
  for (let index = 1; index < line.length; index++) {
    if (line[index] !== '|') continue;
    let slashes = 0;
    for (let prior = index - 1; prior >= 0 && line[prior] === '\\'; prior--) slashes++;
    if (slashes % 2 === 0) { cells.push(line.slice(start, index).trim()); start = index + 1; }
  }
  if (line.slice(start).trim()) cells.push(line.slice(start).trim());
  return cells;
}

/** 保留原时间字符串；不把缺失历史、空正文或非整数新编号解释为成功。 */
export function checkDevelopmentChangelog(text) {
  const errors = [], rows = [], visible = [], annotations = [];
  const issue = (code, line, message) => errors.push({ code, line, message });
  let version = '', table = 0, header = 0, fence = null;
  for (const [offset, raw] of text.replace(/^\uFEFF/, '').split(/\r?\n/).entries()) {
    const number = offset + 1, line = raw.trim();
    const marker = line.match(/^(`{3,}|~{3,})/);
    if (fence) {
      if (marker && marker[1][0] === fence[0] && marker[1].length >= fence.length) fence = null;
      continue;
    }
    if (marker) { fence = marker[1]; table = 0; header = 0; continue; }
    visible.push(raw);
    if (/^##\s/.test(line)) version = /^##\s+\d+\.\d+\.\d+\b/.test(line) ? line : '';
    if (!line.startsWith('|')) { table = 0; header = 0; continue; }
    const cells = cellsOf(line);
    if (cells[0] === 'versionCode') { header = cells.length; table = 0; continue; }
    if (header && cells.every(cell => /^:?-+:?$/.test(cell))) {
      table = cells.length === header ? header : 0; header = 0; continue;
    }
    if (table !== 5 && !/^\d{7}/.test(cells[0] ?? '')) continue;
    // 保留原退役标记及缺失占位；其完整身份集合在下方校验，不能借删除线隐藏新行。
    if (cells[0] === '1000458 / 1000457' || /^~~\d{7}~~$/.test(cells[0])) {
      annotations.push(`${cells[0]}\t${cells[1]}`); continue;
    }
    if (!/^\d{7,}$/.test(cells[0]) || !Number.isSafeInteger(Number(cells[0]))) {
      issue('INVALID_ID', number, '开发流水号必须为整数，不能加 a/b 等后缀'); continue;
    }
    const id = Number(cells[0]), time = cells[1] ?? '';
    const strict = id > LEGACY_MAX || NORMALIZED_BACKFILLS.has(id);
    const row = { id, time, line: number, cells, version, strict, raw };
    rows.push(row);
    if (!version) issue('VERSION_REQUIRED', number, '功能行必须位于版本节内');
    if (!strict) continue;
    if (table !== 5 || cells.length !== 5 || !line.endsWith('|')) {
      issue('FIVE_COLUMNS', number, '新记录必须在五列表头下且恰有五列');
    }
    const prefix = (cells[2] ?? '').match(/^\[([^\]]+)\]\s+\*\*\S.+?\*\*/);
    if (!prefix || !LABELS.includes(prefix[1])) {
      issue('SINGLE_LABEL', number, '描述须以一个七分类标签和加粗标题开头，禁止多标签及组合标签');
    }
    if (!/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\s+[+-]\d{2}:?\d{2}/.test(time)) {
      issue('TIMESTAMP', number, '新记录时间须精确到秒并含时区；不同编号允许同一时间戳');
    }
    if (!cells[3] || !cells[4]) issue('EMPTY_FIELD', number, '关联文件／模块和作者不能为空');
  }
  if (fence) issue('UNCLOSED_FENCE', 0, '代码围栏未闭合，后续记录可能被隐藏');

  const identity = row => `${row.id}\t${row.time}`;
  const legacy = rows.filter(row => row.id <= LEGACY_MAX).map(identity).sort().join('\n') + '\n';
  if (createHash('sha256').update(legacy).digest('hex') !== LEGACY_IDENTITIES) {
    issue('HISTORICAL_IDENTITY', 0, '旧编号／原时间集合改变；核对历史证据，不能重编号、删除或向旧号段补新记录');
  }
  if (createHash('sha256').update(annotations.sort().join('\n') + '\n').digest('hex') !== ANNOTATED_IDENTITIES) {
    issue('HISTORICAL_ANNOTATION', 0, '历史退役／缺失占位的编号、原时间或标记改变，不能借标记绕过新增行规则');
  }
  const byId = new Map(), anchors = new Map();
  for (const row of rows) {
    if (!byId.has(row.id)) byId.set(row.id, []);
    byId.get(row.id).push(row);
  }
  for (const [id, group] of byId) {
    if (group.length === 1) continue;
    const allowed = DUPLICATE_RECORDS.filter(record => record.id === id).map(identity).sort();
    if (JSON.stringify(group.map(identity).sort()) !== JSON.stringify(allowed)) {
      issue('DUPLICATE_ID', group[0].line, `${id} 出现非历史例外的重复编号`);
    }
  }
  const document = visible.join('\n');
  for (const match of document.matchAll(/<a\s+id="([^"]+)"\s*>\s*<\/a>/g)) {
    anchors.set(match[1], (anchors.get(match[1]) ?? 0) + 1);
  }
  for (const expected of DUPLICATE_RECORDS) {
    const group = rows.filter(row => identity(row) === identity(expected));
    const marker = `<a id="${expected.anchor}"></a>`;
    if (group.length !== 1 || !group[0].cells.at(-2)?.includes(marker) || anchors.get(expected.anchor) !== 1) {
      issue('HISTORICAL_ANCHOR', group[0]?.line ?? 0, `${identity(expected)} 的唯一锚点缺失、重复或指错记录`);
    }
  }
  for (const match of document.matchAll(/\]\(#(cl-[^)]+)\)/g)) {
    if (anchors.get(match[1]) !== 1) issue('BROKEN_REFERENCE', 0, `历史精确引用 #${match[1]} 未命中唯一锚点`);
  }
  // 旧表曾按时间穿插，不批量改序；新行与相邻行必须遵守本版本流水号倒序。
  for (let index = 1; index < rows.length; index++) {
    const before = rows[index - 1], after = rows[index];
    if (before.version === after.version && (before.strict || after.strict) && before.id < after.id) {
      issue('ORDER', after.line, '新记录必须按本版本开发流水号倒序排列');
    }
  }
  return { ok: errors.length === 0, records: rows.length, checkedLabels: rows.filter(row => row.strict).length,
    historicalDuplicateRows: DUPLICATE_RECORDS.length, errors };
}

/** CLI 仅接收显式文档路径和 JSON 输出选项；读失败、未知参数均以非零退出。 */
function main(args) {
  let file = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../docs/CHANGELOG.md');
  let json = false;
  for (let index = 0; index < args.length; index++) {
    if (args[index] === '--json') json = true;
    else if (args[index] === '--file' && args[index + 1] && !args[index + 1].startsWith('--')) file = path.resolve(args[++index]);
    else throw new Error(`未知或缺值参数：${args[index]}`);
  }
  const result = checkDevelopmentChangelog(fs.readFileSync(file, 'utf8'));
  console.log(json ? JSON.stringify(result) : `${result.ok ? 'PASS' : 'FAIL'} development changelog: ` +
    `${result.records} records, ${result.checkedLabels} labels checked\n` +
    result.errors.map(error => `${error.code} line ${error.line}: ${error.message}`).join('\n'));
  process.exitCode = result.ok ? 0 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(process.argv.slice(2)); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
