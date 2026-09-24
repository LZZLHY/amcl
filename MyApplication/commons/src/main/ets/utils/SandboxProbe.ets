/**
 * SandboxProbe.ets — 鸿蒙沙箱文件系统探针
 *
 * 目的:
 *   评估 PCL 风格 "独立临时 mcFolder + 完成后把 libraries 迁到真实 mcDir" 方案
 *   在鸿蒙 app 沙箱下的可行性. 核心问题是 `fs.renameSync` 跨子目录是否为 O(1)
 *   元数据操作; 这一点决定了方案 B (见 docs/guides/version-isolation-and-
 *   forge-install-audit.md) 的 libraries 迁移策略.
 *
 * 探针测试工况 (8 项):
 *   1. rename-small-samedir        10 KB 文件同目录 rename
 *   2. rename-small-crossdir       10 KB 文件跨子目录 rename
 *   3. rename-large-crossdir       50 MB 文件跨子目录 rename  (关键)
 *   4. copy-unlink-large-crossdir  50 MB 文件 copy+unlink     (基线对照)
 *   5. rename-batch-200x64kb       200 × 64 KB 文件逐个 rename
 *   6. copy-unlink-batch-200x64kb  200 × 64 KB 文件逐个 copy+unlink
 *   7. rename-overwrite            rename 覆盖已存在目标的行为
 *   8. rename-directory            整目录 rename (含 10 个子文件)
 *
 * 判定逻辑:
 *   - 如果 test 3 << test 4 (比如 3 约 1ms, 4 约 1000ms) → rename 是元数据操作 (O(1))
 *   - 如果 test 3 ≈ test 4 → rename 实际上在拷数据 (O(n))
 *   - 如果 test 3 失败 → rename 不支持跨子目录 (EXDEV)
 *   - 如果 test 8 成功 → 整目录 rename 可用, 方案 B 可用单次 rename 迁移 libraries
 *
 * 使用: DevToolsPage 里调用 runFsRenameProbe(context.filesDir),
 *       然后用 formatReport(report) 得到人类可读文本.
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { AppLogger } from './AppLogger';
import { LogTags } from '../common/LogTags';

const TAG = LogTags.UTIL_SANDBOX;

// ============================================================================
//  测试工况常量
// ============================================================================

const SMALL_FILE_SIZE = 10 * 1024;                 // 10 KB
const LARGE_FILE_SIZE = 50 * 1024 * 1024;          // 50 MB
const BATCH_FILE_COUNT = 200;                       // 模拟 libraries 规模
const BATCH_FILE_SIZE = 64 * 1024;                 // 64 KB/文件 → 批量 12.5 MB
const WRITE_CHUNK_SIZE = 1 * 1024 * 1024;          // 写大文件时的分块尺寸
const DIR_RENAME_FILE_COUNT = 10;                  // 整目录 rename 测试的内部文件数

// ============================================================================
//  数据类型
// ============================================================================

/**
 * 单项测试结果.
 * 关注字段:
 *   - timeMs: 操作耗时 (毫秒, 基于 Date.now())
 *   - throughputMBps: 对大文件类测试计算, 用于直观展示
 */
export class FsProbeTestResult {
  name: string = '';
  description: string = '';
  ok: boolean = false;
  timeMs: number = 0;
  bytes: number = 0;
  fileCount: number = 0;
  throughputMBps: number = 0;
  errorMsg: string = '';
  note: string = '';
}

/** 聚合报告 */
export class FsProbeReport {
  filesDir: string = '';
  probeDir: string = '';
  startTime: string = '';
  tests: FsProbeTestResult[] = [];
  summary: string = '';
  rawSummaryLines: string[] = [];
}

// ============================================================================
//  内部小工具 (不依赖业务代码, 让探针保持自包含)
// ============================================================================

/** 创建指定大小的文件 (内容全 0, 对性能评测够用).
 *  失败时抛异常, caller 用外层 try/catch 捕获并记入 errorMsg.
 *
 *  2026-05-23 ArkTS 严格模式：fs.openSync 会报 'Function may throw'。这个函数
 *  整个 body 已经在 try-finally 里，但 openSync 调用在 try 之外。下面把
 *  openSync 也包进 try，失败时直接 rethrow 给 caller 的 errorMsg 吃掉。
 *  详见 docs/guides/api-migration-2026-05.md。 */
