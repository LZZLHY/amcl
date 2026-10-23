/**
 * 运行真正的 AxeVoxelScene 数学/绘制代码，验证代码开屏的可观察视觉契约。
 *
 * 此宿主测试不复制轨迹公式、不引入 npm 包、不创建 SDK 缓存，也不依赖并排视频仓。
 * 用显式 --typescript 路径（或 AMCL_TYPESCRIPT_PATH）加载本机 SDK TypeScript，
 * 在内存中去除类型后执行；它不能替代 ArkTS 检查、HAP 构建或真机帧率验收。
 * --output-dir 只有显式提供时才落 JSON 报告；在 AMCL 工作区必须指向登记的 E 输出。
 * 品牌颜色/透明边距以本仓 amcl_axe.png 为独立证据；--brand-grid 可选核对
 * AMCL-video/brand/logo/axe-grid.json，源标签 V001-v1.0 / 1d8d4375396dee6e76410c0b7e12402fcd1af522。
 */
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import zlib from 'node:zlib';

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

/** 只接收显式命名参数，拼写错误必须报错，避免测试误用另一套 SDK/证据目录。 */
function optionsFromArguments(values) {
  const options = {};
  for (let index = 0; index < values.length; index += 2) {
    const flag = values[index];
    assert.ok(['--typescript', '--output-dir', '--brand-grid'].includes(flag), `未知参数：${flag}`);
    assert.ok(values[index + 1] && !values[index + 1].startsWith('--'), `参数缺值：${flag}`);
    assert.equal(options[flag], undefined, `参数不能重复：${flag}`);
    options[flag] = values[index + 1];
  }
  return options;
}

const options = optionsFromArguments(process.argv.slice(2));
const compilerPath = options['--typescript'] || process.env.AMCL_TYPESCRIPT_PATH;
assert.ok(compilerPath && path.isAbsolute(compilerPath),
  '需要 --typescript <SDK typescript.js绝对路径> 或 AMCL_TYPESCRIPT_PATH，测试不搜索或安装依赖');
const compiler = createRequire(import.meta.url)(compilerPath);
const sourcePath = path.join(repository, 'entry/src/main/ets/components/startup/AxeVoxelScene.ets');
const source = fs.readFileSync(sourcePath, 'utf8');
const compiled = compiler.transpileModule(source, {
  fileName: 'AxeVoxelScene.ts',
  reportDiagnostics: true,
  compilerOptions: { target: compiler.ScriptTarget.ES2021, module: compiler.ModuleKind.CommonJS },
});
assert.equal((compiled.diagnostics || []).filter(item => item.category === compiler.DiagnosticCategory.Error).length,
  0, '场景源码不能包含转译语法错误；完整类型与ArkTS限制仍由正式构建检查');
const module = { exports: {} };
vm.runInNewContext(compiled.outputText, { module, exports: module.exports }, { filename: sourcePath, timeout: 10000 });
const { AxeVoxelScene, AxeSceneFrame, AXE_ASSEMBLY_MS } = module.exports;
// 快启动时钟与坐标类型放在同一纯ArkTS模块；与场景同样内存转译，不加载UI框架。
const typesPath = path.join(repository, 'entry/src/main/ets/components/startup/StartupTypes.ets');
const typesSource = fs.readFileSync(typesPath, 'utf8');
const typesCompiled = compiler.transpileModule(typesSource, {
  fileName: 'StartupTypes.ts', reportDiagnostics: true,
  compilerOptions: { target: compiler.ScriptTarget.ES2021, module: compiler.ModuleKind.CommonJS },
});
assert.equal((typesCompiled.diagnostics || []).filter(item => item.category === compiler.DiagnosticCategory.Error).length, 0);
const typesModule = { exports: {} };
vm.runInNewContext(typesCompiled.outputText, { module: typesModule, exports: typesModule.exports },
  { filename: typesPath, timeout: 10000 });
const { StartupAssemblyClock } = typesModule.exports;

/** 只记录 Canvas 最小多边形输出；任何多余绘制入口都会因没有对应方法而失败。 */
class RecordingCanvas {
  globalAlpha = 1;
  fillStyle = '';
  polygons = [];
  points = [];
  beginPath() { this.points = []; }
  moveTo(x, y) { this.points.push([x, y]); }
  lineTo(x, y) { this.points.push([x, y]); }
  closePath() {}
  fill() { this.polygons.push({ color: this.fillStyle, alpha: this.globalAlpha, points: this.points.slice() }); }
}

