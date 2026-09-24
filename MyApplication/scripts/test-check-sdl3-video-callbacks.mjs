// scripts/test-check-sdl3-video-callbacks.mjs
//
// check-sdl3-video-callbacks.mjs 的定向自测。
//
// ⚠️ **本门禁此前一个自测都没有**（治理规范 §8.1 要求每道门禁都有）。根因不是懒：
// 它的 200 余行主流程原本是**顶层代码**，`import` 就会去找 SDL 仓库并 `process.exit(1)`
// ⇒ 根本 import 不进来。施工记录 §S9.3 把主流程包进 `main()` 后才有了这份文件。
//
// ⚠️ 真实输入（icculus/SDL 的 `src/video/openharmony`）**不在本仓**，需 `--repo`。
// 所以这里造一棵**最小假 SDL 树**当 fixture —— 这不是将就：
// 一道门禁的自测本来就该用自己控制的输入，而不是依赖一棵会漂的外部树
// （否则上游一改，自测就分不清"门禁坏了"还是"上游变了"）。
//
// 用法：node scripts/test-check-sdl3-video-callbacks.mjs

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  stripComments, deadLineRanges, extractFunctionBody, classifyBody, main,
} from './check-sdl3-video-callbacks.mjs';

let failed = 0;
function check(name, cond, extra) {
  if (cond) console.log(`  ok   ${name}`);
  else { failed += 1; console.error(`  FAIL ${name}${extra ? `\n       ${extra}` : ''}`); }
}

// ── 1. ⭐⭐ 行稳定：本门禁按行号工作，strip 不得塌行 ────────────────────
//
// 这是 §S9 的核心回归钉子。旧实现把多行块注释整段换成**一个空格**，
// 于是 `collectAssignments` 报出的 `file:line` 与源文件对不上。
{
  const src = [
    'static bool OHOS_CreateDevice(void) {',        // 1
    '    /* 这是一段',                                // 2
    '       跨了好几行的',                            // 3
    '       块注释 */',                               // 4
    '    device->CreateSDLWindow = OHOS_CreateWindow;', // 5
    '    return true;',                              // 6
    '}',                                             // 7
  ].join('\n');

  const stripped = stripComments(src);
  check('⭐⭐ 多行块注释不塌行（行数与原文一致）',
    stripped.split('\n').length === src.split('\n').length,
    `${stripped.split('\n').length} vs ${src.split('\n').length}`);

  const lines = stripped.split('\n');
  const hit = lines.findIndex((l) => /device->CreateSDLWindow/.test(l));
  check('⭐⭐ 赋值落在原文的第 5 行（旧实现会报成第 2 行）',
    hit + 1 === 5, `实际 = ${hit + 1}`);

  check('⭐ 注释内容被抹掉（不会被当成真赋值）',
    !stripped.includes('块注释'), JSON.stringify(stripped));

  // 赋值正则以 `^\s*` 起头 —— 原地留白后仍要能匹配（判定不变的证据）。
  const re = /^\s*device->(\w+)\s*=\s*([\w&.\->]+)\s*;/;
  check('⭐ 原地留白后赋值正则仍匹配（判定不变）',
    re.test(lines[4]), JSON.stringify(lines[4]));
}

// ── 2. ⭐ C 词法：字符字面量 '"' 不得开启假字符串 ──────────────────────
//
// 旧实现**完全不跟踪单引号**，而 C 里 `'"'` 合法 ⇒ 那个 `"` 会吞到下一个 `"`。
{
  const src = [
    'static void f(char c) {',
    "    if (c == '\"') { return; }",
    '    device->PumpEvents = OHOS_PumpEvents;',
    '}',
  ].join('\n');
  const stripped = stripComments(src);
  check("⭐⭐ 字符字面量 '\"' 之后的赋值仍可见（失步回归钉子）",
    stripped.includes('device->PumpEvents = OHOS_PumpEvents'),
    JSON.stringify(stripped));
  check('⭐ 行数仍不变', stripped.split('\n').length === src.split('\n').length);
}