function createFile(path: string, size: number): void {
  let f: fs.File;
  try {
    f = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  } catch (e) {
    throw e as Error;  // caller (runFsRenameProbe) 接过去记入 errorMsg
  }
  try {
    if (size <= 0) return;
    if (size <= WRITE_CHUNK_SIZE) {
      let buf = new ArrayBuffer(size);
      fs.writeSync(f.fd, buf);
    } else {
      let buf = new ArrayBuffer(WRITE_CHUNK_SIZE);
      let remaining = size;
      while (remaining > 0) {
        let chunk = remaining >= WRITE_CHUNK_SIZE ? WRITE_CHUNK_SIZE : remaining;
        if (chunk === WRITE_CHUNK_SIZE) {
          fs.writeSync(f.fd, buf);
        } else {
          fs.writeSync(f.fd, buf.slice(0, chunk));
        }
        remaining -= chunk;
      }
    }
  } catch (e) {
    // 确保文件被关闭后 rethrow, 让 caller 感知
    try { fs.closeSync(f); } catch (e2) { /* */ }
    throw e as Error;
  }
  try { fs.closeSync(f); } catch (e) { /* */ }
}

/** 安全判断路径是否存在 */
function pathExists(path: string): boolean {
  try {
    fs.statSync(path);
    return true;
  } catch (e) {
    return false;
  }
}

/** 安全取文件大小, 不存在则返回 -1 */
function fileSize(path: string): number {
  try {
    return fs.statSync(path).size;
  } catch (e) {
    return -1;
  }
}

/** 递归删除目录 (探针内部用, 不依赖 FileUtils) */
function removeDir(path: string): void {
  if (!pathExists(path)) return;
  let stat: fs.Stat;
  try {
    stat = fs.statSync(path);
  } catch (e) {
    return;
  }
  let isDir = false;
  try {
    isDir = stat.isDirectory();
  } catch (e) {
    return;
  }
  if (isDir) {
    let entries: string[] = [];
    try {
      entries = fs.listFileSync(path);
    } catch (e) { /* */ }
    for (let name of entries) {
      removeDir(path + '/' + name);
    }
    try {
      fs.rmdirSync(path);
    } catch (e) { /* */ }
  } else {
    try {
      fs.unlinkSync(path);
    } catch (e) { /* */ }
  }
}

/** 尝试 unlink 单个文件, 不存在不报错 */
function safeUnlink(path: string): void {
  try {
    fs.unlinkSync(path);
  } catch (e) { /* */ }
}

/** 计算吞吐量, bytes=0 返回 0 */
function computeThroughput(bytes: number, timeMs: number): number {
  if (bytes <= 0 || timeMs <= 0) return 0;
  return (bytes / (1024 * 1024)) / (timeMs / 1000);
}

/** 捕获异常并转成字符串, 抑制循环引用 */
function errToString(e: Object): string {
  if (e === null || e === undefined) return '(unknown)';
  let err = e as Error;
  if (err && err.message) return err.message;
  try {
    return JSON.stringify(e);
  } catch (e2) {
    return String(e);
  }
}

// ============================================================================
//  单项测试实现
// ============================================================================

/** Test 1: 小文件同目录 rename */
async function test_renameSameDir(probeDir: string): Promise<FsProbeTestResult> {
  let r = new FsProbeTestResult();
  r.name = 'rename-small-samedir';
  r.description = '10 KB 文件在同一目录内 rename';
  r.bytes = SMALL_FILE_SIZE;

  let dir = probeDir + '/t1';
  let src = dir + '/src.bin';
  let dst = dir + '/dst.bin';

  try {
    fs.mkdirSync(dir, true);
    createFile(src, SMALL_FILE_SIZE);
    let t0 = Date.now();
    fs.renameSync(src, dst);
    let t1 = Date.now();
    r.timeMs = t1 - t0;
    r.ok = pathExists(dst) && !pathExists(src) && fileSize(dst) === SMALL_FILE_SIZE;
    if (!r.ok) r.errorMsg = 'post-state mismatch: dstExists=' + pathExists(dst)
      + ' srcExists=' + pathExists(src) + ' dstSize=' + fileSize(dst);
  } catch (e) {
    r.errorMsg = errToString(e as Object);
  } finally {
    safeUnlink(src);
    safeUnlink(dst);
  }
  return r;
}