/** 显式构造生产帧，未指定项保留生产默认值，窗口和时间从测试用例注入。 */
function makeFrame(values = {}) {
  return Object.assign(new AxeSceneFrame(), { width: 390, height: 844, elapsedMs: 1600 }, values);
}

/** 用真实 draw 更新缓存，测试结果只取数字和字符串，避免跨 VM 原型影响断言。 */
function draw(scene, frame) {
  const canvas = new RecordingCanvas();
  scene.draw(canvas, frame);
  return canvas;
}

/** 读取缓存顶点不修改生产逻辑；专用于核对被首帧短路隐藏的屏外起始几何。 */
function verticesOf(voxel) {
  return Array.from(voxel.vertices, vertex => [vertex.x, vertex.y, vertex.depth]);
}

/** 包围盒是独立几何判据，既检验所有顶点，也能发现面心在屏外而角仍露出的错误。 */
function bounds(vertices) {
  return {
    left: Math.min(...vertices.map(vertex => vertex[0])),
    right: Math.max(...vertices.map(vertex => vertex[0])),
    top: Math.min(...vertices.map(vertex => vertex[1])),
    bottom: Math.max(...vertices.map(vertex => vertex[1])),
  };
}

/** PNG 的 Paeth 重建规则只服务于本仓图标读取，不参与任何动画计算。 */
function paeth(left, above, diagonal) {
  const estimate = left + above - diagonal;
  const dl = Math.abs(estimate - left), da = Math.abs(estimate - above), dd = Math.abs(estimate - diagonal);
  return dl <= da && dl <= dd ? left : da <= dd ? above : diagonal;
}

/**
 * 通过 Node 内置 zlib 读取本仓 RGBA8 PNG，独立提取品牌颜色和 alpha 外框。
 * 只支持当前所需的非交错 RGBA8，资产格式改变时明确失败，不静默误读颜色。
 */
function readBrandPng(filename) {
  const file = fs.readFileSync(filename);
  assert.equal(file.subarray(0, 8).toString('hex'), '89504e470d0a1a0a', '品牌资源必须是PNG');
  let width = 0, height = 0;
  const chunks = [];
  for (let cursor = 8; cursor < file.length;) {
    const length = file.readUInt32BE(cursor), type = file.toString('ascii', cursor + 4, cursor + 8);
    const data = file.subarray(cursor + 8, cursor + 8 + length);
    if (type === 'IHDR') {
      width = data.readUInt32BE(0); height = data.readUInt32BE(4);
      assert.deepEqual(Array.from(data.subarray(8)), [8, 6, 0, 0, 0], '仅支持非交错RGBA8品牌PNG');
    }
    if (type === 'IDAT') chunks.push(data);
    cursor += length + 12;
  }
  const raw = zlib.inflateSync(Buffer.concat(chunks)), stride = width * 4;
  assert.equal(raw.length, (stride + 1) * height, 'PNG解压长度必须对应完整像素矩阵');
  const rgba = Buffer.alloc(stride * height);
  const opaquePoints = [];
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    assert.ok(filter <= 4, `不支持PNG过滤器${filter}`);
    for (let x = 0; x < stride; x++) {
      const offset = y * stride + x;
      const left = x >= 4 ? rgba[offset - 4] : 0;
      const above = y > 0 ? rgba[offset - stride] : 0;
      const diagonal = y > 0 && x >= 4 ? rgba[offset - stride - 4] : 0;
      const predictor = filter === 0 ? 0 : filter === 1 ? left : filter === 2 ? above
        : filter === 3 ? Math.floor((left + above) / 2) : paeth(left, above, diagonal);
      rgba[offset] = (raw[y * (stride + 1) + 1 + x] + predictor) & 255;
    }
    for (let x = 0; x < width; x++) {
      if (rgba[(y * width + x) * 4 + 3] > 0) opaquePoints.push([x, y]);
    }
  }
  return {
    width, height, opaque: bounds(opaquePoints),
    /** 网格中心远离像素边缘；颜色断言不会受PNG轮廓的一像素描边影响。 */
    pixel(x, y) {
      const offset = (Math.floor(y) * width + Math.floor(x)) * 4;
      return { color: `#${rgba.subarray(offset, offset + 3).toString('hex')}`, alpha: rgba[offset + 3] };
    },
  };
}

