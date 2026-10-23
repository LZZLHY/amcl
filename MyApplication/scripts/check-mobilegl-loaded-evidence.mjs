/**
 * 现成MobileGL生产诊断的实际加载库取证薄门。它保留原功能admission与copy资格的区分，
 * 只核已完成报告/唯一run/PID/外部NAPI返回/原始实际副本与最终HAP的字节绑定。
 * 没有重算shader或像素算法，也不将函数正常返回等同于应用自然退出/完整CTS。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';
import { assertExternalOutputPath } from './lib/workspace-paths.mjs';

const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const hex = value => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);

/** 元数据只允许唯一字段；非原始UTF8/重复marker/缺close外部返回都不能授予资格。 */
function metadata(line, prefix) {
  if (!line.startsWith(prefix + ' ')) throw new Error('Missing metadata ' + prefix);
  const result = {};
  for (const match of line.slice(prefix.length + 1).matchAll(/(?:^|\s)(\w+)=([^\s]*)/g)) {
    if (Object.hasOwn(result, match[1])) throw new Error('Duplicate metadata field ' + match[1]);
    result[match[1]] = match[2];
  }
  return result;
}

/** expected PID/run/HAP来自宿主独立观测；loadedBytes必须是设备本次run实际副本。 */
export function auditMobileGlLoadedEvidence(report, returned, hap, loadedBytes, expected) {
  const result = { ok: false, functionalPass: false, artifactQualification: 'INCOMPLETE', issues: [],
    reportBytes: report.length, reportSha256: sha(report), returnSha256: sha(returned),
    hapSha256: sha(hap), loadedLibrarySha256: sha(loadedBytes) };
  const reject = reason => result.issues.push(reason);
  try {
    if (!expected || !Number.isSafeInteger(expected.pid) || expected.pid <= 0 ||
        !new RegExp('^' + expected.pid + '-\\d+$').test(expected.runId ?? '') ||
        !hex(expected.hapSha256) || !hex(expected.librarySha256))
      throw new Error('Independent PID/runId/final HAP/library SHA required');
    if (sha(hap) !== expected.hapSha256) reject('Actual final HAP differs from independent frozen artifact');
    const library = readUniqueZipEntry(hap, 'libs/arm64-v8a/libmobilegl.so');
    if (library.length < 64 || library.toString('hex', 0, 6) !== '7f454c460201' || library.readUInt16LE(18) !== 183)
      reject('Final MobileGL payload is not ELF64 AArch64');
    if (sha(library) !== expected.librarySha256 || sha(loadedBytes) !== expected.librarySha256 || !library.equals(loadedBytes))
      reject('Actual loaded-image copy does not match independently frozen HAP library bytes');
    const text = Buffer.from(report).toString('utf8');
    if (!Buffer.from(text).equals(Buffer.from(report)) || !text.endsWith('\n')) reject('Truncated or invalid UTF8 qualification report');
    const lines = text.split(/\r?\n/); if (lines.at(-1) === '') lines.pop();
    const one = prefix => {
      const found = lines.filter(line => line.startsWith(prefix + ' '));
      if (found.length !== 1) throw new Error('Record must occur once: ' + prefix);
      return metadata(found[0], prefix);
    };
    const run = one('MOBILEGL_QUAL_RUN'), end = one('MOBILEGL_QUAL_END');
    if (!lines[0]?.startsWith('MOBILEGL_QUAL_RUN ') || !lines.at(-1)?.startsWith('MOBILEGL_QUAL_END ')) reject('Run header and final END are incomplete');
    for (const record of [run, end]) if (record.runId !== expected.runId || record.processPid !== String(expected.pid)) reject('Run/PID differs from independent observation');
    if (run.runId !== run.processPid + '-' + run.startSteadyNs || !/^\d+$/.test(run.startUnixNs ?? '') || !/^\d+$/.test(run.startSteadyNs ?? '')) reject('Malformed run clocks');
    const original = [
      'AMCL_MOBILEGL_CAPABILITY_V1', 'profile=mobilegl game_api=OPENGL internal_transport=VULKAN',
      'mobilegl_shader_compile_link_draw_readback_verified', 'mobilegl_present_success_1',
      'mobilegl_present_success_2', 'mobilegl_present_success_3',
      'shader_compilations=2 program_links=1 pixel_verifications=5 successful_presents=3 present_counter=3 cleanup_complete=1',
      'admission=PASS reason=mobilegl_launch_prerequisites_verified',
      'lifecycle_smoke=NOT_RUN (rotation/background/input/Minecraft are separate checks)'];
    // 固定冷PID现成executor的原始成功文本必须完整且按原顺序出现；不是搜索任一历史PASS。
    result.functionalPass = original.every((line, index) => lines[index + 1] === line);
    if (!result.functionalPass) reject('Production capability is missing, failed, warm-countered or out of order');
    if (lines.length !== original.length + 3 || lines.some(line => line.startsWith('MOBILEGL_QUAL_FAILURE')))
      reject('Unknown/failed/duplicate qualification record');
    const image = one('MOBILEGL_QUAL_IMAGE');
    const directory = '/data/storage/el2/base/haps/entry/files/mobilegl-capability-probe/' + expected.runId;
    if (image.library !== 'libmobilegl.so' || image.anchor !== 'eglGetDisplay' ||
        path.posix.basename(image.image ?? '') !== 'libmobilegl.so' || !/^0x[0-9a-f]+$/i.test(image.imageBase ?? '') ||
        BigInt(image.imageBase ?? '0') === 0n || image.bytes !== String(library.length) || image.path !== directory + '/loaded-libmobilegl.so')
      reject('Actual canonical symbol owner/copy byte count/run path missing');
    if (expected.imagePath && image.image !== expected.imagePath) reject('Actual loaded image path differs from independent observation');
    if (end.imageCopyComplete !== '1' || end.verdict !== 'COMPLETE') reject('Artifact qualification did not complete');
    const matches = [...Buffer.from(returned).toString('utf8').matchAll(/MOBILEGL_QUAL_RETURN\s+runId=([^\s]+)\s+processPid=(\d+)\s+reportBytes=(\d+)\s+returned=(\d+)\s+verdict=([^\s]+)/g)]
      .filter(row => row[1] === expected.runId && row[2] === String(expected.pid));
    if (matches.length !== 1 || matches[0][3] !== String(report.length) || matches[0][4] !== '1' || matches[0][5] !== 'COMPLETE')
      reject('Independent post-close function RETURN absent, duplicated or wrong byte count');
    result.runId = run.runId; result.pid = expected.pid; result.image = image;
    result.ok = result.issues.length === 0;
    result.artifactQualification = result.ok ? 'COMPLETE' : 'INCOMPLETE';
  } catch (error) { reject(error.message); }
  return result;
}