/** Test 2: 小文件跨子目录 rename */
async function test_renameCrossDir(probeDir: string): Promise<FsProbeTestResult> {
  let r = new FsProbeTestResult();
  r.name = 'rename-small-crossdir';
  r.description = '10 KB 文件跨兄弟子目录 rename';
  r.bytes = SMALL_FILE_SIZE;

  let dirA = probeDir + '/t2/a';
  let dirB = probeDir + '/t2/b';
  let src = dirA + '/file.bin';
  let dst = dirB + '/file.bin';

  try {
    fs.mkdirSync(dirA, true);
    fs.mkdirSync(dirB, true);
    createFile(src, SMALL_FILE_SIZE);
    let t0 = Date.now();
    fs.renameSync(src, dst);
    let t1 = Date.now();
    r.timeMs = t1 - t0;
    r.ok = pathExists(dst) && !pathExists(src) && fileSize(dst) === SMALL_FILE_SIZE;
    if (!r.ok) r.errorMsg = 'post-state mismatch';
  } catch (e) {
    r.errorMsg = errToString(e as Object);
  } finally {
    safeUnlink(src);
    safeUnlink(dst);
  }
  return r;
}

/** Test 3: 大文件跨子目录 rename — 核心测试 */
async function test_renameLargeCrossDir(probeDir: string): Promise<FsProbeTestResult> {
  let r = new FsProbeTestResult();
  r.name = 'rename-large-crossdir';
  r.description = '50 MB 文件跨兄弟子目录 rename (核心: 区分 O(1) vs O(n))';
  r.bytes = LARGE_FILE_SIZE;

  let dirA = probeDir + '/t3/a';
  let dirB = probeDir + '/t3/b';
  let src = dirA + '/big.bin';
  let dst = dirB + '/big.bin';

  try {
    fs.mkdirSync(dirA, true);
    fs.mkdirSync(dirB, true);
    createFile(src, LARGE_FILE_SIZE);
    let t0 = Date.now();
    fs.renameSync(src, dst);
    let t1 = Date.now();
    r.timeMs = t1 - t0;
    r.ok = pathExists(dst) && !pathExists(src) && fileSize(dst) === LARGE_FILE_SIZE;
    r.throughputMBps = computeThroughput(LARGE_FILE_SIZE, r.timeMs);
    if (!r.ok) r.errorMsg = 'post-state mismatch';
  } catch (e) {
    r.errorMsg = errToString(e as Object);
  } finally {
    safeUnlink(src);
    safeUnlink(dst);
  }
  return r;
}

/** Test 4: 大文件 copy+unlink 基线 */
async function test_copyUnlinkLarge(probeDir: string): Promise<FsProbeTestResult> {
  let r = new FsProbeTestResult();
  r.name = 'copy-unlink-large-crossdir';
  r.description = '50 MB 文件 copy+unlink (基线对照)';
  r.bytes = LARGE_FILE_SIZE;

  let dirA = probeDir + '/t4/a';
  let dirB = probeDir + '/t4/b';
  let src = dirA + '/big.bin';
  let dst = dirB + '/big.bin';

  try {
    fs.mkdirSync(dirA, true);
    fs.mkdirSync(dirB, true);
    createFile(src, LARGE_FILE_SIZE);
    let t0 = Date.now();
    fs.copyFileSync(src, dst);
    fs.unlinkSync(src);
    let t1 = Date.now();
    r.timeMs = t1 - t0;
    r.ok = pathExists(dst) && !pathExists(src) && fileSize(dst) === LARGE_FILE_SIZE;
    r.throughputMBps = computeThroughput(LARGE_FILE_SIZE, r.timeMs);
    if (!r.ok) r.errorMsg = 'post-state mismatch';
  } catch (e) {
    r.errorMsg = errToString(e as Object);
  } finally {
    safeUnlink(src);
    safeUnlink(dst);
  }
  return r;
}