// ── 3. `#if 0` 死区识别（本门禁的核心判据之一）────────────────────────
{
  const src = [
    'int a;',                       // 1
    '#if 0',                        // 2
    '    device->Dead = X;',        // 3
    '#endif',                       // 4
    '    device->Live = Y;',        // 5
  ].join('\n');
  const dead = deadLineRanges(stripComments(src));
  check('#if 0 区间被标死（第 3 行）', dead[2] === true, JSON.stringify(dead));
  check('#endif 之后不算死区（第 5 行）', dead[4] === false, JSON.stringify(dead));

  // ⭐ 块注释在 #if 0 之前时，死区行号也不能漂。
  const src2 = [
    '/* a',                         // 1
    '   b',                         // 2
    '   c */',                      // 3
    '#if 0',                        // 4
    '    device->Dead = X;',        // 5
    '#endif',                       // 6
  ].join('\n');
  const dead2 = deadLineRanges(stripComments(src2));
  check('⭐⭐ 块注释在前时 #if 0 死区仍落在第 4–6 行',
    dead2[3] === true && dead2[4] === true && dead2[5] === true && dead2.length === 6,
    JSON.stringify(dead2));

  // ── 钉子（2026-08-27 漏报修复）：#else / #elif 的分支翻转 ──
  //
  // 旧实现的 #else 处理是 `top.dead = !top.dead && false`（恒 false）后又无条件
  // `top.dead = false` ⇒ **任何 #else 分支都被当活**。对 `#if 0 ... #else` 恰好蒙对，
  // 对 `#if 1/#ifdef ... #else` 就把死代码放进 live 文本，空壳会被撑成 REAL。
  // #elif 则完全不识别。以下钉子在修复前应失败。
  {
    const src3 = [
      '#if 1',              // 1
      '    live_call();',   // 2
      '#else',              // 3
      '    dead_call();',   // 4
      '#endif',             // 5
    ].join('\n');
    const d = deadLineRanges(src3);
    check('⭐⭐ 钉子：#if 1 的 #else 分支是死区（旧实现恒当活）',
      d[1] === false && d[3] === true, JSON.stringify(d));
  }
  {
    // 回归保护：#if 0 的 #else 分支必须仍是活的
    const src4 = ['#if 0', '    dead_call();', '#else', '    live_call();', '#endif'].join('\n');
    const d = deadLineRanges(src4);
    check('#if 0 的 #else 分支仍是活的（回归保护）',
      d[1] === true && d[3] === false, JSON.stringify(d));
  }
  {
    // 条件不可字面求值（#ifdef）⇒ 两个分支都保守当活：把活代码当死会误杀真实现，
    // 比漏标死区更糟，所以"不确定就当活"是本函数的安全方向。
    const src5 = ['#ifdef FOO', '    a();', '#else', '    b();', '#endif'].join('\n');
    const d = deadLineRanges(src5);
    check('⭐ #ifdef 的 #else 保守当活（不可求值不误杀）',
      d[1] === false && d[3] === false, JSON.stringify(d));
  }
  {
    const src6 = [
      '#if 0',      // 1
      '    a();',   // 2
      '#elif 1',    // 3
      '    b();',   // 4
      '#elif 1',    // 5
      '    c();',   // 6
      '#else',      // 7
      '    d();',   // 8
      '#endif',     // 9
    ].join('\n');
    const d = deadLineRanges(src6);
    check('⭐⭐ 钉子：#elif 1 接管 #if 0 的死组（旧实现完全不识别 #elif）',
      d[1] === true && d[3] === false, JSON.stringify(d));
    check('⭐ 钉子：本组已 taken 后，第二个 #elif 1 与 #else 都是死区',
      d[5] === true && d[7] === true, JSON.stringify(d));
  }
  {
    const src7 = ['#if 1', '    a();', '#elif 0', '    b();', '#endif'].join('\n');
    const d = deadLineRanges(src7);
    check('⭐ 钉子：#elif 0 字面为假，分支恒死', d[3] === true, JSON.stringify(d));
  }
}

