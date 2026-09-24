import { DiagnosticPolicy } from 'commons';
/**
 * SkinCanvas3D.ets — 真 3D 皮肤渲染（M2.5 · 2026-05-23 v6 software rasterizer）
 *
 * 角色：账户详情 Sheet 里展示玩家皮肤的**主路径**。不依赖 WebView、不依赖
 * 第三方服务（Crafatar 等），全部本地软件渲染。
 *
 * 渲染管线（真 3D，软件光栅化，参考 mineatar-io/skin-render 的 CPU 渲染思路）：
 *   1. 12 个 cuboid（6 基础 + 6 overlay：head/body/双臂/双腿，含 hat/jacket/sleeves/pants）
 *      —— 详见 buildModel()
 *   2. 每个 cuboid 拆 6 面，每个面 4 顶点 + 一个 UV 矩形
 *   3. 顶点做 yaw + pitch 旋转 → 正交投影到 2D 屏幕（详见 projectCube()）
 *   4. 背面剔除（rotated outward normal 的 Z 分量 <= 0 即背向相机，跳过）
 *   5. Painter's algorithm 按 avgZ 从远到近排序
 *   6. **软件光栅化**：把 skin 解码成 RGBA 字节缓冲，逐面用「逆仿射」对每个目标
 *      像素求 UV，最近邻采样源像素，alpha 合成到 W*H*4 字节的目标缓冲
 *      —— 详见 rasterizeFaceToBuffer()
 *   7. 把目标缓冲转成 PixelMap，单次 drawImage(destPM, 0, 0) 一次贴出
 *
 * 为什么 v6 改成软件光栅化：v5 用 ctx.setTransform(a,b,c,d,e,f) + 9-arg
 * drawImage(pm, sx,sy,sw,sh, 0,0,sw,sh) 走 Canvas 仿射。各面 affine math 验证正确，
 * 可视化却是「零碎拼图」，怀疑 OpenHarmony 5 / API 14 的 Canvas 在 setTransform 非
 * 单位变换下 drawImage(PixelMap, sx,sy,sw,sh,…) 不能正确把源裁剪映射到目标平行四
 * 边形（诊断条带 raw blit 在单位变换下是好的 → quirk 锁定在 setTransform 路径）。
 * 软件光栅化绕过这条路径：所有像素自己算、自己写缓冲，最后 drawImage 只用一次而且
 * 是单位变换 + 整图 blit，彻底消除歧义。性能上 280×320 = 90K 像素 × 36 面里只有
 * ~30K 像素被实际填充，纯 JS 也是个位数毫秒。
 *
 * 视角：yaw=-25°（玩家向相机右侧轻微转身）+ pitch=12°（相机略微俯视），
 *       近似 Crafatar /renders/body 的视觉。
 *
 * 不做的事：
 *   - 没有可拖拽旋转（只有静态视图。要旋转需要把 yaw 改成 @State 并加手势识别）
 *   - 没有走路动画
 *   - 没有 cape / elytra 渲染（披风走单独的 CapePreview 组件）
 *   - 没有光照 / 阴影（每个面统一亮度。要加方向光可以基于 normal 算 cos α 做亮度衰减）
 *
 * 创建日期：2026-05-23
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import { ThemeColors } from 'commons';
import { getRemotePixelMap } from 'commons';
import { buildSteveSkinRGBA, DEFAULT_SKIN_W, DEFAULT_SKIN_H } from './DefaultSkin';

const TAG = 'SkinCanvas3D';

// ============================================================
//  ⚠️  HTTPS skin PNG 必须走 PixelMap，不能用 ImageBitmap(url)
//
//  OpenHarmony 5 / API 14 的 `new ImageBitmap(httpsUrl)` 有静默不发请求的 quirk
//  （和 `Image(httpsUrl)` 同源问题）。所以这里走 getRemotePixelMap：
//    http.request → image.createImageSource(ArrayBuffer) → createPixelMap →
//    ctx.drawImage(pixelMap, ...)
//  同一份 fetch+decode 缓存复用 RemoteImage 那套，详见 common/RemoteImageCache.ets。
// ============================================================

// ============================================================
//  真 3D 渲染数据结构
//
//  算法参考：
//    1. mineatar-io/skin-render（Go）—— 主要参考。CPU 软件渲染、UV 偏移表、
//       per-pixel composite。我们这里 3D 数学比 mineatar 更通用（任意 yaw/pitch
//       而不是固定 isometric），但 rasterize 思路一致：自己写每个像素，不依赖
//       Canvas 仿射变换。
//       https://github.com/mineatar-io/skin-render
//    2. Minecraft skin UV layout（64×64，1.8+）来自 wiki/Skin
//       https://minecraft.wiki/w/Skin
//    3. bs-community/skinview3d —— UV 顶点对应关系（特别是底面的特殊翻转）
//       https://github.com/bs-community/skinview3d
//
//  组成：12 个 cuboid（6 个基础层 + 6 个 overlay 层）
//    - head (8×8×8) / body (8×12×4) / 双臂 (aw×12×4) / 双腿 (4×12×4)
//    - 每个 cube 6 个面，每个面对应 skin PNG 的一个 UV 矩形
//
//  渲染管线：
//    Cube → 6 face × 4 vertex（模型空间）
//    → 旋转（yaw + pitch）变换到相机空间
//    → 背面剔除（rotated outward normal Z <= 0 的不画）
//    → painter's algorithm 按 avgZ 从远到近排序
//    → 软件光栅化（rasterizeFaceToBuffer）：每个 dest 像素逆仿射求 UV，
//      最近邻采样源 RGBA，alpha-over 合成到 dest 缓冲
//    → 一次性 image.createPixelMap(destBuf) → ctx.drawImage(destPM, 0, 0)
// ============================================================

/** UV 源矩形（skin PNG 上的像素位置） */
interface UV {
  sx: number;
  sy: number;
  sw: number;
  sh: number;
}

/** 一个 cuboid 6 个面的 UV 集合（基础层或 overlay 层） */
interface CubeUVs {
  front: UV;
  back: UV;
  top: UV;
  bottom: UV;
  right: UV;  // 看玩家正面时玩家的左侧（屏幕的右侧?? 不，是 +X 方向，对应玩家左侧）
  left: UV;   // -X 方向，对应玩家右侧
}

/** 一个 cuboid：中心位置 + 半边长 + 6 个面的 UV */
interface CubeDef {
  cx: number; cy: number; cz: number;
  hw: number; hh: number; hd: number;
  uvs: CubeUVs;
  name: string;
}

/**
 * Minecraft 标准模型：
 *   原点在玩家髋部，Y 朝上、X 朝玩家左侧（视角右）、Z 朝玩家前（视角前）。
 *   单位 = 1 Minecraft pixel。整个玩家 32 单位高。
 *
 * 各部位:
 *   - 双腿（12 高）：底部 y=-12，顶部 y=0  → 中心 y=-6
 *   - 躯干（12 高）：底部 y=0，顶部 y=12   → 中心 y=6
 *   - 双臂（12 高）：与躯干同高（中心 y=6），左右贴着躯干外侧
 *   - 头（8 高）：底部 y=12，顶部 y=20    → 中心 y=16
 */
