/**
 * DefaultSkin.ets — 程序化生成经典「Steve」默认皮肤的 64×64 RGBA 缓冲
 *
 * 用途：离线账户没有 Mojang 皮肤 URL（OfflineAccount.getSkinUrl()=null），但游戏里它们
 * 用的就是默认 Steve 皮肤。账户管理预览里与其画一个字母头像，不如直接渲染默认皮肤的 3D 模型
 * （和游戏一致、更直观）。本模块不依赖任何网络 / 资源文件，纯代码按 1.8+ 皮肤 UV 规范
 * （64×64）把各身体部位的所有面填上经典配色，喂给 SkinCanvas3D 的软件光栅化器即可。
 *
 * 说明：这是「够用的近似 Steve」——主体配色 + 简单五官，不追求逐像素还原。叠加层（帽子/夹克
 * 第二层）全留透明，渲染器对应面不出像素。生成一次后缓存复用。
 */

const W = 64;
const H = 64;

// 经典 Steve 调色板（RGB）
const SKIN: number[] = [0xB5, 0x7A, 0x57];
const HAIR: number[] = [0x32, 0x24, 0x18];
const EYE_W: number[] = [0xEC, 0xEC, 0xEC];
const EYE_I: number[] = [0x3C, 0x2E, 0x8A];
const MOUTH: number[] = [0x6A, 0x48, 0x35];
const SHIRT: number[] = [0x00, 0xAC, 0xAC];
const PANTS: number[] = [0x37, 0x37, 0xB5];

let cachedSteve: Uint8Array | null = null;

function setPx(buf: Uint8Array, x: number, y: number, c: number[]): void {
  if (x < 0 || y < 0 || x >= W || y >= H) return;
  let off = (y * W + x) * 4;
  buf[off] = c[0];
  buf[off + 1] = c[1];
  buf[off + 2] = c[2];
  buf[off + 3] = 0xFF;
}

function fill(buf: Uint8Array, x: number, y: number, w: number, h: number, c: number[]): void {
  for (let yy = y; yy < y + h; yy++) {
    for (let xx = x; xx < x + w; xx++) {
      setPx(buf, xx, yy, c);
    }
  }
}

/**
 * 生成经典 Steve 64×64 RGBA（RGBA_8888，与 SkinCanvas3D._skinRGBA 同布局）。
 * 透明区域 alpha=0（叠加层等不绘制）。
 */
export function buildSteveSkinRGBA(): Uint8Array {
  if (cachedSteve !== null) return cachedSteve;
  let buf = new Uint8Array(W * H * 4);   // 默认全 0 = 透明

  // ===== 头（8×8×8）=====
  // 4 个侧面基底铺肤色：right(0,8) front(8,8) left(16,8) back(24,8)
  fill(buf, 0, 8, 32, 8, SKIN);
  fill(buf, 8, 0, 8, 8, HAIR);   // 头顶
  fill(buf, 16, 0, 8, 8, SKIN);  // 头底
  fill(buf, 24, 8, 8, 8, HAIR);  // 后脑勺整面头发
  fill(buf, 0, 8, 24, 2, HAIR);  // 右/前/左 顶部刘海 2 行
  // 前脸五官（front 面 = (8,8)-(16,16)）
  fill(buf, 9, 11, 6, 1, HAIR);  // 眉
  setPx(buf, 10, 12, EYE_W); setPx(buf, 11, 12, EYE_I);
  setPx(buf, 12, 12, EYE_I); setPx(buf, 13, 12, EYE_W);
  fill(buf, 11, 14, 2, 1, MOUTH); // 嘴

  // ===== 身体（8×12×4）=====
  fill(buf, 16, 20, 24, 12, SHIRT); // 右/前/左/后 4 面
  fill(buf, 20, 16, 16, 4, SHIRT);  // 顶/底

  // ===== 右臂（4×12×4）：上半袖子(SHIRT) 下半肤色 =====
  fill(buf, 40, 20, 16, 12, SKIN);
  fill(buf, 40, 20, 16, 4, SHIRT);  // 袖口 4 行
  fill(buf, 44, 16, 4, 4, SHIRT);   // 臂顶
  fill(buf, 48, 16, 4, 4, SKIN);    // 臂底

  // ===== 左臂（1.8 独立区 (32,48)-(48,64)）=====
  fill(buf, 32, 52, 16, 12, SKIN);
  fill(buf, 32, 52, 16, 4, SHIRT);
  fill(buf, 36, 48, 4, 4, SHIRT);
  fill(buf, 40, 48, 4, 4, SKIN);

  // ===== 右腿（(0,16)-(16,32)）=====
  fill(buf, 0, 20, 16, 12, PANTS);
  fill(buf, 4, 16, 8, 4, PANTS);    // 腿顶/底

  // ===== 左腿（1.8 独立区 (16,48)-(32,64)）=====
  fill(buf, 16, 52, 16, 12, PANTS);
  fill(buf, 20, 48, 8, 4, PANTS);

  cachedSteve = buf;
  return buf;
}

export const DEFAULT_SKIN_W = W;
export const DEFAULT_SKIN_H = H;