// ── 4. 函数体抽取与空壳分类 ────────────────────────────────────────────
{
  const real = [
    'static bool OHOS_SetWindowFullscreen(SDL_VideoDevice *_this, SDL_Window *w) {',
    '    DoSomething(w);',
    '    return SDL_SetWindowSize(w, 1, 2);',
    '}',
  ].join('\n');
  const got = extractFunctionBody(real, 'OHOS_SetWindowFullscreen');
  check('抽到函数体', got !== null && got.body.includes('DoSomething'));
  check('⭐ lineNo 取自 raw 源码（本来就是对的，不受 strip 影响）',
    got !== null && got.lineNo === 1, `${got && got.lineNo}`);
  check('实体实现被判 REAL', got !== null && classifyBody(got.body).kind === 'REAL',
    got ? classifyBody(got.body).kind : 'null');

  const stub = 'static void OHOS_PumpEvents(SDL_VideoDevice *_this) {\n}';
  const gotStub = extractFunctionBody(stub, 'OHOS_PumpEvents');
  check('空函数体被判为非 REAL',
    gotStub !== null && classifyBody(gotStub.body).kind !== 'REAL',
    gotStub ? classifyBody(gotStub.body).kind : 'null');

  // ── 钉子（2026-08-27 漏报修复）：空壳伪装术 ──
  //
  // ① `(void)param;` 消参语句是纯编译期噪音（压 -Wunused-parameter），却会把
  //    `{ (void)enabled; return true; }` 的 compact 撑到不匹配任何空壳模式 ⇒ 判 REAL。
  {
    const src = [
      'static bool OHOS_SetRelativeMouseMode(bool enabled) {',
      '    (void)enabled;',
      '    return true;',
      '}',
    ].join('\n');
    const got = extractFunctionBody(src, 'OHOS_SetRelativeMouseMode');
    check('⭐⭐ 钉子：{ (void)enabled; return true; } 判 STUB（旧实现判 REAL）',
      got !== null && classifyBody(got.body).kind === 'STUB',
      got ? classifyBody(got.body).kind : 'null');
  }
  // ② 只有消参语句、连 return 都没有 ⇒ 与空函数体同罪
  check('⭐ 钉子：{ (void)a; (void)b; } 判为非 REAL',
    classifyBody('\n    (void)a;\n    (void)b;\n').kind !== 'REAL',
    classifyBody('\n    (void)a;\n    (void)b;\n').kind);
  // ③ 单一大写常量 return（return SDL_FULLSCREEN_SUCCEEDED; 之类）——
  //    常量名再长也改变不了"什么都不做直接报成功"的事实。
  check('⭐⭐ 钉子：return SDL_FULLSCREEN_SUCCEEDED; 判 STUB（旧实现判 REAL）',
    classifyBody('\n    return SDL_FULLSCREEN_SUCCEEDED;\n').kind === 'STUB',
    classifyBody('\n    return SDL_FULLSCREEN_SUCCEEDED;\n').kind);
  // ④ 反向保护：消参 + 真语句仍是 REAL（剥噪音不得误杀）
  check('(void) 消参 + 真语句仍判 REAL（反向保护）',
    classifyBody('\n    (void)enabled;\n    HostSetPointerGrab(enabled);\n    return true;\n').kind === 'REAL',
    classifyBody('\n    (void)enabled;\n    HostSetPointerGrab(enabled);\n    return true;\n').kind);
  // ⑤ `#if 1 ... #else <填充> #endif`：else 死区里的代码不得把空壳撑成 REAL
  //    （与上面 deadLineRanges 钉子同源，但这里验证的是 classifyBody 全链路）。
  {
    const body = [
      '',
      '#if 1',
      '    return true;',
      '#else',
      '    HostDoRealWork(a, b, c);',
      '    HostDoMoreRealWork(d, e, f);',
      '    HostFinishRealWork(g);',
      '#endif',
      '',
    ].join('\n');
    check('⭐⭐ 钉子：#else 死区里的填充不得把空壳撑成 REAL（判 STUB）',
      classifyBody(body).kind === 'STUB', classifyBody(body).kind);
  }
}

// ── 5. ⭐ 端到端 helper：最小假 SDL 树跑 main()，捕获输出与退出码 ──
//
// files: { 'src/video/...' 相对 repo 根的路径: 文件内容 }。
// openharmony / android 两个目录总是先建好（android 缺文件时 main 会跳过对比段）。
// main() 从顶部 import 拿（被 import 时静默，见门禁尾部守卫），模拟 `--repo <fixture>`。
function runGate(files) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'amcl-svc-'));
  fs.mkdirSync(path.join(tmp, 'src', 'video', 'openharmony'), { recursive: true });
  fs.mkdirSync(path.join(tmp, 'src', 'video', 'android'), { recursive: true });
  for (const [rel, content] of Object.entries(files)) {
    const full = path.join(tmp, ...rel.split('/'));
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, content);
  }
  const out = [];
  const origLog = console.log;
  const origErr = console.error;
  const origExit = process.exit;
  let exitCode = null;
  console.log = (...a) => out.push(a.join(' '));
  console.error = (...a) => out.push(a.join(' '));
  process.exit = (c) => { exitCode = c; throw new Error('__EXIT__'); };
  try {
    main(['node', 'x', '--repo', tmp]);
  } catch (e) {
    if (!/__EXIT__/.test(e.message)) out.push('THREW: ' + e.message);
  } finally {
    console.log = origLog;
    console.error = origErr;
    process.exit = origExit;
    fs.rmSync(tmp, { recursive: true, force: true });
  }
  return { text: out.join('\n'), exitCode };
}