const brandPngPath = path.join(repository, 'entry/src/main/resources/base/media/amcl_axe.png');
const brandPng = readBrandPng(brandPngPath);
const results = [];

/** 每一组失败都保留到最终报告，失败时进程仍以非零退出，不能只打印PASS。 */
function check(name, action) {
  try {
    const evidence = action() || {};
    results.push({ name, status: 'PASS', ...evidence });
    console.log(`PASS ${name}`);
  } catch (error) {
    results.push({ name, status: 'FAIL', error: error.stack || String(error) });
    console.error(`FAIL ${name}: ${error.message}`);
  }
}

const widths = [1, 8, 32, 80, 128, 240, 320, 390, 600, 720, 1024, 1920, 3840];
const heights = [1, 2, 8, 32, 80, 128, 240, 320, 390, 600, 720, 844, 1024, 1280, 1920, 2160, 3840, 7680];

check('纯背景首帧和无效布局不产生任何图元', () => {
  const scene = new AxeVoxelScene();
  for (const frame of [makeFrame({ elapsedMs: 0 }), makeFrame({ elapsedMs: -1 }),
    makeFrame({ width: 0 }), makeFrame({ height: 0 }), makeFrame({ elapsedMs: 0, reducedMotion: true })]) {
    assert.equal(draw(scene, frame).polygons.length, 0);
    assert.equal(scene.hasVisiblePixels, false);
  }
});

check('每块体素的起始包围盒严格位于窗口外', () => {
  const scene = new AxeVoxelScene();
  let checked = 0;
  for (const width of widths) for (const height of heights) {
    const frame = makeFrame({ width, height, elapsedMs: 0 });
    // draw(0)有意只输出背景；直接调用真实私有数值方法观测其被隐藏的初始状态。
    for (const voxel of scene.voxels) {
      scene.updateVoxel(voxel, frame);
      const box = bounds(verticesOf(voxel));
      assert.ok(box.right < 0 || box.left > width || box.bottom < 0 || box.top > height,
        `${width}×${height} 体素${voxel.row}:${voxel.column} 初始角越过边缘：${JSON.stringify(box)}`);
      checked++;
    }
  }
  return { windows: widths.length * heights.length, voxelBounds: checked };
});

check('多长宽比聚合等待和收尾全部顶点及绘制面均为有限数', () => {
  const scene = new AxeVoxelScene();
  const times = [0.001, 16, 80, 250, 650, AXE_ASSEMBLY_MS, 1600, 10000, 1e8];
  let frames = 0;
  for (const width of widths) for (const height of heights) for (const elapsedMs of times) {
    for (const exitProgress of [0, 0.5, 1]) {
      const frame = makeFrame({ width, height, elapsedMs, exitProgress, exitStartedMs: AXE_ASSEMBLY_MS,
        hasTarget: true, targetX: 35, targetY: 51, targetSize: 30 });
      const canvas = draw(scene, frame);
      for (const voxel of scene.voxels) for (const vertex of verticesOf(voxel)) {
        assert.ok(vertex.every(Number.isFinite), `${width}×${height} @${elapsedMs} 有非有限顶点`);
      }
      for (const polygon of canvas.polygons) {
        assert.ok(polygon.alpha >= 0 && polygon.alpha <= 1);
        assert.equal(polygon.points.length, 4);
        assert.ok(polygon.points.flat().every(Number.isFinite));
      }
      assert.equal(canvas.globalAlpha, 1, '场景绘制必须恢复画布透明度');
      frames++;
    }
  }
  return { windows: widths.length * heights.length, frames };
});

