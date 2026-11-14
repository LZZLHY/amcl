/**
 * 旧版 64×32 皮肤到现代预览 UV 的纯像素适配。
 *
 * 原始 PNG 不被改写：游戏仍读取资产库保存的原件。本函数只为已有 64×64 人物模型
 * 补齐旧纹理缺少的左臂、左腿，逐面水平镜像而不是把整张图拉伸。
 * UV 关系核对自 skinview-utils 892bbca3985a24454669e56cfd56fd6b003f64e7
 * src/process.ts 的 convertSkinTo1_8，以及 CustomSkinLoader 5830503 的 FakeSkinBuffer。
 */

/** 解码后的 RGBA 字节与真实尺寸；调用方用它替换一次性的预览采样快照。 */
export interface PreviewSkinPixels {
  pixels: Uint8Array;
  width: number;
  height: number;
}

/**
 * 复制一个面并水平镜像。坐标均为 64 像素宽 UV 中的整数，不做插值，也不改源缓冲。
 * 源、目标由 normalizePreviewSkinPixels 校验，不向外暴露任意内存复制接口。
 */
function mirrorFace(source: Uint8Array, destination: Uint8Array, sx: number, sy: number,
  width: number, height: number, dx: number, dy: number): void {
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const from = ((sy + y) * 64 + sx + width - 1 - x) * 4;
      const to = ((dy + y) * 64 + dx + x) * 4;
      destination[to] = source[from];
      destination[to + 1] = source[from + 1];
      destination[to + 2] = source[from + 2];
      destination[to + 3] = source[from + 3];
    }
  }
}

/**
 * 标准尺寸的旧格式被转换成独立 64×64 缓冲，新增第二层保持透明。
 * 现代或既有远程高清输入保持原有采样行为，不在这里偷偷重编码或调整模型。
 * 长度不匹配时抛错，由预览加载层回退，避免越界读取造成错色。
 */
export function normalizePreviewSkinPixels(source: Uint8Array, width: number, height: number): PreviewSkinPixels {
  if (width <= 0 || height <= 0 || source.byteLength !== width * height * 4) {
    throw new Error('皮肤预览像素尺寸不匹配');
  }
  if (width !== 64 || height !== 32) return { pixels: source, width: width, height: height };
  const output = new Uint8Array(64 * 64 * 4);
  output.set(source);
  // 左腿的顶、底、外、前、内、后六个面分别对应右腿的镜像，不能整块平移。
  mirrorFace(source, output, 4, 16, 4, 4, 20, 48);
  mirrorFace(source, output, 8, 16, 4, 4, 24, 48);
  mirrorFace(source, output, 0, 20, 4, 12, 24, 52);
  mirrorFace(source, output, 4, 20, 4, 12, 20, 52);
  mirrorFace(source, output, 8, 20, 4, 12, 16, 52);
  mirrorFace(source, output, 12, 20, 4, 12, 28, 52);
  // 左臂同样逐面补齐；旧格式只有四像素宽手臂，模型选择层也会强制 Classic。
  mirrorFace(source, output, 44, 16, 4, 4, 36, 48);
  mirrorFace(source, output, 48, 16, 4, 4, 40, 48);
  mirrorFace(source, output, 40, 20, 4, 12, 40, 52);
  mirrorFace(source, output, 44, 20, 4, 12, 36, 52);
  mirrorFace(source, output, 48, 20, 4, 12, 32, 52);
  mirrorFace(source, output, 52, 20, 4, 12, 44, 52);
  // 老编辑器常用全不透明底色填满整图；这不是实际的帽子第二层。
  // 只在整张旧纹理都不透明时清空帽子 UV，有真实透明通道的叠加层原样保留。
  let fullyOpaque = true;
  for (let offset = 3; offset < source.length; offset += 4) {
    if (source[offset] !== 255) { fullyOpaque = false; break; }
  }
  if (fullyOpaque) {
    for (let y = 0; y < 16; y++) {
      for (let x = 32; x < 64; x++) output[(y * 64 + x) * 4 + 3] = 0;
    }
  }
  return { pixels: output, width: 64, height: 64 };
}
