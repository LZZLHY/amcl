#!/usr/bin/env node
// 设备输出的纯解析器 —— 全部导出，供 scripts/test-device-automation.mjs 做反向自测。
//
// 为什么单独成文件：AGENTS.md §二.8 要求"判定产物里有没有某样东西的工具，本身要先在一个
// 已知含有它的样本上验证过"。判定逻辑与 I/O 混在一起就没法在样本上跑，于是那条纪律
// 事实上执行不了。⇒ 这里只有纯函数：输入字符串、输出结构，零副作用。
//
// ⚠️ 本文件里每一条正则都对应一个"永远匹配不到 ⇒ 永远不失败"的假绿风险
// （方案 §7 风险 5）。下面标了 ⚠️ 的三处是 2026-09-07 真机实测出来的形状陷阱，
// 不是猜的：
//   1. `param get` 的输出**带尾随空格**；
//   2. `ps -A` 的 CMD 列被截断到 15 字符（`com.amcl.launcher` → `m.amcl.launcher`）
//      ⇒ 按完整包名匹配永远匹配不到；
//   3. hilog 默认格式**不带年份与时区**，`-v year -v zone` 才带，两种形状都要能解析。

/** AMCL 的 hilog domain（commons/src/main/ets/common/Constants.ets）。 */
export const AMCL_LOG_DOMAINS = new Map([
  [0xa000, 'main'],
  [0xa001, 'download'],
  [0xa002, 'account'],
  [0xa003, 'launch'],
  [0xa004, 'modloader'],
  [0xa005, 'ui'],
  [0xa006, 'native'],
]);

/**
 * `hilog -r` 清空缓冲后**仍然存在**的一行（设备启动时刻）。
 * 契约 §8.5：时间锚点不得用"缓冲区最早一行"来定 —— 这条哨兵行就是原因。
 */
export const PERSISTENT_SENTINEL = '========Zeroth log of type: init';

/** 允许的时间锚点方法。`earliest-buffer-line` 刻意不在表里（见上）。 */
export const TIME_ANCHOR_METHODS = new Set([
  'injected-marker',    // L1a 之后：应用侧 log.mark
  'borrowed-consumer',  // 今天：借既有 want 参数消费者打的那行（施工记录 §S03.1）
  'wallclock',          // 兜底：宿主壁钟 + 设备 date
]);

// ============================================================
//  工具与设备身份
// ============================================================

/** `hdc -v` → `3.2.0f`；解析不出来返回 null（不猜）。 */
export function parseHdcVersion(text) {
  const match = /Ver:\s*([0-9][0-9A-Za-z.]*)/.exec(text ?? '');
  return match ? match[1] : null;
}

/**
 * `hdc list targets` → SN 数组。
 * 无设备时 hdc 输出 `[Empty]`；把它解析成空数组而不是一台名叫 `[Empty]` 的设备。
 */
export function parseTargets(text) {
  return (text ?? '')
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(line => line.length > 0 && line !== '[Empty]');
}

/** ⚠️ `param get` 的值带尾随空格（实测）⇒ 必须 trim。空值返回 null。 */
export function parseParamValue(text) {
  const value = (text ?? '').replace(/\r?\n/g, '').trim();
  return value.length > 0 ? value : null;
}

/** `uitest --version` → `6.0.2.3`。 */
export function parseUitestVersion(text) {
  const value = parseParamValue(text);
  return value && /^[0-9][0-9.]*$/.test(value) ? value : null;
}

/**
 * `bm dump -n <bundle>` → 应用身份。
 *
 * 输出形状是 `<bundle>:\n{ …json… }`，⇒ 从第一个 `{` 起 JSON.parse。
 * ⚠️ 这份 JSON 同时含 `metaData` 与 `metadata` 两个键。Node 的 JSON.parse 大小写敏感、
 * 能正常解析；PowerShell 的 `ConvertFrom-Json` 会因"重复键"直接拒收（实测）。
 * ⇒ 这是本编排器用 Node 而不是 PowerShell 的一条具体理由，别顺手改回去。
 */
export function parseBmDump(text) {
  const raw = text ?? '';
  const start = raw.indexOf('{');
  if (start < 0) return { ok: false, reason: 'no JSON object in bm dump output' };
  let parsed;
  try {
    parsed = JSON.parse(raw.slice(start));
  } catch (error) {
    return { ok: false, reason: `bm dump JSON parse failed: ${error.message}` };
  }
  const app = parsed.applicationInfo ?? {};
  return {
    ok: true,
    bundle: typeof parsed.name === 'string' ? parsed.name : null,
    versionCode: typeof parsed.versionCode === 'number' ? parsed.versionCode : null,
    versionName: typeof parsed.versionName === 'string' ? parsed.versionName : null,
    provisionType: typeof app.appProvisionType === 'string' ? app.appProvisionType : null,
    debug: typeof app.debug === 'boolean' ? app.debug : null,
    apiTargetVersion: typeof app.apiTargetVersion === 'number' ? app.apiTargetVersion : null,
  };
}

