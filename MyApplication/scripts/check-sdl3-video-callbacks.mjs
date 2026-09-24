#!/usr/bin/env node
// check-sdl3-video-callbacks.mjs — OHOS video/mouse 后端回调接线核对
// （SDL3_MIGRATION_PLAN.md Phase 2 关卡 3）
//
// ============================================================================
// 为什么需要这个脚本：「能编译 + 能加载 + 能建窗口」全绿，功能仍可能大面积缺失
// ============================================================================
// SDL 核心调用后端能力的方式是**函数指针判空**：
//
//     if (_this->SetWindowTitle) {          // SDL_video.c 里到处是这个形状
//         _this->SetWindowTitle(_this, window);
//     }
//
// 也就是说，没接线的回调**不报错、不崩溃、不打日志 —— 功能直接消失**。
// 这正是最难查的一类问题：MC 会跑起来，但改窗口标题没反应、相对鼠标模式不生效、
// 全屏切换无声失败，而日志里一片干净。
//
// 比"没接线"更隐蔽的是**接了线但实现是空壳**：
//
//     static void OPENHARMONY_MinimizeWindow(SDL_VideoDevice *_this, SDL_Window *w)
//     {
//     #if 0
//         ...真正的实现...
//     #endif
//     }
//
// 从 `device->MinimizeWindow = ...` 看是"已接线"，判空能过，调用也不崩，
// 但什么都不会发生。所以本脚本查两层：**接线** + **实现是否为空壳**。
//
// ============================================================================
// 必需清单的来源（不是我拍的）
// ============================================================================
// REQUIRED_VIDEO / REQUIRED_MOUSE 两张表来自 SDL3_MIGRATION_PLAN.md §Phase 2
// 的验收清单，那份清单是从 **MC 实际触碰的 35 个 SDLVideo 成员**机械推导出来的
// （推导过程见计划 §2.6 常量池全量清点）。这里硬编码是因为推导输入是 MC 的
// 字节码分析结论、已在计划里定案；脚本只负责核对，不重新推导。
//
// 而第二、三段（Android 平价对比、文件级缺口）**完全是机械对比**，不依赖任何
// 手写清单 —— Android 后端是上游最完整的移动端实现，它接了而 OHOS 没接的，
// 就是候选缺口。这一段的价值在于能发现必需清单之外的遗漏。
//
// 用法：
//   node scripts/check-sdl3-video-callbacks.mjs [--repo <SDL 仓库或 worktree>]
// 退出码：0 = needed 项全部接线且非空壳；1 = 有缺失/空壳；2 = 用法或路径错误
//（fallback / unsupported 项不要求接线，空壳也只算软警告，理由见「判据大修」）
//
// ============================================================================
// 为什么本脚本**不进 CI 的执行环节**（只在 CI 里做存在性检查）
// ============================================================================
// 两个原因：
//   ① 它需要 SDL 源码树才能跑（--repo 指向开发仓或 worktree），而 CI runner 上
//      没有那份源码；为它单独 clone 一个 SDL 仓库不划算。
//   ② 更重要：它现在的正常结果就是 FAIL（Phase 2 未完工，15 项硬失败）。
//      把一个"预期为红"的检查放进 CI 只会训练大家忽略红灯。
// ⇒ 定位：**开发期的进度追踪工具**，不是回归闸门。等 Phase 2 补齐到全绿之后，
//   再考虑接入 CI 当防回退闸门（那时它的语义才是"不许退步"）。
//   与 check-sdl3-abi.mjs / check-sdl3-surface.mjs 的定位区别正在这里 ——
//   那两个从第一天起就应该是绿的，所以它们进了 CI。

import fs from 'node:fs';
import path from 'node:path';

// 词法前置只允许有一份实现（治理规范 §8.2.1）。本门禁按行号工作，
// 依赖它"逐字符换空格、换行保留"的偏移契约，理由见下面 stripComments 的注释。
import { stripComments as stripCommentsShared } from './lib/source-noise.mjs';