check('60格品牌身份颜色和33粉27棕构成由本仓PNG独立核实', () => {
  const scene = new AxeVoxelScene();
  const identities = new Set();
  let blade = 0;
  assert.equal(scene.voxels.length, 60);
  for (const voxel of scene.voxels) {
    const id = `${voxel.row}:${voxel.column}`;
    assert.ok(!identities.has(id), `重复品牌像素${id}`);
    identities.add(id);
    const pixel = brandPng.pixel(256 + (voxel.column - 5.5) * 31, 256 + (voxel.row - 6.5) * 31);
    assert.equal(pixel.alpha, 255, `${id}必须对应品牌图标实色像素`);
    assert.equal(voxel.faces[0].color, pixel.color, `${id}正面必须保持原始品牌色`);
    if (parseInt(pixel.color.slice(5, 7), 16) > parseInt(pixel.color.slice(3, 5), 16)) blade++;
  }
  assert.equal(blade, 33); assert.equal(scene.voxels.length - blade, 27);
  assert.deepEqual(Array.from(scene.voxels, voxel => [voxel.row, voxel.column, voxel.seed, voxel.order]),
    Array.from(new AxeVoxelScene().voxels, voxel => [voxel.row, voxel.column, voxel.seed, voxel.order]));
});

check('聚合末态所有品牌格落定且等待悬浮保留完整网格', () => {
  const scene = new AxeVoxelScene();
  for (const elapsedMs of [AXE_ASSEMBLY_MS, AXE_ASSEMBLY_MS + 100, AXE_ASSEMBLY_MS + 500, AXE_ASSEMBLY_MS + 3000]) {
    const canvas = draw(scene, makeFrame({ elapsedMs }));
    assert.equal(scene.hasVisiblePixels, true);
    assert.equal(scene.voxels.filter(voxel => voxel.faces[0].visible).length, 60);
    // 1120ms已全部落位，但最后到达的格仍可保留设计允许的≤5%短回弹。
    // 回弹结束后每块共用同一斧形平面，相邻格的前面四顶点必须连续，无残留散块。
    const byCell = new Map(Array.from(scene.voxels, voxel => [`${voxel.row}:${voxel.column}`, voxel]));
    for (const voxel of scene.voxels) {
      const right = byCell.get(`${voxel.row}:${voxel.column + 1}`);
      if (right && elapsedMs >= AXE_ASSEMBLY_MS + 100) for (const [leftIndex, rightIndex] of [[1, 0], [2, 3]]) {
        const a = verticesOf(voxel)[leftIndex], b = verticesOf(right)[rightIndex];
        assert.ok(a.every((coordinate, axis) => Math.abs(coordinate - b[axis]) < 1e-7),
          `落定后相邻品牌格不能分离：${voxel.row}:${voxel.column}`);
      }
    }
    assert.ok(canvas.polygons.length >= 60, '完整斧头至少保留每格一个可见正面');
  }
});

check('30vp首页锚点按PNG透明边距归位且末态为平面原色', () => {
  const scene = new AxeVoxelScene(), targetX = 42, targetY = 64, targetSize = 30;
  const frame = makeFrame({ hasTarget: true, targetX, targetY, targetSize,
    exitProgress: 1, exitStartedMs: 1500 });
  const canvas = draw(scene, frame);
  const box = bounds(Array.from(scene.voxels).flatMap(verticesOf));
  // PNG抗锯齿/描边边缘可能比网格实色延伸1px；允许每侧一个源像素，拒绝把30vp
  // 当成斧形实色宽度的错误（会导致约8vp跳变）。以真实PNG边界计算，未复写运动公式。
  const tolerance = targetSize / brandPng.width * 1.1;
  const expected = {
    left: targetX + (brandPng.opaque.left / brandPng.width - 0.5) * targetSize,
    right: targetX + ((brandPng.opaque.right + 1) / brandPng.width - 0.5) * targetSize,
    top: targetY + (brandPng.opaque.top / brandPng.height - 0.5) * targetSize,
    bottom: targetY + ((brandPng.opaque.bottom + 1) / brandPng.height - 0.5) * targetSize,
  };
  for (const side of Object.keys(expected)) assert.ok(Math.abs(box[side] - expected[side]) <= tolerance,
    `${side}边界${box[side]}偏离PNG${expected[side]}`);
  assert.ok(box.left > targetX - targetSize / 2 && box.right < targetX + targetSize / 2,
    '首页图标透明边距必须保留');
  assert.equal(canvas.polygons.length, 60, '归位后立体侧面应完全收束');
  for (const voxel of scene.voxels) {
    const vertices = verticesOf(voxel);
    assert.ok(vertices.every(vertex => Math.abs(vertex[2]) < 1e-10), '归位后不可残留厚度或倾角');
  }
  return { anchorVp: { targetX, targetY, targetSize }, visibleBounds: box, pngAlphaBounds: brandPng.opaque };
});