function buildModel(slim: boolean, showOverlay: boolean): CubeDef[] {
  let aw = slim ? 3 : 4;   // 手臂宽度
  let ahw = aw / 2;        // 手臂半宽

  let cubes: CubeDef[] = [];

  // ============ 基础层 ============

  // 头 (8×8×8) center (0, 16, 0)
  cubes.push({
    cx: 0, cy: 16, cz: 0,
    hw: 4, hh: 4, hd: 4,
    name: 'head',
    uvs: {
      front:  { sx: 8,  sy: 8,  sw: 8, sh: 8 },
      back:   { sx: 24, sy: 8,  sw: 8, sh: 8 },
      top:    { sx: 8,  sy: 0,  sw: 8, sh: 8 },
      bottom: { sx: 16, sy: 0,  sw: 8, sh: 8 },
      right:  { sx: 16, sy: 8,  sw: 8, sh: 8 },  // +X 玩家左脸
      left:   { sx: 0,  sy: 8,  sw: 8, sh: 8 },  // -X 玩家右脸
    },
  });

  // 躯干 (8×12×4) center (0, 6, 0)
  cubes.push({
    cx: 0, cy: 6, cz: 0,
    hw: 4, hh: 6, hd: 2,
    name: 'body',
    uvs: {
      front:  { sx: 20, sy: 20, sw: 8, sh: 12 },
      back:   { sx: 32, sy: 20, sw: 8, sh: 12 },
      top:    { sx: 20, sy: 16, sw: 8, sh: 4 },
      bottom: { sx: 28, sy: 16, sw: 8, sh: 4 },
      right:  { sx: 28, sy: 20, sw: 4, sh: 12 },  // +X 玩家左腰
      left:   { sx: 16, sy: 20, sw: 4, sh: 12 },  // -X 玩家右腰
    },
  });

  // 玩家右臂（在 -X 侧）—— 使用 (44,20) 起的右臂 UV
  cubes.push({
    cx: -(4 + ahw), cy: 6, cz: 0,
    hw: ahw, hh: 6, hd: 2,
    name: 'rightArm',
    uvs: {
      front:  { sx: 44,        sy: 20, sw: aw, sh: 12 },
      back:   { sx: 44+aw+4,   sy: 20, sw: aw, sh: 12 },
      top:    { sx: 44,        sy: 16, sw: aw, sh: 4 },
      bottom: { sx: 44+aw,     sy: 16, sw: aw, sh: 4 },
      right:  { sx: 44+aw,     sy: 20, sw: 4,  sh: 12 },  // +X 朝身体
      left:   { sx: 40,        sy: 20, sw: 4,  sh: 12 },  // -X 外侧
    },
  });

  // 玩家左臂（在 +X 侧）—— 1.8+ 独立 UV (36, 52)
  cubes.push({
    cx: (4 + ahw), cy: 6, cz: 0,
    hw: ahw, hh: 6, hd: 2,
    name: 'leftArm',
    uvs: {
      front:  { sx: 36,        sy: 52, sw: aw, sh: 12 },
      back:   { sx: 36+aw+4,   sy: 52, sw: aw, sh: 12 },
      top:    { sx: 36,        sy: 48, sw: aw, sh: 4 },
      bottom: { sx: 36+aw,     sy: 48, sw: aw, sh: 4 },
      right:  { sx: 36+aw,     sy: 52, sw: 4,  sh: 12 },  // +X 外侧
      left:   { sx: 32,        sy: 52, sw: 4,  sh: 12 },  // -X 朝身体
    },
  });

  // 玩家右腿（-X 侧）
  cubes.push({
    cx: -2, cy: -6, cz: 0,
    hw: 2, hh: 6, hd: 2,
    name: 'rightLeg',
    uvs: {
      front:  { sx: 4,  sy: 20, sw: 4, sh: 12 },
      back:   { sx: 12, sy: 20, sw: 4, sh: 12 },
      top:    { sx: 4,  sy: 16, sw: 4, sh: 4 },
      bottom: { sx: 8,  sy: 16, sw: 4, sh: 4 },
      right:  { sx: 8,  sy: 20, sw: 4, sh: 12 },  // +X 内侧
      left:   { sx: 0,  sy: 20, sw: 4, sh: 12 },  // -X 外侧
    },
  });

  // 玩家左腿（+X 侧）—— 1.8+ 独立 UV (20, 52)
  cubes.push({
    cx: 2, cy: -6, cz: 0,
    hw: 2, hh: 6, hd: 2,
    name: 'leftLeg',
    uvs: {
      front:  { sx: 20, sy: 52, sw: 4, sh: 12 },
      back:   { sx: 28, sy: 52, sw: 4, sh: 12 },
      top:    { sx: 20, sy: 48, sw: 4, sh: 4 },
      bottom: { sx: 24, sy: 48, sw: 4, sh: 4 },
      right:  { sx: 24, sy: 52, sw: 4, sh: 12 },  // +X 外侧
      left:   { sx: 16, sy: 52, sw: 4, sh: 12 },  // -X 内侧
    },
  });

  if (!showOverlay) return cubes;

  // ============ Overlay 层（hat/jacket/sleeve/pants）============
  // 每个 overlay cube 比基础 cube 稍大 0.5 单位（每个方向 +0.25），避免 Z-fighting
  let ovExpand = 0.25;

  // hat
  cubes.push({
    cx: 0, cy: 16, cz: 0,
    hw: 4 + ovExpand, hh: 4 + ovExpand, hd: 4 + ovExpand,
    name: 'hat',
    uvs: {
      front:  { sx: 40, sy: 8,  sw: 8, sh: 8 },
      back:   { sx: 56, sy: 8,  sw: 8, sh: 8 },
      top:    { sx: 40, sy: 0,  sw: 8, sh: 8 },
      bottom: { sx: 48, sy: 0,  sw: 8, sh: 8 },
      right:  { sx: 48, sy: 8,  sw: 8, sh: 8 },
      left:   { sx: 32, sy: 8,  sw: 8, sh: 8 },
    },
  });

  // jacket
  cubes.push({
    cx: 0, cy: 6, cz: 0,
    hw: 4 + ovExpand, hh: 6 + ovExpand, hd: 2 + ovExpand,
    name: 'jacket',
    uvs: {
      front:  { sx: 20, sy: 36, sw: 8, sh: 12 },
      back:   { sx: 32, sy: 36, sw: 8, sh: 12 },
      top:    { sx: 20, sy: 32, sw: 8, sh: 4 },
      bottom: { sx: 28, sy: 32, sw: 8, sh: 4 },
      right:  { sx: 28, sy: 36, sw: 4, sh: 12 },
      left:   { sx: 16, sy: 36, sw: 4, sh: 12 },
    },
  });

  // 右袖
  cubes.push({
    cx: -(4 + ahw), cy: 6, cz: 0,
    hw: ahw + ovExpand, hh: 6 + ovExpand, hd: 2 + ovExpand,
    name: 'rightSleeve',
    uvs: {
      front:  { sx: 44,        sy: 36, sw: aw, sh: 12 },
      back:   { sx: 44+aw+4,   sy: 36, sw: aw, sh: 12 },
      top:    { sx: 44,        sy: 32, sw: aw, sh: 4 },
      bottom: { sx: 44+aw,     sy: 32, sw: aw, sh: 4 },
      right:  { sx: 44+aw,     sy: 36, sw: 4,  sh: 12 },
      left:   { sx: 40,        sy: 36, sw: 4,  sh: 12 },
    },
  });

  // 左袖（1.8+）
  cubes.push({
    cx: (4 + ahw), cy: 6, cz: 0,
    hw: ahw + ovExpand, hh: 6 + ovExpand, hd: 2 + ovExpand,
    name: 'leftSleeve',
    uvs: {
      front:  { sx: 52,        sy: 52, sw: aw, sh: 12 },
      back:   { sx: 52+aw+4,   sy: 52, sw: aw, sh: 12 },
      top:    { sx: 52,        sy: 48, sw: aw, sh: 4 },
      bottom: { sx: 52+aw,     sy: 48, sw: aw, sh: 4 },
      right:  { sx: 52+aw,     sy: 52, sw: 4,  sh: 12 },
      left:   { sx: 48,        sy: 52, sw: 4,  sh: 12 },
    },
  });

  // 右裤腿
  cubes.push({
    cx: -2, cy: -6, cz: 0,
    hw: 2 + ovExpand, hh: 6 + ovExpand, hd: 2 + ovExpand,
    name: 'rightPants',
    uvs: {
      front:  { sx: 4,  sy: 36, sw: 4, sh: 12 },
      back:   { sx: 12, sy: 36, sw: 4, sh: 12 },
      top:    { sx: 4,  sy: 32, sw: 4, sh: 4 },
      bottom: { sx: 8,  sy: 32, sw: 4, sh: 4 },
      right:  { sx: 8,  sy: 36, sw: 4, sh: 12 },
      left:   { sx: 0,  sy: 36, sw: 4, sh: 12 },
    },
  });

  // 左裤腿（1.8+）
  cubes.push({
    cx: 2, cy: -6, cz: 0,
    hw: 2 + ovExpand, hh: 6 + ovExpand, hd: 2 + ovExpand,
    name: 'leftPants',
    uvs: {
      front:  { sx: 4,  sy: 52, sw: 4, sh: 12 },
      back:   { sx: 12, sy: 52, sw: 4, sh: 12 },
      top:    { sx: 4,  sy: 48, sw: 4, sh: 4 },
      bottom: { sx: 8,  sy: 48, sw: 4, sh: 4 },
      right:  { sx: 8,  sy: 52, sw: 4, sh: 12 },
      left:   { sx: 0,  sy: 52, sw: 4, sh: 12 },
    },
  });

  return cubes;
}