// ---------------------------------------------------------------------------
// 必需清单（来源见上方注释：计划 §Phase 2）
// ---------------------------------------------------------------------------
// ⚠️⚠️ 判据大修（2026-08-02，实测 SDL_video.c 后改）
//
// 本脚本第一版统一断言「未接线 ⇒ SDL 判空后静默跳过 ⇒ 功能消失」。**这个前提是错的**，
// 照它施工会把 10 个不该动的回调"补"出来，而且其中至少一个会引入真 bug。
// 逐个查 SDL_video.c 的调用点后，缺失行为分三类：
//
//   ① FALLBACK —— SDL 有合理回退，不接线是安全的：
//        ShowWindow(3435)            → 自动 SDL_SetMouseFocus + SDL_SetKeyboardFocus
//                                      并照常发 SDL_EVENT_WINDOW_SHOWN。
//                                      ⚠️ 接线反而危险：自己实现却忘了设焦点，
//                                      窗口会没有键盘焦点（游戏直接收不到按键）。
//        GetWindowSizeInPixels(3320) → 回退 SDL_GetWindowSize × display pixel density
//        SyncWindow(3602)            → 回退 return true（我们没有异步窗口操作，正确）
//
//   ② UNSUPPORTED —— SDL 自己就返回不支持，不接线**才是诚实的**：
//        SetWindowSize(3226) / SetWindowIcon(2995) / SetWindowPosition(3069)
//        SetWindowMinimumSize(3358) / SetWindowMaximumSize(3398)
//        这几个如果我们"实现"了，就必须假装改了尺寸/位置 —— 那才是制造假成功。
//        窗口尺寸由系统（嵌入时由宿主）决定，后端无权改。
//
//   ③ CONDITIONAL —— 缺失即该能力不存在，要看是否真影响调用方：
//        GetDisplayModes(1225)   → 只在 display 尚无 fullscreen mode 时调用。
//                                  而 SDL_AddBasicVideoDisplay(841-850) 只填 desktop_mode，
//                                  所以不接线 ⇒ SDL_GetFullscreenDisplayModes() 返回空列表。
//                                  **这是唯一值得实现的一项**，已实现。
//        SetDisplayMode(1548)    → 跳过；系统拥有显示模式，本就不该由后端改。
//        Start/StopTextInput(5829/5852) → 跳过；文本由宿主注入（见 C3.1），不走这条。
//
// ⇒ 所以判据改为：只有 kind==='silent' 且确实影响功能的才算硬失败；
//   FALLBACK / UNSUPPORTED / 已论证的 CONDITIONAL 一律不算，并把理由打进报告，
//   免得下一个人（或下一个审查工具）再把它们当成待办。
//
// ⚠️ 关于 PumpEvents 的判据修正（2026-08-01 实测后改）：
// 计划原文写「PumpEvents 必须是实体，否则所有输入和窗口事件都收不到」——
// 这条**对 OHOS 后端不成立**，照搬会报出一个假的硬失败。实测两件事：
//   ① OHOS 后端是**推送模型**：XComponent 的 native 回调直接调
//      SDL_SendTouch / SDL_SendTouchMotion / SDL_SendMouseButton /
//      SDL_SendMouseMotion / SDL_SendWindowEvent（events.c:120,122,171,181 +
//      window.c:191），事件直接进 SDL 队列，SDL_PollEvent 取得到，
//      **完全不经过 PumpEvents**。
//   ② Android 的 Android_PumpEvents 干的也不是收输入，而是抽
//      **生命周期事件**（pause / resume / destroy，见 SDL_androidevents.c:214）；
//      Android 的输入同样是 JNI 回调推送的。
// ⇒ 所以 OHOS 的 PumpEvents 为空，真实后果是「应用切后台/回前台/被销毁这类
//   生命周期事件不处理」，不是「输入失效」。降为软警告，并在报告里写清后果，
//   由 pushModel 自动判定（后端存在 SDL_Send* 注入即视为推送模型）。
// missing 字段 = 后端不接线时 SDL 核心的实际行为，取值：
//   'fallback'    有合理回退，不接线安全（且可能比乱实现更安全）
//   'unsupported' SDL 自己返回不支持，不接线即诚实
//   'needed'      缺失确实丢功能，必须接线
//   'silent'      判空后静默跳过且无补偿 —— 真缺口
// note 字段会原样打进报告，保证"为什么不补"这个判断不会丢失。
const REQUIRED_VIDEO = [
  { name: 'PumpEvents', missing: 'needed', realUnlessPushModel: true,
    note: '推送模型下空实现只丢生命周期事件，不丢输入' },
  { name: 'ShowWindow', missing: 'fallback',
    note: 'SDL_video.c:3435 回退设 mouse/keyboard focus 并发 SHOWN；接线若忘设焦点会丢键盘输入' },
  { name: 'SetWindowTitle', missing: 'unsupported',
    note: 'OHOS 应用无标题栏可显示；返回 void，无法报错' },
  { name: 'SetWindowIcon', missing: 'unsupported',
    note: 'SDL_video.c:2995 直接 return SDL_Unsupported()' },
  { name: 'SetWindowSize', missing: 'unsupported',
    note: 'SDL_video.c:3226 return SDL_Unsupported()；尺寸由系统/宿主决定，实现就得撒谎' },
  { name: 'SetWindowPosition', missing: 'unsupported',
    note: 'SDL_video.c:3069 落到 SDL_Unsupported()' },
  { name: 'SetWindowMinimumSize', missing: 'unsupported',
    note: 'SDL_video.c:3358 跳过后仍走 SDL_SetWindowSize → unsupported' },
  { name: 'SetWindowMaximumSize', missing: 'unsupported',
    note: 'SDL_video.c:3398 同上' },
  { name: 'SetWindowFullscreen', missing: 'needed',
    note: '已接线；返回 SUCCEEDED 是诚实的（窗口恒等于宿主 surface），FAILED 会让核心 goto error' },
  { name: 'SyncWindow', missing: 'fallback',
    note: 'SDL_video.c:3602 回退 return true；本后端无异步窗口操作' },
  { name: 'GetDisplayModes', missing: 'needed',
    note: 'SDL_AddBasicVideoDisplay 只填 desktop_mode，不接线则 fullscreen mode 列表为空' },
  { name: 'SetDisplayMode', missing: 'unsupported',
    note: 'SDL_video.c:1548 跳过；系统拥有显示模式' },
  { name: 'StartTextInput', missing: 'unsupported',
    note: 'SDL_video.c:5829 跳过；文本由宿主注入（C3.1），不走后端 IME' },
  // 2026-08-02 修正：清单里原写的 `SetTextInputArea` 是**公开 API 名**，
  // SDL_VideoDevice 上的字段实际叫 `UpdateTextInputArea`（SDL_sysvideo.h:369）。
  // 名字抄错的后果是脚本永远查不到它、却报"未接线"。
  // 缺失行为：SDL_SetTextInputArea(SDL_video.c:5867) 会先把矩形存进
  // window->text_input_rect，然后 `if (_this->UpdateTextInputArea)` 判空跳过并
  // return true ⇒ 调用方不会拿到失败。MC 确实会调它（BlazeSDL 的
  // SDLUtil.updateTextInputArea 走 SDLKeyboard.SDL_SetTextInputArea），
  // 但候选框定位对我们无意义：软键盘与候选框由宿主 UI 负责（§C3.1）。
  { name: 'UpdateTextInputArea', missing: 'fallback',
    note: 'SDL_video.c:5878 判空跳过并 return true；矩形已存入 window->text_input_rect，宿主 IME 可自行读取' },
  { name: 'GetWindowSizeInPixels', missing: 'fallback',
    note: 'SDL_video.c:3320 回退 SDL_GetWindowSize × pixel density' },
];

