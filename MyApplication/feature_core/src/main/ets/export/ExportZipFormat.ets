/**
 * 导出专用 ZIP64 STORE 容器的纯二进制编码。没有 Kit、文件或页面依赖，可在宿主直接验证。
 * 每个 entry 固定 UTF-8、data descriptor 和 ZIP64 尺寸；不做 DEFLATE，避免 SDK 整包压缩的
 * 不可取消生命周期，也避免已经压缩的 JAR/资源包再占用一份目录快照以外的内存。
 * 所有位移先限制为 JS 安全整数，64 位值按两个 32 位小端字写入，不截断到位运算范围。
 */
export const EXPORT_ZIP_CHUNK = 65536;
export const EXPORT_ZIP_MAX_ENTRIES = 200000;
export const EXPORT_ZIP_FLAGS = 0x0808;

/** 目录只允许结尾的一个斜杠；拒绝绝对路径、路径穿越和 Windows 盘符语法。 */
export function exportZipPath(path: string, directory: boolean): string {
  const value = directory && path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  if (value.length === 0 || value.startsWith('/') || value.indexOf('\\') >= 0 ||
    new RegExp('[\\x00-\\x1f:]').test(value)) throw new Error('归档路径无效');
  for (const part of value.split('/')) {
    if (part.length === 0 || part === '.' || part === '..') throw new Error('归档路径包含越界片段');
  }
  return value + (directory ? '/' : '');
}

/** 用于所有尺寸和偏移边界，超出能力时在产生截断头之前失败。 */
export function exportZipInteger(value: number): void {
  if (!Number.isSafeInteger(value) || value < 0) throw new Error('归档尺寸超过安全整数范围');
}

/** ZIP 的 64 位字段以低/高两个 u32 读写，不能用 >>>32（JS 位移会按32取模）。 */
export function exportZipU64(view: DataView, offset: number, value: number): void {
  exportZipInteger(value);
  view.setUint32(offset, value % 4294967296, true);
  view.setUint32(offset + 4, Math.floor(value / 4294967296), true);
}

/** 独立解析器复用的数值原语；高位值无法精确表达时拒绝归档。 */
export function exportZipReadU64(view: DataView, offset: number): number {
  const value = view.getUint32(offset, true) + view.getUint32(offset + 4, true) * 4294967296;
  exportZipInteger(value); return value;
}

/** 生成 CRC32 标准多项式表；只保留256个u32，逐块运算不分配整文件内存。 */
function makeCrcTable(): number[] {
  const table: number[] = [];
  for (let index = 0; index < 256; index++) {
    let value = index;
    for (let bit = 0; bit < 8; bit++) value = (value & 1) !== 0 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
    table.push(value >>> 0);
  }
  return table;
}
const CRC_TABLE: number[] = makeCrcTable();

/** 输入上次已完成的CRC（首块传0），返回可继续传给下一块的标准CRC32值。 */
export function exportZipCrc32(previous: number, bytes: Uint8Array): number {
  let value = previous ^ 0xffffffff;
  for (let index = 0; index < bytes.length; index++) value = CRC_TABLE[(value ^ bytes[index]) & 255] ^ (value >>> 8);
  return (value ^ 0xffffffff) >>> 0;
}

/** 文件名已由调用者按UTF-8编码；ZIP字段只有u16长度，不能静默截断中文长路径。 */
function checkName(name: Uint8Array): void {
  if (name.length === 0 || name.length > 65535) throw new Error('归档 UTF-8 路径超过 ZIP 长度限制');
}

/** Local header中先写已知尺寸，CRC在数据后descriptor中提交。固定DOS日期为1980-01-01。 */
export function exportZipLocalHeader(name: Uint8Array, size: number): Uint8Array {
  checkName(name); exportZipInteger(size);
  const bytes = new Uint8Array(50 + name.length); const view = new DataView(bytes.buffer);
  view.setUint32(0, 0x04034b50, true); view.setUint16(4, 45, true);
  view.setUint16(6, EXPORT_ZIP_FLAGS, true); view.setUint16(12, 33, true);
  view.setUint32(18, 0xffffffff, true); view.setUint32(22, 0xffffffff, true);
  view.setUint16(26, name.length, true); view.setUint16(28, 20, true); bytes.set(name, 30);
  const extra = 30 + name.length; view.setUint16(extra, 1, true); view.setUint16(extra + 2, 16, true);
  exportZipU64(view, extra + 4, size); exportZipU64(view, extra + 12, size); return bytes;
}

/** STORE的压缩/原始长度相同；带签名的ZIP64 descriptor避免CRC恰好等于签名时歧义。 */
export function exportZipDescriptor(crc: number, size: number): Uint8Array {
  const bytes = new Uint8Array(24); const view = new DataView(bytes.buffer);
  view.setUint32(0, 0x08074b50, true); view.setUint32(4, crc, true);
  exportZipU64(view, 8, size); exportZipU64(view, 16, size); return bytes;
}

/** 中央目录只保存相对路径、CRC、长度和local offset；目录用DOS directory属性表达。 */
export function exportZipCentralHeader(name: Uint8Array, size: number, crc: number,
  localOffset: number, directory: boolean): Uint8Array {
  checkName(name); exportZipInteger(size); exportZipInteger(localOffset);
  const bytes = new Uint8Array(74 + name.length); const view = new DataView(bytes.buffer);
  view.setUint32(0, 0x02014b50, true); view.setUint16(4, 45, true); view.setUint16(6, 45, true);
  view.setUint16(8, EXPORT_ZIP_FLAGS, true); view.setUint16(14, 33, true); view.setUint32(16, crc, true);
  view.setUint32(20, 0xffffffff, true); view.setUint32(24, 0xffffffff, true);
  view.setUint16(28, name.length, true); view.setUint16(30, 28, true);
  view.setUint32(38, directory ? 16 : 0, true); view.setUint32(42, 0xffffffff, true); bytes.set(name, 46);
  const extra = 46 + name.length; view.setUint16(extra, 1, true); view.setUint16(extra + 2, 24, true);
  exportZipU64(view, extra + 4, size); exportZipU64(view, extra + 12, size);
  exportZipU64(view, extra + 20, localOffset); return bytes;
}

/** ZIP64 EOCD+locator+兼容EOCD。固定单磁盘、不带注释，解析时可严格核对最后98字节。 */
export function exportZipEnd(entries: number, centralSize: number, centralOffset: number): Uint8Array {
  exportZipInteger(entries); exportZipInteger(centralSize); exportZipInteger(centralOffset);
  const bytes = new Uint8Array(98); const view = new DataView(bytes.buffer);
  view.setUint32(0, 0x06064b50, true); exportZipU64(view, 4, 44);
  view.setUint16(12, 45, true); view.setUint16(14, 45, true);
  exportZipU64(view, 24, entries); exportZipU64(view, 32, entries);
  exportZipU64(view, 40, centralSize); exportZipU64(view, 48, centralOffset);
  view.setUint32(56, 0x07064b50, true); exportZipU64(view, 64, centralOffset + centralSize);
  view.setUint32(72, 1, true); view.setUint32(76, 0x06054b50, true);
  view.setUint16(84, 65535, true); view.setUint16(86, 65535, true);
  view.setUint32(88, 0xffffffff, true); view.setUint32(92, 0xffffffff, true); return bytes;
}