/** Test 5: 批量 rename (模拟 libraries 迁移) */
async function test_batchRename(probeDir: string): Promise<FsProbeTestResult> {
  let r = new FsProbeTestResult();
  r.name = 'rename-batch-200x64kb';
  r.description = '200 × 64 KB 文件逐个 rename (模拟 libraries 迁移)';
  r.bytes = BATCH_FILE_COUNT * BATCH_FILE_SIZE;
  r.fileCount = BATCH_FILE_COUNT;

  let dirA = probeDir + '/t5/a';
  let dirB = probeDir + '/t5/b';

  let okCount = 0;
  try {
    fs.mkdirSync(dirA, true);
    fs.mkdirSync(dirB, true);
    // 预造 200 个文件
    for (let i = 0; i < BATCH_FILE_COUNT; i++) {
      createFile(dirA + '/f' + i + '.bin', BATCH_FILE_SIZE);
    }
    let t0 = Date.now();
    for (let i = 0; i < BATCH_FILE_COUNT; i++) {
      try {
        fs.renameSync(dirA + '/f' + i + '.bin', dirB + '/f' + i + '.bin');
        okCount++;
      } catch (e) { /* 继续统计 */ }
    }
    let t1 = Date.now();
    r.timeMs = t1 - t0;
    r.fileCount = okCount;
    r.ok = (okCount === BATCH_FILE_COUNT);
    r.throughputMBps = computeThroughput(r.bytes, r.timeMs);
    if (!r.ok) r.errorMsg = 'only ' + okCount + '/' + BATCH_FILE_COUNT + ' succeeded';
    r.note = 'avg ' + (r.timeMs / Math.max(okCount, 1)).toFixed(2) + ' ms/file';
  } catch (e) {
    r.errorMsg = errToString(e as Object);
  } finally {
    removeDir(probeDir + '/t5');
  }
  return r;
}

/** Test 6: 批量 copy+unlink (对照 Test 5) */
async function test_batchCopyUnlink(probeDir: string): Promise<FsProbeTestResult> {
  let r = new FsProbeTestResult();
  r.name = 'copy-unlink-batch-200x64kb';
  r.description = '200 × 64 KB 文件逐个 copy+unlink (基线)';
  r.bytes = BATCH_FILE_COUNT * BATCH_FILE_SIZE;
  r.fileCount = BATCH_FILE_COUNT;

  let dirA = probeDir + '/t6/a';
  let dirB = probeDir + '/t6/b';

  let okCount = 0;
  try {
    fs.mkdirSync(dirA, true);
    fs.mkdirSync(dirB, true);
    for (let i = 0; i < BATCH_FILE_COUNT; i++) {
      createFile(dirA + '/f' + i + '.bin', BATCH_FILE_SIZE);
    }
    let t0 = Date.now();
    for (let i = 0; i < BATCH_FILE_COUNT; i++) {
      try {
        fs.copyFileSync(dirA + '/f' + i + '.bin', dirB + '/f' + i + '.bin');
        fs.unlinkSync(dirA + '/f' + i + '.bin');
        okCount++;
      } catch (e) { /* */ }
    }
    let t1 = Date.now();
    r.timeMs = t1 - t0;
    r.fileCount = okCount;
    r.ok = (okCount === BATCH_FILE_COUNT);
    r.throughputMBps = computeThroughput(r.bytes, r.timeMs);
    if (!r.ok) r.errorMsg = 'only ' + okCount + '/' + BATCH_FILE_COUNT + ' succeeded';
    r.note = 'avg ' + (r.timeMs / Math.max(okCount, 1)).toFixed(2) + ' ms/file';
  } catch (e) {
    r.errorMsg = errToString(e as Object);
  } finally {
    removeDir(probeDir + '/t6');
  }
  return r;
}