// mouse driver 上的回调（挂在 SDL_Mouse 而不是 SDL_VideoDevice 上，
// 所以即使 video 后端全绿，这几项仍可能整体缺失）。
const REQUIRED_MOUSE = [
  { name: 'SetRelativeMouseMode', missing: 'needed',
    note: '第一人称视角靠它；必须落到宿主的 grab 状态（单一权威写点）' },
  { name: 'WarpMouse', missing: 'fallback',
    note: 'SDL_mouse.c 回退 SDL_PrivateSendMouseMotion；接线是为了让宿主的 look 基准对齐' },
  { name: 'CreateCursor', missing: 'needed', note: '鼠标子系统需要 cursor 对象存在' },
  // trivialOk：这一项的"空壳"就是契约本身 —— OHOS 无系统光标，可见性由宿主
  // cursor 管线（PumpHostCursor / SetGrabState）单向拥有，SDL 侧唯一正确行为
  // 是接受调用并返回成功。豁免必须逐项显式声明并写明理由；没有 trivialOk 的
  // needed 项接成空壳仍是硬失败（防遗忘属性不变）。
  { name: 'ShowCursor', missing: 'needed', trivialOk: true,
    note: '同上；OHOS 无系统光标，可见性由宿主决定' },
];

// ---------------------------------------------------------------------------
// 参数
// ---------------------------------------------------------------------------
function parseArgs(argv) {
  let repo = path.resolve('..', '.tmp-sdl3', 'icculus-wt');
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === '--repo' && i + 1 < argv.length) {
      repo = path.resolve(argv[i + 1]);
      i++;
    }
  }
  return { repo };
}

// ---------------------------------------------------------------------------
// C 源码分析工具
// ---------------------------------------------------------------------------

/**
 * 去掉块注释和行注释，避免注释里的 `device->X =` 被当成真赋值。
 *
 * ⭐ **2026-08-27：实现搬到 `lib/source-noise.mjs`（`lang:'c'`），修两处缺陷。**
 *
 * 本门禁**按行号工作**：`deadLineRanges()` 在 strip 后的文本上逐行匹配 `#if 0`，
 * `collectAssignments()` 取 `lines[i]` 并把 `i + 1` 当 `file:line` 报给人看
 * （输出里 5 处）。所以它对 strip 的**行稳定性**有硬依赖。
 *
 * | 旧实现 | 后果 |
 * |---|---|
 * | 多行块注释整段换成**一个空格**，注释里的换行全部丢掉 | 行号塌缩 ⇒ **报出的 `file:line` 与源文件对不上**。SDL 源码里 `/** … *\/` 极多，几乎每处命中都偏 |
 * | **完全不跟踪单引号** | C 里 `'"'` 是合法字符字面量，那个 `"` 会开启一段假字符串并吞到下一个 `"` ⇒ 失步（§S6.2 同族） |
 *
 * 新实现逐字符换空格、换行原样保留 ⇒ 行号与列都不漂；`lang:'c'` 同时把 `'` 按
 * 字符字面量处理，并**关掉正则字面量识别**（C 里 `/` 永远是除号，见 source-noise §LANGS）。
 *
 * ⚠️ **判定不变**：赋值正则以 `^\s*` 起头，块注释无论塌成一个空格还是原地留白，
 * `^\s*` 都照样匹配 —— 变的只是命中落在第几行。故本次是"证据坐标修正"，
 * 不是"判据修正"，不该当成一次行为变更来解读。
 */
