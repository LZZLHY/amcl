/**
 * CurseForgeFingerprint.ets — CurseForge 文件指纹(MurmurHash2 变体)
 *
 * CurseForge 用一种特化的 MurmurHash2(32-bit, seed=1)作为文件指纹，用于
 * `POST /fingerprints`(反查文件属于哪个 mod / file)。规则(所有启动器通用)：
 *   1. 先从文件字节里【剔除空白字节】：0x09(\t) 0x0a(\n) 0x0d(\r) 0x20(space)。
 *   2. 对剔除后的字节序列做 MurmurHash2，seed=1，length=剔除后的长度。
 *   3. 结果取无符号 32 位整数。
 *
 * 用途：用户手动导入的 CurseForge 模组(Modrinth sha1 反查落空)——用指纹反查 CF 源，
 *       命中即"自动链接"(可检查更新 + 收编进安装清单作损坏基准)。
 *
 * 纯计算 + 文件 IO，无网络。大文件(>上限)跳过以免移动端内存峰值。
 *
 * 创建日期：2026-07-03(模组完整性/来源链接)
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_DOWNLOAD } from 'commons';

const TAG = 'CurseForgeFingerprint';

/** 指纹计算的文件大小上限(字节)。超过则跳过(返回 0)，避免一次性读入超大 jar 撑爆内存。 */
const MAX_FINGERPRINT_BYTES = 96 * 1024 * 1024; // 96MB，覆盖绝大多数模组

/** CurseForge 视为"空白"的字节(计算指纹前剔除)。 */
function isCfWhitespace(b: number): boolean {
  return b === 9 || b === 10 || b === 13 || b === 32;
}

/**
 * MurmurHash2(32-bit)——CurseForge 变体(seed 由外部传入，CF 用 1)。
 * data 为已剔除空白的字节序列，len = data.length。
 * 32 位乘法用 Math.imul 保证溢出语义正确。
 */
export function murmur2(data: Uint8Array, seed: number): number {
  const m = 0x5bd1e995;
  const r = 24;
  let len = data.length;
  let h = (seed ^ len) >>> 0;
  let i = 0;
  while (len >= 4) {
    let k = (data[i] | (data[i + 1] << 8) | (data[i + 2] << 16) | (data[i + 3] << 24)) >>> 0;
    k = Math.imul(k, m) >>> 0;
    k = (k ^ (k >>> r)) >>> 0;
    k = Math.imul(k, m) >>> 0;
    h = Math.imul(h, m) >>> 0;
    h = (h ^ k) >>> 0;
    i += 4;
    len -= 4;
  }
  // tail
  if (len === 3) {
    h = (h ^ (data[i + 2] << 16)) >>> 0;
    h = (h ^ (data[i + 1] << 8)) >>> 0;
    h = (h ^ data[i]) >>> 0;
    h = Math.imul(h, m) >>> 0;
  } else if (len === 2) {
    h = (h ^ (data[i + 1] << 8)) >>> 0;
    h = (h ^ data[i]) >>> 0;
    h = Math.imul(h, m) >>> 0;
  } else if (len === 1) {
    h = (h ^ data[i]) >>> 0;
    h = Math.imul(h, m) >>> 0;
  }
  h = (h ^ (h >>> 13)) >>> 0;
  h = Math.imul(h, m) >>> 0;
  h = (h ^ (h >>> 15)) >>> 0;
  return h >>> 0;
}

/**
 * 计算文件的 CurseForge 指纹(seed=1，剔除空白字节)。
 * 失败 / 文件过大 / 读不到 → 返回 0(调用方视 0 为"无指纹")。
 */
export async function computeCurseForgeFingerprint(path: string): Promise<number> {
  let file: fs.File | null = null;
  try {
    let stat = fs.statSync(path);
    if (stat.size <= 0) return 0;
    if (stat.size > MAX_FINGERPRINT_BYTES) {
      AppLogger.warn(TAG, `file too large for fingerprint (${stat.size} bytes): ${path}`, null, LOG_DOMAIN_DOWNLOAD);
      return 0;
    }
    file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    let raw = new Uint8Array(stat.size);
    let total = 0;
    // OHOS readSync 不保证一次读满，循环读到 EOF
    while (total < stat.size) {
      let n = fs.readSync(file.fd, raw.buffer, { offset: total, length: stat.size - total });
      if (n <= 0) break;
      total += n;
    }
    // 剔除空白：先数长度，再填充(避免 push 动态数组开销)
    let kept = 0;
    for (let j = 0; j < total; j++) {
      if (!isCfWhitespace(raw[j])) kept++;
    }
    let stripped = new Uint8Array(kept);
    let w = 0;
    for (let j = 0; j < total; j++) {
      let b = raw[j];
      if (!isCfWhitespace(b)) { stripped[w] = b; w++; }
    }
    return murmur2(stripped, 1);
  } catch (e) {
    AppLogger.warn(TAG, `computeCurseForgeFingerprint failed: ${path}`, e as Object, LOG_DOMAIN_DOWNLOAD);
    return 0;
  } finally {
    if (file !== null) {
      try { fs.closeSync(file); } catch (e) { /* ignore */ }
    }
  }
}
