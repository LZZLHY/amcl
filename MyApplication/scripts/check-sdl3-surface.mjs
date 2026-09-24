#!/usr/bin/env node
// check-sdl3-surface.mjs — libSDL3.so 符号面硬闸门（SDL3_MIGRATION_PLAN.md Phase 1）
//
// ============================================================================
// 为什么需要这个闸门，以及为什么"MC 只用 110 个成员"是错的判据
// ============================================================================
// LWJGL 的 SDL 绑定不是按调用点惰性解析符号的。每个 `org.lwjgl.sdl.X` 都有一个
// `X$Functions` 静态持有类，它的 `<clinit>` **一次性把该类的全部函数地址解析完**：
//
//     static {                                    // SDLVideo$Functions.<clinit>
//         GetNumVideoDrivers = APIUtil.apiGetFunctionAddress(SDL.getLibrary(), "SDL_GetNumVideoDrivers");
//         GetVideoDriver     = APIUtil.apiGetFunctionAddress(SDL.getLibrary(), "SDL_GetVideoDriver");
//         ... 114 个 ...
//     }
//
// 绝大多数符号用 `apiGetFunctionAddress`（缺失即抛异常），少数用
// `apiGetFunctionAddressOptional`（缺失填 0，不抛）。
//
// ⚠️ 2026-07-31 修正：本注释此前断言「全 jar 里只用 apiGetFunctionAddress，
//    没有 Optional 变体」，那是**只查了 SDLVideo$Functions 一个类就外推的错误结论**。
//    全 jar 实测（`.tmp-sdl3/scan-lwjgl-optional.mjs`，48 个 $Functions 类全扫）：
//      · apiGetFunctionAddress         **1037** 个  ← 真必需，缺失即 ExceptionInInitializerError
//      · apiGetFunctionAddressOptional     **8** 个  ← 缺失只是填 0，不影响类初始化
//    1037 + 8 = 1045，与本闸门统计的"绑定涉及符号总数"正好吻合。
//    8 个 Optional 的分布（都不在 MC 的必需集里，所以 365 这个数字不受影响）：
//      SDLMain$Functions   : SDL_SDL_RegisterApp / SDL_SDL_UnregisterApp（LWJGL 命名 bug）
//      SDLSystem$Functions : SDL_SetWindowsMessageHook / SDL_GetDirect3D9AdapterIndex /
//                            SDL_GetDXGIOutputInfo / SDL_SetX11EventHook /
//                            SDL_SetLinuxThreadPriority / SDL_SetLinuxThreadPriorityAndPolicy
//                            （平台专属，本来就不该在 OHOS 上存在）
//
// ⇒ 结论：**MC 只调用 110 个成员，但只要它碰到 SDLVideo 这个类，
//    SDL_GetNumVideoDrivers 等 114 个符号一个都不能缺**，否则
//    `SDLVideo` 的类初始化就在第一次使用时炸掉。
//    （SDLVideo$Functions 的 114 处确实全是非 Optional，这一点原注释没说错。）
//
// 所以本闸门的必需集不是"MC 调用的成员"，而是
// **「MC 触碰的每个绑定类」的 Functions 全集**。这个集合由脚本从 jar 字节码
// 机械推导，不手写清单 —— 手写清单会漏，而漏掉的那个符号会在真机上表现为
// 一个难以定位的 ExceptionInInitializerError。
//
// ============================================================================
// 顺带核的四项（都在同一个 ELF 里，一次读完）
// ============================================================================
//   · ELF class/machine 必须是 ELF64 / AArch64
//   · SONAME 必须恰好是 `libSDL3.so`（不带版本后缀）—— AMCL 平铺部署 .so，
//     由 HarmonyOS linker namespace 按确切文件名加载，且传给 MC 的是
//     `-Dorg.lwjgl.sdl.libname=libSDL3.so`
//   · `__1` / `__ndk1`（OHOS libc++ 命名空间）符号数必须为 0：SDL3 是
//     `project(SDL3 LANGUAGES C)`，出现即说明误链了 libc++
//   · 未定义 `gl*` 符号数应为 0：说明 GL 入口全走 SDL_EGL_GetProcAddress
//     动态解析，没有静态绑定系统 GLESv2（这是 C2 能成立的前提之一）
//
// ELF 解析是本文件自己实现的（纯 Node，~120 行），**不依赖 readelf/nm**，
// 这样 CI 与开发机都能跑，不需要进容器。
//
// ============================================================================
// 用法
// ============================================================================
//   node scripts/check-sdl3-surface.mjs --so entry/libs/arm64-v8a/libSDL3.so \
//        --jar .tmp-sdl3/lwjgl-sdl-3.4.2.jar [--mc-jar .tmp-devlogs/mc-26.3-snapshot-6.jar] \
//        [--json out.json] [--verbose]
//
// --mc-jar 给了就**从 MC 的 class 常量池动态求出它引用了哪些绑定类**（最稳）；
// 不给则退回文件内嵌的 32 个类清单（来自 .tmp-sdl3/scan-mc-sdl.mjs 的扫描结果）。
//
// 退出码：0 = 必需集 100% 覆盖且 ABI 纯净；1 = 有缺失或不纯净。
// ============================================================================

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { inflateRawSync } from 'node:zlib';
import process from 'node:process';

