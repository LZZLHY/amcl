/**
 * 离线外观 PNG 的纯字节准入。此层不依赖鸿蒙图像解码器，先以有界输入检查
 * PNG 块结构、CRC、尺寸和动画标记，防止 APNG 被只识别首帧的解码器误放行。
 * IDAT 压缩流的完整解码仍由 AppearanceLibrary 的 ImageSource 校验负责。
 */
import { AppearanceKind } from './AppearanceTypes';

/** 压缩文件的产品预算；不是 HarmonyOS 或所有 Minecraft 版本的格式上限。 */
export const MAX_APPEARANCE_PNG_BYTES: number = 1024 * 1024;

/** 返回真实 IHDR 尺寸，供解码结果与持久化记录交叉核对。 */
export interface AppearancePngInfo {
  width: number;
  height: number;
}

/** 读取网络字节序 uint32，避免依赖宿主字节序或有符号位移结果。 */
function uint32_(bytes: Uint8Array, offset: number): number {
  return (bytes[offset] * 0x1000000 + bytes[offset + 1] * 0x10000 +
    bytes[offset + 2] * 0x100 + bytes[offset + 3]) >>> 0;
}

/** PNG 的 CRC 覆盖块类型和块数据，不包含长度和存储 CRC 本身。 */
function crc32_(bytes: Uint8Array, start: number, end: number): number {
  let crc: number = 0xffffffff;
  for (let i: number = start; i < end; i++) {
    crc ^= bytes[i];
    for (let bit: number = 0; bit < 8; bit++) {
      crc = (crc >>> 1) ^ ((crc & 1) === 1 ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

/** 按首期消费者能力严格限制尺寸；旧皮肤保留原字节，由预览层解释旧 UV。 */
export function isAppearanceSize(kind: AppearanceKind, width: number, height: number): boolean {
  return width === 64 && (kind === 'skin' ? height === 64 || height === 32 :
    kind === 'cape' && height === 32);
}

/**
 * 校验完整 PNG 包装并返回尺寸。所有拒绝均抛面向用户的稳定错误；不包含来源 URI。
 * 块长度在访问前核对，CRC 和 IEND 后零尾随数据用于区分损坏/拼接伪文件。
 */
export function validateAppearancePng(bytes: Uint8Array, kind: AppearanceKind): AppearancePngInfo {
  if (kind !== 'skin' && kind !== 'cape') throw new Error('外观类型无效');
  if (bytes.byteLength === 0 || bytes.byteLength > MAX_APPEARANCE_PNG_BYTES) {
    throw new Error('请选择不超过 1 MiB 的 PNG 文件');
  }
  const signature: number[] = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.byteLength < 33 || !signature.every((value: number, index: number): boolean =>
    bytes[index] === value)) throw new Error('文件不是有效的 PNG 图片');
  let offset: number = 8;
  let width: number = 0;
  let height: number = 0;
  let colorType: number = -1;
  let paletteSeen: boolean = false;
  let dataSeen: boolean = false;
  let dataEnded: boolean = false;
  let endSeen: boolean = false;
  while (offset < bytes.byteLength) {
    if (bytes.byteLength - offset < 12) throw new Error('PNG 数据不完整');
    const length: number = uint32_(bytes, offset);
    if (length > bytes.byteLength - offset - 12) throw new Error('PNG 块长度无效');
    const type: string = String.fromCharCode(bytes[offset + 4], bytes[offset + 5],
      bytes[offset + 6], bytes[offset + 7]);
    if (!new RegExp('^[A-Za-z]{2}[A-Z][A-Za-z]$').test(type)) throw new Error('PNG 块类型无效');
    const data: number = offset + 8;
    const end: number = data + length;
    if (crc32_(bytes, offset + 4, end) !== uint32_(bytes, end)) throw new Error('PNG 校验失败，图片可能已损坏');
    if (type === 'acTL' || type === 'fcTL' || type === 'fdAT') throw new Error('暂不支持 APNG 动画，请导入静态 PNG');
    if (offset === 8 && type !== 'IHDR') throw new Error('PNG 缺少图片头');
    if (type === 'IHDR') {
      if (offset !== 8 || length !== 13) throw new Error('PNG 图片头无效');
      width = uint32_(bytes, data);
      height = uint32_(bytes, data + 4);
      if (!isAppearanceSize(kind, width, height)) {
        throw new Error(kind === 'skin' ? '皮肤尺寸须为 64×64 或 64×32 像素' : '披风尺寸须为 64×32 像素');
      }
      const depth: number = bytes[data + 8];
      colorType = bytes[data + 9];
      const depthAllowed: boolean = colorType === 0 ? [1, 2, 4, 8, 16].includes(depth) :
        colorType === 3 ? [1, 2, 4, 8].includes(depth) :
          [2, 4, 6].includes(colorType) && [8, 16].includes(depth);
      if (!depthAllowed || bytes[data + 10] !== 0 || bytes[data + 11] !== 0 || bytes[data + 12] > 1) {
        throw new Error('PNG 编码参数无效');
      }
    } else if (type === 'PLTE') {
      if (paletteSeen || dataSeen || length === 0 || length > 768 || length % 3 !== 0 ||
        colorType === 0 || colorType === 4) throw new Error('PNG 调色板无效');
      paletteSeen = true;
    } else if (type === 'IDAT') {
      if (dataEnded || (colorType === 3 && !paletteSeen)) throw new Error('PNG 像素块顺序无效');
      dataSeen = true;
    } else if (type === 'IEND') {
      if (!dataSeen || length !== 0 || end + 4 !== bytes.byteLength) throw new Error('PNG 结束块无效');
      endSeen = true;
    } else {
      // 未识别关键块不能由本层安全解释；普通附属元数据可保留，不重写原图。
      if ((bytes[offset + 4] & 0x20) === 0) throw new Error('PNG 包含不支持的关键数据块');
    }
    if (dataSeen && type !== 'IDAT') dataEnded = true;
    offset = end + 4;
  }
  if (!endSeen) throw new Error('PNG 缺少结束块');
  return { width: width, height: height };
}