// 全绿后端源码生成器：REQUIRED_VIDEO / REQUIRED_MOUSE 里所有 missing:'needed' 项
// 都接线且给实体实现（fallback / unsupported 项刻意不接线 —— 那才是本后端的正确姿态）。
// overrides 用来把某个实现替换成空壳，extraTop 用来在文件头部塞注释/死代码。
// ⚠️ 实体实现全部用 Host* 假函数、刻意不含 SDL_Send*，这样推送模型判定完全由
// 各用例自己注入的证据决定，互不串扰。
const GREEN_IMPLS = {
  OHOS_PumpEvents: [
    'static void OHOS_PumpEvents(SDL_VideoDevice *_this) {',
    '    HostDrainEventRing(_this);',
    '    HostDispatchLifecycle(_this);',
    '}',
  ],
  OHOS_SetWindowFullscreen: [
    'static bool OHOS_SetWindowFullscreen(SDL_VideoDevice *_this, SDL_Window *w) {',
    '    HostSyncGeometry(w);',
    '    HostNotifyFullscreenChange(w);',
    '    return SDL_FULLSCREEN_SUCCEEDED;',
    '}',
  ],
  OHOS_GetDisplayModes: [
    'static bool OHOS_GetDisplayModes(SDL_VideoDevice *_this, SDL_VideoDisplay *display) {',
    '    HostFillDesktopMode(display);',
    '    HostAppendFullscreenMode(display);',
    '    return true;',
    '}',
  ],
  OHOS_SetRelativeMouseMode: [
    'static bool OHOS_SetRelativeMouseMode(bool enabled) {',
    '    HostSetPointerGrab(enabled);',
    '    return true;',
    '}',
  ],
  OHOS_CreateCursor: [
    'static SDL_Cursor *OHOS_CreateCursor(SDL_Surface *surface, int hot_x, int hot_y) {',
    '    SDL_Cursor *cur = HostAllocCursor(surface, hot_x, hot_y);',
    '    return cur;',
    '}',
  ],
  OHOS_ShowCursor: [
    'static bool OHOS_ShowCursor(SDL_Cursor *cursor) {',
    '    HostSetCursorVisible(cursor);',
    '    return true;',
    '}',
  ],
};
function makeBackend(overrides = {}, extraTop = []) {
  return [
    '#include "SDL_internal.h"',
    ...extraTop,
    'static bool OHOS_CreateDevice(SDL_VideoDevice *device, SDL_Mouse *mouse) {',
    '    device->PumpEvents = OHOS_PumpEvents;',
    '    device->SetWindowFullscreen = OHOS_SetWindowFullscreen;',
    '    device->GetDisplayModes = OHOS_GetDisplayModes;',
    '    mouse->SetRelativeMouseMode = OHOS_SetRelativeMouseMode;',
    '    mouse->CreateCursor = OHOS_CreateCursor;',
    '    mouse->ShowCursor = OHOS_ShowCursor;',
    '    return true;',
    '}',
    ...Object.entries(GREEN_IMPLS).flatMap(([fn, impl]) => overrides[fn] ?? impl),
    '',
  ].join('\n');
}

