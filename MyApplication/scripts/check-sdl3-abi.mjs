#!/usr/bin/env node
// check-sdl3-abi.mjs — SDL3 公开 ABI 兼容性闸门（SDL3_MIGRATION_PLAN.md Phase 0.11）
//
// ============================================================================
// 为什么需要这个脚本
// ============================================================================
// AMCL 用 LWJGL 3.4.2 的 `lwjgl-sdl` 绑定跑 MC 26.3+。该绑定是**按 SDL 3.4.12 生成**的：
// 每个 `org.lwjgl.sdl.SDL_*` Struct 类在 <clinit> 里用一串 `__member(size)` 声明成员布局，
// 再由 `layout.offsetof(i)` 算出字段偏移 —— 也就是说**成员顺序与类型是硬编进 jar 的**。
//
// 但我们的 OHOS 移植开发分支基于 `upstream/main`（3.6.x 开发线），而不是 3.4.12 tag。
// 若 3.4.12 → 基线 之间任何**公开 struct 的成员被插入/删除/重排/改类型**，
// LWJGL 读到的就是错位数据 —— **不崩溃，但行为诡异**，是最难查的一类问题
// （对比：函数缺失会响亮地抛 UnsatisfiedLinkError）。
//
// SDL3 承诺 3.x ABI 向后兼容（只在 struct 末尾追加字段），但**承诺不能替代验证**。
// 本脚本就是那道验证。
//
// ============================================================================
// 判定规则（struct 与 union 分别处理 —— 二者 ABI 语义完全不同）
// ============================================================================
// struct（成员顺序决定偏移，因此**顺序敏感**）：
//   IDENTICAL   成员序列完全一致                     → 安全
//   APPENDED    旧序列是新序列的前缀（末尾追加）     → 既有字段偏移不变；但 SIZEOF 变大，
//                                                      故额外做"按值嵌入"分析（见下）
//   BREAKING    插入 / 删除 / 重排 / 改类型          → 不安全
//
// union（所有成员都在偏移 0，因此**顺序无关**，只关心集合与总大小）：
//   IDENTICAL   成员集合一致
//   EXTENDED    只新增成员，既有成员一个没动         → 安全（新成员 LWJGL 不认识，无妨）
//   BREAKING    既有成员被删 / 声明被改              → 不安全
//   union 另加"大小锚点"检查：SDL 的 union 用 `Uint8 padding[N]` 钉住 sizeof，
//   N 变化即意味着 sizeof 变化 → 单独报出。
//
// 「按值嵌入」分析：某个 APPENDED/EXTENDED 变大的类型，如果被别的 **struct** 按值嵌入，
//   会把外层后续字段整体后移 → 升级为 BREAKING；若只被 **union** 按值嵌入，则无害。
//
// 函数侧：MC 经 libffi 直调 `SDL_*`，签名变化会静默传错参数。
//   比较前先剥掉**不影响 ABI 的注解宏**（SDL_ACQUIRE/SDL_MALLOC/SDL_PRINTF_FORMAT_STRING…），
//   否则上游调整 clang 线程安全注解都会误报。
//
// ============================================================================
// 本脚本的能力边界（必须诚实声明）
// ============================================================================
// 这是**头文件文本层面**的比较，不是 C 语言布局计算。它能可靠回答"有没有东西动过"，
// 但不能回答"sizeof/offsetof 具体是多少"。后者由 Phase 1 的编译期探针
// （用真正的 OHOS clang 编 offsetof 表，与 LWJGL 反射读出的 SIZEOF/offsetof 对撞）
// 作为权威闸门。两道闸门是互补关系，不能互相替代。
//
// ============================================================================
// 用法
// ============================================================================
//   node scripts/check-sdl3-abi.mjs --repo <SDL 仓库路径> [--base release-3.4.12] [--head HEAD]
//   node scripts/check-sdl3-abi.mjs --repo ../sdl3-ohos --json out.json --verbose
//
// 退出码：0 = 关键集内无 ABI 破坏；1 = 有破坏或执行失败。
// ============================================================================

import { execFileSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import process from 'node:process';

// ---------------------------------------------------------------------------
// MC 26.3 实际接触的 SDL 绑定类（来自 .tmp-sdl3/scan-mc-sdl.mjs 对 client jar
// 11179 个 class 常量池的全量扫描；见 SDL3_MIGRATION_PLAN.md §二·2.6）。
// 这些类型的布局错位会直接表现为游戏行为异常。
// ---------------------------------------------------------------------------
const MC_CRITICAL_STRUCTS = new Set([
  // MC 直接引用的
  'SDL_Event', 'SDL_DisplayMode', 'SDL_Rect', 'SDL_PixelFormatDetails',
  'SDL_KeyboardEvent', 'SDL_MouseMotionEvent', 'SDL_MouseButtonEvent', 'SDL_MouseWheelEvent',
  'SDL_TextInputEvent', 'SDL_TextEditingEvent', 'SDL_TextEditingCandidatesEvent',
  'SDL_DropEvent', 'SDL_DisplayEvent', 'SDL_WindowEvent',
  // SDL_Event 是 union：任何成员 struct 自身错位都会让 MC 从 union 里读错
  'SDL_CommonEvent', 'SDL_KeyboardDeviceEvent', 'SDL_MouseDeviceEvent',
  'SDL_JoyAxisEvent', 'SDL_JoyBallEvent', 'SDL_JoyHatEvent', 'SDL_JoyButtonEvent',
  'SDL_JoyDeviceEvent', 'SDL_JoyBatteryEvent',
  'SDL_GamepadAxisEvent', 'SDL_GamepadButtonEvent', 'SDL_GamepadDeviceEvent',
  'SDL_GamepadTouchpadEvent', 'SDL_GamepadSensorEvent',
  'SDL_AudioDeviceEvent', 'SDL_CameraDeviceEvent', 'SDL_SensorEvent',
  'SDL_QuitEvent', 'SDL_UserEvent', 'SDL_TouchFingerEvent', 'SDL_PinchFingerEvent',
  'SDL_PenProximityEvent', 'SDL_PenTouchEvent', 'SDL_PenMotionEvent',
  'SDL_PenButtonEvent', 'SDL_PenAxisEvent', 'SDL_RenderEvent', 'SDL_ClipboardEvent',
  // 其它被 MC 间接用到的
  'SDL_Surface', 'SDL_Palette', 'SDL_Color', 'SDL_FRect', 'SDL_FPoint', 'SDL_Point',
]);

// MC 实际调用的 SDL 函数（同一次扫描得出）
const MC_CRITICAL_FUNCS = new Set([
  'SDL_GetError', 'SDL_free', 'SDL_GetPlatform', 'SDL_GetTicksNS',
  'SDL_Init', 'SDL_Quit', 'SDL_SetAppMetadataProperty', 'SDL_SetHint',
  'SDL_SetLogOutputFunction', 'SDL_SetLogPriorities',
  'SDL_GetClipboardText', 'SDL_SetClipboardText',
  'SDL_FlushEvents', 'SDL_GetWindowFromEvent', 'SDL_PollEvent', 'SDL_PumpEvents',
  'SDL_GetKeyFromScancode', 'SDL_GetKeyName', 'SDL_GetKeyboardState', 'SDL_GetModState',
  'SDL_SetTextInputArea', 'SDL_StartTextInput', 'SDL_StopTextInput',
  'SDL_CreateSystemCursor', 'SDL_GetDefaultCursor', 'SDL_SetCursor',
  'SDL_SetWindowRelativeMouseMode', 'SDL_WarpMouseInWindow',
  'SDL_GetPixelFormatDetails',
  'SDL_AddSurfaceAlternateImage', 'SDL_CreateSurfaceFrom', 'SDL_DestroySurface',
  'SDL_CreateWindow', 'SDL_DestroyWindow',
  'SDL_GL_CreateContext', 'SDL_GL_DestroyContext', 'SDL_GL_GetProcAddress',
  'SDL_GL_LoadLibrary', 'SDL_GL_MakeCurrent', 'SDL_GL_SetAttribute',
  'SDL_GL_SetSwapInterval', 'SDL_GL_SwapWindow', 'SDL_GL_UnloadLibrary',
  'SDL_GetClosestFullscreenDisplayMode', 'SDL_GetCurrentDisplayMode',
  'SDL_GetCurrentVideoDriver', 'SDL_GetDisplayBounds', 'SDL_GetDisplayForWindow',
  'SDL_GetDisplayName', 'SDL_GetDisplays', 'SDL_GetFullscreenDisplayModes',
  'SDL_GetPrimaryDisplay', 'SDL_GetWindowFlags', 'SDL_GetWindowFullscreenMode',
  'SDL_GetWindowPixelDensity', 'SDL_GetWindowPosition', 'SDL_GetWindowSizeInPixels',
  'SDL_SetWindowFullscreen', 'SDL_SetWindowFullscreenMode', 'SDL_SetWindowIcon',
  'SDL_SetWindowMaximumSize', 'SDL_SetWindowMinimumSize', 'SDL_SetWindowPosition',
  'SDL_SetWindowSize', 'SDL_SetWindowTitle', 'SDL_ShowWindow', 'SDL_SyncWindow',
  'SDL_Vulkan_CreateSurface', 'SDL_Vulkan_GetInstanceExtensions',
  'SDL_Vulkan_GetPresentationSupport', 'SDL_Vulkan_GetVkGetInstanceProcAddr',
  'SDL_Vulkan_LoadLibrary', 'SDL_Vulkan_UnloadLibrary',
]);

// 只影响编译期诊断 / 静态分析，**不影响 ABI** 的注解宏。
// 比较签名前必须剥掉，否则上游动一下 clang thread-safety 注解就会误报。
const ANNOT_WITH_ARGS = [
  'SDL_ACQUIRE', 'SDL_ACQUIRE_SHARED', 'SDL_RELEASE', 'SDL_RELEASE_SHARED',
  'SDL_TRY_ACQUIRE', 'SDL_TRY_ACQUIRE_SHARED', 'SDL_REQUIRES', 'SDL_REQUIRES_SHARED',
  'SDL_EXCLUDES', 'SDL_ALLOC_SIZE', 'SDL_ALLOC_SIZE2',
  'SDL_PRINTF_VARARG_FUNC', 'SDL_PRINTF_VARARG_FUNCV',
  'SDL_WPRINTF_VARARG_FUNC', 'SDL_WPRINTF_VARARG_FUNCV',
  'SDL_SCANF_VARARG_FUNC', 'SDL_SCANF_VARARG_FUNCV',
  'SDL_IN_BYTECAP', 'SDL_INOUT_Z_CAP', 'SDL_OUT_BYTECAP', 'SDL_OUT_CAP',
  'SDL_OUT_Z_BYTECAP', 'SDL_OUT_Z_CAP',
];
const ANNOT_BARE = [
  'SDL_MALLOC', 'SDL_NORETURN', 'SDL_ANALYZER_NORETURN', 'SDL_DEPRECATED',
  'SDL_PRINTF_FORMAT_STRING', 'SDL_SCANF_FORMAT_STRING', 'SDL_UNUSED', 'SDL_FALLTHROUGH',
];

// ---------------------------------------------------------------------------
// 参数
// ---------------------------------------------------------------------------
function parseArgs(argv) {
  const o = { repo: null, base: 'release-3.4.12', head: 'HEAD', json: null, verbose: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--repo') o.repo = argv[++i];
    else if (a === '--base') o.base = argv[++i];
    else if (a === '--head') o.head = argv[++i];
    else if (a === '--json') o.json = argv[++i];
    else if (a === '--verbose' || a === '-v') o.verbose = true;
    else { console.error(`unknown arg: ${a}`); process.exit(1); }
  }
  if (!o.repo) { console.error('缺少 --repo <SDL 仓库路径>'); process.exit(1); }
  return o;
}

function git(repo, args, quiet = false) {
  return execFileSync('git', ['-C', repo, ...args], {
    encoding: 'utf8', maxBuffer: 256 * 1024 * 1024,
    stdio: quiet ? ['ignore', 'pipe', 'ignore'] : ['ignore', 'pipe', 'pipe'],
  });
}

// ---------------------------------------------------------------------------
// C 头解析（够用即可，不做完整 C parser）
// ---------------------------------------------------------------------------

// 去注释。逐字符扫，避免正则跨行贪婪吞掉代码（SDL 头里 /**< ... */ 极多）。
function stripComments(src) {
  let out = '';
  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i], d = src[i + 1];
    if (c === '/' && d === '*') {
      i += 2;
      while (i < n && !(src[i] === '*' && src[i + 1] === '/')) i++;
      i += 2;
      out += ' ';
    } else if (c === '/' && d === '/') {
      while (i < n && src[i] !== '\n') i++;
    } else if (c === '"' || c === '\'') {
      const q = c; out += src[i++];
      while (i < n) {
        if (src[i] === '\\') { out += src[i++]; if (i < n) out += src[i++]; continue; }
        out += src[i];
        if (src[i] === q) { i++; break; }
        i++;
      }
    } else {
      out += c; i++;
    }
  }
  return out;
}