// ============================================================
//  渲染管线 helpers
// ============================================================

/**
 * 一个 face 在相机空间的状态：4 个旋转后的 3D 顶点 + UV + avgZ（用于排序）
 */
interface ProjFace {
  // 屏幕空间四角（TL/TR/BR/BL）—— 不含居中偏移
  p0x: number; p0y: number;
  p1x: number; p1y: number;
  p2x: number; p2y: number;
  p3x: number; p3y: number;
  // 旋转后外法线的 Z 分量（用于背面剔除：> 0 即朝向相机，画；<= 0 即背向，跳过）
  //
  // 注意：这是真正的 3D 外法线的 Z（在 yaw+pitch 之后的相机空间），
  // 不是早期版本那种屏幕空间 2D cross。原 cross 方案的 bug：底面（-Y）的顶点顺序
  // 给出的是 OUTWARD 法线，其余 5 面给出的是 INWARD —— 不一致导致底面误判可见。
  // 现在每个面直接存预算好的外法线 Z（cardinal 方向，只有 6 种值），保证一致。
  normalZ: number;
  // 4 顶点 Z 均值（painter's algorithm 排序）
  avgZ: number;
  // 源 UV
  sx: number; sy: number; sw: number; sh: number;
  // 调试用
  name: string;
}

/**
 * 把一个 cube 转成 6 个 face 在相机空间的投影。
 *
 * @param def       cube 定义（中心 + 半边 + 6 UV）
 * @param yawSin    sin(yaw)，绕 Y 轴旋转
 * @param yawCos    cos(yaw)
 * @param pitchSin  sin(pitch)，绕 X 轴旋转
 * @param pitchCos  cos(pitch)
 * @param scale     模型 → 屏幕的缩放系数（pixel-per-unit）
 *
 * 返回的 face 投影坐标尚未加 ox/oy 居中偏移，由调用方在 drawFaces 加上。
 *
 * 关键修正（2026-05-23 v5）：背面剔除从「屏幕空间 2D cross」改为「3D 外法线 Z」。
 * 6 种 cardinal 外法线（±X、±Y、±Z）经过 yaw + pitch 旋转后的 Z 分量只有 6 个常数值，
 * 在函数开头算一次复用 —— 比 6 face × 1 cross 还便宜，而且不会受顶点顺序约定影响。
 */