// ============================================================
//  进程观测
// ============================================================

/**
 * `ps -A` → 进程行。列是 `PID TTY TIME CMD`（表头实测：`   PID TTY          TIME CMD`）。
 * `hdc shell` 不能用管道 ⇒ 过滤在宿主侧做（AGENTS.md §三.5/§三.6）。
 */
export function parsePsRows(text) {
  const rows = [];
  for (const line of (text ?? '').split(/\r?\n/)) {
    const match = /^\s*(\d+)\s+(\S+)\s+(\d\d:\d\d:\d\d)\s+(.+?)\s*$/.exec(line);
    if (!match) continue;
    rows.push({ pid: Number(match[1]), tty: match[2], time: match[3], cmd: match[4] });
  }
  return rows;
}

/**
 * 在 `ps -A` 的行里找某个 bundle 的进程。
 *
 * ⚠️ 实测：CMD 列被截断到 15 字符，`com.amcl.launcher` 显示为 `m.amcl.launcher`。
 * ⇒ 只按完整包名相等匹配的实现**永远匹配不到**，而它的失败形态是"进程不存在"，
 * 会被读成"应用已退出"。因此这里同时接受"截断后缀"匹配，并把用到的规则回报出去，
 * 让报告能写明是怎么匹配上的（不可复核的匹配等于没匹配）。
 */
export function findBundleProcesses(text, bundle) {
  const rows = parsePsRows(text);
  const matched = [];
  for (const row of rows) {
    if (row.cmd === bundle) {
      matched.push({ ...row, rule: 'exact' });
      continue;
    }
    // 截断后缀：CMD 必须是包名的真后缀，且足够长以免误伤（`r` 之类的一字符后缀）。
    if (row.cmd.length >= 10 && bundle.endsWith(row.cmd)) {
      matched.push({ ...row, rule: 'truncated-suffix' });
    }
  }
  return matched;
}

// ============================================================
//  hilog
// ============================================================

/**
 * 解析一行 hilog。两种形状（实测）：
 *   默认：      `09-07 17:00:58.975 10467 10467 W C02C02/PARAM: msg`
 *   -v year -v zone： `CST 2026-09-07 17:00:57.855 41120 51741 E C02925/bms_behavior/bms_file: msg`
 * domain 字段是 `<类型字符><5 位十六进制>`，例如 `A0A003` = 类型 `A` + domain `0xA003`。
 * 解析不出来返回 null（调用方按需计入 unparsed，不得静默丢弃）。
 */
export function parseHilogLine(line) {
  const text = typeof line === 'string' ? line : '';
  const pattern =
    /^(?:([A-Z]{3,4})\s+)?(?:(\d{4})-)?(\d{2})-(\d{2})\s+(\d{2}:\d{2}:\d{2})(?:\.(\d{1,6}))?\s+(\d+)\s+(\d+)\s+([A-Z])\s+([0-9A-Za-z]{6})\/(\S+?):\s?([\s\S]*)$/;
  const match = pattern.exec(text);
  if (!match) return null;
  const [, zone, year, month, day, clock, fraction, pid, tid, level, domainField, tagPath, message] = match;
  const domainHex = domainField.slice(1);
  const domain = Number.parseInt(domainHex, 16);
  const tagParts = tagPath.split('/');
  return {
    zone: zone ?? null,
    year: year ? Number(year) : null,
    month: Number(month),
    day: Number(day),
    clock,
    millis: fraction ? Number(fraction.padEnd(3, '0').slice(0, 3)) : null,
    pid: Number(pid),
    tid: Number(tid),
    level,
    typeChar: domainField[0],
    domain: Number.isNaN(domain) ? null : domain,
    tag: tagParts[tagParts.length - 1],
    tagPath,
    message,
  };
}

/** 该行是否属于 AMCL 自己的 domain（0xA000–0xA006，类型字符 `A`）。 */
export function isAmclLine(parsed) {
  return Boolean(parsed) && parsed.typeChar === 'A' && AMCL_LOG_DOMAINS.has(parsed.domain);
}

/** 逐 domain 统计 AMCL 行数 —— §1.2 要求的"可以数的量"。 */
export function countAmclLines(text) {
  const counts = { total: 0, unparsed: 0, byDomain: {} };
  for (const line of (text ?? '').split(/\r?\n/)) {
    if (line.trim() === '') continue;
    const parsed = parseHilogLine(line);
    if (!parsed) { counts.unparsed += 1; continue; }
    if (!isAmclLine(parsed)) continue;
    counts.total += 1;
    const name = AMCL_LOG_DOMAINS.get(parsed.domain);
    counts.byDomain[name] = (counts.byDomain[name] ?? 0) + 1;
  }
  return counts;
}

/** 该行是不是那条清不掉的持久哨兵行。 */
export function isPersistentSentinel(line) {
  return typeof line === 'string' && line.includes(PERSISTENT_SENTINEL);
}