check('减弱动态从出现到退出均无位移旋转且只改变整体透明度', () => {
  const scene = new AxeVoxelScene();
  let reference;
  for (const elapsedMs of [1, 80, 160, 1800, 15000]) for (const exitProgress of [0, 0.25, 0.75, 1]) {
    const canvas = draw(scene, makeFrame({ reducedMotion: true, elapsedMs, exitProgress,
      exitStartedMs: 1600, hasTarget: true, targetX: 40, targetY: 50, targetSize: 30 }));
    const geometry = Array.from(scene.voxels, verticesOf);
    if (reference === undefined) reference = geometry;
    assert.deepEqual(geometry, reference, '减弱动态不能缩向首页、悬浮或自转');
    assert.ok(canvas.polygons.every(polygon => polygon.alpha >= 0 && polygon.alpha <= 1));
    if (exitProgress === 1) assert.ok(canvas.polygons.every(polygon => polygon.alpha === 0));
  }
});

check('同一时间输入不受曾经绘制和窗口变化影响', () => {
  const first = new AxeVoxelScene(), second = new AxeVoxelScene();
  const target = makeFrame({ elapsedMs: 764.5 });
  const expected = JSON.stringify(draw(first, target).polygons);
  for (const frame of [makeFrame({ width: 1920, height: 200, elapsedMs: 9000 }),
    makeFrame({ elapsedMs: 500, reducedMotion: true }),
    makeFrame({ elapsedMs: 1800, hasTarget: true, targetX: 30, targetY: 70, targetSize: 30, exitProgress: 0.7 })]) {
    draw(first, frame);
  }
  assert.equal(JSON.stringify(draw(first, target).polygons), expected);
  assert.equal(JSON.stringify(draw(second, target).polygons), expected);
});

check('60/90/120Hz早期ready连续加速且跨聚合终点后恢复1倍', () => {
  const completionTimes = [];
  for (const refreshRate of [60, 90, 120]) {
    const delta = 1000 / refreshRate;
    let normalCompletion = 0;
    const completed = [];
    for (const readyAt of [0, 80, 160, 240, 600]) {
      const clock = new StartupAssemblyClock();
      let foreground = 0, previous = 0, firstCompletion = 0;
      while (foreground < 1600) {
        foreground += delta;
        const ready = foreground >= readyAt;
        // 同一时刻切换ready不能移动视觉时间，只有真实帧间隔才能推进动画。
        assert.equal(clock.advance(0, foreground, ready, false, false, AXE_ASSEMBLY_MS), previous);
        const elapsed = clock.advance(delta, foreground, ready, false, false, AXE_ASSEMBLY_MS);
        assert.ok(Number.isFinite(elapsed) && elapsed >= previous, '视觉时间必须有限且单调');
        assert.ok(elapsed - previous <= delta * 1.5 + 1e-7, 'ready不能触发超越最高速率的时间跳变');
        if (previous >= AXE_ASSEMBLY_MS) {
          assert.ok(Math.abs(elapsed - previous - delta) < 1e-7, '聚合终点之后必须恢复1倍');
        }
        if (!firstCompletion && elapsed >= AXE_ASSEMBLY_MS) firstCompletion = foreground;
        previous = elapsed;
      }
      assert.ok(firstCompletion > 0);
      completed.push({ readyAtMs: readyAt, completedAtMs: firstCompletion });
      if (readyAt === 600) normalCompletion = firstCompletion;
    }
    assert.ok(normalCompletion >= AXE_ASSEMBLY_MS - 1e-7 && normalCompletion <= AXE_ASSEMBLY_MS + delta,
      '600ms才ready时不得选择早期快启动');
    for (const item of completed.filter(item => item.readyAtMs < 600)) {
      assert.ok(item.completedAtMs >= 700 && item.completedAtMs <= 900,
        `${refreshRate}Hz ready${item.readyAtMs}应压缩聚合但保留完整可见过程`);
      assert.ok(item.completedAtMs < normalCompletion - 150, '快启动必须比普通节奏有实质缩短');
    }
    // 失败或减弱动态都不应选中快启动；这两种状态仍按真实前台帧间隔推进。
    for (const [failed, reducedMotion] of [[true, false], [false, true]]) {
      const guarded = new StartupAssemblyClock();
      let foreground = 0;
      for (let count = 0; count < refreshRate; count++) {
        foreground += delta;
        assert.ok(Math.abs(guarded.advance(delta, foreground, true, failed, reducedMotion, AXE_ASSEMBLY_MS)
          - foreground) < 1e-7, '失败或减弱动态不适用聚合倍速');
      }
    }
    completionTimes.push({ refreshRateHz: refreshRate, completed });
  }
  return { completionTimes };
});