function projectCube(def: CubeDef, yawSin: number, yawCos: number,
                     pitchSin: number, pitchCos: number, scale: number): ProjFace[] {
  // ============ 旋转后的 6 个 cardinal 外法线 Z 分量 ============
  //
  // 推导：单位向量 n = (nx, ny, nz) 做 yaw（绕 Y）+ pitch（绕 X）：
  //   x1 = nx*yawCos + nz*yawSin
  //   z1 = -nx*yawSin + nz*yawCos
  //   z2 = ny*pitchSin + z1*pitchCos
  //
  // 代入 6 个轴向单位向量得：
  //   +X 面：n=(1,0,0) → z2 = -yawSin * pitchCos
  //   -X 面：n=(-1,0,0) → z2 = +yawSin * pitchCos
  //   +Y 面：n=(0,1,0) → z2 = +pitchSin
  //   -Y 面：n=(0,-1,0) → z2 = -pitchSin
  //   +Z 面：n=(0,0,1) → z2 = +yawCos * pitchCos
  //   -Z 面：n=(0,0,-1) → z2 = -yawCos * pitchCos
  //
  // 视图默认 yaw=-25°, pitch=+12° → yawSin≈-0.42, yawCos≈0.91, pitchSin≈0.21, pitchCos≈0.98。
  // 所以可见的 3 个面（z2 > 0）分别是 +X（玩家左面）、+Y（顶面）、+Z（正面）—— 正确。
  let normalZPosX = -yawSin * pitchCos;   // +X 面（玩家左侧）
  let normalZNegX = yawSin * pitchCos;    // -X 面（玩家右侧）
  let normalZPosY = pitchSin;             // +Y 面（顶）
  let normalZNegY = -pitchSin;            // -Y 面（底）
  let normalZPosZ = yawCos * pitchCos;    // +Z 面（玩家正面）
  let normalZNegZ = -yawCos * pitchCos;   // -Z 面（玩家背面）
  // 8 个 cube 顶点（model space）。命名约定:
  //   xLo/xHi = -hw/+hw，yLo/yHi = -hh/+hh，zLo/zHi = -hd/+hd
  let xLo = def.cx - def.hw, xHi = def.cx + def.hw;
  let yLo = def.cy - def.hh, yHi = def.cy + def.hh;
  let zLo = def.cz - def.hd, zHi = def.cz + def.hd;

  // 每个顶点先 yaw（绕 Y）再 pitch（绕 X），然后正交投影到 2D。
  // 函数内联展开避免临时对象（ArkTS 上 GC 压力小一点）。

  // 顶点 0..7（model space）：
  //  0: (xLo, yLo, zLo)  1: (xHi, yLo, zLo)  2: (xHi, yHi, zLo)  3: (xLo, yHi, zLo)
  //  4: (xLo, yLo, zHi)  5: (xHi, yLo, zHi)  6: (xHi, yHi, zHi)  7: (xLo, yHi, zHi)

  // 旋转 + 投影：对每个顶点算出 (screenX, screenY, cameraZ)
  // 注意 ArkTS 数组性能：直接用 8 组 6 个数字（48 numbers）比对象数组快
  let vx0 = 0, vy0 = 0, vz0 = 0;
  let vx1 = 0, vy1 = 0, vz1 = 0;
  let vx2 = 0, vy2 = 0, vz2 = 0;
  let vx3 = 0, vy3 = 0, vz3 = 0;
  let vx4 = 0, vy4 = 0, vz4 = 0;
  let vx5 = 0, vy5 = 0, vz5 = 0;
  let vx6 = 0, vy6 = 0, vz6 = 0;
  let vx7 = 0, vy7 = 0, vz7 = 0;

  // 手动展开 8 次 rotateY + rotateX + project
  // yawCos / yawSin 把 (x, z) 旋转：x' = x*yawCos + z*yawSin, z' = -x*yawSin + z*yawCos
  // pitchCos / pitchSin 把 (y, z) 旋转：y'' = y*pitchCos - z'*pitchSin, z'' = y*pitchSin + z'*pitchCos
  // 屏幕 X = x' * scale，屏幕 Y = -y'' * scale（屏幕 Y 朝下，模型 Y 朝上）
  // 相机 Z = z''
  {
    let x = xLo, y = yLo, z = zLo;
    let x1 = x * yawCos + z * yawSin;
    let z1 = -x * yawSin + z * yawCos;
    let y2 = y * pitchCos - z1 * pitchSin;
    let z2 = y * pitchSin + z1 * pitchCos;
    vx0 = x1 * scale; vy0 = -y2 * scale; vz0 = z2;
  }
  {
    let x = xHi, y = yLo, z = zLo;
    let x1 = x * yawCos + z * yawSin;
    let z1 = -x * yawSin + z * yawCos;
    let y2 = y * pitchCos - z1 * pitchSin;
    let z2 = y * pitchSin + z1 * pitchCos;
    vx1 = x1 * scale; vy1 = -y2 * scale; vz1 = z2;
  }
  {
    let x = xHi, y = yHi, z = zLo;
    let x1 = x * yawCos + z * yawSin;
    let z1 = -x * yawSin + z * yawCos;
    let y2 = y * pitchCos - z1 * pitchSin;
    let z2 = y * pitchSin + z1 * pitchCos;
    vx2 = x1 * scale; vy2 = -y2 * scale; vz2 = z2;
  }
  {
    let x = xLo, y = yHi, z = zLo;
    let x1 = x * yawCos + z * yawSin;
    let z1 = -x * yawSin + z * yawCos;
    let y2 = y * pitchCos - z1 * pitchSin;
    let z2 = y * pitchSin + z1 * pitchCos;
    vx3 = x1 * scale; vy3 = -y2 * scale; vz3 = z2;
  }
  {
    let x = xLo, y = yLo, z = zHi;
    let x1 = x * yawCos + z * yawSin;
    let z1 = -x * yawSin + z * yawCos;
    let y2 = y * pitchCos - z1 * pitchSin;
    let z2 = y * pitchSin + z1 * pitchCos;
    vx4 = x1 * scale; vy4 = -y2 * scale; vz4 = z2;
  }
  {
    let x = xHi, y = yLo, z = zHi;
    let x1 = x * yawCos + z * yawSin;
    let z1 = -x * yawSin + z * yawCos;
    let y2 = y * pitchCos - z1 * pitchSin;
    let z2 = y * pitchSin + z1 * pitchCos;
    vx5 = x1 * scale; vy5 = -y2 * scale; vz5 = z2;
  }
  {
    let x = xHi, y = yHi, z = zHi;
    let x1 = x * yawCos + z * yawSin;
    let z1 = -x * yawSin + z * yawCos;
    let y2 = y * pitchCos - z1 * pitchSin;
    let z2 = y * pitchSin + z1 * pitchCos;
    vx6 = x1 * scale; vy6 = -y2 * scale; vz6 = z2;
  }
  {
    let x = xLo, y = yHi, z = zHi;
    let x1 = x * yawCos + z * yawSin;
    let z1 = -x * yawSin + z * yawCos;
    let y2 = y * pitchCos - z1 * pitchSin;
    let z2 = y * pitchSin + z1 * pitchCos;
    vx7 = x1 * scale; vy7 = -y2 * scale; vz7 = z2;
  }

  // 6 个面 —— 每个面 4 顶点按 (TL, TR, BR, BL) 顺序排列（从面外看 CCW）
  //
  // Front (+Z, 玩家正面，向 +Z 方向看时位于"后" —— 玩家面对相机时 +Z 朝相机后方？
  //   等等，约定要统一。这里约定：
  //   - Z 朝玩家"背后"是正方向（标准右手系，玩家朝 -Z 方向看）
  //   - 玩家的"正面"（脸朝向）= -Z 方向
  //   但 Minecraft 习惯 Z 朝玩家正前（玩家朝 +Z 看）。我们按 Minecraft：
  //     - +Z = 玩家正前（脸朝向）= 朝向相机
  //     - -Z = 玩家背后
  //
  //   yaw=0 时玩家正面朝相机。相机沿 -Z 方向看（看进屏幕）。
  //
  //   所以面 +Z 朝相机 → 是玩家"正面"。
  let faces: ProjFace[] = [];

  // 顶点速记 —— 立方体的 8 角，用 [x_lo/hi][y_lo/hi][z_lo/hi] 索引
  // ll0=(xLo,yLo,zLo)=v0, hl0=(xHi,yLo,zLo)=v1, hh0=(xHi,yHi,zLo)=v2, lh0=(xLo,yHi,zLo)=v3
  // ll1=(xLo,yLo,zHi)=v4, hl1=(xHi,yLo,zHi)=v5, hh1=(xHi,yHi,zHi)=v6, lh1=(xLo,yHi,zHi)=v7

  // Front face: +Z 方向（玩家正面）—— 外法线 +Z
  // 从相机看：TL=v7, TR=v6, BR=v5, BL=v4
  faces.push(makeFace(def.uvs.front, def.name + '.front', normalZPosZ,
    vx7, vy7, vz7, vx6, vy6, vz6, vx5, vy5, vz5, vx4, vy4, vz4));

  // Back face: -Z 方向 —— 外法线 -Z
  // 从相机看（背后）：TL=v2, TR=v3, BR=v0, BL=v1
  faces.push(makeFace(def.uvs.back, def.name + '.back', normalZNegZ,
    vx2, vy2, vz2, vx3, vy3, vz3, vx0, vy0, vz0, vx1, vy1, vz1));

  // Top face: +Y 方向 —— 外法线 +Y
  // 从上往下看：TL=v3, TR=v2, BR=v6, BL=v7（往 +Z 方向是"下面"，因为面在玩家头顶）
  faces.push(makeFace(def.uvs.top, def.name + '.top', normalZPosY,
    vx3, vy3, vz3, vx2, vy2, vz2, vx6, vy6, vz6, vx7, vy7, vz7));

  // Bottom face: -Y 方向
  //
  // 修正（2026-05-23 v4）：之前的 [v4, v5, v1, v0] 顺序与 Three.js BoxGeometry 不一致。
  // 我对照 mrdoob/three.js BoxGeometry.buildPlane 推导：-Y face 的 4 个顶点（按 Three.js
  // gridX=gridY=1 的 ix/iy 顺序）= UV-TL/TR/BL/BR 三角索引，对应 3D 位置：
  //   - Vertex 0 (UV-TL = image-TL of bottom rect) → (-X, -Y, +Z) = right-bottom-FRONT = v4
  //   - Vertex 1 (UV-TR = image-TR)                → (+X, -Y, +Z) = left-bottom-FRONT  = v5
  //   - Vertex 2 (UV-BL = image-BL)                → (-X, -Y, -Z) = right-bottom-BACK  = v0
  //   - Vertex 3 (UV-BR = image-BR)                → (+X, -Y, -Z) = left-bottom-BACK   = v1
  // 但 skinview3d 在 setUVs 里把 bottom 的 UV 顺序额外做了一次反转：
  //   `uvBottom = [bottom[0], bottom[1], bottom[3], bottom[2]]`（BL/BR/TL/TR），
  // 这就把 Three.js Vertex (0/1/2/3) 接到 image (BL/BR/TL/TR)：
  //   - 3D right-bottom-FRONT (v4) ← image-BL（bottom rect 的左下）
  //   - 3D left-bottom-FRONT  (v5) ← image-BR
  //   - 3D right-bottom-BACK  (v0) ← image-TL
  //   - 3D left-bottom-BACK   (v1) ← image-TR
  //
  // 所以我们的 (TL=P0, TR=P1, BR=P2, BL=P3) 应该是：
  //   - TL ← image-TL = back-right = v0
  //   - TR ← image-TR = back-left  = v1
  //   - BR ← image-BR = front-left = v5
  //   - BL ← image-BL = front-right= v4
  //
  // 历史 bug（v3 之前）：底面顶点顺序给出的 cross 是 OUTWARD 法线，其余 5 面给出的是 INWARD。
  // 用屏幕 2D cross 做剔除时 5 面 OK 但底面被误判为可见 —— 渲染日志显示 48 visible faces
  // 而非预期的 36（12 cubes × 3 visible faces）。现在用外法线 Z（-Y 旋转后），无歧义。
  faces.push(makeFace(def.uvs.bottom, def.name + '.bottom', normalZNegY,
    vx0, vy0, vz0, vx1, vy1, vz1, vx5, vy5, vz5, vx4, vy4, vz4));

  // Right face: +X 方向（玩家左侧，视角右）—— 外法线 +X
  // 从 +X 看：TL=v6, TR=v2, BR=v1, BL=v5
  faces.push(makeFace(def.uvs.right, def.name + '.right', normalZPosX,
    vx6, vy6, vz6, vx2, vy2, vz2, vx1, vy1, vz1, vx5, vy5, vz5));

  // Left face: -X 方向（玩家右侧，视角左）—— 外法线 -X
  // 从 -X 看：TL=v3, TR=v7, BR=v4, BL=v0
  faces.push(makeFace(def.uvs.left, def.name + '.left', normalZNegX,
    vx3, vy3, vz3, vx7, vy7, vz7, vx4, vy4, vz4, vx0, vy0, vz0));

  return faces;
}

