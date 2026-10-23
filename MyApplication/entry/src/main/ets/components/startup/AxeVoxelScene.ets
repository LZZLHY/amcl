/**
 * AMCL 代码开屏的确定性体素场景：纯数值三维旋转、透视投影及可见面深度排序。
 *
 * 品牌数据精确取自 AMCL-video/brand/logo/axe-grid.json，schema amcl-video/pixel-grid@1，
 * 对照正式 V001-v1.0（1d8d4375396dee6e76410c0b7e12402fcd1af522）。保留 12×14
 * 网格的全部 60 个非空格及原始颜色；运动参考 bot.mjs updateVoxels 的半径收拢、
 * 螺旋旋进、转正与错峰落位，使用独立实现，运行时不加载视频、Three.js 或图片序列。
 *
 * 场景只根据前台累计时间求值，不读取系统时钟/业务状态。窗口变化时复用同一组
 * 种子和当前时间，更新屏外起点与投影尺寸，避免重播或随机跳动。全部工作在 UI
 * 线程完成，仅 60 个立方体；顶点/面缓存复用，避免每帧创建大量短命对象。
 */

/** 普通聚合结束时间；等待阶段从这一时刻开始，收尾时间由宿主组件单独驱动。 */
export const AXE_ASSEMBLY_MS: number = 1120;

/** 空字符串是透明格，顺序与品牌源数据逐行逐列一致，不压缩或重新取色。 */
const AXE_GRID: string[][] = [
  ['', '', '', '', '', '', '', '', '', '', '#271c09', '#271c09'],
  ['', '', '', '', '', '', '', '', '', '#271c09', '#856120', '#463211'],
  ['', '', '', '', '', '', '', '', '#281d0a', '#684b19', '#463312', ''],
  ['', '', '', '', '', '', '', '#281d09', '#846020', '#453212', '', ''],
  ['', '', '', '', '', '', '#2a1d0a', '#694d1b', '#443211', '', '', ''],
  ['', '', '', '', '', '#281e09', '#6b4d1b', '#453212', '', '', '', ''],
  ['', '#a4295a', '#a4295a', '', '#291d0a', '#866221', '#483414', '', '', '', '', ''],
  ['#a4285a', '#fd82c0', '#fd83c0', '#291d0a', '#684b1a', '#483413', '', '', '', '', '', ''],
  ['#a4295a', '#fc82c1', '#fb4f9a', '#fc81c0', '#433212', '#a42a5b', '#a4295a', '', '', '', '', ''],
  ['', '#281d0a', '#fc7bbb', '#fb509a', '#fd68af', '#fd87c3', '#fdb5db', '#a52a5b', '', '', '', ''],
  ['', '#624719', '#2a1f0a', '#fd67ae', '#fd68af', '#fc67ad', '#feb4db', '#a5295b', '', '', '', ''],
  ['', '', '#a52a5b', '#fe87c2', '#fc68ae', '#feb5db', '#a4295a', '', '', '', '', ''],
  ['', '', '#a42a5b', '#fdb4da', '#feb6dc', '#a3295b', '', '', '', '', '', ''],
  ['', '', '', '#a3295a', '#a42a5b', '', '', '', '', '', '', '']
];

/** 立方体六面的顶点索引；正面在 z<0，屏幕 y 轴向下时正面绕序为正。 */
const FACE_VERTICES: number[][] = [
  [0, 1, 2, 3], [5, 4, 7, 6], [4, 0, 3, 7],
  [1, 5, 6, 2], [4, 5, 1, 0], [3, 2, 6, 7]
];

/** 可复用投影顶点，depth 为相机空间深度，较大者先画。 */
class VoxelVertex {
  x: number = 0;
  y: number = 0;
  depth: number = 0;
}

/** 一个待绘制面仅引用所属体素和固定顶点，不复制数组。 */
class VoxelFace {
  vertices: VoxelVertex[];
  indices: number[];
  color: string;
  depth: number = 0;
  visible: boolean = false;

