/**
 * 所选 LWJGL 槽的只读完整性校验，以及部署前使用的 SHA-256 工具。
 *
 * 只访问调用方给定的已知槽，未选中的 modern/322/2 不参与本局准入。marker 只是
 * 部署提交凭据，不能代替每次对最终 JAR 集合、大小与内容摘要的核验。本模块不修改
 * 文件，不升级旧槽、不更改路由；并不声称解决跨进程并发或整槽 generation 事务。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { LwjglModernJar } from './LwjglModernSlot';
import { lwjglRuntimeSlot } from './LwjglRuntimeSlots';

/** 同时保留机器判据与可读原因，调用方不得把失败映射为另一槽的成功。 */
export interface LwjglSlotIntegrityResult {
  ok: boolean;
  detail: string;
}

/** 将 SHA-256 结果转为稳定小写文本；只用于内容身份，不承担签名验证。 */
function digestHex(bytes: Uint8Array): string {
  let result: string = '';
  for (const byte of bytes) result += byte.toString(16).padStart(2, '0');
  return result;
}

/** 对 rawfile 的有效视图计算摘要；不能把 backing buffer 的前后额外字节算进去。 */
export function lwjglBytesSha256(bytes: Uint8Array): string {
  const digest = cryptoFramework.createMd('SHA256');
  digest.updateSync({ data: bytes });
  return digestHex(digest.digestSync().data);
}

/** 分块读最终文件，限制瞬时内存；任何 IO/crypto 失败都向校验边界传播。 */
function fileSha256(path: string): string {
  const opened: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
  try {
    const digest = cryptoFramework.createMd('SHA256');
    const buffer = new ArrayBuffer(256 * 1024);
    while (true) {
      const count: number = fs.readSync(opened.fd, buffer);
      if (count === 0) break;
      if (count < 0) throw new Error('LWJGL 文件读取失败：' + path);
      digest.updateSync({ data: new Uint8Array(buffer, 0, count) });
    }
    return digestHex(digest.digestSync().data);
  } finally {
    fs.closeSync(opened);
  }
}

/** 限长读取 marker；大文件或目录不能被当作有效提交凭据。 */
function readMarker(path: string): string {
  const stat = fs.statSync(path);
  if (!stat.isFile() || stat.size > 4096) throw new Error('LWJGL 部署标记不是有效的小型文件');
  return fs.readTextSync(path);
}

/**
 * 同步核心供现有同步部署流程在提交 marker 前复核。requireMarker=false 只供部署
 * 内部使用；预启动入口总要求 marker。部署中断会留下未提交槽，由下次部署修复，
 * 不能仅凭 PK 头或文件数量将混版字节交给 JVM。
 */
export function verifyLwjglRuntimeSlotSync(slotDirectory: string,
  requireMarker: boolean = true): LwjglSlotIntegrityResult {
  try {
    const slot = lwjglRuntimeSlot(slotDirectory);
    const markerPath: string = slotDirectory + '/.installed';
    if (requireMarker && readMarker(markerPath) !== slot.marker) {
      throw new Error('部署标记缺失或内容身份不匹配，请完全退出并重新打开应用');
    }
    const actualNames: string[] = fs.listFileSync(slotDirectory).filter((name: string): boolean => name.endsWith('.jar'));
    const expectedNames: string[] = slot.jars.map((jar: LwjglModernJar): string => jar.name);
    actualNames.sort();
    expectedNames.sort();
    if (actualNames.join('|') !== expectedNames.join('|')) {
      throw new Error('JAR 集合不匹配：期望 ' + expectedNames.join(', ') + '，实际 ' + actualNames.join(', '));
    }
    for (const jar of slot.jars) {
      const path: string = slotDirectory + '/' + jar.name;
      const stat = fs.statSync(path);
      if (!stat.isFile() || stat.size !== jar.size) throw new Error(jar.name + ' 大小不匹配或不是普通文件');
      if (fileSha256(path) !== jar.sha256) throw new Error(jar.name + ' SHA-256 不匹配，已阻止加载混合版本 LWJGL');
    }
    // 防止核验期间开始的部署已经移除 marker；这不是跨进程锁或 TOCTOU 的完整解法。
    if (requireMarker && readMarker(markerPath) !== slot.marker) throw new Error('校验期间部署标记发生变化');
    return { ok: true, detail: 'LWJGL ' + slot.version + ' 槽 ' + slot.deploymentDirectory
      + ' 完整（' + slot.jars.length + ' 个 jar，SHA-256 已核验）' };
  } catch (error) {
    return { ok: false, detail: slotDirectory + '：' + (error as Error).message };
  }
}

/**
 * 预启动集成入口：只接收 builder/合并清单确定的真实槽目录，失败返回明确原因。
 * Promise 保持现有预检调用形式；当前 IO/摘要仍是同步实现，不声称已移到工作线程。
 */
export async function verifyLwjglRuntimeSlot(slotDirectory: string): Promise<LwjglSlotIntegrityResult> {
  return verifyLwjglRuntimeSlotSync(slotDirectory);
}