/**
 * 构造一个 ProjFace —— 4 个屏幕顶点 + UV + 预算好的外法线 Z + avgZ（排序用）。
 *
 * @param outwardNormalZ  旋转后外法线的 Z 分量。> 0 表示面朝相机，drawPlayer 据此剔除。
 *                        由 projectCube 在函数开头一次性算出（6 种 cardinal 方向中的一种）。
 *
 * 历史：v3 之前这里用 (p1-p0) × (p3-p0) 屏幕 2D cross 做剔除，对 5 面有效，但底面顶点
 * 顺序给出的是 OUTWARD 法线而不是 INWARD，造成底面误判可见。现在改成由 projectCube 预
 * 计算外法线 Z 传入，完全消除歧义。
 */
function makeFace(uv: UV, name: string, outwardNormalZ: number,
                  p0x: number, p0y: number, p0z: number,
                  p1x: number, p1y: number, p1z: number,
                  p2x: number, p2y: number, p2z: number,
                  p3x: number, p3y: number, p3z: number): ProjFace {
  return {
    p0x, p0y, p1x, p1y, p2x, p2y, p3x, p3y,
    normalZ: outwardNormalZ,
    avgZ: (p0z + p1z + p2z + p3z) * 0.25,
    sx: uv.sx, sy: uv.sy, sw: uv.sw, sh: uv.sh,
    name,
  };
}

@Component
export struct SkinCanvas3D {
  @Prop @Watch('onInputsChange') skinUrl: string = '';
  @Prop @Watch('onInputsChange') username: string = '';
  @Prop @Watch('onInputsChange') isOffline: boolean = false;
  @Prop @Watch('onInputsChange') slim: boolean = false;
  @Prop theme: ThemeColors = {} as ThemeColors;

  /**
   * v6 之前 caller 用 containerWidth / containerHeight 给 SkinCanvas3D 强制尺寸；
   * v6 把外层 Stack 改成 width('100%').height('100%')，由父容器约束尺寸，自己用
   * onAreaChange 测量出实际像素，再按测量值生成 dest 缓冲。这两个 prop 保留是
   * 因为「父容器没给约束时」要有兜底初始值（也用作首次 onAreaChange 之前的占位）。
   */
  @Prop containerWidth: number = 280;
  @Prop containerHeight: number = 320;

  /** （保留向后兼容；新主路径不再上层降级，这里只是 no-op 默认值） */
  onError: () => void = () => {};

  @State _stage: string = 'loading';  // 'loading' | 'ready' | 'error'
  @State _errorMsg: string = '';
  /**
   * 已解码的 skin PixelMap。null = 还在加载 / 加载失败 → 走 letter fallback。
   * 用 @State 是为了在 fetch 回来后触发 build() 重跑，进而触发 Canvas onReady
   * 重绘。
   */
  @State _pixelMap: image.PixelMap | null = null;
  /** Canvas 是否已经准备好（onReady 触发过） */
  @State _canvasReady: boolean = false;

  /**
   * Canvas 上下文：抗锯齿打开（settings 第一个参数），但下面绘制时会显式
   * `imageSmoothingEnabled = false` 以保留像素风味。
   */
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  /**
   * 防止同一 skinUrl 重复 fetch：记录上次发出请求的 url，相同就不再发。
   * （getRemotePixelMap 内部有 cache，但 await 一次还是有开销，这里再短路一层。）
   */
  private _lastFetchedUrl: string = '';

  /**
   * 已解码的 skin RGBA 像素缓冲（PixelMap 解出来的字节，
   * RGBA_8888 layout —— 因为 RemoteImageCache 用 desiredPixelFormat=RGBA_8888 解码）。
   *
   * 软件光栅化的源数据：rasterizeFaceToBuffer 直接读这个数组采样像素。null = 还没解码
   * / 解码失败 → tryDraw 走 letter fallback。
   *
   * 占用：64×64×4 = 16 KiB（普通 1.8+ 64×64 皮肤）；旧版 32 像素高皮肤是 64×32×4 = 8 KiB。
   */
  private _skinRGBA: Uint8Array | null = null;
  private _skinW: number = 0;
  private _skinH: number = 0;

  /**
   * Async 绘制串行化标志。drawPlayer 异步（要 await image.createPixelMap），
   * tryDraw 可能被快连触发（onReady + fetch 回调 + slim 切换 + 拖拽旋转），用这两
   * 个标志保证同一时刻只有一个 drawPlayer 在跑，并合并掉中间的重复请求。
   */
  private _drawInProgress: boolean = false;
  private _drawPending: boolean = false;

  /**
   * 实际测量的 Canvas 尺寸（vp）。Canvas 用 width('100%').height('100%') 撑满父容器，
   * 通过 .onAreaChange 拿到真实像素 → drawPlayer 用这个尺寸建 dest 缓冲，保证渲染
   * 充满整个画布而不是固定 280×320 占左上角。
   *
   * 用 private 而非 @State 是因为我们手动调 tryDraw() 重绘 Canvas，不需要触发
   * build() 重跑。首次 onAreaChange 之前是 0，drawPlayer 会跳过这一帧。
   */
  private _measuredW: number = 0;
  private _measuredH: number = 0;

  /**
   * 相机角度（弧度）。yaw = 绕竖直轴（左右），pitch = 绕水平轴（俯仰）。
   * 默认 yaw=-25° pitch=12° → Crafatar 风的 3/4 透视。PanGesture 拖拽时按
   * 「1 vp = 0.5°」更新这两个角度，然后 tryDraw() 重绘。
   *
   * pitch 限幅 [-45°, 45°] 避免「头朝下 / 朝天」这种破图角度。
   */
  private _yaw: number = -25 * Math.PI / 180;
  private _pitch: number = 12 * Math.PI / 180;

  /**
   * PanGesture onActionStart 时记录手势起点的 yaw/pitch，onActionUpdate 时基于
   * 累计 offset 算新角度（而不是逐帧增量累加，避免漂移）。
   */
  private _gestureBaseYaw: number = 0;
  private _gestureBasePitch: number = 0;

  aboutToAppear(): void {
    // 第一手日志 —— 如果 hilog 看不到这条，说明 SkinCanvas3D 根本没被挂载
    // （检查 SkinCapeDetailSheet 是否打开，或 SkinCard 是否构建到了这个分支）。
    hilog.info(0x0000, TAG, 'aboutToAppear url=%{public}s slim=%{public}s offline=%{public}s w=%{public}d h=%{public}d',
      this.skinUrl.length > 0 ? this.skinUrl.substring(0, 80) : '(empty)',
      this.slim ? 'true' : 'false',
      this.isOffline ? 'true' : 'false',
      this.containerWidth, this.containerHeight);
    this.kickOffFetch();
  }

  /** @Watch 回调：skinUrl / slim 变化都重新拉皮肤 + 重绘 */
  onInputsChange(_propName: string): void {
    this.kickOffFetch();
  }