  /** 顶点由体素更新，面本身只刷新平均深度和可见性。 */
  constructor(vertices: VoxelVertex[], indices: number[], color: string) {
    this.vertices = vertices;
    this.indices = indices;
    this.color = color;
  }
}

/** 一格品牌像素对应一个立方体，并持有确定性入场参数。 */
class AxeVoxel {
  column: number;
  row: number;
  order: number = 0;
  seed: number;
  vertices: VoxelVertex[] = [];
  faces: VoxelFace[] = [];

  /** 颜色只在构造时计算，三维侧面保留品牌色并压暗，不改变最终正面颜色。 */
  constructor(column: number, row: number, color: string, seed: number) {
    this.column = column;
    this.row = row;
    this.seed = seed;
    for (let index: number = 0; index < 8; index++) {
      this.vertices.push(new VoxelVertex());
    }
    const shades: number[] = [1, 0.49, 0.67, 0.81, 1.08, 0.58];
    for (let face: number = 0; face < FACE_VERTICES.length; face++) {
      this.faces.push(new VoxelFace(this.vertices, FACE_VERTICES[face], shadeColor(color, shades[face])));
    }
  }
}

/** 只对有限区间做钳位，防止窗口极窄或暂停恢复时参数越界。 */
function clamp(value: number, low: number, high: number): number {
  return Math.min(high, Math.max(low, value));
}

/** 平滑补间的一阶导数在两端为零，收尾不会突然改变速度。 */
function smooth(value: number): number {
  const unit: number = clamp(value, 0, 1);
  return unit * unit * (3 - 2 * unit);
}

/** 静态种子生成器：每块跨设备、窗口和后台恢复都沿同一条轨迹。 */
function seeded(seed: number): number {
  const value: number = Math.sin(seed * 127.1 + 311.7) * 43758.5453123;
  return value - Math.floor(value);
}

/** 在缓存构建期生成 CSS RGB 色，不在逐帧路径解析十六进制或分配字符串。 */
function shadeColor(color: string, brightness: number): string {
  if (brightness === 1) {
    return color;
  }
  const red: number = clamp(Math.round(parseInt(color.substring(1, 3), 16) * brightness), 0, 255);
  const green: number = clamp(Math.round(parseInt(color.substring(3, 5), 16) * brightness), 0, 255);
  const blue: number = clamp(Math.round(parseInt(color.substring(5, 7), 16) * brightness), 0, 255);
  return `rgb(${red},${green},${blue})`;
}

/** 单帧的布局与交接输入；targetX/Y 已转换为 Canvas 本地 vp 坐标。 */
export class AxeSceneFrame {
  width: number = 0;
  height: number = 0;
  elapsedMs: number = 0;
  exitProgress: number = 0;
  exitStartedMs: number = 0;
  targetX: number = 0;
  targetY: number = 0;
  targetSize: number = 0;
  hasTarget: boolean = false;
  reducedMotion: boolean = false;
}

/**
 * Canvas 绘制器。每次 draw 会重算相机空间顶点并按面排序，支持相互遮挡；
 * Canvas 自身只接收二维闭合多边形，立方体的厚度与旋转来自真实三维坐标。
 */
export class AxeVoxelScene {
  private voxels: AxeVoxel[] = [];
  private faces: VoxelFace[] = [];
  /** 最近一次绘制是否有实际几何进入窗口，供宿主在运动首帧之后启动准备任务。 */
  hasVisiblePixels: boolean = false;