// 剥掉 `NAME(...)` 形式的注解宏（括号配平），以及裸注解宏。
function stripAnnotations(text) {
  let s = text;
  for (const name of ANNOT_WITH_ARGS) {
    let idx;
    while ((idx = s.indexOf(name)) !== -1) {
      // 必须是完整标识符（前后不是 \w），否则 SDL_ACQUIRE 会误吃 SDL_ACQUIRE_SHARED
      const before = idx === 0 ? '' : s[idx - 1];
      let j = idx + name.length;
      while (j < s.length && /\s/.test(s[j])) j++;
      if (/\w/.test(before) || s[j] !== '(' || /\w/.test(s[idx + name.length] ?? '')) {
        // 不是我们要的形态：把该处标识符临时占位，避免死循环
        s = s.slice(0, idx) + '\u0000'.repeat(name.length) + s.slice(idx + name.length);
        continue;
      }
      let depth = 0, k = j;
      for (; k < s.length; k++) {
        if (s[k] === '(') depth++;
        else if (s[k] === ')') { depth--; if (depth === 0) { k++; break; } }
      }
      s = s.slice(0, idx) + ' ' + s.slice(k);
    }
    s = s.replaceAll('\u0000', '');
  }
  for (const name of ANNOT_BARE) {
    s = s.replace(new RegExp(`\\b${name}\\b`, 'g'), ' ');
  }
  return s;
}