  build() {
    Stack() {
      // 注意：SkinCanvas3D 自己**不再画底色**，由父容器决定。
      //   - SkinCapeDetailSheet 在外层 Stack 提供了蓝色渐变 Column 作底
      //   - AccountListSheet 的 HeroCard 里只是个透明 Stack，背后是 card 的 bgCard
      // 这样调用方更灵活；旧版在这里画 60A5FA→1E40AF 蓝渐变会强制所有用法都有"蓝盒子"
      // 视觉，不符合"账户管理页不要蓝底"的需求。

      // Canvas 渲染层 —— 撑满父容器，自己用 onAreaChange 测量出实际像素，
      // 然后按测量值生成 dest 缓冲。PanGesture 处理拖拽旋转。
      Canvas(this.ctx)
        .width('100%')
        .height('100%')
        .onReady(() => {
          hilog.info(0x0000, TAG, 'canvas ready (skinUrl=%{public}s pmReady=%{public}s measured=%{public}dx%{public}d)',
            this.skinUrl.length > 0 ? 'set' : 'empty',
            this._pixelMap !== null ? 'yes' : 'no',
            this._measuredW, this._measuredH);
          this._canvasReady = true;
          this.tryDraw();
        })
        .onAreaChange((_old: Area, neu: Area) => {
          // Area.width / .height 是 Length，runtime 上是 number 或 string('xx vp')；
          // 这里是 Canvas 而且明确给了 100% 像素值，runtime 是 number
          let w = Math.round(Number(neu.width));
          let h = Math.round(Number(neu.height));
          if (w > 0 && h > 0 && (w !== this._measuredW || h !== this._measuredH)) {
            hilog.info(0x0000, TAG, 'onAreaChange %{public}dx%{public}d → %{public}dx%{public}d',
              this._measuredW, this._measuredH, w, h);
            this._measuredW = w;
            this._measuredH = h;
            this.tryDraw();
          }
        })
        .gesture(
          // 拖拽旋转：水平拖 → yaw（绕竖直轴左右转），垂直拖 → pitch（俯仰）。
          // distance: 5 vp 起步，避免误触；fingers: 1 单指拖拽。
          PanGesture({ fingers: 1, distance: 5 })
            .onActionStart(() => {
              this._gestureBaseYaw = this._yaw;
              this._gestureBasePitch = this._pitch;
            })
            .onActionUpdate((e: GestureEvent) => {
              // 1 vp 拖拽 = 0.5° 旋转（π/360）。手感跟 skinview3d / NameMC 类似。
              this._yaw = this._gestureBaseYaw + e.offsetX * Math.PI / 360;
              // pitch 限幅 [-45°, 45°]，避免角度极端导致面退化（det≈0）
              let dp = this._gestureBasePitch + e.offsetY * Math.PI / 360;
              let pitchMax = Math.PI / 4;
              this._pitch = dp > pitchMax ? pitchMax : (dp < -pitchMax ? -pitchMax : dp);
              this.tryDraw();
            })
        )

      // 错误兜底文字（letter fallback 也会画在 Canvas 上，这里仅留作 stage=error 时显示）
      if (this._stage === 'error' && this._errorMsg.length > 0) {
        Text(this._errorMsg)
          .fontSize(11)
          .fontColor('#FCA5A5')
          .textAlign(TextAlign.Center)
          .padding(12)
          .maxLines(2)
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
  }

  // ============================================================
  //  Fetch + 绘制流水线
  // ============================================================

  /**
   * 异步发起 skin PNG 拉取。完成后 `_pixelMap` 被赋值 + `_skinRGBA` 字节缓冲被填好，
   * 然后触发 `tryDraw()`。
   *
   * 幂等性：同一 url 不会重复 fetch（_lastFetchedUrl 短路 + getRemotePixelMap
   * 自己的 inflight cache 双保险）。
   */
  private kickOffFetch(): void {
    // Offline 或无 url —— 不走网络。离线账户改用程序化默认 Steve 皮肤渲染 3D 模型
    // （比字母头像更直观、与游戏一致）；真正"无皮肤且非离线占位"才退字母。
    if (this.isOffline || this.skinUrl.length === 0) {
      this._pixelMap = null;
      this._lastFetchedUrl = '';
      this._skinRGBA = buildSteveSkinRGBA();
      this._skinW = DEFAULT_SKIN_W;
      this._skinH = DEFAULT_SKIN_H;
      this.tryDraw();
      return;
    }

    let url = this.skinUrl;
    if (url === this._lastFetchedUrl && this._pixelMap !== null && this._skinRGBA !== null) {
      // 已经拉过同一张 + 像素缓冲也在 → 直接重绘（处理 slim 切换场景）
      this.tryDraw();
      return;
    }
    this._lastFetchedUrl = url;

    getRemotePixelMap(url).then(async (pm: image.PixelMap | null): Promise<void> => {
      // 异步回来时 skinUrl 可能已经被切换到别的账户；只有当前 prop 仍然是当时
      // 发起的 url 才 commit，避免快切账户时显示错图。
      if (this.skinUrl !== url) {
        hilog.info(0x0000, TAG, 'skinUrl changed mid-fetch, dropping result for %{public}s', url);
        return;
      }
      if (pm !== null) {
        // 把 PixelMap 字节倒到 Uint8Array，软件光栅化会从这里采样源像素。
        // RemoteImageCache 用 desiredPixelFormat=RGBA_8888 解码 → buf 字节是 RGBA。
        await this.cacheSkinPixels(pm);
      } else {
        this._skinRGBA = null;
        this._skinW = 0;
        this._skinH = 0;
      }
      // cacheSkinPixels 也是 async，期间 skinUrl 可能再次被切换，再次校验
      if (this.skinUrl !== url) {
        hilog.info(0x0000, TAG, 'skinUrl changed during pixel cache, dropping for %{public}s', url);
        return;
      }
      this._pixelMap = pm;
      if (pm === null) {
        hilog.warn(0x0000, TAG, 'fetch returned null for %{public}s, falling back to letter', url);
      } else {
        hilog.info(0x0000, TAG, 'fetch+cache ok for %{public}s rgba=%{public}s',
          url, this._skinRGBA !== null ? 'yes' : 'no');
      }
      this.tryDraw();
    });
  }

  /**
   * 把 PixelMap 字节倒到 Uint8Array，软件光栅化会从这里直接采样源像素。
   *
   * 字节布局：因为 RemoteImageCache 用 desiredPixelFormat=RGBA_8888 解码，所以缓冲
   * 是 RGBA 排列（每像素 4 字节，顺序 R, G, B, A）。如果哪天上游格式变了，需要在这里
   * 显式做一次 swizzle。
   *
   * 失败时 `_skinRGBA = null`，外层 `tryDraw` 会走 letter fallback。
   */
  private async cacheSkinPixels(pm: image.PixelMap): Promise<void> {
    try {
      let info = await pm.getImageInfo();
      let sw = info.size.width;
      let sh = info.size.height;
      if (sw <= 0 || sh <= 0) {
        hilog.warn(0x0000, TAG, 'invalid skin size %{public}dx%{public}d', sw, sh);
        this._skinRGBA = null;
        return;
      }
      let buf = new ArrayBuffer(sw * sh * 4);
      await pm.readPixelsToBuffer(buf);
      this._skinRGBA = new Uint8Array(buf);
      this._skinW = sw;
      this._skinH = sh;
      hilog.info(0x0000, TAG, 'skin pixels cached %{public}dx%{public}d (%{public}d bytes)',
        sw, sh, buf.byteLength);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'cacheSkinPixels failed: %{public}s', (e as Error).message);
      this._skinRGBA = null;
      this._skinW = 0;
      this._skinH = 0;
    }
  }

  /**
   * 尝试绘制 —— 三个条件：Canvas 已经 onReady + (pixelMap + 像素缓冲都有 → drawPlayer)
   * 或 (没有 pixmap → letter fallback)。
   *
   * drawPlayer 是 async（要 await image.createPixelMap 把 dest 缓冲转回 PixelMap），
   * 用 _drawInProgress / _drawPending 串行化：同一时刻只跑一个 drawPlayer，重复请求
   * 合并到尾后再跑一次，避免快连触发（fetch 完 + onReady + slim 切换）撞到一起。
   */
  private tryDraw(): void {
    if (!this._canvasReady) return;
    // onAreaChange 没跑过 → Canvas 真实尺寸还不知道，先不画，等 onAreaChange 触发再说。
    // （onReady 和 onAreaChange 两者顺序在 ArkUI 里没强保证，这里防御性处理。）
    if (this._measuredW <= 0 || this._measuredH <= 0) return;

    // 没有皮肤 / 像素缓冲未就绪 → letter fallback（同步路径）
    if (this._pixelMap === null || this._skinRGBA === null) {
      try {
        this.drawLetterFallback();
        this._stage = 'ready';
      } catch (e) {
        this._stage = 'error';
        this._errorMsg = '渲染失败';
        hilog.warn(0x0000, TAG, 'fallback draw failed: %{public}s', (e as Error).message);
        this.onError();
      }
      return;
    }

    // 已有 drawPlayer 在跑 → 标记尾后再跑一次，自己直接 return
    if (this._drawInProgress) {
      this._drawPending = true;
      return;
    }

    this._drawInProgress = true;
    let pm = this._pixelMap;
    this.drawPlayer(pm)
      .then(() => {
        this._stage = 'ready';
      })
      .catch((e: Error) => {
        this._stage = 'error';
        this._errorMsg = '渲染失败';
        hilog.warn(0x0000, TAG, 'draw failed: %{public}s', e.message);
        this.onError();
      })
      .then(() => {
        // 串行化收尾。注意这里没用 .finally —— ArkTS / API 14 早期版本对它支持有歧义，
        // 拿第二个 .then 当 finally 一样可靠（前一个 .catch 已经吃掉异常）。
        this._drawInProgress = false;
        if (this._drawPending) {
          this._drawPending = false;
          this.tryDraw();
        }
      });
  }

  /**
   * 渲染没皮肤时的 fallback：渐变底（外层 Stack 已经画好）+ 用户名大首字母。
   *
   * 用 _measuredW/H 而不是 containerWidth/Height —— v6 起 SkinCanvas3D 撑满父容器，
   * 实际像素由 onAreaChange 测出来。首次 onAreaChange 之前用 containerWidth/Height 兜底。
   */
  private drawLetterFallback(): void {
    let ctx = this.ctx;
    let w = this._measuredW > 0 ? this._measuredW : this.containerWidth;
    let h = this._measuredH > 0 ? this._measuredH : this.containerHeight;
    if (w <= 0 || h <= 0) return;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, w, h);

    let letter = this.username && this.username.length > 0
      ? this.username.charAt(0).toUpperCase()
      : '?';
    ctx.fillStyle = '#FFFFFF';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.font = 'bold ' + Math.floor(Math.min(w, h) * 0.5) + 'px sans-serif';
    ctx.fillText(letter, w / 2, h / 2);
  }

