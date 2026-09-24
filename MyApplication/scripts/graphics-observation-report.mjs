#!/usr/bin/env node
/** 从本地证据提取公共帧统计，保留进程/生命周期分段和真实测量范围。
 * 不输出原始游戏日志，不平均百分位数，不将滚动窗口当作整局 GPU/CPU 性能。
 * 对比必须使用完整的同场景实验配置；缺失字段只能生成观测报告，不能给 A/B 结论。
 */
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

export const comparisonKeys = ['device', 'osBuild', 'gpuDriver', 'gameVersion', 'loader', 'modsSha256',
  'world', 'cameraRoute', 'resolution', 'renderScale', 'renderDistance', 'simulationDistance',
  'vsync', 'fpsLimit', 'jdk', 'heapMb', 'settingsSha256', 'cacheState', 'warmupSeconds', 'durationSeconds'];
const numeric = ['pid', 'presentCount', 'surfaceGeneration', 'intervalSamples', 'sampleWindow',
  'frameP50Us', 'frameP95Us', 'frameP99Us', 'long50ms', 'long100ms', 'long1000ms',
  'boundaryResets', 'swapSamples', 'segment', 'swapFailures', 'swapP95Us', 'failureSequence', 'failurePresentCount'];
const textFields = ['profile', 'provider', 'measurementScope'];
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
/** 白名单导出：任何账号、路径、聊天等邻接日志都不会进入结果。 */
export function observationReport(log, configuration, selection = {}) {
  if (!configuration || typeof configuration !== 'object' || Array.isArray(configuration)) throw new Error('configuration must be an object');
  const groups = new Map();
  let parsedCount = 0;
  for (const [index, line] of log.split(/\r?\n/).entries()) {
    const marker = line.indexOf('graphics_frame_stats ');
    if (marker < 0 || (selection.fromLine && index + 1 < selection.fromLine) || (selection.toLine && index + 1 > selection.toLine)) continue;
    const snapshot = JSON.parse(line.slice(marker + 'graphics_frame_stats '.length).trim());
    if (snapshot.schemaVersion !== 1 || textFields.some(key => typeof snapshot[key] !== 'string') ||
        numeric.some(key => !Number.isSafeInteger(snapshot[key]) || snapshot[key] < 0) || snapshot.pid <= 0 ||
        typeof snapshot.foreground !== 'boolean' || snapshot.sampleWindow !== Math.min(1024, snapshot.intervalSamples) ||
        snapshot.frameP50Us > snapshot.frameP95Us || snapshot.frameP95Us > snapshot.frameP99Us ||
        snapshot.gpuTimeUs !== null || snapshot.cpuRenderTimeUs !== null || snapshot.uploadTimeUs !== null ||
        snapshot.measurementScope !== 'present-interval-and-swap-call') throw new Error('invalid graphics observation at line ' + (index + 1));
    if (selection.pid && snapshot.pid !== selection.pid) continue;
    if (selection.profile && snapshot.profile !== selection.profile) continue;
    ++parsedCount;
    const sample = Object.fromEntries([...textFields, ...numeric, 'foreground'].map(key => [key, snapshot[key]]));
    // 兼容旧证据；新协议必须保留采样关闭、丢样及观测成本，不能把无样本的0分位数当作更快。
    for (const key of ['samplesEnabled', 'observerCostEnabled']) if (Object.hasOwn(snapshot, key)) {
      if (typeof snapshot[key] !== 'boolean') throw new Error('invalid observation mode: ' + key);
      sample[key] = snapshot[key];
    }
    for (const key of ['sampledPresentCount', 'droppedSamples', 'observerCostSamples', 'observerCostTotalNs', 'observerCostMaxNs']) {
      if (!Object.hasOwn(snapshot, key)) continue;
      if (snapshot[key] !== null && (!Number.isSafeInteger(snapshot[key]) || snapshot[key] < 0)) throw new Error('invalid observation cost: ' + key);
      sample[key] = snapshot[key];
    }
    sample.gpuTimeUs = null; sample.cpuRenderTimeUs = null; sample.uploadTimeUs = null;
    const key = [sample.pid, sample.profile, sample.provider, sample.segment].join(':');
    const previous = groups.get(key);
    if (previous && (sample.presentCount < previous.last.presentCount || sample.intervalSamples < previous.last.intervalSamples))
      throw new Error('non-monotonic counters within a lifecycle segment');
    groups.set(key, { firstLine: previous?.firstLine ?? index + 1, lastLine: index + 1,
      observations: (previous?.observations ?? 0) + 1, firstPresentCount: previous?.firstPresentCount ?? sample.presentCount, last: sample });
  }
  if (!parsedCount) throw new Error('no matching graphics observations');
  const configurationCopy = {};
  for (const key of [...comparisonKeys, 'hapSha256', 'translatorSha256', 'purpose']) {
    if (Object.hasOwn(configuration, key)) configurationCopy[key] = configuration[key];
  }
  return { schemaVersion: 1, sourceSha256: digest(log), configuration: configurationCopy,
    selection, parsedCount, segments: [...groups.values()],
    measurement: 'Each percentile describes the last <=1024 intervals in one lifecycle segment; long-frame counts describe that entire segment. No aggregate FPS or GPU time inferred.' };
}
/** 实验身份必须逐项相等；进程身份/翻译器是被比较的变量，不能掩盖其他配置变化。 */
export function compareObservations(left, right) {
  if ([left, right].some(report => report.segments.some(segment => segment.last.samplesEnabled === false)))
    throw new Error('disabled samples cannot provide frame-time comparison');
  for (const key of comparisonKeys) {
    if (!Object.hasOwn(left.configuration, key) || !Object.hasOwn(right.configuration, key) ||
        left.configuration[key] === null || left.configuration[key] === '' ||
        JSON.stringify(left.configuration[key]) !== JSON.stringify(right.configuration[key]))
      throw new Error('incomparable experiment configuration: ' + key);
  }
  for (const report of [left, right]) {
    for (const key of ['hapSha256', 'translatorSha256'])
      if (!/^[a-f0-9]{64}$/.test(report.configuration[key] ?? '')) throw new Error('missing artifact identity: ' + key);
    if (report.segments.length !== 1 || !report.segments[0].last.foreground || report.segments[0].last.sampleWindow < 100 ||
        report.segments[0].last.failureSequence) throw new Error('select one healthy foreground segment with >=100 intervals');
  }
  const a = left.segments[0].last, b = right.segments[0].last;
  if (a.provider !== b.provider) throw new Error('window provider differs');
  return { schemaVersion: 1, configuration: left.configuration,
    left: { sourceSha256: left.sourceSha256, sample: a }, right: { sourceSha256: right.sourceSha256, sample: b },
    deltasUs: Object.fromEntries(['frameP50Us', 'frameP95Us', 'frameP99Us', 'swapP95Us'].map(key => [key, b[key] - a[key]])),
    limitation: 'A single controlled sample comparison; not a thermal or multi-device benchmark. Percentiles are not averaged.' };
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const value = flag => { const at = process.argv.indexOf(flag); return at < 0 ? '' : process.argv[at + 1]; };
    let report;
    if (value('--compare')) report = compareObservations(JSON.parse(fs.readFileSync(value('--compare'), 'utf8')),
      JSON.parse(fs.readFileSync(value('--with'), 'utf8')));
    else report = observationReport(fs.readFileSync(value('--log'), 'utf8'), JSON.parse(fs.readFileSync(value('--config'), 'utf8')),
      { pid: Number(value('--pid')) || undefined, profile: value('--profile') || undefined,
        fromLine: Number(value('--from-line')) || undefined, toLine: Number(value('--to-line')) || undefined });
    if (!value('--out')) throw new Error('--out is required');
    fs.writeFileSync(value('--out'), JSON.stringify(report, null, 2) + '\n');
    console.log('graphics-observation-report PASS: ' + value('--out'));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