// ── 5a. ⭐ 端到端：行稳定 + 主流程能跑完 + 退出码断言 ──
{
  // 故意在赋值前放一段多行块注释：若 strip 塌行，报出的 file:line 就会偏。
  const { text, exitCode } = runGate({
    'src/video/openharmony/SDL_openharmonyvideo.c': [
      '#include "x.h"',                                     // 1
      '/* 多行',                                             // 2
      '   注释 */',                                          // 3
      'static bool OHOS_CreateDevice(SDL_VideoDevice *device) {', // 4
      '    device->PumpEvents = OHOS_PumpEvents;',           // 5
      '#if 0',                                               // 6
      '    device->SetWindowFullscreen = OHOS_SetWindowFullscreen;', // 7
      '#endif',                                              // 8
      '    return true;',                                    // 9
      '}',                                                   // 10
      'static void OHOS_PumpEvents(SDL_VideoDevice *_this) {',// 11
      '    SDL_SendMouseMotion(0, NULL, 0, 0, 1.0f, 2.0f);', // 12
      '}',                                                   // 13
      '',
    ].join('\n'),
  });

  check('⭐ main() 能在假树上跑完（包进 main 没改坏主流程）',
    text.includes('必需 video 回调'), text.slice(0, 400));
  check('⭐⭐ #if 0 里的赋值报出的行号是原文第 7 行（行稳定的端到端证据）',
    /SDL_openharmonyvideo\.c:7\b/.test(text),
    (text.match(/@ SDL_openharmonyvideo\.c:\d+/g) ?? ['(没打印 file:line)']).join(' | '));
  // 钉子（2026-08-27）：此前 exitCode 被捕获却从不断言 —— 门禁把 fixture 判成什么
  // 退出码都能"过测"。本 fixture 有多个 missing:'needed' 项未接线，必须 exit 1。
  check('⭐⭐ 钉子：含未接线 needed 项的 fixture 退出码必须是 1（此前捕获了却不断言）',
    exitCode === 1, 'exit=' + exitCode);
}

// ── 5b. ⭐ 端到端：全绿 fixture ⇒ 退出码 0（钉子的另一半：门禁不许乱咬）──
{
  const { text, exitCode } = runGate({
    'src/video/openharmony/SDL_openharmonyvideo.c': makeBackend(),
  });
  check('⭐⭐ 钉子：needed 项全部接线且实体 ⇒ 退出码 0',
    exitCode === 0, 'exit=' + exitCode + '\n' + text.slice(-500));
  check('⭐ 全绿 fixture 报告无任何硬失败标记', !text.includes('✗'),
    (text.match(/^.*✗.*$/gm) ?? []).join(' | '));
}

// ── 5c. ⭐ 端到端钉子：needed 项接成 `return true;` 空壳 ⇒ exit 1 ──
//
// 旧实现里 needed 项的空壳只走 `△ 空壳` softWarn ⇒ 退出码 0，与文件头
// 「退出码 0 = 必需项全部接线且非空壳」直接矛盾（漏报）。修复前本块应失败。
{
  const { text, exitCode } = runGate({
    'src/video/openharmony/SDL_openharmonyvideo.c': makeBackend({
      OHOS_SetWindowFullscreen: [
        'static bool OHOS_SetWindowFullscreen(SDL_VideoDevice *_this, SDL_Window *w) {',
        '    return true;',
        '}',
      ],
    }),
  });
  check('⭐⭐ 钉子：needed 项接成 return true; 空壳 ⇒ exit 1（旧实现软警告放行）',
    exitCode === 1, 'exit=' + exitCode);
  check('⭐ 报告以"✗ 空壳(必须实体)"点名该项',
    /✗ 空壳\(必须实体\)\s*SetWindowFullscreen/.test(text),
    (text.match(/^.*SetWindowFullscreen.*$/gm) ?? []).join(' | '));
}

// ── 5d. ⭐ 端到端钉子：needed 项接成 { (void)enabled; return true; } ⇒ exit 1 ──
//
// 叠加两个旧缺陷：consumeParam 消参把空壳撑成 REAL（classifyBody），
// REAL 之外 needed 项又只 softWarn（checkRequired）。修复前本块应失败。
{
  const { exitCode } = runGate({
    'src/video/openharmony/SDL_openharmonyvideo.c': makeBackend({
      OHOS_SetRelativeMouseMode: [
        'static bool OHOS_SetRelativeMouseMode(bool enabled) {',
        '    (void)enabled;',
        '    return true;',
        '}',
      ],
    }),
  });
  check('⭐⭐ 钉子：needed 项接成 { (void)enabled; return true; } ⇒ exit 1（旧实现判 REAL 全绿放行）',
    exitCode === 1, 'exit=' + exitCode);
}