/** CLI只读实际文件；全部身份需调用方明确提供，不能从report自动补预期。 */
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const names = new Set(['--report', '--return-marker-file', '--hap', '--loaded-library', '--expected-pid', '--expected-run-id', '--expected-hap-sha', '--expected-library-sha', '--expected-image', '--out']);
    const flags = {}, args = process.argv.slice(2);
    for (let i = 0; i < args.length; i += 2) {
      if (!names.has(args[i]) || !args[i + 1] || Object.hasOwn(flags, args[i])) throw new Error('Invalid/duplicate input ' + args[i]);
      flags[args[i]] = args[i + 1];
    }
    for (const required of ['--report', '--return-marker-file', '--hap', '--loaded-library', '--expected-pid', '--expected-run-id', '--expected-hap-sha', '--expected-library-sha'])
      if (!flags[required]) throw new Error('Missing independent input ' + required);
    const result = auditMobileGlLoadedEvidence(fs.readFileSync(flags['--report']), fs.readFileSync(flags['--return-marker-file']), fs.readFileSync(flags['--hap']), fs.readFileSync(flags['--loaded-library']),
      { pid: Number(flags['--expected-pid']), runId: flags['--expected-run-id'], hapSha256: flags['--expected-hap-sha'], librarySha256: flags['--expected-library-sha'], imagePath: flags['--expected-image'] });
    const bytes = JSON.stringify(result, null, 2) + '\n';
    if (flags['--out']) { const output = assertExternalOutputPath(flags['--out']); fs.mkdirSync(path.dirname(output), { recursive: true }); fs.writeFileSync(output, bytes); }
    process.stdout.write(bytes); process.exitCode = result.ok ? 0 : 1;
  } catch (error) { console.error('MobileGL actual-image qualification incomplete: ' + error.message); process.exitCode = 1; }
}