export function stripComments(src) {
  return stripCommentsShared(src, { lang: 'c' });
}

/**
 * 标出源码中被条件编译排除掉的行区间。
 *
 * 判定能力（2026-08-27 扩展，此前只认 `#if 0`）：
 *   · `#if 0` / `#if 1` 按字面求值；其他 `#if` / `#ifdef` / `#ifndef` 无法字面求值。
 *   · `#elif 0` / `#elif 1` 做同等字面判定；本组若已出现过字面为活的分支，
 *     后续 `#elif` / `#else` 一律死（预处理器一组只编译一个分支）。
 *   · `#else`：本组已有活分支 ⇒ 死；至今全是字面死分支 ⇒ 活。
 *   · 条件不可求值时**宁可当活**（含它之后的 #elif/#else）：把死代码当活最多漏报空壳，
 *     把活代码当死会直接误杀真实现 —— 后者是更贵的错误。
 * 仍不做完整的预处理器求值（宏展开/表达式），那是另一个量级的工程，且当前无必要。
 *
 * ⚠️ 旧实现的 `#else` 处理是坏的：`top.dead = !top.dead && false` 恒 false 后又无条件
 * `top.dead = false` ⇒ 任何 `#else` 分支都被当活。对 `#if 0 ... #else` 恰好蒙对，
 * 对 `#if 1`/`#ifdef` 的 `#else` 死分支则会把死代码放进 live 文本，空壳被撑成 REAL
 * （自测钉子：`#else 死区里的填充不得把空壳撑成 REAL`）。`#elif` 此前完全不识别，
 * `#if 0 ... #elif 1` 的活分支会被整组标死。
 *
 * 预处理指令行本身（#if/#elif/#else/#endif，无论活死）一律标 dead：它们不是可执行
 * 代码，留在 live 文本里会污染 classifyBody 的空壳匹配（`#if 1` + `return true;`
 * 拼出来就不再是"只有 return"）。
 */
export function deadLineRanges(src) {
  const lines = src.split('\n');
  const dead = new Array(lines.length).fill(false);
  // 每个 #if..#endif 组一帧：
  //   dead  — 当前分支是否死
  //   state — 'taken'   本组已出现字面判定为活的分支 ⇒ 后续 #elif/#else 全死
  //           'open'    至今全是字面死分支 ⇒ 下一个字面为活的候选可接管
  //           'unknown' 出现过无法字面求值的条件 ⇒ 后续分支保守当活
  const stack = [];
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim();
    if (/^#\s*if\s+0\b/.test(t)) {
      stack.push({ dead: true, state: 'open' });
      dead[i] = true;
      continue;
    }
    if (/^#\s*if\s+1\b/.test(t)) {
      stack.push({ dead: false, state: 'taken' });
      dead[i] = true;
      continue;
    }
    if (/^#\s*(if|ifdef|ifndef)\b/.test(t)) {
      stack.push({ dead: false, state: 'unknown' });
      dead[i] = true;
      continue;
    }
    if (/^#\s*elif\b/.test(t) && stack.length > 0) {
      const top = stack[stack.length - 1];
      if (top.state === 'taken' || /^#\s*elif\s+0\b/.test(t)) {
        top.dead = true; // 本组已有活分支，或本分支字面为假
      } else if (/^#\s*elif\s+1\b/.test(t)) {
        top.dead = false;
        if (top.state === 'open') top.state = 'taken';
        // state === 'unknown' 时保持 unknown：前面有分支可能已被采用
      } else {
        top.dead = false; // 无法求值 ⇒ 保守当活
        top.state = 'unknown';
      }
      dead[i] = true;
      continue;
    }
    if (/^#\s*else\b/.test(t) && stack.length > 0) {
      const top = stack[stack.length - 1];
      top.dead = top.state === 'taken'; // open ⇒ 活（#if 0 的 else）；unknown ⇒ 保守当活
      if (top.state === 'open') top.state = 'taken';
      dead[i] = true;
      continue;
    }
    if (/^#\s*endif\b/.test(t) && stack.length > 0) {
      stack.pop();
      dead[i] = true;
      continue;
    }
    if (stack.length > 0 && stack.some((s) => s.dead)) dead[i] = true;
  }
  return dead;
}

/**
 * 抽取某个 C 函数的函数体（大括号配对）。返回 { body, lineNo } 或 null。
 * 匹配形如 `... NAME(...)\n{ ... }`，允许返回类型/修饰符换行。
 */
export function extractFunctionBody(src, fnName) {
  const re = new RegExp('(^|[^\\w])' + fnName + '\\s*\\([^;{]*\\)\\s*\\{', 'm');
  const m = re.exec(src);
  if (!m) return null;
  const open = src.indexOf('{', m.index + m[0].length - 1);
  if (open < 0) return null;
  let depth = 0;
  let i = open;
  for (; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}') {
      depth--;
      if (depth === 0) break;
    }
  }
  const body = src.slice(open + 1, i);
  const lineNo = src.slice(0, open).split('\n').length;
  return { body, lineNo };
}