// ---------------------------------------------------------------------------
// MC 26.3 引用的 32 个绑定类（.tmp-sdl3/scan-mc-sdl.mjs 扫 client jar
// 11179 个 class 常量池的结果；见 SDL3_MIGRATION_PLAN.md §二·2.6）。
// 只在没给 --mc-jar 时用作兜底。
// ---------------------------------------------------------------------------
const MC_BINDING_CLASSES_FALLBACK = [
  'SDL', 'SDLClipboard', 'SDLError', 'SDLEvents', 'SDLHints', 'SDLInit',
  'SDLKeyboard', 'SDLLog', 'SDLMouse', 'SDLPixels', 'SDLPlatform', 'SDLStdinc',
  'SDLSurface', 'SDLTimer', 'SDLVideo', 'SDLVulkan',
  'SDL_DisplayEvent', 'SDL_DisplayMode', 'SDL_DropEvent', 'SDL_Event',
  'SDL_KeyboardEvent', 'SDL_LogOutputFunction', 'SDL_MouseButtonEvent',
  'SDL_MouseMotionEvent', 'SDL_MouseWheelEvent', 'SDL_PixelFormatDetails',
  'SDL_Rect', 'SDL_TextEditingCandidatesEvent', 'SDL_TextEditingEvent',
  'SDL_TextInputEvent', 'SDL_WindowEvent',
];

// ---------------------------------------------------------------------------
function parseArgs(argv) {
  const o = { so: null, jar: null, mcJar: null, json: null, verbose: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--so') o.so = argv[++i];
    else if (a === '--jar') o.jar = argv[++i];
    else if (a === '--mc-jar') o.mcJar = argv[++i];
    else if (a === '--json') o.json = argv[++i];
    else if (a === '--verbose' || a === '-v') o.verbose = true;
    else { console.error(`unknown arg: ${a}`); process.exit(1); }
  }
  if (!o.so || !o.jar) {
    console.error('用法: --so <libSDL3.so> --jar <lwjgl-sdl-*.jar> [--mc-jar <client.jar>]');
    process.exit(1);
  }
  return o;
}
const opt = parseArgs(process.argv.slice(2));
for (const [k, p] of [['--so', opt.so], ['--jar', opt.jar], ['--mc-jar', opt.mcJar]]) {
  if (p && !existsSync(p)) { console.error(`${k} 不存在: ${p}`); process.exit(1); }
}

