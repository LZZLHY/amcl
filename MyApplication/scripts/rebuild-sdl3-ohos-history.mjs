#!/usr/bin/env node
// rebuild-sdl3-ohos-history.mjs
// 在 upstream/main 之上把 OpenMinecraft-Dev/SDL 的 OHOS 移植重建成一条**干净、可评审、
// 保留原作者署名**的提交序列（SDL3_MIGRATION_PLAN.md §七 Phase 1 第 2 步 / Task#7）。
//
// ============================================================================
// 为什么不逐提交 cherry-pick
// ============================================================================
// 实测（.tmp-sdl3/probe-cherry.mjs）：95 个非 merge 提交里只有 6 个能干净应用。
// 更关键的是**技术上做不完整**：前人在 commit bc8a01803 里把 `ohos-project` 作为
// submodule（`160000 commit d48a2ee…`），后来才改成普通目录；那个 gitlink 指向的
// commit 属于另一个仓库、本地没有、公开位置未知 ⇒ 重放必然卡死。
// 而且 95 个提交里大量 "Harmony port: fix" / 连续三个 "Workflows (fix script error)"，
// 中间态互相修补、无一可单独构建 —— 正是 madebr 一年前要求整理的形状。
//
// ============================================================================
// 署名原则（本脚本的硬约束）
// ============================================================================
// - 每个提交的 **author = 原作者**（92/95 出自 GitHub uid 83895170，
//   账号先后 Jack253-png → Coder2 → MetsukiMio）。
// - 第三方贡献用 **Co-authored-by:** 挂在对应提交上：
//   Starcloudsea（napi 调用修复、video device）、artin（touch 事件只处理变化点）。
// - 每个提交正文注明出处（原 PR #13152）与该组对应的原始提交范围。
// - committer = 我们（经 GIT_COMMITTER_* 环境变量传入，**不写 git config**）。
//
// ============================================================================
// 顺带修掉的 5 处缺陷（逐条读 17 个被修改文件的 diff 后发现）
// ============================================================================
// D1 CMakeLists.txt：`max-page-size=16384` 链接选项块被错放进 `if(ANDROID)` 分支尾部
//    → 作用于 Android，与 OHOS 移植无关。AMCL 12 个 OHOS 交叉编译产物无一需要它。
//    处置：**整块丢弃**。
// D2 SDL_build_config.h.cmake：`SDL_VIDEO_DRIVER_OHOS` 重复定义，其中一处错放在
//    **AUDIO driver** 段（夹在 NETBSD 与 OSS 之间）。处置：**删掉 audio 段那处**。
// D3 src/audio/SDL_audiotypecvt.c：`#ifndef SDL_PLATFORM_OHOS / #undef SDL_NEON_INTRINSICS`
//    —— 逻辑写反了，等于**给除 OHOS 以外所有平台关掉 NEON**，是全平台性能回归。
//    处置：**整个文件的改动丢弃**，改为 Phase 1 实测「OHOS clang 能否编 NEON 路径」，
//    能编就永远不需要这个 hack；不能编再带着真实编译错误单独提。
// D4 src/power/SDL_power.c：`SDL_GetPowerInfo_OHOS` 缺尾逗号，与 SDL_POWER_HARDWIRED
//    同时定义时 → `A B,` 编译失败。处置：**补逗号**。
// D5 src/SDL_log.c：OHOS 的 `#elif` 缩进 4 空格（违反 .clang-format 的顶格惯例）；
//    且缺 Android 那条 `SDL_COMPILE_TIME_ASSERT` 表长校验。处置：**修缩进 + 补 assert**。
// D6（改进）src/thread/pthread/SDL_systhread.c：`!defined(SDL_PLATFORM_OHOS)` 无注释。
//    处置：**加一行说明**，否则评审一定会问。
//
// 保留不动、留作 PR 描述里的开放问题：`SDL_GetPlatform()` 返回
// "OpenHarmony/HarmonyOS"（带斜杠，虽有 "GNU/Hurd" 先例，但维护者可能想要 "OpenHarmony"）。
//
// ============================================================================
// 用法
// ============================================================================
//   node scripts/rebuild-sdl3-ohos-history.mjs --repo <SDL 仓库> --dry-run
//   node scripts/rebuild-sdl3-ohos-history.mjs --repo <SDL 仓库> \
//        --committer-name "X" --committer-email "y@z"
//
// --dry-run 只做分组校验与缺陷修复预演，**不创建任何提交、不改工作区**。
// 正式运行前会检查：分支干净、HEAD == upstream/main、每个文件恰好归入一组。
// ============================================================================