// 提取 `typedef struct|union [Name] { ... } TypeName;`
// 返回 Map<TypeName, {kind, members:[normalizedMemberString]}>
function parseStructs(src) {
  const text = stripAnnotations(stripComments(src));
  const res = new Map();
  const re = /\btypedef\s+(struct|union)\b([A-Za-z0-9_\s]*?)\{/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    const kind = m[1];
    const bodyStart = re.lastIndex;          // '{' 之后
    let depth = 1, i = bodyStart;
    while (i < text.length && depth > 0) {
      if (text[i] === '{') depth++;
      else if (text[i] === '}') depth--;
      i++;
    }
    if (depth !== 0) continue;               // 未配平，跳过
    const body = text.slice(bodyStart, i - 1);
    const tailMatch = /^\s*([A-Za-z_]\w*)\s*;/.exec(text.slice(i));
    if (!tailMatch) continue;                // 匿名 / 函数指针 typedef 等
    res.set(tailMatch[1], { kind, members: normalizeMembers(body) });
    re.lastIndex = i;                        // 避免重复匹配嵌套体
  }
  return res;
}

// 切成成员列表并归一化（塌缩空白）。嵌套匿名 struct/union 整体压成一条，
// 其内部变化仍参与比较。
function normalizeMembers(body) {
  const out = [];
  let depth = 0, cur = '';
  for (let i = 0; i < body.length; i++) {
    const c = body[i];
    if (c === '{') { depth++; cur += c; continue; }
    if (c === '}') { depth--; cur += c; continue; }
    if (c === ';' && depth === 0) {
      const t = cur.replace(/\s+/g, ' ').trim();
      if (t) out.push(t);
      cur = '';
      continue;
    }
    cur += c;
  }
  const tail = cur.replace(/\s+/g, ' ').trim();
  if (tail) out.push(tail);
  return out;
}