check('1120ms残余回弹在退出0至极小进度的全部顶点连续', () => {
  const scene = new AxeVoxelScene();
  const frame = makeFrame({ elapsedMs: AXE_ASSEMBLY_MS, exitStartedMs: AXE_ASSEMBLY_MS,
    hasTarget: true, targetX: 42, targetY: 64, targetSize: 30 });
  draw(scene, frame);
  const before = Array.from(scene.voxels, verticesOf);
  frame.exitProgress = 1e-7;
  draw(scene, frame);
  let largestDisplacement = 0;
  scene.voxels.forEach((voxel, index) => verticesOf(voxel).forEach((vertex, corner) => {
    const displacement = Math.hypot(...vertex.map((value, axis) => value - before[index][corner][axis]));
    largestDisplacement = Math.max(largestDisplacement, displacement);
    assert.ok(displacement < 1e-7, `退出不能骤停体素${voxel.row}:${voxel.column}的残余回弹`);
  }));
  return { elapsedMs: AXE_ASSEMBLY_MS, exitProgress: frame.exitProgress, vertices: 60 * 8,
    largestDisplacementVp: largestDisplacement };
});

if (options['--brand-grid']) check('可选视频品牌源与应用像素逐格一致', () => {
  const external = JSON.parse(fs.readFileSync(options['--brand-grid'], 'utf8'));
  assert.equal(external.meta.schema, 'amcl-video/pixel-grid@1');
  assert.equal(external.meta.columns, 12); assert.equal(external.meta.rows, 14);
  const expected = [];
  external.grid.forEach((row, y) => row.forEach((color, x) => { if (color) expected.push([y, x, color]); }));
  const actual = Array.from(new AxeVoxelScene().voxels, voxel => [voxel.row, voxel.column, voxel.faces[0].color]);
  const byCell = (left, right) => left[0] - right[0] || left[1] - right[1];
  assert.deepEqual(actual.sort(byCell), expected.sort(byCell));
});

const report = {
  schema: 'amcl/startup-scene-regression@1',
  recordedAt: new Date().toISOString(),
  evidenceTimezone: 'UTC; commands and implementation worklog use Asia/Shanghai',
  source: sourcePath,
  sourceSha256: crypto.createHash('sha256').update(source).digest('hex'),
  clockSource: typesPath,
  clockSourceSha256: crypto.createHash('sha256').update(typesSource).digest('hex'),
  typescript: compilerPath,
  typescriptVersion: compiler.version,
  asset: brandPngPath,
  assetSha256: crypto.createHash('sha256').update(fs.readFileSync(brandPngPath)).digest('hex'),
  results,
  status: results.some(result => result.status === 'FAIL') ? 'FAIL' : 'PASS',
  limitations: ['不执行ArkUI布局/帧回调', '不证明系统启动窗口主题', '不证明HAP载荷或真机视觉/帧率'],
};
if (options['--output-dir']) {
  assert.ok(path.isAbsolute(options['--output-dir']), '--output-dir必须是绝对路径');
  fs.mkdirSync(options['--output-dir'], { recursive: true });
  const reportPath = path.join(options['--output-dir'], 'scene-regression.json');
  fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
  console.log(`报告：${reportPath}`);
}
console.log(`${report.status}: ${results.filter(result => result.status === 'PASS').length}/${results.length}`);
if (report.status === 'FAIL') process.exitCode = 1;