  /** 先创建品牌体素，再按握把→斧柄→斧刃分配落位顺序。 */
  constructor() {
    for (let row: number = 0; row < AXE_GRID.length; row++) {
      for (let column: number = 0; column < AXE_GRID[row].length; column++) {
        const color: string = AXE_GRID[row][column];
        if (color.length > 0) {
          this.voxels.push(new AxeVoxel(column, row, color, row * 12 + column + 1));
        }
      }
    }
    // 源图的握把位于右上，粉色斧刃在左下：按原图这一方向逐格生长。
    this.voxels.sort((left: AxeVoxel, right: AxeVoxel): number => {
      return (left.row * 1.3 - left.column * 0.3) - (right.row * 1.3 - right.column * 0.3);
    });
    for (let index: number = 0; index < this.voxels.length; index++) {
      this.voxels[index].order = index;
      for (let face: number = 0; face < this.voxels[index].faces.length; face++) {
        this.faces.push(this.voxels[index].faces[face]);
      }
    }
  }

  /**
   * 清屏由调用方负责，以便背景独立淡出而体素保持不透明。减弱动态模式只呈现
   * 平面斧的短淡入/淡出，不执行从屏外飞入、旋转或位移。
   */
  draw(context: CanvasRenderingContext2D, frame: AxeSceneFrame): void {
    this.hasVisiblePixels = false;
    if (frame.width <= 0 || frame.height <= 0 || frame.elapsedMs <= 0) {
      return;
    }
    const appear: number = frame.reducedMotion ? smooth(frame.elapsedMs / 160) : 1;
    const leave: number = frame.exitProgress > 0 && (!frame.hasTarget || frame.reducedMotion)
      ? 1 - smooth(frame.exitProgress) : 1;
    context.globalAlpha = appear * leave;
    for (let index: number = 0; index < this.voxels.length; index++) {
      this.updateVoxel(this.voxels[index], frame);
    }
    this.faces.sort((left: VoxelFace, right: VoxelFace): number => right.depth - left.depth);
    for (let index: number = 0; index < this.faces.length; index++) {
      const face: VoxelFace = this.faces[index];
      if (!face.visible) {
        continue;
      }
      let hasVertexInside: boolean = false;
      for (let corner: number = 0; corner < 4; corner++) {
        const vertex: VoxelVertex = face.vertices[face.indices[corner]];
        if (vertex.x > 0 && vertex.x < frame.width && vertex.y > 0 && vertex.y < frame.height) {
          hasVertexInside = true;
        }
      }
      // 首运动帧采取保守判据：至少一个可见面的顶点已经进入窗口，避免仅包围盒
      // 擦过窗口角落时过早通知宿主。对本场景几十vp的方块不会造成长时间漏判。
      if (hasVertexInside) {
        this.hasVisiblePixels = true;
      }
      context.fillStyle = face.color;
      context.beginPath();
      context.moveTo(face.vertices[face.indices[0]].x, face.vertices[face.indices[0]].y);
      for (let corner: number = 1; corner < 4; corner++) {
        context.lineTo(face.vertices[face.indices[corner]].x, face.vertices[face.indices[corner]].y);
      }
      context.closePath();
      context.fill();
    }
    context.globalAlpha = 1;
  }