// ===========================================================================
// 一、极简 zip 读取（stored / deflate）
// ===========================================================================
function openZip(path) {
  const buf = readFileSync(path);
  let eocd = -1;
  for (let i = buf.length - 22; i >= 0 && i > buf.length - 70000; i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error(`EOCD not found in ${path}`);
  const count = buf.readUInt16LE(eocd + 10);
  let off = buf.readUInt32LE(eocd + 16);
  const entries = [];
  for (let i = 0; i < count; i++) {
    if (buf.readUInt32LE(off) !== 0x02014b50) break;
    const method = buf.readUInt16LE(off + 10);
    const compSize = buf.readUInt32LE(off + 20);
    const nameLen = buf.readUInt16LE(off + 28);
    const extraLen = buf.readUInt16LE(off + 30);
    const cmtLen = buf.readUInt16LE(off + 32);
    const lfh = buf.readUInt32LE(off + 42);
    entries.push({ name: buf.toString('utf8', off + 46, off + 46 + nameLen), method, compSize, lfh });
    off += 46 + nameLen + extraLen + cmtLen;
  }
  const read = e => {
    const nl = buf.readUInt16LE(e.lfh + 26);
    const el = buf.readUInt16LE(e.lfh + 28);
    const start = e.lfh + 30 + nl + el;
    const raw = buf.subarray(start, start + e.compSize);
    return e.method === 0 ? raw : inflateRawSync(raw);
  };
  return { entries, read };
}

// ===========================================================================
// 二、class 常量池：取 UTF8 字符串、String 常量、被引用的类名
// ===========================================================================
const T = { Utf8: 1, Integer: 3, Float: 4, Long: 5, Double: 6, Class: 7, String: 8,
  Fieldref: 9, Methodref: 10, InterfaceMethodref: 11, NameAndType: 12,
  MethodHandle: 15, MethodType: 16, Dynamic: 17, InvokeDynamic: 18,
  Module: 19, Package: 20 };

function parseClass(b) {
  if (b.length < 10 || b.readUInt32BE(0) !== 0xCAFEBABE) return null;
  const cpCount = b.readUInt16BE(8);
  let p = 10;
  const utf8 = new Map(), classNameIdx = new Map(), strIdx = [];
  for (let i = 1; i < cpCount; i++) {
    const tag = b[p]; p += 1;
    switch (tag) {
      case T.Utf8: { const len = b.readUInt16BE(p); utf8.set(i, b.toString('utf8', p + 2, p + 2 + len)); p += 2 + len; break; }
      case T.Integer: case T.Float: p += 4; break;
      case T.Long: case T.Double: p += 8; i++; break;
      case T.Class: classNameIdx.set(i, b.readUInt16BE(p)); p += 2; break;
      case T.String: strIdx.push(b.readUInt16BE(p)); p += 2; break;
      case T.MethodType: case T.Module: case T.Package: p += 2; break;
      case T.Fieldref: case T.Methodref: case T.InterfaceMethodref:
      case T.NameAndType: case T.Dynamic: case T.InvokeDynamic: p += 4; break;
      case T.MethodHandle: p += 3; break;
      default: return null;
    }
  }
  const thisName = utf8.get(classNameIdx.get(b.readUInt16BE(p + 2))) ?? '?';
  const strings = strIdx.map(i => utf8.get(i)).filter(s => typeof s === 'string');
  const refClasses = [...classNameIdx.values()].map(i => utf8.get(i)).filter(Boolean);
  return { thisName, strings, refClasses };
}

// ===========================================================================
// 三、ELF64 解析（dynsym / dynamic），纯 Node，不依赖 readelf/nm
// ===========================================================================
const SHT_DYNSYM = 11, SHT_DYNAMIC = 6, SHT_STRTAB = 3;
const DT_NEEDED = 1n, DT_SONAME = 14n, DT_NULL = 0n;
const SHN_UNDEF = 0;
const STB_GLOBAL = 1, STB_WEAK = 2;
const EM_AARCH64 = 0xB7;

function parseElf(path) {
  const b = readFileSync(path);
  if (b.length < 64 || b.readUInt32BE(0) !== 0x7f454c46) throw new Error('不是 ELF 文件');
  const cls = b[4];                 // 1=32bit 2=64bit
  const data = b[5];                // 1=LE 2=BE
  if (cls !== 2 || data !== 1) throw new Error(`只支持 ELF64 LE（读到 class=${cls} data=${data}）`);
  const machine = b.readUInt16LE(0x12);
  const shoff = Number(b.readBigUInt64LE(0x28));
  const shentsize = b.readUInt16LE(0x3A);
  const shnum = b.readUInt16LE(0x3C);

  const sections = [];
  for (let i = 0; i < shnum; i++) {
    const o = shoff + i * shentsize;
    sections.push({
      nameOff: b.readUInt32LE(o),
      type: b.readUInt32LE(o + 4),
      offset: Number(b.readBigUInt64LE(o + 24)),
      size: Number(b.readBigUInt64LE(o + 32)),
      link: b.readUInt32LE(o + 40),
      entsize: Number(b.readBigUInt64LE(o + 56)),
    });
  }
  const cstr = (base, off) => {
    let e = base + off;
    while (e < b.length && b[e] !== 0) e++;
    return b.toString('utf8', base + off, e);
  };

  // ---- .dynsym ----
  const dynsym = sections.find(s => s.type === SHT_DYNSYM);
  if (!dynsym) throw new Error('找不到 .dynsym（是静态库或已被剥离动态符号？）');
  const dynstr = sections[dynsym.link];
  if (!dynstr || dynstr.type !== SHT_STRTAB) throw new Error('.dynsym 的 sh_link 不是 strtab');

  const defined = new Set(), undef = new Set(), all = [];
  const entsize = dynsym.entsize || 24;
  for (let o = dynsym.offset; o + entsize <= dynsym.offset + dynsym.size; o += entsize) {
    const stName = b.readUInt32LE(o);
    const stInfo = b[o + 4];
    const stShndx = b.readUInt16LE(o + 6);
    const name = stName ? cstr(dynstr.offset, stName) : '';
    if (!name) continue;
    const bind = stInfo >> 4;
    const rec = { name, bind, shndx: stShndx };
    all.push(rec);
    if (stShndx !== SHN_UNDEF && (bind === STB_GLOBAL || bind === STB_WEAK)) defined.add(name);
    else if (stShndx === SHN_UNDEF) undef.add(name);
  }

  // ---- .dynamic ----
  const needed = [];
  let soname = null;
  const dyn = sections.find(s => s.type === SHT_DYNAMIC);
  if (dyn) {
    const dstr = sections[dyn.link] ?? dynstr;
    for (let o = dyn.offset; o + 16 <= dyn.offset + dyn.size; o += 16) {
      const tag = b.readBigUInt64LE(o);
      const val = b.readBigUInt64LE(o + 8);
      if (tag === DT_NULL) break;
      if (tag === DT_NEEDED) needed.push(cstr(dstr.offset, Number(val)));
      else if (tag === DT_SONAME) soname = cstr(dstr.offset, Number(val));
    }
  }
  return { size: b.length, machine, defined, undef, all, needed, soname };
}

// ===========================================================================
// 四、从 lwjgl-sdl jar 推导「类 → 该类 Functions 会解析的符号集」
// ===========================================================================
function buildBindingMap(jarPath) {
  const zip = openZip(jarPath);
  const map = new Map();        // 绑定类简名 -> Set(SDL_xxx)
  let funcClasses = 0;
  for (const e of zip.entries) {
    if (!/^org\/lwjgl\/sdl\/[^/]+\$Functions\.class$/.test(e.name)) continue;
    let cf;
    try { cf = parseClass(zip.read(e)); } catch { continue; }
    if (!cf) continue;
    funcClasses++;
    // org/lwjgl/sdl/SDLVideo$Functions -> SDLVideo
    const owner = cf.thisName.replace(/^org\/lwjgl\/sdl\//, '').replace(/\$Functions$/, '');
    const syms = new Set(cf.strings.filter(s => /^SDL_[A-Za-z0-9_]+$/.test(s)));
    if (syms.size) map.set(owner, syms);
  }
  return { map, funcClasses };
}

// 从 MC client jar 求出它引用了哪些 org/lwjgl/sdl 类（最稳，不依赖内嵌清单）
function scanMcBindingClasses(mcJarPath) {
  const zip = openZip(mcJarPath);
  const used = new Set();
  let scanned = 0;
  for (const e of zip.entries) {
    if (!e.name.endsWith('.class')) continue;
    let cf;
    try { cf = parseClass(zip.read(e)); } catch { continue; }
    if (!cf) continue;
    scanned++;
    for (const c of cf.refClasses) {
      const m = /^org\/lwjgl\/sdl\/([^/$]+)/.exec(c);
      if (m) used.add(m[1]);
    }
  }
  return { used, scanned };
}

// ===========================================================================
// 五、执行
// ===========================================================================
console.log('SDL3 符号面闸门');
console.log(`  so  : ${opt.so}`);
console.log(`  jar : ${opt.jar}`);
if (opt.mcJar) console.log(`  mc  : ${opt.mcJar}`);
console.log('');

const elf = parseElf(opt.so);
console.log('=== ELF ===');
console.log(`  大小      : ${elf.size} B (${(elf.size / 1048576).toFixed(2)} MB)`);
console.log(`  machine   : 0x${elf.machine.toString(16)} ${elf.machine === EM_AARCH64 ? '(AArch64) ✅' : '❌ 期望 AArch64(0xb7)'}`);
console.log(`  SONAME    : ${elf.soname ?? '(无)'} ${elf.soname === 'libSDL3.so' ? '✅' : '❌ 期望 libSDL3.so'}`);
console.log(`  NEEDED    : ${elf.needed.join(', ')}`);
console.log(`  导出符号  : ${elf.defined.size}   未定义符号: ${elf.undef.size}`);

const { map: bindingMap, funcClasses } = buildBindingMap(opt.jar);
const sdlAll = new Set();
for (const s of bindingMap.values()) for (const x of s) sdlAll.add(x);
console.log('');
console.log('=== LWJGL 绑定面（从 jar 字节码机械推导） ===');
console.log(`  X$Functions 类数 : ${funcClasses}（其中 ${bindingMap.size} 个含 SDL_* 符号）`);
console.log(`  绑定涉及符号总数 : ${sdlAll.size}`);

// ---- 必需集：MC 触碰的类的 Functions 全集 ----
let mcClasses, mcSource;
if (opt.mcJar) {
  const r = scanMcBindingClasses(opt.mcJar);
  mcClasses = [...r.used].sort();
  mcSource = `扫描 ${r.scanned} 个 MC class 得出`;
} else {
  mcClasses = [...MC_BINDING_CLASSES_FALLBACK].sort();
  mcSource = '文件内嵌兜底清单（建议传 --mc-jar 动态求）';
}

const required = new Set();
const perClass = [];
const classesWithoutFunctions = [];
for (const c of mcClasses) {
  const syms = bindingMap.get(c);
  if (!syms) { classesWithoutFunctions.push(c); continue; }  // struct 类没有 Functions，正常
  for (const s of syms) required.add(s);
  perClass.push({ cls: c, count: syms.size });
}

console.log('');
console.log('=== 必需集（MC 触碰的类 → 其 Functions 全集） ===');
console.log(`  MC 引用的绑定类 : ${mcClasses.length} 个（${mcSource}）`);
console.log(`  其中带 Functions: ${perClass.length} 个`);
console.log(`  无 Functions（struct/回调类，无需符号）: ${classesWithoutFunctions.length} 个`);
console.log(`  ⇒ 必需符号总数  : ${required.size}`);
for (const r of perClass.sort((a, b) => b.count - a.count)) {
  console.log(`      ${String(r.count).padStart(4)}  ${r.cls}`);
}

// ---- 覆盖比对 ----
// 缺失要分两类，否则会把「补不了的上游绑定缺陷」误记成我们的账：
//
//   (a) 绑定名字本身是错的 —— 实测 lwjgl-sdl 3.4.2 的 SDLMain$Functions 里写着
//       `SDL_SDL_RegisterApp` / `SDL_SDL_UnregisterApp`，`SDL_` 前缀重复了两次。
//       真实符号是 `SDL_RegisterApp`（`SDL_main.h` L625-675，`#if defined(SDL_PLATFORM_WINDOWS)`
//       包着，Windows-only）。这两个名字在**世界上任何 SDL3 库里都不存在**，
//       连官方 Windows 版也没有。
//       这是 LWJGL 绑定生成器的 bug，我们**补不了也不该补**，只能标注 + 上报 LWJGL。
//
//       ⚠️ 2026-07-31 修正：此处原先断言「⇒ org.lwjgl.sdl.SDLMain 在任何平台都无法
//       初始化」，**那是错的**。实测 SDLMain$Functions.<clinit> 的字节码，这两个
//       错误名字用的是 `apiGetFunctionAddressOptional`（缺失填 0、不抛），
//       只有 SetMainReady / RunApp / EnterAppMainCallbacks 三个用
//       `apiGetFunctionAddress`。⇒ **SDLMain 可以正常初始化并使用。**
//
//       这条修正对 AMCL 有直接影响：OHOS 上必须在 SDL_Init 之前调
//       `SDL_SetMainReady()`（见 SDL3_MIGRATION_PLAN.md §C1.1，已真机实证），
//       而它正是通过 `org.lwjgl.sdl.SDLMain.SDL_SetMainReady()` 暴露的。
//       原先那句错误结论会让人以为这条路走不通、从而绕道 native 侧。
//
//   (b) 名字正确但我们的库没导出 —— 这才是我们的账（少编了子系统、或版本差异）。
const isDoublePrefixed = s => s.startsWith('SDL_SDL_');

const missingRequiredRaw = [...required].filter(s => !elf.defined.has(s)).sort();
const missingAllRaw = [...sdlAll].filter(s => !elf.defined.has(s)).sort();
const missingRequired = missingRequiredRaw.filter(s => !isDoublePrefixed(s));
const missingAll = missingAllRaw.filter(s => !isDoublePrefixed(s));
const upstreamBindingBugs = missingAllRaw.filter(isDoublePrefixed);

console.log('');
console.log('=== 覆盖 ===');
console.log(`  必需集   : ${required.size - missingRequiredRaw.length}/${required.size} 覆盖`
  + (missingRequired.length ? `   ❌ 缺 ${missingRequired.length}` : '   ✅'));
console.log(`  绑定全集 : ${sdlAll.size - missingAllRaw.length}/${sdlAll.size} 覆盖`
  + (missingAll.length ? `   ⚠️ 缺 ${missingAll.length}（MC 今天不用，未来快照可能用）` : '   ✅'));
if (upstreamBindingBugs.length) {
  console.log(`  另有 ${upstreamBindingBugs.length} 个符号是 **LWJGL 绑定名字有误**（SDL_ 前缀重复），`);
  console.log('  在任何 SDL3 库里都不存在，我们补不了：');
  for (const s of upstreamBindingBugs) {
    const owners = [...bindingMap.entries()].filter(([, v]) => v.has(s)).map(([k]) => k);
    console.log(`      ${s}   ← ${owners.join(', ')}   （真实符号应为 ${s.replace(/^SDL_SDL_/, 'SDL_')}）`);
  }
  const affected = new Set(upstreamBindingBugs.flatMap(
    s => [...bindingMap.entries()].filter(([, v]) => v.has(s)).map(([k]) => k)));
  const hit = [...affected].filter(c => mcClasses.includes(c));
  // 这两个错误名字在字节码里用的是 apiGetFunctionAddressOptional（缺失填 0、不抛），
  // 所以**不会**导致所属类无法初始化 —— 2026-07-31 反编译 SDLMain$Functions.<clinit> 实测。
  // 这一点很重要：SDLMain 里的 SDL_SetMainReady 是 OHOS 上 SDL_Init 的前置条件（§C1.1），
  // 必须可用。
  console.log(`  所属绑定类：${[...affected].join(', ')}`);
  console.log('  ℹ️ 这两个名字用的是 apiGetFunctionAddressOptional（缺失填 0，不抛异常），');
  console.log('     所以所属类仍可正常初始化 —— 例如 SDLMain.SDL_SetMainReady() 照常可用。');
  console.log(`  MC 是否引用这些类：${hit.length ? '❌ ' + hit.join(', ') : '否 ✅（对我们无影响）'}`);
}

if (missingRequired.length) {
  console.log('\n  --- 必需集缺失（会让对应类的 <clinit> 抛 ExceptionInInitializerError）---');
  for (const s of missingRequired) {
    const owners = [...bindingMap.entries()].filter(([, v]) => v.has(s)).map(([k]) => k);
    console.log(`      ${s}   ← ${owners.join(', ')}`);
  }
}
if (missingAll.length && opt.verbose) {
  console.log('\n  --- 绑定全集缺失（仅提示）---');
  for (const s of missingAll) console.log(`      ${s}`);
}

// ---- ABI 纯净 ----
console.log('');
console.log('=== ABI 纯净 ===');
const n1 = [...elf.defined, ...elf.undef].filter(s => s.includes('__1') || s.includes('__ndk1'));
console.log(`  __1/__ndk1 (libc++ 命名空间) 符号数 : ${n1.length} ${n1.length === 0 ? '✅' : '❌'}`);
if (n1.length) for (const s of n1.slice(0, 10)) console.log(`      ${s}`);
const hasLibcxx = elf.needed.some(n => n.includes('libc++'));
console.log(`  NEEDED 含 libc++                   : ${hasLibcxx ? '❌ 是' : '否 ✅'}`);
const undefGl = [...elf.undef].filter(s => /^gl[A-Z]/.test(s)).sort();
console.log(`  未定义 gl* 符号数                  : ${undefGl.length} ${undefGl.length === 0 ? '✅（GL 全走动态解析，C2 前提成立）' : '⚠️ 静态绑定了系统 GL'}`);
if (undefGl.length && opt.verbose) for (const s of undefGl.slice(0, 20)) console.log(`      ${s}`);

// ---- OHOS 后端在位证据（strip 后本地符号已无，靠 .rodata 字符串） ----
//
// 有两种可接受的 OHOS video 后端形态，判据必须同时认，否则换基线就假红：
//
//   flavor                      driver 注册名    VideoBootStrap 描述串
//   --------------------------  --------------  ---------------------------------------
//   icculus/SDL sdl3-harmonyos  "openharmony"   "SDL OpenHarmony/HarmonyOS video driver"
//   AMCL 自有 fork (LZZLHY/SDL) "ohos"          "OpenHarmony video driver"
//
// 出处：icculus 分支 src/video/openharmony/SDL_openharmonyvideo.c:53 与 :270；
//       自有 fork  src/video/ohos/SDL_ohosvideo.c:134-135。
//
// 用**描述串**而不是 driver 注册名做判据：注册名 "ohos" 只有 4 个字符，
// 很容易在路径、日志、无关标识符里偶然命中，作为"后端在位"的证据强度不够。
// 两个描述串互不为子串（自有 fork 是 `OpenHarmony␠video`，icculus 是
// `OpenHarmony/HarmonyOS␠video`），所以能无歧义区分 —— 这也正是旧判据
// 只认前者时会对 icculus 产物报假阴性的原因。
// 带 \0 结尾匹配，确保命中的是完整字符串字面量而非某个更长串的前缀。
const OHOS_BACKENDS = [
  { flavor: 'icculus/SDL sdl3-harmonyos', driver: 'openharmony', desc: 'SDL OpenHarmony/HarmonyOS video driver' },
  { flavor: 'AMCL fork (LZZLHY/SDL ohos)', driver: 'ohos', desc: 'OpenHarmony video driver' },
];
const soBuf = readFileSync(opt.so);
const ohosBackend = OHOS_BACKENDS.find(b => soBuf.includes(Buffer.from(`${b.desc}\0`, 'utf8'))) || null;
const hasOhosDriver = ohosBackend !== null;
console.log(`  OHOS video driver 注册名在 .rodata : ${hasOhosDriver ? `在 ✅（${ohosBackend.flavor}，driver="${ohosBackend.driver}"）` : '缺 ❌'}`);

// ---- JSON ----
if (opt.json) {
  writeFileSync(opt.json, JSON.stringify({
    so: opt.so, size: elf.size, machine: elf.machine, soname: elf.soname,
    needed: elf.needed, exported: elf.defined.size, undefined: elf.undef.size,
    bindingFunctionsClasses: funcClasses, bindingSymbols: sdlAll.size,
    mcClasses, mcSource, requiredSymbols: required.size,
    missingRequired, missingAll, upstreamBindingBugs,
    n1Symbols: n1, undefGl, ohosDriverString: hasOhosDriver,
    ohosBackendFlavor: ohosBackend?.flavor ?? null,
    ohosVideoDriverName: ohosBackend?.driver ?? null,
  }, null, 2));
  console.log(`\nJSON 报告: ${opt.json}`);
}

// ---- 闸门 ----
const fatals = [];
if (elf.machine !== EM_AARCH64) fatals.push('machine 不是 AArch64');
if (elf.soname !== 'libSDL3.so') fatals.push(`SONAME 不是 libSDL3.so（是 ${elf.soname}）—— 构建时加 -DCMAKE_PLATFORM_NO_VERSIONED_SONAME=ON`);
if (missingRequired.length) fatals.push(`必需符号缺 ${missingRequired.length} 个`);
if (n1.length) fatals.push(`出现 ${n1.length} 个 libc++ 命名空间符号`);
if (hasLibcxx) fatals.push('NEEDED 含 libc++');
if (!hasOhosDriver) fatals.push(`产物里找不到任何已知的 OHOS video 后端描述串（认这些：${OHOS_BACKENDS.map(b => `"${b.desc}"`).join(' / ')}）`);

console.log('');
if (fatals.length === 0) {
  console.log('VERDICT: PASS');
  console.log(`  必需集 ${required.size} 个符号 100% 导出；ELF64/AArch64；SONAME=libSDL3.so；`);
  console.log(`  无 libc++ 污染；GL 全走动态解析；OHOS 驱动在位（${ohosBackend.flavor}，driver="${ohosBackend.driver}"）。`);
  if (missingAll.length) {
    console.log(`  ⚠️ 绑定全集尚缺 ${missingAll.length} 个符号 —— MC 今天不碰，`);
    console.log('     但后续快照一旦用到对应类就会炸。用 --verbose 看清单。');
  }
  if (upstreamBindingBugs.length) {
    console.log(`  ℹ️ 另有 ${upstreamBindingBugs.length} 个 LWJGL 绑定名字有误（SDL_ 前缀重复），`);
    console.log('     不计入我们的账；建议向 LWJGL 上报。');
  }
  process.exit(0);
} else {
  console.log('VERDICT: FAIL');
  for (const f of fatals) console.log(`  · ${f}`);
  process.exit(1);
}