/**
 * 判断函数体是否"空壳"。空壳 = 去掉注释/空白/预处理死代码/消参噪音后：
 *   · 完全空（含"只剩 `(void)param;` 消参语句"）
 *   · 只有 return 语句（return; / return true; / return SDL_Unsupported(); 等）
 *   · 只有单一大写常量 return（`return SDL_FULLSCREEN_SUCCEEDED;` 之类 ——
 *     常量名再长也改变不了"什么都不做直接报成功"的事实）
 *
 * ⭐ 2026-08-27：匹配前先从函数体里剥掉所有 `(void)标识符;` 语句。它是纯编译期
 * 噪音（压 -Wunused-parameter），却会把 `{ (void)enabled; return true; }` 撑到
 * 不匹配任何空壳模式 ⇒ 旧实现判 REAL（自测钉子同名）。只剥"无调用括号"的形状，
 * `(void)DoWork();` 这种丢弃返回值的真调用不受影响。
 *
 * 说明：`return SDL_Unsupported()` 严格说不算空壳（它会设置错误码），
 * 但对 MC 来说效果一样是"功能不可用"，所以一并报出来供判断。
 */
export function classifyBody(body) {
  const noComments = stripComments(body);
  // 去掉条件编译死区（#if 0、#if 1 的 #else 分支等，见 deadLineRanges）
  const dead = deadLineRanges(noComments);
  const live = noComments
    .split('\n')
    .filter((_, idx) => !dead[idx])
    .join('\n');
  const compact = live.replace(/\s+/g, ' ').trim();
  // 空壳判定用的"本质代码"：剥掉 (void)ident; 消参语句
  const essence = compact
    .replace(/\(\s*void\s*\)\s*[A-Za-z_]\w*\s*;/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

  if (essence.length === 0) {
    return { kind: 'EMPTY', detail: compact.length === 0 ? '函数体为空' : '只有 (void) 消参语句' };
  }
  if (/^return\s*;$/.test(essence)) return { kind: 'EMPTY', detail: '只有 return;' };
  if (/^return\s+(true|false|0|SDL_TRUE|SDL_FALSE)\s*;$/.test(essence)) {
    return { kind: 'STUB', detail: '只有 ' + essence };
  }
  if (/^return\s+[A-Z][A-Z0-9_]*\s*;$/.test(essence)) {
    return { kind: 'STUB', detail: '只有 ' + essence + '（单一常量 return）' };
  }
  if (/^return\s+SDL_Unsupported\s*\(\s*\)\s*;$/.test(essence)) {
    return { kind: 'STUB', detail: 'return SDL_Unsupported()' };
  }
  // 整个实现被 #if 0 包住：live 空但原 body 非空
  const rawCompact = noComments.replace(/\s+/g, ' ').trim();
  if (compact.length < rawCompact.length * 0.35 && /#\s*if\s+0/.test(noComments)) {
    return { kind: 'DISABLED', detail: '实现主体被 #if 0 排除' };
  }
  return { kind: 'REAL', detail: compact.length + ' 字符实现' };
}

/**
 * 收集某后端目录里所有 `X->field = value;` 赋值（X 为 device / mouse 等）。
 * 返回两张表：
 *   live     — 真正参与编译的赋值
 *   disabled — 落在 `#if 0` 里的赋值（**这类信息量最大**，见下）
 *
 * 为什么要单独收 disabled：OHOS 后端里有 5 处 `#if 0 // !!! FIXME`，里面是
 * 从 Android 后端照抄过来的赋值骨架（剪贴板 / 屏幕键盘 / 屏保 / system_theme /
 * Init{Touch,Mouse}）。只报"未接线"会让人以为是漏了一行赋值，实际上被赋的那些
 * 函数**全仓一处实现都没有**（实测每个名字只有 `#if 0` 里那 1 处引用）。
 * 也就是说这些是 TODO 占位符，工作量是"从零写实现"，不是"打开开关" ——
 * 这个区别直接决定 Phase 2 的排期，所以必须在报告里分开呈现。
 */
function collectAssignments(dir, lhs) {
  const live = new Map(); // field -> { fn, file, line }
  const disabled = new Map();
  if (!fs.existsSync(dir)) return { live, disabled };
  for (const f of fs.readdirSync(dir)) {
    if (!f.endsWith('.c')) continue;
    const full = path.join(dir, f);
    const src = stripComments(fs.readFileSync(full, 'utf8'));
    const dead = deadLineRanges(src);
    const lines = src.split('\n');
    const re = new RegExp('^\\s*' + lhs + '->(\\w+)\\s*=\\s*([\\w&.\\->]+)\\s*;');
    for (let i = 0; i < lines.length; i++) {
      const m = re.exec(lines[i]);
      if (!m) continue;
      const rec = { fn: m[2], file: f, line: i + 1 };
      if (dead[i]) {
        if (!disabled.has(m[1])) disabled.set(m[1], rec);
      } else {
        live.set(m[1], rec);
      }
    }
  }
  return { live, disabled };
}

/**
 * 数某个标识符在整个后端目录**活代码**里的引用次数
 * （用于推送模型判定、"只有赋值没有实现"判定、文件级特征函数复核）。
 *
 * ⭐ 2026-08-27：改在剥注释 + 过滤条件编译死区之后的文本上计数。旧实现数原文，
 * `SDL_SendKeyboardKey` 哪怕只出现在注释或 `#if 0` 里也被计入，直接后果：
 *   ① 推送模型误判 ⇒ PumpEvents 空壳被降级成软警告（漏报）；
 *   ② 文件级缺口误报「已在 events.c 内实现」；
 *   ③ `#if 0` 赋值段的"待实现/待启用"判定被死代码撑成"可能已有实现"。
 */
function countReferences(dir, ident) {
  let n = 0;
  if (!fs.existsSync(dir)) return 0;
  for (const f of fs.readdirSync(dir)) {
    if (!f.endsWith('.c') && !f.endsWith('.h')) continue;
    const src = stripComments(fs.readFileSync(path.join(dir, f), 'utf8'));
    const dead = deadLineRanges(src);
    const live = src
      .split('\n')
      .filter((_, idx) => !dead[idx])
      .join('\n');
    const re = new RegExp('\\b' + ident.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\b', 'g');
    const m = live.match(re);
    if (m) n += m.length;
  }
  return n;
}

/** 在整个后端目录里找函数实现并分类。 */
function classifyCallback(dir, fnName) {
  if (!fs.existsSync(dir)) return null;
  for (const f of fs.readdirSync(dir)) {
    if (!f.endsWith('.c')) continue;
    const src = fs.readFileSync(path.join(dir, f), 'utf8');
    const got = extractFunctionBody(src, fnName);
    if (got) {
      const cls = classifyBody(got.body);
      return { file: f, line: got.lineNo, kind: cls.kind, detail: cls.detail };
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// 主流程
//
// ⭐ 2026-08-27（施工记录 §S9.3）：原本这 200 余行是**顶层代码**，于是 `import`
// 本模块就会立刻去找 SDL 仓库并在找不到时 `process.exit(1)` ⇒ **无法被自测 import**。
// 治理规范 §8.1 要求每道门禁都有自己的测试，而本门禁此前一个都没有，根因就是这个。
// ⇒ 包进 main()，仅在被直接执行时调用。纯函数（stripComments / deadLineRanges /
//   extractFunctionBody / classifyBody）已导出，自测直接驱动它们 + 一棵最小假 SDL 树。
//
// ⚠️ `repo` 必须从**参数**解析而不是直接读 `process.argv`：自测要能传一棵 fixture 树。
//    第一版把 `const { repo } = parseArgs(process.argv)` 留在了 main() 外面，
//    结果 main(['node','x','--repo',tmp]) 静默用了默认路径、自测当场变红 —— 那次变红
//    正好证明这条自测在测真东西。
// ---------------------------------------------------------------------------
export function main(argv = process.argv) {
  const { repo } = parseArgs(argv);
  const ohDir = path.join(repo, 'src', 'video', 'openharmony');
  const andDir = path.join(repo, 'src', 'video', 'android');

  if (!fs.existsSync(ohDir)) {
    console.error('[FATAL] 找不到 OHOS video 后端: ' + ohDir);
    console.error('        用 --repo 指向 SDL 仓库或 worktree 根目录。');
    process.exit(2);
  }

  console.log('SDL3 OHOS 后端回调接线核对');
  console.log('repo    : ' + repo);
  console.log('backend : src/video/openharmony');
  console.log('');

  const ohDev = collectAssignments(ohDir, 'device');
  const ohMse = collectAssignments(ohDir, 'mouse');
  const andDev = collectAssignments(andDir, 'device');
  const andMse = collectAssignments(andDir, 'mouse');
  const ohDevice = ohDev.live;
  const ohMouse = ohMse.live;
  const andDevice = andDev.live;
  const andMouse = andMse.live;

  let hardFail = 0;
  let softWarn = 0;

  // 事件模型判定：后端里存在 SDL_Send* 注入 ⇒ 推送模型（事件不经 PumpEvents）。
  // 这个判定直接影响 PumpEvents 空实现算硬失败还是软警告，见 REQUIRED_VIDEO 处注释。
  const pushSignals = ['SDL_SendTouch', 'SDL_SendMouseMotion', 'SDL_SendMouseButton', 'SDL_SendWindowEvent'];
  const pushHits = pushSignals.filter((s) => countReferences(ohDir, s) > 0);
  const pushModel = pushHits.length > 0;
  console.log('事件模型: ' + (pushModel ? '推送（回调直接注入：' + pushHits.join(', ') + '）' : '拉取（依赖 PumpEvents）'));
  console.log('');

  // ---- 第一段：必需清单核对 ----
  function checkRequired(title, list, assigns, dir) {
    console.log('== ' + title + ' ==');
    const rows = [];
    for (const req of list) {
      const hit = assigns.get(req.name);
      if (!hit) {
        // 未接线的后果按 SDL 核心的实际行为分类，不再一律当硬失败。
        // 判据依据见文件头「判据大修」那段。
        const why = req.note ? ' — ' + req.note : '';
        switch (req.missing) {
          case 'fallback':
            rows.push(['· 未接线(有回退)', req.name, '—', 'SDL 自带合理回退，无需接线' + why]);
            break;
          case 'unsupported':
            rows.push(['· 未接线(诚实)', req.name, '—', 'SDL 自己报 unsupported，接线反而要撒谎' + why]);
            break;
          case 'silent':
            rows.push(['✗ 未接线(静默失效)', req.name, '—', '判空后静默跳过且无补偿' + why]);
            hardFail++;
            break;
          default: // 'needed'
            rows.push(['✗ 未接线', req.name, '—', '缺失确实丢功能' + why]);
            hardFail++;
            break;
        }
        continue;
      }
      const cls = classifyCallback(dir, hit.fn);
      if (!cls) {
        rows.push(['? 找不到实现', req.name, hit.fn, '赋值存在但函数定义未找到（可能在别处/宏生成）']);
        softWarn++;
        continue;
      }
      if (cls.kind === 'REAL') {
        rows.push(['✓ 实体', req.name, hit.fn, cls.file + ':' + cls.line]);
      } else if (req.realUnlessPushModel) {
        // 推送模型下空 PumpEvents 不影响输入，只丢生命周期事件（见清单处长注释）
        if (pushModel) {
          rows.push([
            '△ 空壳(推送模型)', req.name, hit.fn,
            '输入不受影响；但生命周期事件(切后台/前台/销毁)无人处理 @ ' + cls.file + ':' + cls.line,
          ]);
          softWarn++;
        } else {
          rows.push(['✗ 空壳(必须实体)', req.name, hit.fn, cls.detail + ' @ ' + cls.file + ':' + cls.line]);
          hardFail++;
        }
      } else if (req.missing === 'needed' && req.trivialOk) {
        // 显式声明过"空壳即契约"的 needed 项（见清单处 trivialOk 注释）：
        // 不计失败，但保留一行输出 —— 设计决定要可见，不是被吞掉。
        rows.push(['· 契约空壳(设计)', req.name, hit.fn,
                   (req.note || '') + ' @ ' + cls.file + ':' + cls.line]);
      } else if (req.missing === 'needed') {
        // ⭐ 2026-08-27：needed 项接了线但实现是空壳 ⇒ 与"未接线"同罪，硬失败。
        // 此前这里落进下面的 softWarn 分支，把 needed 项接成 `return true;` 门禁照样
        // 放行 —— 与文件头「退出码 0 = needed 项全部接线且非空壳」直接矛盾（漏报）。
        // fallback / unsupported 项的空壳仍只软警告：那些项连接线都不要求，
        // 空壳最多说明"多写了没用的代码"，不构成功能缺口。
        rows.push(['✗ 空壳(必须实体)', req.name, hit.fn, cls.detail + ' @ ' + cls.file + ':' + cls.line]);
        hardFail++;
      } else {
        rows.push(['△ 空壳', req.name, hit.fn, cls.detail + ' @ ' + cls.file + ':' + cls.line]);
        softWarn++;
      }
    }
    for (const r of rows) {
      console.log('  ' + r[0].padEnd(16) + r[1].padEnd(24) + (r[2] + '').padEnd(34) + r[3]);
    }
    console.log('');
  }

  checkRequired('必需 video 回调（' + REQUIRED_VIDEO.length + ' 项）', REQUIRED_VIDEO, ohDevice, ohDir);
  checkRequired('必需 mouse 回调（' + REQUIRED_MOUSE.length + ' 项）', REQUIRED_MOUSE, ohMouse, ohDir);

  // ---- 第二段：被 #if 0 关掉的赋值（TODO 占位符 vs 待启用，必须分清）----
  console.log('== 落在 #if 0 里的回调赋值（判断是"待启用"还是"待实现"）==');
  const disabledRows = [];
  for (const [field, rec] of [...ohDev.disabled, ...ohMse.disabled]) {
    // 目标函数在后端目录**活代码**里的引用数（countReferences 已剥注释、滤死区，
    // `#if 0` 里这次赋值本身不再计入）。==0 意味着既没有定义也没有声明
    // ⇒ 是 TODO 占位符，要从零写实现。
    const refs = countReferences(ohDir, rec.fn);
    disabledRows.push({ field, fn: rec.fn, at: rec.file + ':' + rec.line, refs });
  }
  if (disabledRows.length === 0) {
    console.log('  (无)');
  } else {
    for (const r of disabledRows) {
      const verdict = r.refs === 0 ? '待实现（活代码零引用，无定义）' : '待启用（活代码引用 ' + r.refs + ' 处，可能已有实现）';
      // ⭐ `r.at`（`#if 0` 赋值所在的 file:line）此前**被组装但从未打印**。
      //    它来自 collectAssignments，而那里的行号取自 strip 后的文本 ——
      //    旧 stripComments 把多行块注释塌成一个空格，所以那个行号是**错的**；
      //    正因为它没被打印，这个错从未浮现（施工记录 §S9.2）。
      //    2026-08-27 换用 lib/source-noise.mjs 的行稳定实现后它才可信 ⇒ 现在打出来，
      //    让这条修复承重，而不是留一个"算了但不敢用"的字段。
      console.log('  ' + r.field.padEnd(28) + r.fn.padEnd(36) + verdict.padEnd(34) + '@ ' + r.at);
    }
    console.log('');
    console.log('  ⇒ 这些不是"漏写一行赋值"。icculus 从 Android 后端照抄了 CreateDevice 骨架，');
    console.log('    把未实现的部分用 `#if 0 // !!! FIXME` 包住当 TODO 标记。');
  }
  console.log('');

  // ---- 第三段：Android 平价对比（机械，不依赖手写清单）----
  console.log('== Android 接了而 OHOS 没接的回调（候选缺口，非硬失败）==');
  if (andDevice.size === 0 && andMouse.size === 0) {
    console.log('  (找不到 android 后端，跳过对比)');
  } else {
    const missDev = [...andDevice.keys()].filter((k) => !ohDevice.has(k)).sort();
    const missMouse = [...andMouse.keys()].filter((k) => !ohMouse.has(k)).sort();
    const mark = (k) => (ohDev.disabled.has(k) || ohMse.disabled.has(k) ? k + '(#if 0)' : k);
    console.log('  device-> 缺 ' + missDev.length + ' / android 共 ' + andDevice.size + ':');
    console.log('    ' + (missDev.length ? missDev.map(mark).join(', ') : '(无)'));
    console.log('  mouse->  缺 ' + missMouse.length + ' / android 共 ' + andMouse.size + ':');
    console.log('    ' + (missMouse.length ? missMouse.map(mark).join(', ') : '(无)'));
  }
  console.log('');

  // ---- 第四段：文件级缺口 ----
  //
  // 两个归一化注意点（不处理就会误报）：
  //   ① android 叫 SDL_androidgl.c，OHOS 叫 SDL_openharmonyopengl.c —— 同一模块不同命名，
  //      naive 的 "去前缀比字符串" 会把它当缺失。
  //   ② OHOS 没有独立的 touch 文件，但触摸**已在 SDL_openharmonyevents.c 里实现**
  //      （有 SDL_SendTouch 调用）。所以文件缺失 != 功能缺失，要按"模块内特征函数"复核。
  console.log('== 文件级：android 有、openharmony 没有的后端文件 ==');
  if (fs.existsSync(andDir)) {
    // 模块名归一化：把已知的别名对齐
    const ALIAS = new Map([['gl', 'opengl']]);
    const norm = (f) => {
      let n = f.replace(/^SDL_(android|openharmony)/, '').replace(/\.[ch]$/, '');
      return ALIAS.get(n) || n;
    };
    // 某模块是否其实已在别处实现：用特征函数判断
    const FEATURE = new Map([
      ['touch', 'SDL_SendTouch'],
      ['keyboard', 'SDL_SendKeyboardKey'],
      ['pen', 'SDL_SendPenMotion'],
      // OHOS 没有独立的 mouse 后端文件，鼠标钩子挂在宿主输入桥那个文件里
      ['mouse', 'SetRelativeMouseMode'],
    ]);
    const ohFiles = fs.readdirSync(ohDir).filter((f) => f.endsWith('.c'));
    const ohSet = new Set(ohFiles.map(norm));
    const rows = fs
      .readdirSync(andDir)
      .filter((f) => f.endsWith('.c'))
      .filter((f) => !ohSet.has(norm(f)))
      .map((f) => {
        const n = fs.readFileSync(path.join(andDir, f), 'utf8').split('\n').length;
        const mod = norm(f);
        let note = '整体缺失';
        const feat = FEATURE.get(mod);
        if (feat && countReferences(ohDir, feat) > 0) {
          note = '无独立文件，但已在 events.c 内实现（含 ' + feat + '）';
        }
        return { f, n, note };
      })
      .sort((a, b) => b.n - a.n);
    if (rows.length === 0) {
      console.log('  (无)');
    } else {
      for (const r of rows) {
        console.log('  ' + String(r.n).padStart(5) + ' 行  ' + r.f.padEnd(28) + r.note);
      }
    }
  } else {
    console.log('  (找不到 android 后端，跳过)');
  }
  console.log('');

  // ---- 判定 ----
  console.log('== 判定 ==');
  console.log('  硬失败（needed 项未接线或空壳 / PumpEvents 空壳）: ' + hardFail);
  console.log('  软警告（非关键空壳 / 实现未定位）      : ' + softWarn);
  if (hardFail > 0) {
    console.log('');
    console.log('回调核对: FAIL —— Phase 2 关卡 3 未关闭');
    process.exit(1);
  }
  console.log('');
  console.log('回调核对: PASS');
  process.exit(0);
}

// 直接执行才跑主流程；被 import 时保持静默（自测依赖这一点）。
if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1].replace(/\\/g, '/')}`).href) {
  main();
}