  /**
   * 真 3D 渲染主入口：把 12 个 cuboid（基础层 + overlay）旋转、剔除背面、
   * painter's algorithm 排序，**软件光栅化**到 W*H*4 字节缓冲，最后单次
   * `image.createPixelMap` + `drawImage` 一次贴出。
   *
   * 默认相机角度：yaw=-25°（玩家向相机右轻微转身，露出玩家的右侧 / 视角左侧），
   *               pitch=12°（相机略微俯视，露出头顶 + 肩膀 + 鞋面）。
   *
   * 为什么是 async：image.createPixelMap 没有同步版本（API 12+ 才补的 Sync 系列在
   * 部分设备 / 版本上不稳），稳妥起见走 Promise，调用方 `tryDraw` 用 _drawInProgress
   * 串行化避免重入。
   *
   * 失败语义：rasterize 阶段不抛（per-pixel 失败默默跳过），createPixelMap 抛了直接
   * 把错误冒泡给 tryDraw 的 .catch，那里会切到 'error' stage。
   */
  private async drawPlayer(_img: image.PixelMap): Promise<void> {
    let ctx = this.ctx;
    // 用 onAreaChange 测出来的实际 Canvas 尺寸；首次 onAreaChange 之前用 containerWidth/Height 兜底
    let w = this._measuredW > 0 ? this._measuredW : Math.floor(this.containerWidth);
    let h = this._measuredH > 0 ? this._measuredH : Math.floor(this.containerHeight);
    if (w <= 0 || h <= 0) {
      hilog.warn(0x0000, TAG, 'invalid canvas size %{public}dx%{public}d, skip', w, h);
      return;
    }
    if (this._skinRGBA === null) {
      hilog.warn(0x0000, TAG, 'drawPlayer called without skin RGBA cached, abort');
      return;
    }

    // 相机角度（来自手势状态；初值 yaw=-25° pitch=12°）
    let yawSin = Math.sin(this._yaw);
    let yawCos = Math.cos(this._yaw);
    let pitchSin = Math.sin(this._pitch);
    let pitchCos = Math.cos(this._pitch);

    // 模型 → 屏幕缩放：玩家高 32 unit（脚底到头顶），加上 hat overlay 厚 0.5 unit
    // + pitch 旋转后头顶相对髋部还会再往上偏一点点 → 实际占用 ~33 unit。
    //
    // 之前用 scaleH = h/36 + oy = h*0.48 → 顶部只有 ~11 vp 留白，hat 顶角会被
    // canvas 上边切掉。改成 scaleH = h/40 + oy = h*0.52 留更宽裕的 padding：
    //   上 padding ≈ h × (0.52 - 16/40) = 0.12h ≈ 38 vp (320 时)
    //   下 padding ≈ h × (1 - 0.52 - 16/40) = 0.08h ≈ 26 vp (320 时)
    //
    // 玩家旋转后水平投影最宽 ≈ sqrt(8² + 8²) ≈ 11.3 unit（头宽 8 + 厚 8 的对角线），
    // 加 pitch 后水平宽度小幅变化，按 ~18 unit（约 ±9 unit）留余量基本够用。
    let scaleW = w / 18;
    let scaleH = h / 40;
    let scale = Math.min(scaleW, scaleH);

    // 模型原点在玩家髋部（y=0）；画到屏幕中央偏下，给头部多留 padding，避免 hat overlay
    // 顶角 / pitch 旋转后的头顶被 canvas 上边切掉。
    let ox = w * 0.5;
    let oy = h * 0.52;

    let t0 = Date.now();
    hilog.info(0x0000, TAG, 'drawPlayer canvas=%{public}dx%{public}d scale=%{public}f origin=(%{public}f,%{public}f)',
      w, h, scale, ox, oy);

    // 1. 构造 12 个 cuboid 模型
    let cubes = buildModel(this.slim, true);

    // 2. 每个 cuboid → 6 个投影 face，收集到统一 face 列表
    let allFaces: ProjFace[] = [];
    for (let cube of cubes) {
      let cubeFaces = projectCube(cube, yawSin, yawCos, pitchSin, pitchCos, scale);
      for (let face of cubeFaces) {
        // 背面剔除：face.normalZ 是旋转后 3D 外法线的 Z 分量。
        // > 0 = 朝相机（保留）；<= 0 = 背向（剔除）。
        if (face.normalZ <= 0) continue;
        allFaces.push(face);
      }
    }

    // 3. Painter's algorithm —— avgZ 从远到近排（远的先画，近的覆盖）
    //    相机沿 -Z 方向看，所以 z 大 = 近相机；从小到大排即「远 → 近」。
    allFaces.sort((a: ProjFace, b: ProjFace): number => a.avgZ - b.avgZ);

    hilog.info(0x0000, TAG, 'projected %{public}d cubes → %{public}d visible faces',
      cubes.length, allFaces.length);

    // 4. 分配目标 RGBA 字节缓冲（已是全 0 = 全透明，符合 Uint8Array 默认）。
    //    280×320×4 = 358 400 bytes ≈ 350 KiB，单次分配，画完一张就回收。
    let destBuf = new ArrayBuffer(w * h * 4);
    let dest = new Uint8Array(destBuf);

    // 5. 软件光栅化每个 face（已按 painter's 排好序）。先画的远面会被后画的近面覆盖。
    let totalTouched = 0;
    for (let face of allFaces) {
      totalTouched += this.rasterizeFaceToBuffer(face, ox, oy, dest, w, h);
    }
    let t1 = Date.now();
    hilog.info(0x0000, TAG, 'rasterized %{public}d faces, touched=%{public}d px in %{public}d ms',
      allFaces.length, totalTouched, t1 - t0);

    // 6. dest buffer → PixelMap → 一次性 drawImage 贴到 Canvas（单位变换路径，已验证可靠）
    let opts: image.InitializationOptions = {
      size: { width: w, height: h },
      srcPixelFormat: image.PixelMapFormat.RGBA_8888,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      alphaType: image.AlphaType.UNPREMUL,
      editable: false,
    };

    let destPM: image.PixelMap;
    try {
      destPM = await image.createPixelMap(destBuf, opts);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'createPixelMap failed: %{public}s', (e as Error).message);
      throw e as Error;
    }