import { execFileSync, spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import process from 'node:process';

// ---------------------------------------------------------------------------
const AUTHOR = 'MetsukiMio <guoxiuchen20170402@163.com>';
const CO_STARCLOUDSEA = 'Co-authored-by: Starcloudsea <84891987+Starcloudsea@users.noreply.github.com>';
const CO_ARTIN = 'Co-authored-by: artin <artin@cat.ms>';
const PROVENANCE = [
  'This is a history-clean reconstruction of the OpenHarmony port from',
  'OpenMinecraft-Dev/SDL (libsdl-org/SDL#13152), rebased onto current main',
  'and regrouped one-topic-per-commit. Authorship is preserved.',
].join('\n');

const BASE = 'upstream/main';
const SRC = 'vendor-ohos-ref';

// 丢弃的文件（见 D3）
const DROP_FILES = new Set(['src/audio/SDL_audiotypecvt.c']);

// ---------------------------------------------------------------------------
// 提交序列。顺序按「源码先、构建系统后」——这样在第 11 个提交打开构建开关之前，
// 新增文件全部处于休眠状态，历史中途不会出现"引用了还不存在的文件"。
// match: 判断某文件是否属于本组（按数组顺序，先匹配者获得该文件）
// ---------------------------------------------------------------------------
const COMMITS = [
  {
    id: 1,
    subject: 'Add OHOS platform detection macros',
    body: [
      'Define SDL_PLATFORM_OHOS when building for OpenHarmony / HarmonyOS,',
      'and undefine SDL_PLATFORM_LINUX because the OHOS libc (musl-based)',
      'and system services differ enough that the Linux code paths do not',
      'apply.',
      '',
      'This commit only adds the macro; nothing consumes it yet.',
    ].join('\n'),
    match: f => f === 'include/SDL3/SDL_platform_defines.h',
  },
  {
    id: 2,
    subject: 'Add OHOS core: napi bridge and app lifecycle',
    body: [
      'Add src/core/ohos, the bridge between the ArkTS application shell and',
      'SDL: napi entry points, XComponent registration, the SDL main thread,',
      'display metrics, clipboard, message boxes and text input plumbing.',
      '',
      'This is the foundation every other OHOS backend builds on.',
    ].join('\n'),
    co: [CO_STARCLOUDSEA],
    match: f => f.startsWith('src/core/ohos/'),
  },
  {
    id: 3,
    subject: 'Add OHOS video driver: device and window',
    body: [
      'Add the ohos VideoBootStrap with display enumeration and window',
      'creation/destruction, and register it in the video driver table.',
      '',
      'The bootstrap is guarded by SDL_VIDEO_DRIVER_OHOS, which is not',
      'defined until the build system commit later in this series.',
    ].join('\n'),
    co: [CO_STARCLOUDSEA],
    match: f =>
      /^src\/video\/ohos\/SDL_ohos(video|window)\.[ch]$/.test(f) ||
      f === 'src/video/SDL_sysvideo.h' ||
      f === 'src/video/SDL_video.c',
  },
  {
    id: 4,
    subject: 'Add OHOS OpenGL ES support via EGL',
    body: [
      'Wire the generic SDL EGL layer to the OHOS native window so that',
      'OpenGL ES contexts can be created, made current and swapped.',
    ].join('\n'),
    match: f => /^src\/video\/ohos\/SDL_ohosgl\.[ch]$/.test(f),
  },
  {
    id: 5,
    subject: 'Add OHOS Vulkan surface support',
    body: [
      'Implement Vulkan_LoadLibrary/GetInstanceExtensions/CreateSurface for',
      'OHOS using VK_OHOS_surface.',
    ].join('\n'),
    match: f =>
      /^src\/video\/ohos\/SDL_ohosvulkan\.[ch]$/.test(f) ||
      f.startsWith('src/video/khronos/'),
  },
  {
    id: 6,
    subject: 'Add OHOS keyboard, mouse and touch input',
    body: [
      'Translate OHOS multimodal input events into SDL events:',
      '',
      '- keyboard: a keycode table indexed by the OHOS keyCode value',
      '  (@ohos.multimodalInput.keyCode), mapping to SDL scancodes',
      '- mouse: motion and button events',
      '- touch: finger down/up/motion',
    ].join('\n'),
    co: [CO_ARTIN],
    match: f => /^src\/video\/ohos\/SDL_ohos(keyboard|mouse|touch)\.[ch]$/.test(f),
  },
  {
    id: 7,
    subject: 'Add OHOS sensor driver',
    body: [
      'Implement the SDL sensor driver on top of libohsensor, exposing the',
      'accelerometer and gyroscope, and register it in the driver table.',
    ].join('\n'),
    match: f =>
      f.startsWith('src/sensor/ohos/') ||
      f === 'src/sensor/SDL_sensor.c' ||
      f === 'src/sensor/SDL_syssensor.h',
  },
  {
    id: 8,
    subject: 'Add OHOS power info implementation',
    body: [
      'Implement SDL_GetPowerInfo_OHOS and add it to the implementation',
      'table.',
    ].join('\n'),
    match: f =>
      f.startsWith('src/power/ohos/') ||
      f === 'src/power/SDL_power.c' ||
      f === 'src/power/SDL_syspower.h',
    // D4：补尾逗号
    fixes: [{
      file: 'src/power/SDL_power.c',
      from: '#ifdef SDL_POWER_OHOS\n    SDL_GetPowerInfo_OHOS\n#endif',
      to: '#ifdef SDL_POWER_OHOS\n    SDL_GetPowerInfo_OHOS,\n#endif',
      why: 'D4 missing trailing comma would break the array when SDL_POWER_HARDWIRED is also defined',
    }],
  },
  {
    id: 9,
    subject: 'Add OHOS filesystem, locale, misc and dialog',
    body: [
      'Implement the remaining small platform backends:',
      '',
      '- filesystem: base/pref paths from the application sandbox',
      '- locale: system language and region',
      '- misc: SDL_OpenURL',
      '- dialog: file dialogs',
    ].join('\n'),
    match: f =>
      f.startsWith('src/filesystem/ohos/') ||
      f.startsWith('src/locale/ohos/') ||
      f.startsWith('src/misc/ohos/') ||
      f.startsWith('src/dialog/ohos/'),
  },
  {
    id: 10,
    subject: 'Support OHOS in platform-independent code',
    body: [
      '- SDL_GetPlatform() and SDL_IsPhone() report OHOS',
      '- SDL_log routes messages to hilog (OH_LOG_Print), mirroring the',
      '  Android __android_log_write path, with a compile-time assert that',
      '  the priority table stays in sync with SDL_LogPriority',
      '- pthread: do not request asynchronous cancellation on OHOS, whose',
      '  libc does not support it',
    ].join('\n'),
    match: f =>
      f === 'src/SDL.c' ||
      f === 'src/SDL_log.c' ||
      f === 'src/thread/pthread/SDL_systhread.c',
    fixes: [
      // D5a：#elif 顶格
      {
        file: 'src/SDL_log.c',
        from: '    #elif defined(SDL_PLATFORM_OHOS)',
        to: '#elif defined(SDL_PLATFORM_OHOS)',
        why: 'D5 indented preprocessor directive violates the project style',
      },
      // D5b：补 SDL_COMPILE_TIME_ASSERT，与 Android 表对称
      {
        file: 'src/SDL_log.c',
        from: '    LOG_FATAL\n};\n#endif\n',
        to: '    LOG_FATAL\n};\nSDL_COMPILE_TIME_ASSERT(ohos_priority, SDL_arraysize(SDL_ohos_priority) == SDL_LOG_PRIORITY_COUNT);\n#endif // SDL_PLATFORM_OHOS\n',
        why: 'D5 add the same priority-table length assert Android already has',
      },
      // D6：加注释
      {
        file: 'src/thread/pthread/SDL_systhread.c',
        from: '#if defined(PTHREAD_CANCEL_ASYNCHRONOUS) && !defined(SDL_PLATFORM_OHOS)\n',
        to: '// The OHOS libc declares PTHREAD_CANCEL_ASYNCHRONOUS but does not\n// implement pthread_setcanceltype(), so skip it there.\n#if defined(PTHREAD_CANCEL_ASYNCHRONOUS) && !defined(SDL_PLATFORM_OHOS)\n',
        why: 'D6 explain why OHOS is excluded, otherwise reviewers will ask',
      },
    ],
  },
  {
    id: 11,
    subject: 'Add OHOS build system support',
    body: [
      'Add the OHOS branch to CMakeLists.txt (core, video, misc, power,',
      'locale, loadso, time, timer, filesystem, sensor, dialog, pthreads),',
      'the matching cmakedefine entries, and teach the CMake helpers about',
      'the platform.',
      '',
      'This is the commit that actually turns the port on.',
    ].join('\n'),
    match: f =>
      f === 'CMakeLists.txt' ||
      f.startsWith('cmake/') ||
      f === 'include/build_config/SDL_build_config.h.cmake',
    fixes: [
      // D1：丢弃错放进 ANDROID 分支的 page-size 块
      {
        file: 'CMakeLists.txt',
        from:
          'if(TARGET SDL3-shared)\n' +
          '  target_link_options(SDL3-shared PRIVATE "-Wl,-z,max-page-size=16384")\n' +
          '  target_link_options(SDL3-shared PRIVATE "-Wl,-z,common-page-size=16384")\n' +
          'endif()\n' +
          '\n' +
          'elseif(OHOS)',
        to: 'elseif(OHOS)',
        why: 'D1 drop a 16K-page link option block that landed inside the ANDROID branch and is unrelated to this port',
      },
      // D2：删掉 audio 段里的重复 cmakedefine
      {
        file: 'include/build_config/SDL_build_config.h.cmake',
        from: '#cmakedefine SDL_AUDIO_DRIVER_NETBSD 1\n#cmakedefine SDL_VIDEO_DRIVER_OHOS 1\n',
        to: '#cmakedefine SDL_AUDIO_DRIVER_NETBSD 1\n',
        why: 'D2 SDL_VIDEO_DRIVER_OHOS was duplicated into the AUDIO driver section',
      },
    ],
  },
  {
    id: 12,
    subject: 'Add OHOS example project',
    body: [
      'Add ohos-project, a minimal DevEco Studio project that builds SDL and',
      'runs it inside an ArkTS ability, mirroring the role android-project',
      'plays for Android.',
    ].join('\n'),
    match: f => f.startsWith('ohos-project/'),
  },
  {
    id: 13,
    subject: 'Add docs/README-ohos.md',
    body: [
      'Document how to build SDL for OpenHarmony and how to embed it in an',
      'ArkTS application.',
    ].join('\n'),
    match: f => f === 'docs/README-ohos.md',
  },
  {
    id: 14,
    subject: 'Add OHOS to continuous integration',
    body: [
      'Add a composite action that fetches the OpenHarmony native SDK (with',
      'caching), hook it into generic.yml, and add harmony-arm64,',
      'harmony-arm32 and harmony-x86_64 build jobs.',
      '',
      'Only harmony-arm64 is marked as a priority job, so pull requests get',
      'one OHOS build rather than three; the other two run on push, which',
      'matches how the Android jobs are configured.',
    ].join('\n'),
    match: f => f.startsWith('.github/'),
    special: 'ci',
  },
];

// ---------------------------------------------------------------------------
function parseArgs(argv) {
  const o = { repo: null, dryRun: false, name: null, email: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--repo') o.repo = argv[++i];
    else if (a === '--dry-run') o.dryRun = true;
    else if (a === '--committer-name') o.name = argv[++i];
    else if (a === '--committer-email') o.email = argv[++i];
    else { console.error(`unknown arg: ${a}`); process.exit(1); }
  }
  if (!o.repo) { console.error('缺少 --repo'); process.exit(1); }
  if (!o.dryRun && (!o.name || !o.email)) {
    console.error('正式运行需要 --committer-name 与 --committer-email');
    process.exit(1);
  }
  return o;
}
const opt = parseArgs(process.argv.slice(2));

const ENV = {
  ...process.env,
  GIT_COMMITTER_NAME: opt.name ?? 'dry-run',
  GIT_COMMITTER_EMAIL: opt.email ?? 'dry-run@invalid',
};

function git(args, { allowFail = false } = {}) {
  const r = spawnSync('git', ['-C', opt.repo, ...args], {
    encoding: 'utf8', env: ENV, maxBuffer: 128 << 20,
  });
  if (r.status !== 0 && !allowFail) {
    throw new Error(`git ${args.join(' ')} → ${r.status}\n${r.stderr}${r.stdout}`);
  }
  return { code: r.status, out: (r.stdout ?? '').replace(/\s+$/, ''), err: (r.stderr ?? '').trim() };
}

// ---------------------------------------------------------------------------
// 0) 前置检查
// ---------------------------------------------------------------------------
console.log('=== 前置检查 ===');
const branch = git(['rev-parse', '--abbrev-ref', 'HEAD']).out;
const head = git(['rev-parse', 'HEAD']).out;
const baseSha = git(['rev-parse', BASE]).out;
const dirty = git(['status', '--porcelain']).out;
console.log(`  分支      : ${branch}`);
console.log(`  HEAD      : ${head.slice(0, 9)}`);
console.log(`  ${BASE.padEnd(10)}: ${baseSha.slice(0, 9)}`);
console.log(`  工作区    : ${dirty ? '⚠️ 有未提交改动' : '干净'}`);
if (dirty) { console.error('工作区不干净，先处理再跑。'); process.exit(1); }
if (head !== baseSha) {
  console.error(`HEAD 必须等于 ${BASE}（当前不等）。若已跑过一次，请先 git reset --hard ${BASE}。`);
  process.exit(1);
}

// ---------------------------------------------------------------------------
// 1) 取权威文件清单并分组，逐一断言
// ---------------------------------------------------------------------------
console.log('\n=== 分组校验 ===');
const nameStatus = git(['diff', '--name-status', `${BASE}...${SRC}`]).out.split('\n').filter(Boolean);
const bad = nameStatus.filter(l => !/^[AM]\t/.test(l));
if (bad.length) {
  console.error('出现非 A/M 的变更类型（本脚本按"取终态"工作，不支持 D/R）:');
  for (const b of bad) console.error('  ' + b);
  process.exit(1);
}
const allFiles = nameStatus.map(l => l.split('\t')[1]);
const ADDED = new Set(nameStatus.filter(l => l.startsWith('A\t')).map(l => l.split('\t')[1]));
console.log(`  净 diff 文件数 : ${allFiles.length}  （新增 ${ADDED.size} / 修改 ${allFiles.length - ADDED.size}）`);

const assign = new Map();      // file -> commit id
const groups = new Map();      // commit id -> [files]
for (const c of COMMITS) groups.set(c.id, []);
const dropped = [];

for (const f of allFiles) {
  if (DROP_FILES.has(f)) { dropped.push(f); continue; }
  const hit = COMMITS.filter(c => c.match(f));
  if (hit.length === 0) {
    console.error(`  ❌ 未归组: ${f}`);
    process.exitCode = 1;
    continue;
  }
  if (hit.length > 1) {
    console.error(`  ❌ 多重归组: ${f} → ${hit.map(h => h.id).join(',')}`);
    process.exitCode = 1;
    continue;
  }
  assign.set(f, hit[0].id);
  groups.get(hit[0].id).push(f);
}
if (process.exitCode) { console.error('分组不干净，终止。'); process.exit(1); }

let sum = 0;
for (const c of COMMITS) {
  const fs_ = groups.get(c.id);
  if (!fs_.length) { console.error(`  ❌ 空分组: #${c.id} ${c.subject}`); process.exit(1); }
  sum += fs_.length;
  const st = git(['diff', '--shortstat', `${BASE}...${SRC}`, '--', ...fs_]).out.replace(/^\s+/, '');
  console.log(`  #${String(c.id).padStart(2)} ${c.subject.padEnd(46)} ${String(fs_.length).padStart(3)} 文件  ${st}`);
}
console.log(`  丢弃 : ${dropped.length ? dropped.join(', ') : '(无)'}`);
console.log(`  合计 : ${sum} + ${dropped.length} = ${sum + dropped.length}  （应等于 ${allFiles.length}）`);
if (sum + dropped.length !== allFiles.length) { console.error('数目不闭合，终止。'); process.exit(1); }

// ---------------------------------------------------------------------------
// 2) 缺陷修复的预演/应用
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// 行尾无感的读写。
// 这个仓库在 Windows 上是 core.autocrlf=true：index 存 LF、工作区是 CRLF
// （`git ls-files --eol` 显示 `i/lf w/crlf`）。所有锚点都按 LF 书写，
// 因此编辑前先把工作区内容归一化成 LF，写回时再还原成原本的行尾 ——
// 否则锚点在正式运行时会 0 命中（预演走的是 `git show`，天然是 LF，掩盖了这个问题）。
// 提交时 git 会把 CRLF 归一化回 LF，所以进入历史的内容始终是 LF。
// ---------------------------------------------------------------------------
function readWT(file) {
  const p = join(opt.repo, file);
  if (!existsSync(p)) throw new Error(`目标文件不存在: ${file}`);
  const raw = readFileSync(p, 'utf8');
  return { path: p, text: raw.replace(/\r\n/g, '\n'), crlf: raw.includes('\r\n') };
}
function writeWT(h, text) {
  writeFileSync(h.path, h.crlf ? text.replace(/\n/g, '\r\n') : text, 'utf8');
}

// ---------------------------------------------------------------------------
// D7-D10 新增文件的行尾/空白规范化
//
// 上游 .editorconfig 对 *.{c,cc,h,java,py,sh,txt} / CMakeLists.txt / cmake/*.cmake 要求
// `insert_final_newline = true` 与 `trim_trailing_whitespace = true`，且整棵树是 LF
// （只有 *.bat / *.rc 明确 crlf）。前人在 Windows/DevEco 上写的文件带着：
//   src/core/ohos/SDL_ohos.c   1020 个 CRLF + 64 行行尾空白
//   src/core/ohos/SDL_ohos.h     40 个 CRLF + 1 行行尾空白
//   SDL_ohosvideo.c 7 / SDL_ohossensor.c 9 / SDL_ohosdialog.c 6 / … 行尾空白
//   SDL_ohosmouse.c、ohos-project 下 20 余个文件缺末尾换行
//   ohos-project/entry/src/main/ets/pages/Index.ets 212 个 CRLF
//
// 贡献规范里"避免整文件重排"的豁免针对**既有代码**；这些是我们新增的文件，
// 按规范写好是本分。因此：
//   - 所有**新增的文本文件**：CRLF → LF、补末尾换行
//   - 其中 .editorconfig 覆盖的类型：额外去掉行尾空白
//   - 二进制文件（png 等）与**被修改的上游既有文件**一律不碰
// ---------------------------------------------------------------------------
// 行尾空白对任何文本文件都没有好处，且 `git diff --check` 会逐条报出来，
// 所以不再按 .editorconfig 的扩展名清单区分（那份清单其实是
// *.{c,cc,cg,cpp,gradle,h,java,m,metal,pl,py,S,sh,txt}，第一版漏了 cpp/cg/gradle/m/metal/pl/S，
// 导致 ohos-project/entry/src/main/cpp/entrypoint.cpp 等仍有 58 处残留），
// 统一对所有新增的**文本**文件去尾空白。
// 二进制判定用 git 自己的结论（numstat 对二进制给 "-\t-"）
const BINARY = new Set(
  git(['diff', '--numstat', `${BASE}...${SRC}`]).out.split('\n')
    .filter(l => l.startsWith('-\t-\t')).map(l => l.split('\t')[2]),
);

function normalizeNewFiles(files, addedSet, { check }) {
  const changed = [];
  for (const f of files) {
    if (!addedSet.has(f)) continue;      // 只碰新增文件
    if (BINARY.has(f)) continue;         // 不碰二进制
    const p = join(opt.repo, f);
    if (!existsSync(p)) continue;
    const raw = readFileSync(p);
    if (raw.includes(0)) continue;       // 兜底：含 NUL 视为二进制
    let t = raw.toString('utf8');
    const before = t;
    t = t.replace(/\r\n/g, '\n').replace(/[ \t]+$/gm, '');
    if (t.length && !t.endsWith('\n')) t += '\n';
    if (t !== before) {
      const what = [];
      if (/\r\n/.test(before)) what.push(`CRLF×${(before.match(/\r\n/g) || []).length}`);
      const ws = (before.replace(/\r\n/g, '\n').match(/[ \t]+$/gm) || []).length;
      if (ws) what.push(`行尾空白×${ws}`);
      if (!before.endsWith('\n')) what.push('末尾换行');
      changed.push(`${f} (${what.join(', ')})`);
      if (!check) writeFileSync(p, t, 'utf8');
    }
  }
  if (changed.length) {
    console.log(`      🔧 D7-D9 规范化 ${changed.length} 个新增文件:`);
    for (const c of changed.slice(0, 6)) console.log(`           ${c}`);
    if (changed.length > 6) console.log(`           … 另 ${changed.length - 6} 个`);
  }
  return changed.length;
}

function applyFixes(c, { check }) {
  for (const fx of c.fixes ?? []) {
    const h = readWT(fx.file);
    const n = h.text.split(fx.from).length - 1;
    if (n !== 1) {
      throw new Error(`fix 锚点匹配 ${n} 次（应为 1）: ${fx.file}\n  why=${fx.why}`);
    }
    if (!check) writeWT(h, h.text.replace(fx.from, fx.to));
    console.log(`      🔧 ${fx.why}`);
  }
}

// CI 组的特殊处理：两个与 upstream 都改过的文件不能取终态
function doCi(files, { check }) {
  const CTP = '.github/workflows/create-test-plan.py';
  const GEN = '.github/workflows/generic.yml';
  const others = files.filter(f => f !== CTP && f !== GEN);

  if (!check && others.length) git(['checkout', SRC, '--', ...others]);

  // generic.yml：三方应用他们那一个 hunk（merge-tree 已验证可自动合并）
  const patch = git(['diff', `${BASE}...${SRC}`, '--', GEN]).out + '\n';
  const pf = join(opt.repo, '.git', 'AMCL_generic_yml.patch');
  writeFileSync(pf, patch, 'utf8');
  const chk = git(['apply', '--3way', '--check', pf], { allowFail: true });
  console.log(`      generic.yml 三方应用 --check → ${chk.code === 0 ? 'OK' : 'FAIL: ' + chk.err}`);
  if (chk.code !== 0) throw new Error('generic.yml 无法三方应用');
  if (!check) git(['apply', '--3way', pf]);

  // create-test-plan.py：在 upstream 当前文本上重写 4 个 hunk（Phase 0.12 定案）
  const h = readWT(CTP);
  let t = h.text;
  const edits = [
    {
      from: '    DJGPP = "djgpp"\n',
      to: '    DJGPP = "djgpp"\n    Harmony = "harmony"\n',
      why: 'SdlPlatform.Harmony',
    },
    {
      from: '    more_hard_deps: bool = False\n',
      to: '    more_hard_deps: bool = False\n    harmony_arch: Optional[str] = None\n',
      why: 'JobSpec.harmony_arch',
    },
    {
      from: '    "djgpp": JobSpec(name="DOS (DJGPP)",',
      to: '__HARMONY_JOBS__    "djgpp": JobSpec(name="DOS (DJGPP)",',
      why: 'JOB_SPECS harmony entries (priority: arm64 only)',
    },
    {
      from: '        case _:\n            raise ValueError(f"Unsupported platform={spec.platform}")',
      to:
        '        case SdlPlatform.Harmony:\n' +
        '            job.cmake_arguments.extend((\n' +
        '                f"-DOHOS_ARCH={spec.harmony_arch}",\n' +
        '                "-DCMAKE_TOOLCHAIN_FILE=/opt/native/build/cmake/ohos.toolchain.cmake",\n' +
        '                "-DCMAKE_PLATFORM_NO_VERSIONED_SONAME=1",\n' +
        '            ))\n' +
        '            job.shared_lib = SharedLibType.SO\n' +
        '            job.static_lib = StaticLibType.A\n' +
        '            job.run_tests = False\n' +
        '            job.test_pkg_config = False\n' +
        '            job.werror = False\n' +
        '        case _:\n            raise ValueError(f"Unsupported platform={spec.platform}")',
      why: 'spec_to_job case SdlPlatform.Harmony',
    },
  ];
  for (const e of edits) {
    const n = t.split(e.from).length - 1;
    if (n !== 1) throw new Error(`create-test-plan.py 锚点匹配 ${n} 次（应为 1）: ${e.why}`);
    t = t.replace(e.from, e.to);
    console.log(`      🔧 rewrite hunk: ${e.why}`);
  }
  // harmony job 行要对齐现有列宽，单独拼
  const jobs =
    '    "harmony-arm64": JobSpec(name="Harmony (Arm64)",                      priority=True,  os=JobOs.UbuntuLatest,      platform=SdlPlatform.Harmony,     artifact="SDL-harmony-arm64",      harmony_arch="arm64-v8a", ),\n' +
    '    "harmony-arm32": JobSpec(name="Harmony (Arm32)",                      priority=False, os=JobOs.UbuntuLatest,      platform=SdlPlatform.Harmony,     artifact="SDL-harmony-arm32",      harmony_arch="armeabi-v7a", ),\n' +
    '    "harmony-x86_64": JobSpec(name="Harmony (x86-64)",                    priority=False, os=JobOs.UbuntuLatest,      platform=SdlPlatform.Harmony,     artifact="SDL-harmony-x86_64",     harmony_arch="x86_64", ),\n';
  t = t.replace('__HARMONY_JOBS__', jobs);
  if (!check) writeWT(h, t);
}

// ---------------------------------------------------------------------------
// 3) 执行
// ---------------------------------------------------------------------------
console.log(opt.dryRun ? '\n=== 预演（不提交） ===' : '\n=== 构建提交序列 ===');

for (const c of COMMITS) {
  const files = groups.get(c.id);
  console.log(`\n  #${c.id} ${c.subject}`);
  try {
    if (c.special === 'ci') {
      doCi(files, { check: opt.dryRun });
      if (!opt.dryRun) normalizeNewFiles(files, ADDED, { check: false });
    } else {
      if (!opt.dryRun) git(['checkout', SRC, '--', ...files]);
      // dry-run 下 fix 锚点校验需要文件内容 → 用 git show 逐个验
      if (opt.dryRun) {
        for (const fx of c.fixes ?? []) {
          const txt = git(['show', `${SRC}:${fx.file}`]).out;
          const n = txt.split(fx.from).length - 1;
          if (n !== 1) throw new Error(`fix 锚点匹配 ${n} 次（应为 1）: ${fx.file} — ${fx.why}`);
          console.log(`      🔧 ${fx.why}`);
        }
      } else {
        // 顺序要紧：先规范化（去 CRLF），再按 LF 锚点做定点修复
        normalizeNewFiles(files, ADDED, { check: false });
        applyFixes(c, { check: false });
      }
    }
  } catch (e) {
    console.error(`  ❌ ${e.message}`);
    if (!opt.dryRun) {
      console.error('  已中止；请 git reset --hard ' + BASE + ' 后重来。');
    }
    process.exit(1);
  }

  if (opt.dryRun) continue;

  git(['add', '-A', '--', ...files]);
  const msg = [
    c.subject,
    '',
    c.body,
    '',
    PROVENANCE,
    '',
    ...(c.co ?? []),
  ].join('\n').replace(/\n{3,}/g, '\n\n');
  const mf = join(opt.repo, '.git', 'AMCL_COMMIT_MSG');
  writeFileSync(mf, msg + '\n', 'utf8');
  git(['commit', '--author', AUTHOR, '-F', mf]);
  console.log(`      → ${git(['rev-parse', '--short', 'HEAD']).out}`);
}

if (opt.dryRun) {
  console.log('\n预演通过：分组闭合、全部 fix 锚点唯一命中、CI 重写锚点唯一命中。');
  console.log('正式运行请加 --committer-name / --committer-email。');
  process.exit(0);
}

// ---------------------------------------------------------------------------
// 4) 事后核对
// ---------------------------------------------------------------------------
console.log('\n=== 事后核对 ===');
console.log(`  新增提交数 : ${git(['rev-list', '--count', `${BASE}..HEAD`]).out}  （应为 ${COMMITS.length}）`);
console.log(`  工作区     : ${git(['status', '--porcelain']).out ? '⚠️ 有残留' : '干净'}`);
console.log('\n  与 vendor-ohos-ref 的剩余差异（应只剩：被丢弃的 D3 文件 + 两个 CI 文件）:');
const rest = git(['diff', '--stat', 'HEAD', SRC]).out;
console.log(rest.split('\n').map(l => '    ' + l).join('\n'));
console.log('\n  提交列表:');
console.log(git(['log', '--format=    %h %an <%ae> :: %s', `${BASE}..HEAD`]).out);
console.log('\n完成。下一步：跑 check-sdl3-abi.mjs 复核闸门，然后推 origin。');