// ── 5e. ⭐ 端到端钉子：SDL_Send* 只出现在注释 / #if 0 里 ⇒ 不得判为推送模型 ──
//
// 旧 countReferences 数的是未剥注释、未滤死区的原文：
//   ① 注释里的 SDL_SendMouseMotion 撑起 pushModel=true ⇒ PumpEvents 空壳被降成软警告；
//   ② 注释里的 SDL_SendKeyboardKey 让文件级缺口误报「已在 events.c 内实现」。
// 修复前本块三条断言应全失败。
{
  const { text, exitCode } = runGate({
    'src/video/openharmony/SDL_openharmonyvideo.c': makeBackend({
      OHOS_PumpEvents: [
        '/* TODO: 事件注入还没接。Android 后端是推送模型：',
        '   SDL_SendMouseMotion / SDL_SendTouch / SDL_SendKeyboardKey 都在回调里发。 */',
        'static void OHOS_PumpEvents(SDL_VideoDevice *_this) {',
        '}',
      ],
    }, [
      '#if 0',
      'static void NotCompiledYet(void) {',
      '    SDL_SendWindowEvent(NULL, SDL_EVENT_WINDOW_SHOWN, 0, 0);',
      '}',
      '#endif',
    ]),
    // android 侧放一个 keyboard 后端文件，触发文件级缺口对 keyboard 模块的判定
    'src/video/android/SDL_androidkeyboard.c': 'int Android_Keyboard_Stub(void) { return 1; }\n',
  });
  check('⭐⭐ 钉子：SDL_Send* 仅在注释/#if 0 里 ⇒ 判拉取模型（旧实现数原文误判推送）',
    text.includes('事件模型: 拉取'),
    (text.match(/^事件模型.*$/m) ?? ['(没打印事件模型)']).join(''));
  check('⭐⭐ 钉子：拉取模型 + PumpEvents 空壳 ⇒ exit 1（旧实现降成软警告放行）',
    exitCode === 1, 'exit=' + exitCode);
  check('⭐ 钉子：SDL_SendKeyboardKey 仅在注释里 ⇒ keyboard 模块仍报"整体缺失"',
    /SDL_androidkeyboard\.c\s*整体缺失/.test(text),
    (text.match(/^.*SDL_androidkeyboard.*$/gm) ?? ['(文件级段没提 keyboard)']).join(' | '));
}

// ── 5f. ⭐ 端到端钉子：trivialOk 的 needed 项（ShowCursor）空壳 ⇒ 不算失败 ──
//
// OHOS 无系统光标，可见性由宿主 cursor 管线拥有 —— ShowCursor 的"空壳"就是契约
// 本身（清单处 trivialOk 注释）。豁免必须显式声明：同样是 needed 的 CreateCursor
// 没有 trivialOk，空壳仍必须硬失败（防止豁免语义悄悄扩散）。
{
  const { text, exitCode } = runGate({
    'src/video/openharmony/SDL_openharmonyvideo.c': makeBackend({
      OHOS_ShowCursor: [
        'static bool OHOS_ShowCursor(SDL_Cursor *cursor) {',
        '    return true;',
        '}',
      ],
    }),
  });
  check('⭐⭐ 钉子：trivialOk 项（ShowCursor）接成 return true; 空壳 ⇒ exit 0',
    exitCode === 0, 'exit=' + exitCode + '\n' + text.slice(-500));
  check('⭐ 报告以"契约空壳(设计)"标注而不是吞掉',
    /契约空壳\(设计\)\s*ShowCursor/.test(text),
    (text.match(/^.*ShowCursor.*$/gm) ?? []).join(' | '));
}
{
  const { exitCode } = runGate({
    'src/video/openharmony/SDL_openharmonyvideo.c': makeBackend({
      OHOS_CreateCursor: [
        'static SDL_Cursor *OHOS_CreateCursor(SDL_Surface *surface, int hot_x, int hot_y) {',
        '    return 0;',
        '}',
      ],
    }),
  });
  check('⭐⭐ 钉子：无 trivialOk 的 needed 项（CreateCursor）空壳仍 ⇒ exit 1（豁免不扩散）',
    exitCode === 1, 'exit=' + exitCode);
}

console.log('');
if (failed > 0) {
  console.error(`test-check-sdl3-video-callbacks: ${failed} failure(s)`);
  process.exit(1);
}
console.log('test-check-sdl3-video-callbacks: all checks passed');