    let t2 = Date.now();
    hilog.info(0x0000, TAG, 'createPixelMap took %{public}d ms', t2 - t1);

    // 单次 drawImage —— 单位变换 + 整图 blit。
    //
    // ⚠️ 重要：必须用 5 参 drawImage(pm, dx, dy, dw, dh) 显式给目标矩形（vp 坐标）。
    // 2 参版本 drawImage(pm, 0, 0) 在 HarmonyOS Canvas 上会把 PM 的「自然尺寸」按
    // **device px** 解释贴出来 —— 在 3.x 密度屏上 342 px 只覆盖 ~97 vp，整张图缩
    // 在左上角，外面留出大片渐变背景（这就是 v6 初版的「皮肤还是只能显示在左上角」）。
    //
    // 用 5 参显式给 dest = (w, h) vp 后，Canvas 会把 PM 从 native (w×h) 像素放大到
    // (w×h) vp = (w·density)×(h·density) device px，配合 imageSmoothingEnabled=false
    // 走 nearest-neighbor 放大 —— 对 Minecraft 像素风皮肤来说，这就是「想要的视觉」。
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.imageSmoothingEnabled = false;
    ctx.clearRect(0, 0, w, h);
    try {
      ctx.drawImage(destPM, 0, 0, w, h);
      let t3 = Date.now();
      hilog.info(0x0000, TAG, 'final blit ok (drawImage %{public}d ms, total %{public}d ms)',
        t3 - t2, t3 - t0);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'final drawImage failed: %{public}s', (e as Error).message);
      throw e as Error;
    }

    // 释放 dest PixelMap：Canvas drawImage 是同步把内容上屏的（拷到 surface），
    // 之后这个临时 PixelMap 就可以回收，否则每帧泄一份 ~350 KiB。
    try {
      destPM.release();
    } catch (e) {
      // PixelMap.release 抛错就忽略，GC 兜底
      if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'destPM release ignored: %{public}s', (e as Error).message);
    }
  }

  /**
   * 软件光栅化一个面：把 `face` 的 UV 矩形 (sx,sy,sw,sh) 沿仿射映射贴到目标 RGBA 缓冲。
   *
   * 算法（per-pixel，类似 mineatar-io 的 compositeTransform 思路）：
   *   1. 屏幕空间 4 顶点 P0..P3 围成一个平行四边形（正交投影下立方体面就是平行四边形）
   *   2. 算屏幕轴对齐 bbox，逐目标像素 `(x, y)` 走
   *   3. 对每个像素，反解仿射得到源 UV：
   *        forward: dest = M·src + P0 其中 M = [[a,c],[b,d]],
   *                 a = (P1-P0).x/sw, b = (P1-P0).y/sw, c = (P3-P0).x/sh, d = (P3-P0).y/sh
   *        inverse: src = M⁻¹·(dest - P0)，det = a·d − b·c，
   *                 u = (d·dx − c·dy)/det，v = (−b·dx + a·dy)/det
   *   4. 如果 (u, v) 落在 [0, sw) × [0, sh) 之外 → 像素不在平行四边形里 → 跳过
   *   5. 最近邻采样 skin (sx + ⌊u⌋, sy + ⌊v⌋) 的 RGBA
   *   6. alpha-over 合成到 dest 缓冲（remember: 调用方按 painter's algorithm 由远到近调用，
   *      所以 source-over 直接覆盖即可正确处理 overlay）
   *
   * 返回：实际填到 dest 的像素数（用于 hilog 打总览）。
   *
   * 性能：bbox × 1 inverse-affine + 1 sample / pixel ≈ 数 µs/face，36 face × ~30×30 ≈
   * 30 K pixel，整体 ~5 ms 量级。够用。
   */
  private rasterizeFaceToBuffer(face: ProjFace, ox: number, oy: number,
                                 dest: Uint8Array, destW: number, destH: number): number {
    let pixels = this._skinRGBA;
    if (pixels === null) return 0;

    // 应用居中偏移到 4 顶点
    let p0x = face.p0x + ox, p0y = face.p0y + oy;
    let p1x = face.p1x + ox, p1y = face.p1y + oy;
    let p2x = face.p2x + ox, p2y = face.p2y + oy;
    let p3x = face.p3x + ox, p3y = face.p3y + oy;

    // 屏幕轴对齐 bbox（裁剪到 canvas）
    let minXf = Math.min(p0x, p1x, p2x, p3x);
    let maxXf = Math.max(p0x, p1x, p2x, p3x);
    let minYf = Math.min(p0y, p1y, p2y, p3y);
    let maxYf = Math.max(p0y, p1y, p2y, p3y);

    let minX = Math.max(0, Math.floor(minXf));
    let maxX = Math.min(destW - 1, Math.ceil(maxXf));
    let minY = Math.max(0, Math.floor(minYf));
    let maxY = Math.min(destH - 1, Math.ceil(maxYf));
    if (minX > maxX || minY > maxY) return 0;  // 完全在画面外

    let sw = face.sw;
    let sh = face.sh;
    if (sw <= 0 || sh <= 0) return 0;

    // 仿射 forward 系数：src(0,0)→P0, src(sw,0)→P1, src(0,sh)→P3
    let a = (p1x - p0x) / sw;
    let b = (p1y - p0y) / sw;
    let c = (p3x - p0x) / sh;
    let d = (p3y - p0y) / sh;
    let det = a * d - b * c;
    if (Math.abs(det) < 1e-9) return 0;  // 退化（面边缘正对相机），跳过
    let invDet = 1 / det;

    let skinW = this._skinW;
    let skinH = this._skinH;
    let sx = face.sx;
    let sy = face.sy;
    let touched = 0;

    for (let y = minY; y <= maxY; y++) {
      for (let x = minX; x <= maxX; x++) {
        // 像素中心采样：(x + 0.5, y + 0.5)
        let dx = (x + 0.5) - p0x;
        let dy = (y + 0.5) - p0y;
        let u = (d * dx - c * dy) * invDet;
        let v = (-b * dx + a * dy) * invDet;

        // src 空间矩形内才算这个像素属于这个面
        if (u < 0 || u >= sw || v < 0 || v >= sh) continue;

        // 最近邻采样（Minecraft 像素风必须 nearest，不能 bilinear）
        let skinX = sx + Math.floor(u);
        let skinY = sy + Math.floor(v);
        if (skinX < 0 || skinX >= skinW || skinY < 0 || skinY >= skinH) continue;

        let srcIdx = (skinY * skinW + skinX) * 4;
        let srcA = pixels[srcIdx + 3];
        if (srcA === 0) continue;  // 全透明源像素：跳过（hat/jacket 经常有大片透明）

        let dstIdx = (y * destW + x) * 4;

        if (srcA === 255) {
          // 不透明：直接覆盖（最常见情况，单 RGB 拷贝快）
          dest[dstIdx] = pixels[srcIdx];
          dest[dstIdx + 1] = pixels[srcIdx + 1];
          dest[dstIdx + 2] = pixels[srcIdx + 2];
          dest[dstIdx + 3] = 255;
        } else {
          // 半透明：UNPREMUL source-over alpha 合成
          //   dst' = src·αs + dst·(1−αs)
          //   αdst' = αs + αdst·(1−αs)
          let aN = srcA / 255;
          let invA = 1 - aN;
          let dstA = dest[dstIdx + 3];
          dest[dstIdx]     = Math.round(pixels[srcIdx]     * aN + dest[dstIdx]     * invA);
          dest[dstIdx + 1] = Math.round(pixels[srcIdx + 1] * aN + dest[dstIdx + 1] * invA);
          dest[dstIdx + 2] = Math.round(pixels[srcIdx + 2] * aN + dest[dstIdx + 2] * invA);
          dest[dstIdx + 3] = Math.round(srcA + dstA * invA);
        }
        touched++;
      }
    }
    return touched;
  }
}