/** Test 7: rename 覆盖已存在目标 */
async function test_renameOverwrite(probeDir: string): Promise<FsProbeTestResult> {
  let r = new FsProbeTestResult();
  r.name = 'rename-overwrite';
  r.description = 'rename 到已存在目标的行为 (是否覆盖/报错)';

  let dir = probeDir + '/t7';
  let src = dir + '/src.bin';
  let dst = dir + '/dst.bin';

  try {
    fs.mkdirSync(dir, true);
    // src 16 字节, dst 8 字节, 便于区分
    createFile(src, 16);
    createFile(dst, 8);
    let srcSizeBefore = fileSize(src);
    let dstSizeBefore = fileSize(dst);
    let t0 = Date.now();
    let renameOk = false;
    let renameErr = '';
    try {
      fs.renameSync(src, dst);
      renameOk = true;
    } catch (e) {
      renameErr = errToString(e as Object);
    }
    let t1 = Date.now();
    r.timeMs = t1 - t0;

    if (renameOk) {
      let dstSizeAfter = fileSize(dst);
      let srcExistsAfter = pathExists(src);
      r.ok = true;
      r.note = '覆盖成功: src(' + srcSizeBefore + ')→dst(' + dstSizeBefore + '→' + dstSizeAfter + ')'
        + ', srcExists=' + srcExistsAfter;
      // 判断是不是真覆盖: dst 尺寸应该等于 src 原尺寸
      if (dstSizeAfter !== srcSizeBefore || srcExistsAfter) {
        r.note += ' [⚠️ 语义可疑]';
      }
    } else {
      r.ok = true;   // 报错也是一种确定行为, 测试本身成功
      r.note = 'rename 到已存在目标会报错: ' + renameErr;
    }
  } catch (e) {
    r.errorMsg = errToString(e as Object);
  } finally {
    safeUnlink(src);
    safeUnlink(dst);
  }
  return r;
}

/** Test 8: 整目录 rename */
async function test_renameDirectory(probeDir: string): Promise<FsProbeTestResult> {
  let r = new FsProbeTestResult();
  r.name = 'rename-directory';
  r.description = '整目录 rename (含 ' + DIR_RENAME_FILE_COUNT + ' 子文件)';
  r.fileCount = DIR_RENAME_FILE_COUNT;
  r.bytes = DIR_RENAME_FILE_COUNT * SMALL_FILE_SIZE;

  let parent = probeDir + '/t8';
  let srcDir = parent + '/src';
  let dstDir = parent + '/dst';

  try {
    fs.mkdirSync(parent, true);
    fs.mkdirSync(srcDir, true);
    for (let i = 0; i < DIR_RENAME_FILE_COUNT; i++) {
      createFile(srcDir + '/f' + i + '.bin', SMALL_FILE_SIZE);
    }
    let t0 = Date.now();
    fs.renameSync(srcDir, dstDir);
    let t1 = Date.now();
    r.timeMs = t1 - t0;

    // 验证: dstDir 存在, srcDir 不存在, 内部文件都在
    let dstOk = pathExists(dstDir);
    let srcOk = !pathExists(srcDir);
    let allFilesOk = true;
    for (let i = 0; i < DIR_RENAME_FILE_COUNT; i++) {
      if (fileSize(dstDir + '/f' + i + '.bin') !== SMALL_FILE_SIZE) {
        allFilesOk = false;
        break;
      }
    }
    r.ok = dstOk && srcOk && allFilesOk;
    if (!r.ok) r.errorMsg = 'post-state: dstDir=' + dstOk + ' srcGone=' + srcOk + ' filesOk=' + allFilesOk;
    r.throughputMBps = computeThroughput(r.bytes, r.timeMs);
  } catch (e) {
    r.errorMsg = errToString(e as Object);
  } finally {
    removeDir(parent);
  }
  return r;
}

// ============================================================================
//  报告生成
// ============================================================================