// ============================================================
//  借既有消费者（施工记录 §S03.1 的手法）
// ============================================================

/**
 * 找 `EntryAbility.consumeNotificationWant` 对合法 `amclSessionKey` 打的那行：
 *   `notification tap → open error sheet key=777`
 *
 * ⚠️ 刻意**不**匹配那个 `→`（U+2192）：它经 hdc / 控制台 / 文件三段编码，
 * 任一段转码失败都会让正则永远匹配不到，而失败形态是"通道不通"这个**错误结论**
 * （施工记录 §S03.2 已经因为类似原因误判过一次）。只匹配 ASCII 骨架 + key。
 *
 * @param {string} text 任意日志文本（hilog 流或文件日志都可以）
 * @param {number|string} [expectedKey] 给了就只认这个 key（防止把上一轮的行算到本轮）
 */
export function findBorrowedConsumerHits(text, expectedKey) {
  const wanted = expectedKey === undefined || expectedKey === null
    ? null : String(expectedKey);
  const hits = [];
  for (const line of (text ?? '').split(/\r?\n/)) {
    const match = /notification tap\b[^\n]*?key=(\d+)/.exec(line);
    if (!match) continue;
    if (wanted !== null && match[1] !== wanted) continue;
    hits.push({ key: match[1], line: line.trim() });
  }
  return hits;
}

// ============================================================
//  启动器文件日志
// ============================================================

/** 文件日志行：`[2026-09-07 13:22:51][I][EntryAbility] msg`（实测形状）。 */
export function parseFileLogLine(line) {
  const match =
    /^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]\[([A-Z])\]\[([^\]]+)\]\s?([\s\S]*)$/
      .exec(typeof line === 'string' ? line : '');
  if (!match) return null;
  return { timestamp: match[1], level: match[2], tag: match[3], message: match[4] };
}

/** `========== AMCL Session Start: 2026-09-07 13:21:29 ==========` → 时间戳数组。 */
export function findSessionStarts(text) {
  const stamps = [];
  for (const line of (text ?? '').split(/\r?\n/)) {
    const match = /AMCL Session Start:\s*(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})/.exec(line);
    if (match) stamps.push(match[1]);
  }
  return stamps;
}

// ============================================================
//  时间锚点
// ============================================================

/**
 * 校验时间锚点。契约 §8.5：**不得**用"缓冲区最早一行"。
 *
 * 除了那条持久哨兵行，实测还有第二个理由：hilog 的行**不是严格按时间有序**的
 * （3 秒采样里第二行的时间戳早于第一行）⇒ "最早一行"本身就不是一个良定义的量。
 */
export function validateTimeAnchor(anchor) {
  const issues = [];
  if (!anchor || typeof anchor !== 'object') {
    return ['timeAnchor is missing'];
  }
  if (!TIME_ANCHOR_METHODS.has(anchor.method)) {
    issues.push(
      `timeAnchor.method '${anchor.method}' is not allowed; use one of ` +
      `${[...TIME_ANCHOR_METHODS].join(' / ')} (contract §8.5 forbids earliest-buffer-line)`);
  }
  if (typeof anchor.deviceTime !== 'string' || anchor.deviceTime.trim() === '') {
    issues.push('timeAnchor.deviceTime must be a non-empty string');
  }
  if (typeof anchor.hostTime !== 'string' || anchor.hostTime.trim() === '') {
    issues.push('timeAnchor.hostTime must be a non-empty string');
  }
  return issues;
}

/** `date +%Y-%m-%dT%H:%M:%S%z` → 设备时间字符串（实测 `2026-09-07T16:52:46+0800`）。 */
export function parseDeviceDate(text) {
  const match = /(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{4})/.exec(text ?? '');
  return match ? match[1] : null;
}

/** `hdc fport ls` → 转发规则行；无规则时设备端输出 `[Empty]`。 */
export function parseFportRules(text) {
  return (text ?? '')
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(line => line.length > 0 && line !== '[Empty]');
}

/** `ls -la <path>` 是否命中"不存在"。用来读 S1 标记的存在性而不误判。 */
export function looksMissing(text) {
  return /No such file or directory|not found/i.test(text ?? '');
}

/**
 * `ls <dir>` → 条目数组（宿主侧过滤，不用管道）。
 *
 * ⚠️ 目录不存在时 `ls` 输出的是一句错误（`ls: …: No such file or directory`）。
 * 若逐 token 过滤，`ls:` / `No` / `such` 会被当成条目 ⇒ "目录不存在"变成"有 6 个条目"。
 * 因此先整体判定，再拆分。
 */
export function parseLsNames(text) {
  const raw = text ?? '';
  if (looksMissing(raw)) return [];
  return raw
    .split(/\r?\n/)
    .flatMap(line => line.trim().split(/\s+/))
    .map(name => name.trim())
    .filter(name => name.length > 0);
}