// 提取公开函数签名：extern SDL_DECLSPEC <ret> SDLCALL SDL_Name(<args>);
function parseFuncs(src) {
  const text = stripAnnotations(stripComments(src)).replace(/\s+/g, ' ');
  const res = new Map();
  const re = /\bextern\s+SDL_DECLSPEC\s+([^;()]*?)\bSDLCALL\s+(SDL_\w+)\s*\(([^;]*?)\)\s*;/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    const ret = m[1].replace(/\s+/g, ' ').trim();
    const name = m[2];
    const args = m[3].replace(/\s+/g, ' ').trim();
    res.set(name, `${ret} ${name}(${args})`);
  }
  return res;
}

// union 的大小锚点：SDL 用 `Uint8 padding[N]` 钉住 sizeof。取出 N。
function unionSizeAnchor(members) {
  for (const m of members) {
    const g = /^Uint8\s+padding\s*\[\s*(\d+)\s*\]$/.exec(m);
    if (g) return Number(g[1]);
  }
  return null;
}

// 「按值嵌入」索引：typeName → [{outer, outerKind}]
// 成员形如 `Foo bar` / `Foo bar[3]` 算按值；`Foo *bar` 算指针（不受 SIZEOF 影响）。
function buildEmbedIndex(structs) {
  const idx = new Map();
  for (const [outer, def] of structs) {
    for (const mem of def.members) {
      const g = /^(?:const\s+|volatile\s+)*([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?$/.exec(mem);
      if (!g) continue;                       // 指针 / 函数指针 / 位域 / 匿名体
      const t = g[1];
      if (!idx.has(t)) idx.set(t, []);
      idx.get(t).push({ outer, outerKind: def.kind });
    }
  }
  return idx;
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------
const opt = parseArgs(process.argv.slice(2));

for (const rev of [opt.base, opt.head]) {
  try { git(opt.repo, ['rev-parse', '--verify', rev], true); }
  catch { console.error(`revision 不存在: ${rev}`); process.exit(1); }
}
const baseSha = git(opt.repo, ['rev-parse', '--short', opt.base]).trim();
const headSha = git(opt.repo, ['rev-parse', '--short', opt.head]).trim();

function listHeaders(rev) {
  return git(opt.repo, ['ls-tree', '-r', '--name-only', rev, 'include/SDL3/'])
    .split(/\r?\n/).filter(p => p.endsWith('.h'));
}
const headers = [...new Set([...listHeaders(opt.base), ...listHeaders(opt.head)])].sort();

function showFile(rev, path) {
  // 该 revision 下不存在是正常情况（新增/删除的头），静默处理
  try { return git(opt.repo, ['show', `${rev}:${path}`], true); }
  catch { return null; }
}

// 设 ABI_TRACE=1 时把逐阶段进度打到 stderr（88×2 个头文件全量解析，出问题时需要能定位）
const TRACE = process.env.ABI_TRACE === '1';
const trace = (...a) => { if (TRACE) process.stderr.write(a.join(' ') + '\n'); };

function collect(rev) {
  const structs = new Map(), funcs = new Map(), origin = new Map();
  for (const h of headers) {
    const t0 = Date.now();
    const src = showFile(rev, h);
    if (src === null) { trace(`  ${rev} ${h} <absent>`); continue; }
    const t1 = Date.now();
    for (const [k, v] of parseStructs(src)) { structs.set(k, v); origin.set(k, h); }
    const t2 = Date.now();
    for (const [k, v] of parseFuncs(src)) funcs.set(k, v);
    const t3 = Date.now();
    trace(`  ${rev} ${h} ${src.length}B  git=${t1 - t0}ms struct=${t2 - t1}ms func=${t3 - t2}ms`);
  }
  return { structs, funcs, origin };
}

console.log('SDL3 ABI 闸门');
console.log(`  repo : ${opt.repo}`);
console.log(`  base : ${opt.base} (${baseSha})   ← LWJGL 3.4.2 绑定生成所依据的版本`);
console.log(`  head : ${opt.head} (${headSha})   ← 我们的 OHOS 移植基线`);
console.log(`  头文件: ${headers.length}`);
console.log('');

const A = collect(opt.base);
const B = collect(opt.head);
const embedHead = buildEmbedIndex(B.structs);

// ---- 类型比较 ----
const results = [];
const grown = [];   // 变大的类型，稍后做按值嵌入分析

for (const name of [...new Set([...A.structs.keys(), ...B.structs.keys()])].sort()) {
  const a = A.structs.get(name), b = B.structs.get(name);
  const critical = MC_CRITICAL_STRUCTS.has(name);
  const rec = { name, critical, kind: (b ?? a).kind, verdict: null, detail: '', notes: [] };

  if (!a) { rec.verdict = 'ADDED'; results.push(rec); continue; }
  if (!b) { rec.verdict = 'REMOVED'; results.push(rec); continue; }
  if (a.kind !== b.kind) {
    rec.verdict = 'BREAKING';
    rec.detail = `聚合类型变了：${a.kind} → ${b.kind}`;
    results.push(rec); continue;
  }

  const am = a.members, bm = b.members;
  const same = am.length === bm.length && am.every((x, i) => x === bm[i]);
  if (same) { rec.verdict = 'IDENTICAL'; results.push(rec); continue; }

  if (b.kind === 'union') {
    // union：所有成员偏移都是 0 → 顺序无关，只看集合与总大小
    const setB = new Set(bm);
    const lost = am.filter(x => !setB.has(x));
    const added = bm.filter(x => !new Set(am).has(x));
    const anchorA = unionSizeAnchor(am), anchorB = unionSizeAnchor(bm);
    if (anchorA !== anchorB) {
      rec.notes.push(`大小锚点变化：padding[${anchorA}] → padding[${anchorB}] ⇒ sizeof 变了`);
    } else if (anchorB !== null) {
      rec.notes.push(`大小锚点未变：Uint8 padding[${anchorB}]`);
    }
    if (lost.length) {
      rec.verdict = 'BREAKING';
      rec.detail = `既有成员消失/被改 ${lost.length} 个：${lost.join(' | ')}`;
    } else if (anchorA !== anchorB) {
      rec.verdict = 'BREAKING';
      rec.detail = `既有成员未动，但 sizeof 变了（LWJGL 的 SIZEOF 会偏小/偏大）`;
    } else {
      rec.verdict = 'EXTENDED';
      rec.detail = `新增成员 ${added.length} 个（偏移全为 0，不影响既有成员）：${added.join(' | ')}`;
    }
    results.push(rec); continue;
  }

  // struct：顺序敏感
  const isPrefix = am.length <= bm.length && am.every((x, i) => x === bm[i]);
  if (isPrefix) {
    rec.verdict = 'APPENDED';
    rec.detail = `末尾追加 ${bm.length - am.length} 个：${bm.slice(am.length).join(' | ')}`;
    grown.push(name);
    results.push(rec); continue;
  }
  let i = 0;
  while (i < Math.min(am.length, bm.length) && am[i] === bm[i]) i++;
  rec.verdict = 'BREAKING';
  rec.detail = `首处分歧 @${i}: base="${am[i] ?? '<无>'}"  head="${bm[i] ?? '<无>'}"`
    + `  (成员数 ${am.length} → ${bm.length})`;
  results.push(rec);
}

// ---- 变大的 struct：按值嵌入分析 ----
// 只被 union 按值嵌入 → 无害（union 成员各自从 0 开始）。
// 被 struct 按值嵌入 → 外层后续字段整体后移，升级为 BREAKING。
for (const name of grown) {
  const rec = results.find(r => r.name === name);
  const sites = embedHead.get(name) ?? [];
  const inStruct = sites.filter(s => s.outerKind === 'struct');
  const inUnion = sites.filter(s => s.outerKind === 'union');
  if (inUnion.length) {
    rec.notes.push(`按值嵌入于 union: ${inUnion.map(s => s.outer).join(', ')}（无害）`);
  }
  if (inStruct.length) {
    rec.notes.push(`⚠️ 按值嵌入于 struct: ${inStruct.map(s => s.outer).join(', ')} → 外层字段会后移`);
    rec.verdict = 'BREAKING';
    rec.detail += `；且被 struct 按值嵌入，外层偏移被推移`;
    for (const s of inStruct) {
      if (MC_CRITICAL_STRUCTS.has(s.outer)) rec.critical = true;
    }
  }
  if (!sites.length) rec.notes.push('未被任何类型按值嵌入（仅独立使用）');
}

// ---- 函数签名比较 ----
const funcResults = [];
for (const name of [...new Set([...A.funcs.keys(), ...B.funcs.keys()])].sort()) {
  const a = A.funcs.get(name), b = B.funcs.get(name);
  const critical = MC_CRITICAL_FUNCS.has(name);
  if (!a) { if (critical) funcResults.push({ name, verdict: 'ADDED', critical, a, b }); continue; }
  if (!b) { funcResults.push({ name, verdict: 'REMOVED', critical, a, b }); continue; }
  if (a !== b) funcResults.push({ name, verdict: 'CHANGED', critical, a, b });
}

// ---- 报告 ----
const VERDICTS = ['IDENTICAL', 'APPENDED', 'EXTENDED', 'BREAKING', 'ADDED', 'REMOVED'];
const by = v => results.filter(r => r.verdict === v);

console.log('=== 类型汇总 ===');
for (const v of VERDICTS) {
  const all = by(v), crit = all.filter(r => r.critical);
  console.log(`  ${v.padEnd(10)} ${String(all.length).padStart(4)}   (MC 关键集 ${crit.length})`);
}

const show = (title, arr) => {
  if (!arr.length) return;
  console.log(`\n--- ${title} ---`);
  for (const r of arr) {
    console.log(`  ${r.critical ? '[MC]' : '    '} ${r.name}  (${r.kind})`);
    if (r.detail) console.log(`         ${r.detail}`);
    for (const n of r.notes) console.log(`         · ${n}`);
  }
};
show('BREAKING —— 必须处理', by('BREAKING'));
show('REMOVED —— 必须确认是否在关键集', by('REMOVED'));
show('APPENDED（struct 末尾追加，既有偏移不变）', by('APPENDED'));
show('EXTENDED（union 新增成员，偏移全为 0）', by('EXTENDED'));
if (opt.verbose) show('ADDED（3.4.12 尚不存在，LWJGL 不认识 → 无关）', by('ADDED'));

console.log('\n=== 函数签名（已剥离不影响 ABI 的注解宏）===');
const fCrit = funcResults.filter(r => r.critical);
console.log(`  差异总数 ${funcResults.length}   (MC 关键集 ${fCrit.length})`);
for (const r of funcResults) {
  if (!r.critical && !opt.verbose) continue;
  console.log(`  ${r.critical ? '[MC]' : '    '} ${r.verdict}  ${r.name}`);
  if (r.a) console.log(`         base: ${r.a}`);
  if (r.b) console.log(`         head: ${r.b}`);
}

if (opt.json) {
  writeFileSync(opt.json, JSON.stringify({
    repo: opt.repo, base: opt.base, baseSha, head: opt.head, headSha,
    headers: headers.length,
    summary: Object.fromEntries(VERDICTS.map(v => [v, by(v).length])),
    structs: results, funcs: funcResults,
  }, null, 2));
  console.log(`\nJSON 报告: ${opt.json}`);
}

// ---- 闸门判定 ----
const fatalTypes = results.filter(r =>
  r.critical && (r.verdict === 'BREAKING' || r.verdict === 'REMOVED'));
const fatalFuncs = fCrit.filter(r => r.verdict === 'CHANGED' || r.verdict === 'REMOVED');
const fatal = fatalTypes.length + fatalFuncs.length;

console.log('');
if (fatal === 0) {
  console.log('VERDICT: PASS —— MC 关键集内无 ABI 破坏（无布局移动、无签名变化、无类型消失）。');
  console.log('         LWJGL 3.4.2 的绑定在该基线上可用 ⇒ 路线 β（跟 upstream/main）成立。');
  console.log('         边界声明：本闸门只比头文件文本，不算 C 布局；');
  console.log('         sizeof/offsetof 的权威核对由 Phase 1 的编译期探针完成。');
  process.exit(0);
} else {
  console.log(`VERDICT: FAIL —— ${fatal} 项 MC 关键集问题`
    + `（类型 ${fatalTypes.length} / 函数 ${fatalFuncs.length}）。`);
  console.log('         须逐项处理，或改走路线 α（基于 upstream/release-3.4.x 编库）。');
  process.exit(1);
}