function buildSummary(tests: FsProbeTestResult[]): string[] {
  let byName: Record<string, FsProbeTestResult> = {};
  for (let t of tests) byName[t.name] = t;

  let lines: string[] = [];

  let bigRename = byName['rename-large-crossdir'];
  let bigCopy = byName['copy-unlink-large-crossdir'];
  let batchRename = byName['rename-batch-200x64kb'];
  let batchCopy = byName['copy-unlink-batch-200x64kb'];
  let dirRename = byName['rename-directory'];
  let overwriteTest = byName['rename-overwrite'];

  // 1. rename 是否跨子目录可用
  if (!bigRename || !bigRename.ok) {
    lines.push('⚠️ 跨子目录 rename 不可用 — 只能 copy+unlink');
    if (bigRename && bigRename.errorMsg) lines.push('  失败: ' + bigRename.errorMsg);
    lines.push('  → 方案 B 的 libraries 迁移必须走 copy+unlink 路径');
    return lines;
  }

  // 2. O(1) vs O(n) 判定 (核心)
  if (bigCopy && bigCopy.ok) {
    let ratio = bigCopy.timeMs / Math.max(bigRename.timeMs, 0.5);
    if (bigRename.timeMs < 50 && ratio > 20) {
      lines.push('✓ rename 是 O(1) 元数据操作');
      lines.push('  50 MB rename = ' + bigRename.timeMs + ' ms, copy+unlink = ' + bigCopy.timeMs + ' ms ('
        + ratio.toFixed(0) + '× 提速)');
    } else if (bigRename.timeMs < 200 && ratio > 3) {
      lines.push('⚠️ rename 部分优化, 但不是严格 O(1)');
      lines.push('  50 MB rename = ' + bigRename.timeMs + ' ms, copy+unlink = ' + bigCopy.timeMs + ' ms ('
        + ratio.toFixed(1) + '× 提速)');
    } else {
      lines.push('✗ rename 实际耗时接近 copy+unlink (可能是 O(n) 数据拷贝)');
      lines.push('  50 MB rename = ' + bigRename.timeMs + ' ms, copy+unlink = ' + bigCopy.timeMs + ' ms ('
        + ratio.toFixed(1) + '× 提速)');
    }
  } else {
    lines.push('? 无法比较 (基线 copy+unlink 测试失败)');
  }

  // 3. 批量规模下的实测
  if (batchRename && batchCopy && batchRename.ok && batchCopy.ok) {
    let bRatio = batchCopy.timeMs / Math.max(batchRename.timeMs, 0.5);
    lines.push('批量 200 文件: rename=' + batchRename.timeMs + ' ms, copy+unlink='
      + batchCopy.timeMs + ' ms (' + bRatio.toFixed(1) + '× 提速)');
  }

  // 4. 整目录 rename
  if (dirRename && dirRename.ok) {
    lines.push('✓ 整目录 rename 可用 (' + dirRename.timeMs + ' ms)');
    lines.push('  → 方案 B 的 libraries 迁移可用"目录级 rename"一次搞定 (仅当目标不存在时)');
  } else {
    lines.push('✗ 整目录 rename 不可用' + (dirRename ? ': ' + dirRename.errorMsg : ''));
    lines.push('  → 方案 B 只能逐子目录/逐文件 rename');
  }

  // 5. 覆盖行为
  if (overwriteTest && overwriteTest.ok && overwriteTest.note) {
    lines.push('覆盖行为: ' + overwriteTest.note);
  }

  // 6. 结论
  let hasFastRename = bigRename.ok && bigRename.timeMs < 50;
  let hasDirRename = dirRename !== null && dirRename !== undefined && dirRename.ok;
  if (hasFastRename && hasDirRename) {
    lines.push('');
    lines.push('📌 方案 B 推荐策略: 临时沙箱 → 目录级 rename (libraries 整体 O(1) 迁入 mcDir)');
  } else if (hasFastRename) {
    lines.push('');
    lines.push('📌 方案 B 推荐策略: 临时沙箱 → 逐文件 rename (每个 library 元数据移动, 仍远快于 copy)');
  } else {
    lines.push('');
    lines.push('📌 方案 B 仍可实施, 但 libraries 迁移需要走 copy+unlink (时间成本等同现有方式)');
  }

  return lines;
}

/** 生成人类可读报告文本 */
export function formatReport(r: FsProbeReport): string {
  let lines: string[] = [];
  lines.push('=== 鸿蒙沙箱 FS 探针报告 ===');
  lines.push('时间   : ' + r.startTime);
  lines.push('filesDir: ' + r.filesDir);
  lines.push('probeDir: ' + r.probeDir);
  lines.push('');
  lines.push('--- 测试明细 ---');
  for (let t of r.tests) {
    let symbol = t.ok ? '✓' : '✗';
    let line = '  ' + symbol + ' ' + t.name;
    lines.push(line);
    lines.push('      ' + t.description);
    let data = '      时间=' + t.timeMs + ' ms';
    if (t.bytes > 0) {
      let mb = (t.bytes / (1024 * 1024)).toFixed(1);
      data += ', 规模=' + mb + ' MB';
    }
    if (t.fileCount > 0) data += ', 文件=' + t.fileCount;
    if (t.throughputMBps > 0) data += ', 吞吐=' + t.throughputMBps.toFixed(1) + ' MB/s';
    lines.push(data);
    if (t.errorMsg.length > 0) lines.push('      ⚠️ 错误: ' + t.errorMsg);
    if (t.note.length > 0) lines.push('      备注: ' + t.note);
  }
  lines.push('');
  lines.push('--- 结论 ---');
  for (let s of r.rawSummaryLines) lines.push(s);
  return lines.join('\n');
}