  /**
   * 计算一块体素的组装位置与旋转，再变换八个三维顶点。起点按窗口矩形沿射线
   * 向外扩张并加足立方体包围球余量，所以初始任何角都位于窗口外；缩窗后仍成立。
   */
  private updateVoxel(voxel: AxeVoxel, frame: AxeSceneFrame): void {
    const shortest: number = Math.min(frame.width, frame.height);
    const cell: number = clamp(shortest * 0.037, 8, 14);
    const localX: number = voxel.column - 5.5;
    const localY: number = voxel.row - 6.5;
    const stagger: number = voxel.order * 3.2;
    const travel: number = clamp((frame.elapsedMs - stagger) / (850 + voxel.order * 1.2), 0, 1);
    const gather: number = frame.reducedMotion ? 1 : Math.sin(travel * Math.PI / 2);
    const perspective: number = Math.max(700, Math.hypot(frame.width, frame.height) * 1.4);
    const holdTime: number = Math.max(0, frame.elapsedMs - AXE_ASSEMBLY_MS) / 1000;
    // 退出时冻结进入退出瞬间的悬浮相位，再将姿态连续收束，不能跳回相位零。
    const poseTime: number = frame.exitProgress > 0
      ? Math.max(0, frame.exitStartedMs - AXE_ASSEMBLY_MS) / 1000 : holdTime;
    // 减弱动态只走整体淡出，几何必须保持原位，不能一边淡出一边飞向首页。
    const handoff: number = frame.reducedMotion ? 0 : smooth(frame.exitProgress);
    const settle: number = smooth((frame.elapsedMs - 860) / 260);
    const yaw: number = frame.reducedMotion ? 0 : (0.24 + Math.sin(poseTime * 2.1) * 0.075) * (1 - handoff) * gather;
    const pitch: number = frame.reducedMotion ? 0 : -0.11 * (1 - handoff) * gather;
    const roll: number = frame.reducedMotion ? 0 : -0.055 * settle * (1 - handoff) * gather;
    const bob: number = frame.reducedMotion ? 0 : Math.sin(poseTime * 2.1) * 2.5 * (1 - handoff);
    const startCenterX: number = frame.width * 0.5;
    const startCenterY: number = frame.height * 0.46 + bob;
    const targetCenterX: number = frame.hasTarget ? frame.targetX : startCenterX;
    const targetCenterY: number = frame.hasTarget ? frame.targetY : startCenterY;
    // 曲线只作用于整体中心，不改变各像素之间的网格关系。
    const bend: number = Math.sin(handoff * Math.PI);
    const centerX: number = startCenterX + (targetCenterX - startCenterX) * handoff + bend * 10;
    const centerY: number = startCenterY + (targetCenterY - startCenterY) * handoff - bend * 18;
    // amcl_axe.png 为 512²，品牌像素每格31px；保留透明边距后才能无跳变交给首页Image。
    const endCell: number = frame.hasTarget ? frame.targetSize * 31 / 512 : cell;
    const displayCell: number = cell + (endCell - cell) * handoff;
    const initialAngle: number = seeded(voxel.seed) * Math.PI * 2;
    const angleCos: number = Math.cos(initialAngle);
    const angleSin: number = Math.sin(initialAngle);
    const initialDepth: number = (seeded(voxel.seed + 9) - 0.5) * cell * 14;
    // 从实际窗口矩形沿射线向外扩张，再逆透视得到起点。相较固定对角线圆环，
    // 该做法在极宽/极窄窗口仍能保证首帧屏外，并让首批像素尽快跨过屏幕边缘。
    const margin: number = cell * 3.8;
    const edgeX: number = (frame.width * 0.5 + margin) / Math.max(0.001, Math.abs(angleCos));
    const edgeY: number = (frame.height * (angleSin >= 0 ? 0.54 : 0.46) + margin) /
      Math.max(0.001, Math.abs(angleSin));
    const initialRadius: number = Math.min(edgeX, edgeY) * (perspective + initialDepth) / perspective;
    const startDeltaX: number = angleCos * initialRadius - localX * cell;
    const startDeltaY: number = angleSin * initialRadius - localY * cell;
    const radius: number = Math.hypot(startDeltaX, startDeltaY) * (1 - travel * travel);
    const angle: number = Math.atan2(startDeltaY, startDeltaX) -
      (0.25 + seeded(voxel.seed + 5) * 0.35) * Math.PI * 2 * gather;
    let voxelX: number = localX * cell;
    let voxelY: number = localY * cell;
    let voxelZ: number = 0;
    let scale: number = 1;
    let spinX: number = 0;
    let spinY: number = 0;
    let spinZ: number = 0;
    if (!frame.reducedMotion && travel < 1) {
      voxelX += Math.cos(angle) * radius;
      voxelY += Math.sin(angle) * radius;
      voxelZ = initialDepth * (1 - gather);
      scale = 1 + (0.5 + seeded(voxel.seed + 13) * 0.8) * (1 - gather);
      spinX = (seeded(voxel.seed + 17) - 0.5) * 2.4 * (1 - gather);
      spinY = (seeded(voxel.seed + 21) * 4 + frame.elapsedMs / 350) * (1 - gather);
      spinZ = (seeded(voxel.seed + 29) - 0.5) * 1.8 * (1 - gather);
    } else if (!frame.reducedMotion) {
      const landedAgo: number = frame.elapsedMs - stagger - (850 + voxel.order * 1.2);
      // 到达与结束都从0幅度衔接，避免travel刚到1便突然放大。若准备恰在最后
      // 落位时完成，继续当前回弹并随归位平滑消退，不能exit>0便硬切scale=1。
      // 回弹仍在80ms内自行归零，无需为了动画额外等待或推迟首页交接。
      const bounce: number = landedAgo >= 0 && landedAgo < 80
        ? Math.sin(landedAgo / 80 * Math.PI) * 0.05 : 0;
      scale += bounce * (1 - handoff);
    }
    const cellRatio: number = displayCell / cell;
    voxelX *= cellRatio;
    voxelY *= cellRatio;
    voxelZ *= cellRatio;
    const cosX: number = Math.cos(spinX);
    const sinX: number = Math.sin(spinX);
    const cosY: number = Math.cos(spinY);
    const sinY: number = Math.sin(spinY);
    const cosZ: number = Math.cos(spinZ);
    const sinZ: number = Math.sin(spinZ);
    const cosPitch: number = Math.cos(pitch);
    const sinPitch: number = Math.sin(pitch);
    const cosYaw: number = Math.cos(yaw);
    const sinYaw: number = Math.sin(yaw);
    const cosRoll: number = Math.cos(roll);
    const sinRoll: number = Math.sin(roll);
    const half: number = displayCell * 0.5 * scale;
    const thickness: number = 0.76 * (1 - handoff);
    for (let index: number = 0; index < 8; index++) {
      // 顶点顺序对应 FACE_VERTICES，前四点在近面、后四点在远面。
      const x: number = (index === 1 || index === 2 || index === 5 || index === 6) ? half : -half;
      const y: number = (index === 2 || index === 3 || index === 6 || index === 7) ? half : -half;
      const z: number = (index < 4 ? -half : half) * thickness;
      const y1: number = y * cosX - z * sinX;
      const z1: number = y * sinX + z * cosX;
      const x2: number = x * cosY + z1 * sinY;
      const z2: number = -x * sinY + z1 * cosY;
      const worldX: number = x2 * cosZ - y1 * sinZ + voxelX;
      const worldY: number = x2 * sinZ + y1 * cosZ + voxelY;
      const worldZ: number = z2 + voxelZ;
      const y3: number = worldY * cosPitch - worldZ * sinPitch;
      const z3: number = worldY * sinPitch + worldZ * cosPitch;
      const x4: number = worldX * cosYaw + z3 * sinYaw;
      const z4: number = -worldX * sinYaw + z3 * cosYaw;
      const projection: number = perspective / (perspective + z4);
      voxel.vertices[index].x = centerX + (x4 * cosRoll - y3 * sinRoll) * projection;
      voxel.vertices[index].y = centerY + (x4 * sinRoll + y3 * cosRoll) * projection;
      voxel.vertices[index].depth = z4;
    }
    for (let index: number = 0; index < voxel.faces.length; index++) {
      const face: VoxelFace = voxel.faces[index];
      const first: VoxelVertex = face.vertices[face.indices[0]];
      const second: VoxelVertex = face.vertices[face.indices[1]];
      const third: VoxelVertex = face.vertices[face.indices[2]];
      const fourth: VoxelVertex = face.vertices[face.indices[3]];
      face.visible = (second.x - first.x) * (third.y - first.y) -
        (second.y - first.y) * (third.x - first.x) > 0.0001;
      face.depth = (first.depth + second.depth + third.depth + fourth.depth) * 0.25;
    }
  }
}