// ============================================================================
//  主入口
// ============================================================================

/**
 * 运行完整的 FS 探针套件.
 *
 * 预计耗时:
 *   - 主要瓶颈是 Test 4 (50 MB copy): 取决于存储速度, eMMC 一般 1\~5s
 *   - 总时长一般 5\~20s
 * 磁盘占用:
 *   - 峰值约 100 MB (Test 3/4 各 50 MB 文件短暂存在)
 *   - 结束后自动清理 probeDir
 */
export async function runFsRenameProbe(filesDir: string): Promise<FsProbeReport> {
  let report = new FsProbeReport();
  report.filesDir = filesDir;
  report.startTime = new Date().toLocaleString();

  // 唯一 sessionId 防止并发冲突
  let sid = Date.now().toString() + '-' + Math.floor(Math.random() * 10000).toString();
  let probeDir = filesDir + '/sandbox-probe-' + sid;
  report.probeDir = probeDir;

  AppLogger.info(TAG, `Starting FS probe, probeDir=${probeDir}`);

  try {
    fs.mkdirSync(probeDir, true);
  } catch (e) {
    let setup = new FsProbeTestResult();
    setup.name = 'setup';
    setup.description = '创建探针根目录';
    setup.ok = false;
    setup.errorMsg = 'mkdir failed: ' + errToString(e as Object);
    report.tests.push(setup);
    report.rawSummaryLines = ['❌ 无法创建探针目录, 测试终止'];
    report.summary = report.rawSummaryLines.join('\n');
    return report;
  }

  try {
    // 顺序执行 (不并行, 避免互相干扰计时)
    let r1 = await test_renameSameDir(probeDir);
    report.tests.push(r1);
    AppLogger.info(TAG, `T1 ${r1.name}: ok=${r1.ok ? 'yes' : 'no'} time=${r1.timeMs}ms`);

    let r2 = await test_renameCrossDir(probeDir);
    report.tests.push(r2);
    AppLogger.info(TAG, `T2 ${r2.name}: ok=${r2.ok ? 'yes' : 'no'} time=${r2.timeMs}ms`);

    let r3 = await test_renameLargeCrossDir(probeDir);
    report.tests.push(r3);
    AppLogger.info(TAG, `T3 ${r3.name}: ok=${r3.ok ? 'yes' : 'no'} time=${r3.timeMs}ms`);

    let r4 = await test_copyUnlinkLarge(probeDir);
    report.tests.push(r4);
    AppLogger.info(TAG, `T4 ${r4.name}: ok=${r4.ok ? 'yes' : 'no'} time=${r4.timeMs}ms`);

    let r5 = await test_batchRename(probeDir);
    report.tests.push(r5);
    AppLogger.info(TAG, `T5 ${r5.name}: ok=${r5.ok ? 'yes' : 'no'} time=${r5.timeMs}ms`);

    let r6 = await test_batchCopyUnlink(probeDir);
    report.tests.push(r6);
    AppLogger.info(TAG, `T6 ${r6.name}: ok=${r6.ok ? 'yes' : 'no'} time=${r6.timeMs}ms`);

    let r7 = await test_renameOverwrite(probeDir);
    report.tests.push(r7);
    AppLogger.info(TAG, `T7 ${r7.name}: ok=${r7.ok ? 'yes' : 'no'} time=${r7.timeMs}ms`);

    let r8 = await test_renameDirectory(probeDir);
    report.tests.push(r8);
    AppLogger.info(TAG, `T8 ${r8.name}: ok=${r8.ok ? 'yes' : 'no'} time=${r8.timeMs}ms`);
  } finally {
    try {
      removeDir(probeDir);
      AppLogger.info(TAG, 'Probe dir cleaned');
    } catch (e) {
      AppLogger.warn(TAG, 'Cleanup failed', e as Object);
    }
  }

  report.rawSummaryLines = buildSummary(report.tests);
  report.summary = report.rawSummaryLines.join('\n');
  AppLogger.info(TAG, `Probe done. Summary:\n${report.summary}`);

  return report;
}
