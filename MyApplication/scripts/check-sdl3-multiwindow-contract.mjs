#!/usr/bin/env node
// Static contract for the OpenHarmony SDL3 hybrid-window backend and its AMCL
// host-presented activation seam.
//
// This is intentionally a source/patch gate, not a Minecraft-version gate. It
// checks the platform mechanism needed by any caller that asks for a hidden GL
// utility window before its host-presented window:
//
//   requested create flags -> explicit window role -> fixed EGLConfig ->
//   auxiliary pbuffer / presented NativeWindow -> role-owned lifecycle.
//
// Usage:
//   node scripts/check-sdl3-multiwindow-contract.mjs --repo <applied SDL tree>
//   node scripts/check-sdl3-multiwindow-contract.mjs --patch-series <series>
//   node scripts/check-sdl3-multiwindow-contract.mjs --json
//
// With no source argument the checked-in SDL patch series is inspected. Both
// modes also merge the three checked-in AMCL host activation sources needed to
// prove the env gate can open without a component-focus edge. The build must
// additionally run this gate with --repo after applying the series:
// a patch-level PASS proves that the shipped recipe contains the contract;
// an applied-source PASS proves that the recipe still lands on the pinned SDL.

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { stripComments, stripStringLiterals } from './lib/source-noise.mjs';
import { loadSdlHostFixture } from './lib/sdl3-host-runtime-sources.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const root = path.resolve(path.dirname(scriptPath), '..');

const SOURCE_FILES = new Set([
  // 0013 将窗口/事件泵的宿主线程准入放到 SDL core；仍逐文件解析实际补丁，
  // 不把“本补丁不改 video 目录”当成无有效源码，也不跳过既有窗口所有权规则。
  'src/SDL.c',
  'src/events/SDL_events.c',
  'src/core/openharmony/SDL_amclhostruntime.h',
  'src/video/SDL_egl.c',
  'src/video/SDL_egl_c.h',
  'src/video/SDL_sysvideo.h',
  'src/video/SDL_video.c',
]);

const HOST_ACTIVATION_FILES = new Set([
  'entry/src/main/cpp/platform/input_foreground_gate.h',
  'entry/src/main/cpp/platform/xcomponent.cpp',
  'entry/src/main/cpp/platform/ohos_frame_rate_hint.cpp',
]);

const HOST_TYPED_INPUT_FILES = new Set([
  'entry/src/main/cpp/input/adapters/backend_input_bridge.h',
  'entry/src/main/cpp/input/adapters/backend_input_bridge.cpp',
  'entry/src/main/cpp/input/adapters/backend_input_event_encode.h',
  'entry/src/main/cpp/input/adapters/glfw_input_adapter.cpp',
]);

function normalizePath(p) {
  return String(p).replaceAll('\\', '/').replace(/^\.\//, '');
}

function isContractSource(rel) {
  const p = normalizePath(rel);
  return SOURCE_FILES.has(p)
    || HOST_ACTIVATION_FILES.has(p)
    || HOST_TYPED_INPUT_FILES.has(p)
    || /^src\/video\/openharmony\/[^/]+\.(?:c|h)$/.test(p);
}

function loadHostActivationSources() {
  const files = new Map();
  for (const rel of new Set([...HOST_ACTIVATION_FILES, ...HOST_TYPED_INPUT_FILES])) {
    const full = path.join(root, rel);
    if (!fs.existsSync(full)) {
      throw new Error(`host SDL contract source missing: ${full}`);
    }
    files.set(rel, fs.readFileSync(full, 'utf8'));
  }

  // The activation implementation lives in the fixed files above, but the
  // single-writer claim spans every first-party native source. Only merge
  // additional files that mention the env name, keeping the contract corpus
  // small while ensuring a future rogue writer cannot hide elsewhere.
  const nativeRoot = path.join(root, 'entry/src/main/cpp');
  const visit = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) visit(full);
      else if (entry.isFile() && /\.(?:c|cc|cpp|cxx|h|hh|hpp)$/i.test(entry.name)) {
        const rel = normalizePath(path.relative(root, full));
        if (files.has(rel)) continue;
        const content = fs.readFileSync(full, 'utf8');
        // 名字字面量只在 env_slot.h 定义一次，写者引用常量 kWindowForegroundEnv；两者都要收进语料，
        // 否则只引用常量的越界写者会绕过“唯一写者”计数。
        if (content.includes('AMCL_WINDOW_FOREGROUND') || content.includes('kWindowForegroundEnv')) {
          files.set(rel, content);
        }
      }
    }
  };
  visit(nativeRoot);
  return files;
}

function mergeHostActivationSources(loaded) {
  for (const [rel, content] of loadHostActivationSources()) {
    loaded.files.set(rel, content);
  }
  return loaded;
}

function walk(dir, base = dir, out = new Map()) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, base, out);
    else if (entry.isFile()) {
      const rel = normalizePath(path.relative(base, full));
      if (isContractSource(rel)) out.set(rel, fs.readFileSync(full, 'utf8'));
    }
  }
  return out;
}

export function loadRepo(repo) {
  const full = path.resolve(repo);
  if (!fs.existsSync(full)) throw new Error(`SDL source tree missing: ${full}`);
  const files = walk(full);
  if (files.size === 0) {
    throw new Error(`no SDL EGL/OpenHarmony contract sources found under: ${full}`);
  }
  return { files, mode: 'applied-source', input: full };
}

// Reconstruct the post-patch side of every relevant hunk. Context and added
// lines are retained; removed lines and diff metadata are not. A patch view is
// necessarily weaker than an applied tree, which is why the build also runs
// --repo. It is still valuable in preflight/CI: a locked binary plus a patch
// recipe must not silently lose the mechanism that will produce its successor.
export function parsePatchText(text, label = '<patch>') {
  const files = new Map();
  let rel = null;
  let inHunk = false;
  for (const raw of text.split(/\r?\n/)) {
    if (raw.startsWith('+++ ')) {
      const value = raw.slice(4).trim().split(/\s+/, 1)[0];
      rel = value === '/dev/null' ? null : normalizePath(value.replace(/^b\//, ''));
      inHunk = false;
      continue;
    }
    if (raw.startsWith('@@')) {
      inHunk = true;
      // Git's hunk heading often carries the enclosing function signature.
      // Retaining it helps diagnostics without treating diff coordinates as C.
      const suffix = raw.replace(/^@@[^@]*@@\s*/, '');
      if (rel && isContractSource(rel) && suffix) {
        files.set(rel, `${files.get(rel) ?? ''}\n${suffix}\n`);
      }
      continue;
    }
    if (!inHunk || !rel || !isContractSource(rel)) continue;
    if (raw.startsWith('+') && !raw.startsWith('+++')) {
      files.set(rel, `${files.get(rel) ?? ''}${raw.slice(1)}\n`);
    } else if (raw.startsWith(' ')) {
      files.set(rel, `${files.get(rel) ?? ''}${raw.slice(1)}\n`);
    }
  }
  if (files.size === 0) throw new Error(`no relevant SDL source hunks in ${label}`);
  return files;
}

// 按顺序把补丁应用到稀疏源码：未出现在任何 hunk 中的上游行保持未知，不能拼接到
// 相邻函数。声明偏移有冲突时只接受唯一、完整、逐字匹配的旧正文；未知行不是搜索通配符。
// 这与实际 git apply 的来源验证配合使用，防止上下文扩大后把标题 setter 拼成创建分支。
export function applySparsePatch(files, text, label = '<patch>') {
  for (const section of text.split(/^diff --git /m).slice(1)) {
    const target = /^\+\+\+ b\/(.+)$/m.exec(section);
    if (!target || !isContractSource(target[1])) continue;
    const rel = normalizePath(target[1]);
    const old = [...(files.get(rel) ?? [])];
    const output = [];
    let cursor = 0;
    const hunks = [...section.matchAll(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@[^\n]*\n/gm)];
    for (let h = 0; h < hunks.length; h += 1) {
      const header = hunks[h];
      const oldCount = Number(header[2] ?? 1);
      const newCount = Number(header[4] ?? 1);
      let start = Number(header[1]) - (oldCount ? 1 : 0);
      const body = section.slice(header.index + header[0].length, hunks[h + 1]?.index ?? section.length);
      const before = [], after = [];
      for (let line of body.split(/\r?\n/)) {
        if (before.length === oldCount && after.length === newCount) break;
        if (!line) line = ' ';
        if (line.startsWith(' ') || line.startsWith('-')) before.push(line.slice(1));
        if (line.startsWith(' ') || line.startsWith('+')) after.push(line.slice(1));
      }
      if (before.length !== oldCount || after.length !== newCount) {
        throw new Error(`${label}: incomplete hunk ${rel}`);
      }
      while (old.length < start + oldCount) old.push(null);
      const declaredMatches = start >= cursor && before.every((line, n) => old[start + n] === null || old[start + n] === line);
      if (!declaredMatches) {
        if (!before.length) throw new Error(`${label}: empty old body cannot resolve offset ${rel}`);
        const matches = [];
        for (let at = cursor; at + before.length <= old.length; at += 1) {
          if (before.every((line, n) => old[at + n] === line)) matches.push(at);
        }
        if (matches.length !== 1) {
          throw new Error(`${label}: old hunk context mismatch ${rel}; exact matches=${matches.length}`);
        }
        start = matches[0];
      }
      output.push(...old.slice(cursor, start), ...after);
      cursor = start + oldCount;
    }
    output.push(...old.slice(cursor));
    files.set(rel, output);
  }
}

export function loadPatchSeries(seriesPath) {
  const full = path.resolve(seriesPath);
  if (!fs.existsSync(full)) throw new Error(`SDL patch series missing: ${full}`);
  const patchDir = path.dirname(full);
  const names = fs.readFileSync(full, 'utf8').split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#'));
  if (names.length === 0) throw new Error(`SDL patch series has no patches: ${full}`);

  // SDK core现同时承载宿主线程和输入协议。使用既有完整、逐字冻结的pin输入作为这两个
  // 文件的原始正文，避免大context在稀疏行号中错位；摘要/pin变化必须由已有fixture门拒绝。
  // 其他窗口文件仍保留未知行，不能为通过门禁捏造缺失上游源码。
  const lockText = fs.readFileSync(path.join(root, 'deps.lock'), 'utf8').replaceAll('\r\n', '\n');
  const section = /(?:^|\n)\[sdl3-native\]\n([\s\S]*?)(?=\n\[|$)/.exec(lockText);
  const pin = section && /^\s*commit\s*=\s*([0-9a-f]{40})\b/m.exec(section[1]);
  if (!pin) throw new Error('SDL source pin missing for complete core context');
  const fixture = loadSdlHostFixture(root, pin[1]);
  const sparseFiles = new Map([...fixture.buffers].filter(([rel]) => isContractSource(rel))
    .map(([rel, bytes]) => [rel, bytes.toString('utf8').replaceAll('\r\n', '\n').replace(/\n$/, '').split('\n')]));
  for (const name of names) {
    const patchPath = path.resolve(patchDir, name);
    if (!fs.existsSync(patchPath)) throw new Error(`series patch missing: ${patchPath}`);
    applySparsePatch(sparseFiles, fs.readFileSync(patchPath, 'utf8').replaceAll('\r\n', '\n'), patchPath);
  }
  const files = new Map([...sparseFiles].map(([rel, lines]) => [rel,
    lines.map(line => line ?? '#error AMCL_UNAVAILABLE_PATCH_CONTEXT').join('\n') + '\n']));
  if (files.size === 0) throw new Error(`no SDL contract sources reconstructed from ${full}`);
  return { files, mode: 'patch-series', input: full, patches: names };
}

// Remove literal #if 0 branches after lexical comment stripping. This is not a
// general preprocessor; it only prevents an old tombstone or a negative fixture
// from satisfying a positive rule. Unknown conditions stay live (conservative).
function stripLiteralIfZero(text) {
  const lines = text.split(/(?<=\n)/);
  const stack = [];
  let deadDepth = 0;
  return lines.map((line) => {
    const directive = /^\s*#\s*(if|elif|else|endif)\b(.*)/.exec(line);
    const wasDead = deadDepth > 0;
    if (directive) {
      const kind = directive[1];
      const expr = directive[2].trim();
      if (kind === 'if') {
        const dead = /^0(?:\b|$)/.test(expr);
        stack.push({ literal: dead, inDeadBranch: dead });
        if (dead) deadDepth += 1;
      } else if ((kind === 'else' || kind === 'elif') && stack.length) {
        const top = stack.at(-1);
        if (top.literal) {
          if (top.inDeadBranch) deadDepth -= 1;
          top.inDeadBranch = kind === 'elif' ? !/^1(?:\b|$)/.test(expr) : false;
          if (top.inDeadBranch) deadDepth += 1;
        }
      } else if (kind === 'endif' && stack.length) {
        const top = stack.pop();
        if (top.inDeadBranch) deadDepth -= 1;
      }
    }
    const hide = wasDead || deadDepth > 0;
    return hide ? line.replace(/[^\r\n]/g, ' ') : line;
  }).join('');
}

function live(text) {
  return stripLiteralIfZero(stripComments(text, { lang: 'c' }));
}

function code(text) {
  return stripStringLiterals(live(text), { lang: 'c' });
}

function select(files, predicate, transform = live) {
  return [...files].filter(([rel]) => predicate(rel))
    .map(([rel, text]) => `\n/* FILE ${rel} */\n${transform(text)}`).join('\n');
}

function hasAll(text, tokens) {
  return tokens.every((token) => text.includes(token));
}

function hasAny(text, patterns) {
  return patterns.some((pattern) => typeof pattern === 'string'
    ? text.includes(pattern) : pattern.test(text));
}

function extractFunction(files, names) {
  for (const [rel, raw] of files) {
    const src = code(raw);
    for (const name of names) {
      // Anchor the match at a declaration line.  The old `\\bname(...) {`
      // expression could start at a call site such as
      // `if (!SDL_EGL_ChooseConfig(device) || ... ) {` and then treat the
      // enclosing helper's body as the EGL chooser.  That made a valid
      // implementation look as if the lock guard was missing.  A declaration
      // has an optional C return-type prefix made only of identifiers,
      // whitespace and pointer stars; control expressions contain punctuation
      // before the function name and are therefore excluded.
      const re = new RegExp(`(?:^|\\n)[ \\t]*(?:[A-Za-z_][A-Za-z0-9_\\s*]*\\s+)?${name}\\s*\\([^;{}]*\\)\\s*\\{`, 'g');
      let match;
      while ((match = re.exec(src)) !== null) {
        const open = src.indexOf('{', match.index);
        let depth = 1;
        let i = open + 1;
        while (i < src.length && depth > 0) {
          if (src[i] === '{') depth += 1;
          else if (src[i] === '}') depth -= 1;
          i += 1;
        }
        if (depth === 0) return { rel, name, body: src.slice(open + 1, i - 1) };
      }
    }
  }
  return null;
}

// patch-series 拼接的是各 hunk 的后像上下文，不能把 SetWindowTitle 的正常展示参数
// 当成 CreateWindow 的角色输入。仅在完整标题 setter 内屏蔽现役桌面 TITLE 命令的
// 最后一个参数；其他 title 读取（包括同函数中的条件分支）仍按原规则拒绝。
// 不完整函数不处理，保持 fail-closed；字符串指纹检查仍独立扫描全部活代码。
function maskDesktopTitleCommandArgument(source) {
  const declaration = /(?:^|\n)[ \t]*void\s+OPENHARMONY_SetWindowTitle\s*\([^;{}]*\)\s*\{/g;
  let result = source;
  let match;
  while ((match = declaration.exec(source)) !== null) {
    const open = source.indexOf('{', match.index);
    let depth = 1;
    let end = open + 1;
    while (end < source.length && depth > 0) {
      if (source[end] === '{') depth += 1;
      else if (source[end] === '}') depth -= 1;
      end += 1;
    }
    if (depth !== 0) continue;
    const original = source.slice(open, end);
    const masked = original.replace(
      /\bOPENHARMONY_DesktopCommand\s*\(\s*window\s*,\s*9\s*,\s*0\s*,\s*0\s*,\s*0\s*,\s*0\s*,\s*window\s*->\s*title\s*\)/g,
      call => call.replace(/\bwindow\s*->\s*title\b/, title => ' '.repeat(title.length)),
    );
    // 等长替换保留偏移，避免相邻 hunk 或重复 setter 的扫描范围漂移。
    result = result.slice(0, open) + masked + result.slice(end);
    declaration.lastIndex = end;
  }
  return result;
}

function extractSwitchCase(body, label) {
  if (!body) return '';
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const matches = [...body.matchAll(new RegExp(`\\bcase\\s+${escaped}\\s*:`, 'g'))];
  if (matches.length === 0) return '';
  const match = matches.at(-1);
  const tail = body.slice(match.index + match[0].length);
  const next = /\b(?:case\s+[A-Za-z_][A-Za-z0-9_]*|default)\s*:/.exec(tail);
  return next ? tail.slice(0, next.index) : tail;
}

function count(text, re) {
  return [...text.matchAll(re)].length;
}

function check(ok, detail, evidence = null) {
  return { ok: Boolean(ok), detail, evidence };
}

export const RULE_IDS = [
  'requested-flags',
  'fixed-egl-config',
  'window-roles',
  'auxiliary-pbuffer',
  'lease-broker',
  'role-aware-focus',
  'role-aware-pixel-size',
  'role-aware-swap',
  'destroy-any-role',
  'no-runtime-fingerprints',
  'focus-independent-activation',
  'typed-focus-capture',
  'relative-disable-authority',
  'typed-relative-single-owner',
  'typed-surface-context',
  'typed-pointer-device-identity',
];

export function analyzeFiles(files, metadata = {}) {
  const oh = (rel) => rel.includes('/openharmony/');
  const egl = (rel) => /src\/video\/SDL_egl(?:_c\.h|\.c)$/.test(rel);
  const core = (rel) => /src\/video\/(?:SDL_video\.c|SDL_sysvideo\.h)$/.test(rel);
  const hostActivation = (rel) => HOST_ACTIVATION_FILES.has(normalizePath(rel));
  const hostTypedInput = (rel) => HOST_TYPED_INPUT_FILES.has(normalizePath(rel));
  const hostNative = (rel) => /^entry\/src\/main\/cpp\/.*\.(?:c|cc|cpp|cxx|h|hh|hpp)$/.test(
    normalizePath(rel),
  );
  const allLive = select(files, () => true, live);
  const allCode = select(files, () => true, code);
  const ohLive = select(files, oh, live);
  const ohCode = select(files, oh, code);
  const ohRaw = select(files, oh, (text) => text);
  const eglCode = select(files, egl, code);
  const coreCode = select(files, core, code);
  const hostActivationCode = select(files, hostActivation, code);
  const hostTypedInputCode = select(files, hostTypedInput, code);
  const hostNativeLive = select(files, hostNative, live);

  const create = extractFunction(files, ['OPENHARMONY_CreateWindow']);
  const classify = extractFunction(files, [
    'OPENHARMONY_ClassifyWindowRole',
    'OPENHARMONY_GetWindowRole',
    'OPENHARMONY_ResolveWindowRole',
  ]);
  const choose = extractFunction(files, ['SDL_EGL_ChooseConfig']);
  const lock = extractFunction(files, ['SDL_EGL_LockConfig']);
  const show = extractFunction(files, ['OPENHARMONY_ShowWindow']);
  const hide = extractFunction(files, ['OPENHARMONY_HideWindow']);
  const pixels = extractFunction(files, ['OPENHARMONY_GetWindowSizeInPixels']);
  const swap = extractFunction(files, ['OPENHARMONY_GLES_SwapWindow']);
  const destroy = extractFunction(files, ['OPENHARMONY_DestroyWindow']);
  const helper = extractFunction(files, ['SDL_GetWindowCreateFlags']);
  const validateTyped = extractFunction(files, ['OPENHARMONY_ValidateTypedEvent']);
  const disableRelativeForHostLoss = extractFunction(files, [
    'OPENHARMONY_DisableRelativeModeForHostLoss',
  ]);
  const applyFocus = extractFunction(files, ['OPENHARMONY_ApplyTypedFocus']);
  const applyCapture = extractFunction(files, ['OPENHARMONY_ApplyTypedCapture']);
  const setRelativeMode = extractFunction(files, ['OPENHARMONY_SetRelativeMouseMode']);
  const updatePresentedForeground = extractFunction(files, [
    'OPENHARMONY_AMCL_UpdatePresentedForeground',
  ]);
  const quitMouse = extractFunction(files, ['OPENHARMONY_AMCL_QuitMouse']);
  const pumpTyped = extractFunction(files, ['OPENHARMONY_PumpTypedEvents']);
  const releaseHeld = extractFunction(files, ['OPENHARMONY_ReleaseHeldMouseButtons']);
  const pumpCursor = extractFunction(files, ['OPENHARMONY_PumpHostCursor']);
  const pumpEvents = extractFunction(files, ['OPENHARMONY_AMCL_PumpEvents']);
  const setPresentedActive = extractFunction(files, ['OPENHARMONY_AMCL_SetPresentedActive']);
  const sourceFallback = metadata.mode === 'patch-series';

  const helperText = helper?.body ?? (sourceFallback ? coreCode : '');
  // A patch-series reconstruction contains only hunk context and added
  // lines, so a function body can be split across patches (or begin at a
  // hunk-heading fragment).  In that deliberately weaker view, use the full
  // post-hunk corpus for semantic token checks; the applied-source gate runs
  // the exact function extraction against the real tree and remains the
  // authoritative structural check.
  const createText = sourceFallback ? ohCode : (create?.body ?? '');
  const classifyText = sourceFallback ? ohCode : (classify?.body ?? '');
  const chooseText = sourceFallback ? eglCode : (choose?.body ?? '');
  const lockText = sourceFallback ? eglCode : (lock?.body ?? '');
  const showText = sourceFallback ? ohCode : (show?.body ?? '');
  const hideText = sourceFallback ? ohCode : (hide?.body ?? '');
  const pixelText = sourceFallback ? ohCode : (pixels?.body ?? '');
  const swapText = sourceFallback ? ohCode : (swap?.body ?? '');
  const destroyText = sourceFallback ? ohCode : (destroy?.body ?? '');
  const validateTypedText = sourceFallback ? ohCode : (validateTyped?.body ?? '');
  const disableRelativeForHostLossText = sourceFallback
    ? ohCode : (disableRelativeForHostLoss?.body ?? '');
  const applyFocusText = sourceFallback ? ohCode : (applyFocus?.body ?? '');
  const captureText = sourceFallback ? ohCode : (applyCapture?.body ?? '');
  const setRelativeModeText = sourceFallback ? ohCode : (setRelativeMode?.body ?? '');
  const updatePresentedForegroundText = sourceFallback
    ? ohCode : (updatePresentedForeground?.body ?? '');
  const quitMouseText = sourceFallback ? ohCode : (quitMouse?.body ?? '');
  const typedPumpText = sourceFallback ? ohCode : (pumpTyped?.body ?? '');
  const releaseHeldText = sourceFallback ? ohCode : (releaseHeld?.body ?? '');
  const cursorPumpText = sourceFallback ? ohCode : (pumpCursor?.body ?? '');
  const pumpEventsText = sourceFallback ? ohCode : (pumpEvents?.body ?? '');
  const setPresentedActiveText = sourceFallback ? ohCode : (setPresentedActive?.body ?? '');

  const results = [];
  const add = (id, label, result) => results.push({ id, label, ...result });

  const requestedTokens = [
    'SDL_PROP_WINDOW_CREATE_FLAGS_NUMBER',
    'SDL_PROP_WINDOW_CREATE_HIDDEN_BOOLEAN', 'SDL_WINDOW_HIDDEN',
    'SDL_PROP_WINDOW_CREATE_FOCUSABLE_BOOLEAN', 'SDL_WINDOW_NOT_FOCUSABLE',
    'SDL_PROP_WINDOW_CREATE_UTILITY_BOOLEAN', 'SDL_WINDOW_UTILITY',
    'SDL_PROP_WINDOW_CREATE_OPENGL_BOOLEAN', 'SDL_WINDOW_OPENGL',
    'SDL_PROP_WINDOW_CREATE_VULKAN_BOOLEAN', 'SDL_WINDOW_VULKAN',
  ];
  add('requested-flags', 'shared requested-create-flags reconstruction', check(
    Boolean(helper || sourceFallback)
      && hasAll(helperText, requestedTokens)
      && createText.includes('SDL_GetWindowCreateFlags')
      && createText.includes('create_props')
      && Boolean(classify || sourceFallback)
      && hasAny(createText, [
        /OPENHARMONY_(?:Classify|Get|Resolve)WindowRole\s*\(/,
        /OPENHARMONY_WINDOW_AUXILIARY_PBUFFER/,
      ])
      && hasAll(classifyText, [
        'SDL_WINDOW_HIDDEN', 'SDL_WINDOW_UTILITY', 'SDL_WINDOW_NOT_FOCUSABLE',
        'SDL_WINDOW_OPENGL', 'SDL_WINDOW_VULKAN',
      ]),
    'core helper must merge FLAGS_NUMBER/boolean properties (including inverted focusable), and OpenHarmony must classify requested—not core-forced—flags',
    helper ? `${helper.rel}:${helper.name}` : null,
  ));

  add('fixed-egl-config', 'one locked WINDOW|PBUFFER EGLConfig', check(
    allCode.includes('egl_config_locked')
      && Boolean(lock || sourceFallback)
      && lockText.includes('egl_config_locked')
      && Boolean(choose || sourceFallback)
      && chooseText.includes('egl_config_locked')
      && hasAll(ohCode, ['EGL_WINDOW_BIT', 'EGL_PBUFFER_BIT', 'EGL_SURFACE_TYPE'])
      && hasAny(ohCode, [/\beglGetConfigAttrib\b/, /\bSDL_EGL_[A-Za-z0-9_]*GetConfigAttrib\b/])
      && ohCode.includes('SDL_EGL_LockConfig'),
    'EGL selection must verify WINDOW|PBUFFER capability and lock the exact config before creating either surface',
    lock ? `${lock.rel}:${lock.name}` : null,
  ));

  add('window-roles', 'presented/auxiliary role model', check(
    hasAll(ohCode, [
      'OPENHARMONY_WindowRole',
      'OPENHARMONY_WINDOW_PRESENTED',
      'OPENHARMONY_WINDOW_AUXILIARY_PBUFFER',
      'OPENHARMONY_GetPresentedWindow',
      'presented_window',
      'auxiliary_window_count',
    ])
      && /\bOPENHARMONY_WindowRole\s+role\b/.test(ohCode)
      && !/\bSDL_Window\s*\*\s*OPENHARMONY_Window\b/.test(ohCode),
    'every WindowData needs an explicit role; only the presented accessor may own host-visible/input state',
  ));

  add('auxiliary-pbuffer', 'auxiliary windows use offscreen EGL surfaces', check(
    createText.includes('OPENHARMONY_WINDOW_AUXILIARY_PBUFFER')
      && ohCode.includes('SDL_EGL_CreateOffscreenSurface')
      && hasAll(ohCode, ['EGL_NO_SURFACE', 'surface_width', 'surface_height']),
    'auxiliary OpenGL windows must retain independent SDL_Window/EGLSurface state and use SDL_EGL_CreateOffscreenSurface',
  ));

  const acquireEvidence = hasAny(ohCode, [
    /\b[A-Za-z0-9_]*Acquire[A-Za-z0-9_]*NativeWindow[A-Za-z0-9_]*Lease\b/,
    /\bnative_window_lease_broker\s*->\s*acquire\b/,
    /\blease_broker\s*->\s*acquire\b/,
  ]);
  const releaseEvidence = hasAny(ohCode, [
    /\b[A-Za-z0-9_]*Release[A-Za-z0-9_]*NativeWindow[A-Za-z0-9_]*Lease\b/,
    /\bnative_window_lease_broker\s*->\s*release\b/,
    /\blease_broker\s*->\s*release\b/,
  ]);
  add('lease-broker', 'versioned NativeWindow lease ownership', check(
    ohLive.includes('AMCL_NATIVE_WINDOW_LEASE_BROKER')
      && /\b(?:native_window_)?lease_broker\b/.test(ohCode)
      && acquireEvidence && releaseEvidence
      && hasAny(destroyText, [
        /\b[A-Za-z0-9_]*Release[A-Za-z0-9_]*NativeWindow[A-Za-z0-9_]*Lease\b/,
        /\b(?:native_window_)?lease_broker\s*->\s*release\b/,
      ]),
    'presented creation must acquire a versioned cross-namespace lease and every destruction path must release it',
  ));

  const createStealsFocus = Boolean(create)
    && /\bSDL_Set(?:Mouse|Keyboard)Focus\s*\(/.test(create.body);
  add('role-aware-focus', 'show/hide focus is presented-only', check(
    Boolean(show || sourceFallback) && Boolean(hide || sourceFallback)
      && hasAll(showText, ['OPENHARMONY_WINDOW_PRESENTED', 'SDL_SetMouseFocus', 'SDL_SetKeyboardFocus'])
      && hideText.includes('OPENHARMONY_WINDOW_PRESENTED')
      && /SDL_Set(?:Mouse|Keyboard)Focus\s*\([^,;]*(?:NULL|nullptr|0)\s*\)/.test(hideText)
      && /SetWindow(?:Show|Hide)|ShowWindow|HideWindow/.test(ohCode)
      && !createStealsFocus,
    'hidden auxiliary creation must never steal focus; wired show/hide hooks may change focus only for PRESENTED',
    createStealsFocus ? `${create.rel}:${create.name} still sets focus` : null,
  ));

  add('role-aware-pixel-size', 'pixel size follows each surface role', check(
    Boolean(pixels || sourceFallback)
      && /GetWindowSizeInPixels\s*=\s*OPENHARMONY_GetWindowSizeInPixels/.test(ohCode)
      && hasAll(pixelText, [
        'OPENHARMONY_WINDOW_AUXILIARY_PBUFFER',
        'OPENHARMONY_WINDOW_PRESENTED',
        'surface_width', 'surface_height',
      ]),
    'GetWindowSizeInPixels must be wired and return pbuffer dimensions for auxiliary windows and host dimensions for presented windows',
    pixels ? `${pixels.rel}:${pixels.name}` : null,
  ));

  // 新实现把“已呈现但下一帧准备失败”的事实留在驱动包装内；检查真实调用边界与
  // 单一通知点，不能强制通知必须位于旧SwapWindow成功分支，也不能放过不可达helper。
  const observedSwap = extractFunction(files, ['OPENHARMONY_AMCL_ObservedSwap']);
  const observedText = observedSwap ? code(observedSwap.body) : '';
  const helperNotifies = count(observedText, /\bOPENHARMONY_AMCL_NotifyFramePresented\s*\(/g) > 0;
  const notificationText = helperNotifies ? observedText : swapText;
  const notifyCount = sourceFallback ? 1 : count(swapText, /\bOPENHARMONY_AMCL_NotifyFramePresented\s*\(/g)
    + count(observedText, /\bOPENHARMONY_AMCL_NotifyFramePresented\s*\(/g);
  const notifyPresentedOnly = sourceFallback
    ? /OPENHARMONY_WINDOW_PRESENTED[\s\S]{0,1200}OPENHARMONY_AMCL_NotifyFramePresented\s*\(/.test(ohCode)
    : /if\s*\([^)]*OPENHARMONY_WINDOW_PRESENTED[^)]*\)[\s\S]{0,600}\bOPENHARMONY_AMCL_NotifyFramePresented\s*\(/.test(notificationText);
  const evidenceGated = !helperNotifies || (swapText.includes('OPENHARMONY_AMCL_ObservedSwap')
    && /OPENHARMONY_WINDOW_PRESENTED\s*&&\s*data->amcl_last_swap_presented/.test(observedText)
    && /amcl_last_swap_presented\s*=\s*verify\s*\?\s*runtime->presentSequence\(\)\s*>\s*before_present\s*:\s*result/.test(observedText));
  // 观测包装必须真实调用驱动并原样返回结果；不能仅因出现包装函数名就放过空实现。
  const actualSwap = swapText.includes('SDL_EGL_SwapBuffers') || (swapText.includes('OPENHARMONY_AMCL_ObservedSwap')
    && observedSwap && hasAll(observedSwap.body, ['SDL_EGL_SwapBuffersWithError', 'data->egl_surface',
      'return result;', 'data->role == OPENHARMONY_WINDOW_PRESENTED', 'observer->swapped']));
  add('role-aware-swap', 'swap/present notification follows window role', check(
    Boolean(swap || sourceFallback)
      && hasAll(swapText, ['OPENHARMONY_WINDOW_AUXILIARY_PBUFFER', 'OPENHARMONY_WINDOW_PRESENTED'])
      && actualSwap
      && notifyCount === 1 && notifyPresentedOnly && evidenceGated,
    'both surfaces may swap, but frame-present notification must occur exactly once and only under the PRESENTED branch',
    swap ? `${swap.rel}:${swap.name}` : null,
  ));

  const singletonEarlyReturn = sourceFallback
    ? false
    : /if\s*\([^)]*(?:\bOPENHARMONY_Window\b|presented_window)[^)]*\)\s*\{?\s*return\b/.test(destroyText);
  // 0020 的辅助面使用有返回值的退休 helper；必须核对 helper 的真实驱动调用与成功后清槽，
  // 不能仅凭函数名字放行。既有基线的直接销毁入口仍可接受，行为回归另验证失败保留链。
  const auxiliaryRetire = extractFunction(files, ['OPENHARMONY_RetireAuxiliarySurface']);
  const checkedAuxiliaryRetirement = destroyText.includes('OPENHARMONY_RetireAuxiliarySurface')
    && (sourceFallback || (auxiliaryRetire
      && hasAll(auxiliaryRetire.body, ['eglDestroySurface', 'eglGetError', 'return false'])
      && /\*surface\s*=\s*EGL_NO_SURFACE/.test(auxiliaryRetire.body)));
  add('destroy-any-role', 'DestroyWindow frees any WindowData', check(
    Boolean(destroy || sourceFallback)
      && hasAll(destroyText, [
        'window->internal', 'OPENHARMONY_WINDOW_PRESENTED',
        'OPENHARMONY_WINDOW_AUXILIARY_PBUFFER', 'SDL_free',
      ])
      && (hasAny(destroyText, ['SDL_EGL_DestroySurface', 'eglDestroySurface']) || checkedAuxiliaryRetirement)
      && /window->internal\s*=\s*(?:NULL|nullptr|0)/.test(destroyText)
      && !singletonEarlyReturn,
    'DestroyWindow must release the surface/lease/data for every role; role may select extra cleanup but may not guard the base free',
    singletonEarlyReturn ? 'singleton-only early return found' : null,
  ));

  const fingerprintPatterns = [
    /["']Minecraft[^"]*["']/i,
    /["']RenderPearl[^"]*["']/i,
    /["'][^"']*snapshot[-_ ]?[0-9]+[^"']*["']/i,
    /["'][^"']*26\.3(?:\.\d+)?[^"']*["']/i,
    /["'][0-9a-f]{40,64}["']/i,
  ];
  const titleSelectorInput = sourceFallback
    ? maskDesktopTitleCommandArgument(ohCode) : `${createText}\n${classifyText}`;
  const classifierUsesTitle = /\b(?:SDL_GetWindowTitle|SDL_PROP_WINDOW_CREATE_TITLE_STRING)\b|\bwindow\s*->\s*title\b/.test(titleSelectorInput);
  add('no-runtime-fingerprints', 'no title/version/class-hash special case', check(
    !hasAny(ohLive, fingerprintPatterns) && !classifierUsesTitle,
    'window roles must derive only from SDL create flags/properties; title, Minecraft version, snapshot label and class hash are forbidden runtime selectors',
    classifierUsesTitle ? `${create?.rel ?? 'OpenHarmony create path'} reads title` : null,
  ));

  // I27-05：前台位是 env_slot.h 预登记的单字节静态槽位，唯一写者经 Store(kWindowForegroundEnv, …)
  // 原位翻转；任何 setenv/unsetenv/putenv 直接改写这个名字都会释放 SDL 每帧持有的旧串，必须为 0。
  const foregroundSlotWriters = count(
    hostNativeLive, /\bStore\s*\(\s*(?:amcl::envslot::)?kWindowForegroundEnv\b/g,
  );
  const foregroundRawEnvWriters = count(
    hostNativeLive,
    /\b(?:setenv|unsetenv|putenv|SDL_setenv_unsafe|SDL_unsetenv_unsafe)\s*\(\s*(?:["']AMCL_WINDOW_FOREGROUND["']|(?:amcl::envslot::)?kWindowForegroundEnv\b)/g,
  );
  const foregroundEnvWriters = foregroundSlotWriters + foregroundRawEnvWriters;
  add('focus-independent-activation',
    'presented input has a current-state activation path independent of focus edges',
    check(
      hasAll(hostActivationCode, [
        'ComponentFocus', 'Unknown', 'Focused', 'Blurred',
        'ComputeInputForegroundGate', 'surfacePublished',
        'abilityForegroundMask', 'PublishInputForegroundGateLocked',
        'PublishInputForegroundGateForAbility',
      ])
        && /abilityForegroundMask\s*==\s*0u?/.test(hostActivationCode)
        && /focus\s*!=\s*ComponentFocus\s*::\s*Blurred/.test(hostActivationCode)
        && /PublishInputForegroundSurfaceState\s*\(\s*true\s*,/.test(hostActivationCode)
        && /PublishInputForegroundGateForAbility\s*\(\s*foregroundMask\s*,/.test(hostActivationCode)
        && foregroundSlotWriters === 0 && foregroundRawEnvWriters === 0
        && /amclWindowHostSetInputForeground\s*\(/.test(hostActivationCode)
        && /peekInputForeground\s*\(\s*\)\s*==\s*1u/.test(ohCode)
        && /structSize\s*>=\s*AMCL_INPUT_FOREGROUND_BROKER_SIZE/.test(ohCode),
      'host activation must compose published surface + nonzero Ability mask + three-valued focus, open Unknown without waiting for OnFocus, and consume size-checked broker foreground authority without any mutable environment channel',
      `AMCL_WINDOW_FOREGROUND writers=${foregroundEnvWriters} slot=${foregroundSlotWriters} raw-env=${foregroundRawEnvWriters}`,
    ));

  const drainAt = setPresentedActiveText.indexOf('OPENHARMONY_PumpTypedEvents');
  const retireAt = setPresentedActiveText.indexOf(
    'typed_set_active(AMCL_BACKEND_ID_SDL3, 0)',
  );
  add('typed-focus-capture', 'typed backend focus/capture lifecycle is consumed', check(
    hasAll(hostTypedInputCode, [
      'AMCL_BACKEND_INPUT_EVENT_FOCUS', 'AMCL_BACKEND_INPUT_EVENT_CAPTURE',
      'FocusSink', 'CaptureSink', 'sink.focus = FocusSink',
      'sink.capture = CaptureSink',
    ])
      && hasAll(ohCode, [
        'AMCL_BACKEND_EVENT_FOCUS', 'AMCL_BACKEND_EVENT_CAPTURE',
        'OPENHARMONY_ApplyTypedFocus', 'SDL_SetKeyboardFocus', 'SDL_SetMouseFocus',
        'OPENHARMONY_ApplyTypedCapture', 'host_capture_requested',
        'host_capture_active', 'AMCL_CAPTURE_REASON_NONE',
        'AMCL_CAPTURE_REASON_GRANTED',
        'OPENHARMONY_DisableRelativeModeForHostLoss',
      ])
      && /case\s+AMCL_BACKEND_EVENT_FOCUS\s*:/.test(typedPumpText)
      && /case\s+AMCL_BACKEND_EVENT_CAPTURE\s*:/.test(typedPumpText)
      && /!host_capture_active\s*&&\s*event->resetReason\s*!=\s*AMCL_CAPTURE_REASON_NONE/.test(
        captureText,
      )
      && /event->resetReason\s*!=\s*AMCL_CAPTURE_REASON_GRANTED/.test(ohCode)
      && drainAt >= 0 && retireAt > drainAt,
    'host must wire FOCUS/CAPTURE; SDL must validate and apply both, preserve pending capture, unwind only release/loss, and drain lifecycle before SetActive(0)',
    `drainAt=${drainAt} retireAt=${retireAt}`,
  ));

  const requestFlagAt = setRelativeModeText.indexOf('SDL_WINDOW_MOUSE_RELATIVE_MODE');
  const authoritySnapshotAt = setRelativeModeText.indexOf(
    'disable_authority = host_relative_disable_authority',
  );
  const authorityClearAt = setRelativeModeText.indexOf(
    'host_relative_disable_authority = AMCL_RELATIVE_DISABLE_NONE',
    authoritySnapshotAt >= 0 ? authoritySnapshotAt : 0,
  );
  const authorityBranchAt = setRelativeModeText.indexOf(
    'disable_authority != AMCL_RELATIVE_DISABLE_NONE',
  );
  const authorityReturnAt = setRelativeModeText.indexOf('return true', authorityBranchAt);
  const unclassifiedAt = setRelativeModeText.indexOf(
    'host_unclassified_relative_release_count',
    authorityReturnAt >= 0 ? authorityReturnAt : 0,
  );
  const rejectAt = Math.max(
    setRelativeModeText.indexOf('return SDL_SetError', unclassifiedAt),
    setRelativeModeText.indexOf('return false', unclassifiedAt),
  );
  const setGrabZeroAt = setRelativeModeText.indexOf(
    'bridge->SetGrabState(0)', rejectAt >= 0 ? rejectAt : 0,
  );
  const setGrabOneAt = setRelativeModeText.indexOf(
    'bridge->SetGrabState(1)', rejectAt >= 0 ? rejectAt : 0,
  );
  const setGrabTernaryAt = setRelativeModeText.indexOf(
    'bridge->SetGrabState(enabled ? 1 : 0)',
    rejectAt >= 0 ? rejectAt : 0,
  );
  const setGrabAt = [setGrabZeroAt, setGrabOneAt, setGrabTernaryAt]
    .filter((at) => at >= 0).sort((a, b) => a - b)[0] ?? -1;
  const authorityBranchText = authorityBranchAt >= 0 && authorityReturnAt > authorityBranchAt
    ? setRelativeModeText.slice(authorityBranchAt, authorityReturnAt + 'return true'.length)
    : '';

  const hostAuthorityAt = disableRelativeForHostLossText.indexOf(
    'host_relative_disable_authority = authority',
  );
  const hostDisableAt = disableRelativeForHostLossText.indexOf(
    'SDL_SetRelativeMouseMode(false)',
    hostAuthorityAt >= 0 ? hostAuthorityAt : 0,
  );
  const hostAuthorityClearAt = disableRelativeForHostLossText.indexOf(
    'host_relative_disable_authority = AMCL_RELATIVE_DISABLE_NONE',
    hostDisableAt >= 0 ? hostDisableAt : 0,
  );
  const focusAuthorityAt = applyFocusText.indexOf(
    'host_relative_disable_authority = AMCL_RELATIVE_DISABLE_FOCUS_LOST',
  );
  const focusClearAt = applyFocusText.indexOf('SDL_SetKeyboardFocus(NULL)');
  const focusAuthorityClearAt = applyFocusText.indexOf(
    'host_relative_disable_authority = AMCL_RELATIVE_DISABLE_NONE',
    focusClearAt >= 0 ? focusClearAt : 0,
  );
  const resetCaseText = sourceFallback ? '' : extractSwitchCase(
    typedPumpText, 'AMCL_BACKEND_EVENT_RESET',
  );
  const patchCarriesRelativeAuthority = sourceFallback && (
    (metadata.patches ?? []).some((name) =>
      /openharmony-relative-authority-surface-context\.patch$/.test(normalizePath(name)))
      || hasAll(ohCode, [
        'host_relative_disable_authority',
        'AMCL_RELATIVE_DISABLE_FOCUS_LOST',
        'AMCL_RELATIVE_DISABLE_CAPTURE_LOST',
        'host_unclassified_relative_release_count',
      ])
  );
  const resetPreservesRelative = sourceFallback
    ? patchCarriesRelativeAuthority
    : resetCaseText.length > 0
      && !hasAny(resetCaseText, [
        'OPENHARMONY_DisableRelativeModeForHostLoss',
        'SDL_SetRelativeMouseMode',
        'SetGrabState',
        /host_capture_(?:requested|active)\s*=\s*false/,
      ]);
  const relativeAuthorityTokens = hasAll(ohCode, [
    'host_relative_disable_authority',
    'AMCL_RELATIVE_DISABLE_NONE',
    'AMCL_RELATIVE_DISABLE_FOCUS_LOST',
    'AMCL_RELATIVE_DISABLE_CAPTURE_LOST',
    'host_unclassified_relative_release_count',
  ]);
  const exactRelativeAuthorityStructure = requestFlagAt >= 0
    && authoritySnapshotAt >= 0
    && authorityClearAt > authoritySnapshotAt
    && authorityBranchAt >= 0
    && authorityReturnAt > authorityBranchAt
    && unclassifiedAt > requestFlagAt
    && unclassifiedAt > authorityReturnAt
    && rejectAt > unclassifiedAt
    && setGrabAt > rejectAt
    && !authorityBranchText.includes('SetGrabState')
    && hostAuthorityAt >= 0
    && hostDisableAt > hostAuthorityAt
    && hostAuthorityClearAt > hostDisableAt
    && !disableRelativeForHostLossText.includes('SetGrabState')
    && focusAuthorityAt >= 0
    && focusClearAt > focusAuthorityAt
    && focusAuthorityClearAt > focusClearAt
    && /OPENHARMONY_DisableRelativeModeForHostLoss\s*\(\s*AMCL_RELATIVE_DISABLE_CAPTURE_LOST\s*\)/.test(
      captureText,
    );
  // Patch-series reconstruction concatenates successive post-hunk fragments;
  // an older implementation of the same function can therefore precede the
  // final one. Keep ordering checks local to the new fragment and reserve the
  // exact function/no-side-effect proof for the mandatory applied-source run.
  const patchRelativeAuthorityStructure =
    /input_window->flags\s*&\s*SDL_WINDOW_MOUSE_RELATIVE_MODE/.test(ohCode)
    && /disable_authority\s*!=\s*AMCL_RELATIVE_DISABLE_NONE[\s\S]{0,900}return\s+true/.test(
      ohCode,
    )
    && /host_unclassified_relative_release_count[\s\S]{0,1200}return\s+SDL_SetError/.test(
      ohCode,
    )
    && /host_capture_requested\s*=\s*(?:enabled|true)[\s\S]{0,900}bridge->SetGrabState\s*\(\s*1\s*\)/.test(ohCode)
    && /host_capture_requested\s*=\s*false[\s\S]{0,900}bridge->SetGrabState\s*\(\s*0\s*\)/.test(ohCode)
    && /host_relative_disable_authority\s*=\s*authority[\s\S]{0,500}SDL_SetRelativeMouseMode\s*\(\s*false\s*\)[\s\S]{0,500}host_relative_disable_authority\s*=\s*AMCL_RELATIVE_DISABLE_NONE/.test(
      ohCode,
    )
    && /host_relative_disable_authority\s*=\s*AMCL_RELATIVE_DISABLE_FOCUS_LOST[\s\S]{0,500}SDL_SetKeyboardFocus\s*\(\s*NULL\s*\)[\s\S]{0,500}host_relative_disable_authority\s*=\s*AMCL_RELATIVE_DISABLE_NONE/.test(
      ohCode,
    )
    && /OPENHARMONY_DisableRelativeModeForHostLoss\s*\(\s*AMCL_RELATIVE_DISABLE_CAPTURE_LOST\s*\)/.test(
      ohCode,
    );
  const relativeAuthorityStructure = relativeAuthorityTokens &&
    (sourceFallback ? patchRelativeAuthorityStructure : exactRelativeAuthorityStructure);

  const w0RequestAt = updatePresentedForegroundText.indexOf(
    'SDL_WINDOW_MOUSE_RELATIVE_MODE',
  );
  const w0BridgeReadAt = updatePresentedForegroundText.indexOf(
    'bridge->IsGrabbing()', w0RequestAt >= 0 ? w0RequestAt : 0,
  );
  const w0RequestedClearAt = updatePresentedForegroundText.indexOf(
    'host_capture_requested = false', w0BridgeReadAt >= 0 ? w0BridgeReadAt : 0,
  );
  const w0ActiveClearAt = updatePresentedForegroundText.indexOf(
    'host_capture_active = false', w0RequestedClearAt >= 0 ? w0RequestedClearAt : 0,
  );
  const w0SetGrabAt = updatePresentedForegroundText.indexOf(
    'bridge->SetGrabState(0)', w0BridgeReadAt >= 0 ? w0BridgeReadAt : 0,
  );
  const staleGrabClears = w0RequestAt >= 0
    && /SDL_WINDOW_MOUSE_RELATIVE_MODE\s*\)\s*==\s*0/.test(
      updatePresentedForegroundText,
    )
    && w0BridgeReadAt > w0RequestAt
    && w0RequestedClearAt > w0BridgeReadAt
    && w0ActiveClearAt > w0RequestedClearAt
    && w0SetGrabAt > w0ActiveClearAt;

  const grantRestoreAt = captureText.indexOf('SDL_SetRelativeMouseMode(true)');
  const grantRestoreGuard = grantRestoreAt >= 0
    ? captureText.slice(Math.max(0, grantRestoreAt - 1800), grantRestoreAt)
    : '';
  const grantedReactivation = grantRestoreAt >= 0
    && hasAll(grantRestoreGuard, [
      'host_capture_requested', 'host_capture_active',
      'AMCL_CAPTURE_REASON_GRANTED', 'host_presented_active',
      'input_window', 'bridge->IsGrabbing', 'SDL_GetKeyboardFocus',
      'SDL_WINDOW_MOUSE_RELATIVE_MODE', 'SDL_GetRelativeMouseMode',
    ])
    && /event->resetReason\s*==\s*AMCL_CAPTURE_REASON_GRANTED/.test(grantRestoreGuard)
    && /SDL_GetKeyboardFocus\s*\(\s*\)\s*==\s*input_window/.test(grantRestoreGuard)
    && /!\s*SDL_GetRelativeMouseMode\s*\(\s*\)/.test(grantRestoreGuard);

  const enableRequestAt = setRelativeModeText.indexOf('host_capture_requested = true');
  const enableNeedsBridgeAt = setRelativeModeText.indexOf(
    '!bridge->IsGrabbing()', enableRequestAt >= 0 ? enableRequestAt : 0,
  );
  const enableActiveResetAt = setRelativeModeText.indexOf(
    'host_capture_active = false', enableNeedsBridgeAt >= 0 ? enableNeedsBridgeAt : 0,
  );
  const enableSetGrabAt = setRelativeModeText.indexOf(
    'bridge->SetGrabState(1)', enableNeedsBridgeAt >= 0 ? enableNeedsBridgeAt : 0,
  );
  const enableGuardTail = enableNeedsBridgeAt >= 0
    ? setRelativeModeText.slice(Math.max(0, enableNeedsBridgeAt - 40), enableSetGrabAt + 30)
    : '';
  const beforeEnableGuard = enableRequestAt >= 0 && enableNeedsBridgeAt > enableRequestAt
    ? setRelativeModeText.slice(enableRequestAt, enableNeedsBridgeAt)
    : '';
  const idempotentEnablePreservesGrant = enableRequestAt >= 0
    && enableNeedsBridgeAt > enableRequestAt
    && !beforeEnableGuard.includes('host_capture_active = false')
    && !beforeEnableGuard.includes('SetGrabState')
    && enableActiveResetAt > enableNeedsBridgeAt
    && enableSetGrabAt > enableActiveResetAt
    && /if\s*\(\s*!bridge->IsGrabbing\s*\(\s*\)\s*\)/.test(enableGuardTail);

  const teardownAt = setRelativeModeText.indexOf('if (!enabled && driver_teardown)');
  const inactiveWindowAt = setRelativeModeText.indexOf(
    '!host_presented_active || !input_window',
  );
  const teardownBody = teardownAt >= 0 && inactiveWindowAt > teardownAt
    ? setRelativeModeText.slice(teardownAt, inactiveWindowAt)
    : '';
  const driverTeardownClears = teardownBody.length > 0
    && hasAll(teardownBody, [
      'host_capture_requested = false', 'host_capture_active = false',
      'bridge->SetGrabState(0)', 'return true',
    ]);
  const quitMouseClears = hasAll(quitMouseText, [
    'OPENHARMONY_AMCL_SetPresentedActive(false)',
    'bridge->SetGrabState(0)',
    'host_capture_requested = false',
    'host_capture_active = false',
    'host_relative_disable_authority = AMCL_RELATIVE_DISABLE_NONE',
  ]);
  const exactCurrentStateClosure = staleGrabClears && grantedReactivation
    && idempotentEnablePreservesGrant && driverTeardownClears && quitMouseClears;
  const patchCurrentStateClosure = hasAll(ohCode, [
    'SDL_SetRelativeMouseMode(true)',
    'host_capture_requested = true',
    'host_capture_requested = false',
    'host_capture_active = false',
    'SDL_GetKeyboardFocus',
    'SDL_GetRelativeMouseMode',
    'SDL_WINDOW_MOUSE_RELATIVE_MODE',
  ])
    && /SDL_WINDOW_MOUSE_RELATIVE_MODE\s*\)\s*==\s*0[\s\S]{0,1200}bridge->IsGrabbing\s*\(\s*\)[\s\S]{0,1200}host_capture_requested\s*=\s*false[\s\S]{0,500}host_capture_active\s*=\s*false[\s\S]{0,500}SetGrabState\s*\(\s*0\s*\)/.test(
      ohCode,
    )
    && /event->resetReason\s*==\s*AMCL_CAPTURE_REASON_GRANTED[\s\S]{0,1000}SDL_GetKeyboardFocus\s*\(\s*\)\s*==\s*input_window[\s\S]{0,1000}!SDL_GetRelativeMouseMode\s*\(\s*\)[\s\S]{0,500}SDL_SetRelativeMouseMode\s*\(\s*true\s*\)/.test(
      ohCode,
    )
    && /host_capture_requested\s*=\s*true[\s\S]{0,700}if\s*\(\s*!bridge->IsGrabbing\s*\(\s*\)\s*\)[\s\S]{0,500}host_capture_active\s*=\s*false[\s\S]{0,500}SetGrabState\s*\(\s*1\s*\)/.test(
      ohCode,
    )
    && /!enabled\s*&&\s*driver_teardown[\s\S]{0,900}host_capture_requested\s*=\s*false[\s\S]{0,500}host_capture_active\s*=\s*false[\s\S]{0,500}SetGrabState\s*\(\s*0\s*\)/.test(
      ohCode,
    )
    && /OPENHARMONY_AMCL_SetPresentedActive\s*\(\s*false\s*\)[\s\S]{0,1000}SetGrabState\s*\(\s*0\s*\)[\s\S]{0,700}host_capture_requested\s*=\s*false[\s\S]{0,500}host_capture_active\s*=\s*false/.test(
      ohCode,
    );
  const currentStateClosure = sourceFallback
    ? patchCurrentStateClosure : exactCurrentStateClosure;
  add('relative-disable-authority',
    'only application or one-shot host lifecycle authority may leave relative mode', check(
      relativeAuthorityStructure && resetPreservesRelative && currentStateClosure,
      'bridge grab must retain the app request across host suspension; current-state reconciliation must clear stale W=0 grab once, reactivate a granted W=1 relative session without losing capture, and best-effort clear teardown/window-null state',
      `structure=${relativeAuthorityStructure} resetPreserves=${resetPreservesRelative} `
        + `currentState=${currentStateClosure} staleClear=${staleGrabClears} `
        + `grantReactivate=${grantedReactivation} enablePreserves=${idempotentEnablePreservesGrant} `
        + `driverTeardown=${driverTeardownClears} quitCleanup=${quitMouseClears} `
        + `requestAt=${requestFlagAt} authorityAt=${authorityBranchAt} rejectAt=${rejectAt} setGrabAt=${setGrabAt}`,
    ));

  // 旧 v3 来源快照与新 look-v1 不可混作一个机制。look-v1 必须有同序 opaque prefix、
  // ordered physical 索引与真实 SDK receipt；缺任何接缝均拒绝，不能回到最新累计/原 raw。
  // 完整 SDK 行为由独立纵向测试证明，这里继续核所有当前承重源码结构而不跳过旧规则。
  const lookByOrder = /physicalPrefixByOrder\s*\(\s*event\.sequence/.test(typedPumpText);
  const lookEdge = sourceFallback ? ohCode : code(extractFunction(files, ['OPENHARMONY_DeliverLookForMouse'])?.body ?? '');
  const lookCurrent = sourceFallback ? ohCode : code(extractFunction(files, ['OPENHARMONY_LookCurrent'])?.body ?? '');
  const prefixLookContract = lookByOrder
    && hasAll(allCode, ['SDL_AMCL_InputLookProtocolV1', 'amclLookExecutionResolveV1'])
    && hasAll(ohCode, ['OPENHARMONY_DeliverLookForMouse', 'SDL_SendMouseMotionWithReceipt',
      'AMCL_CONTROL_STATE_ONLY', 'AMCL_CONTROL_PULL_COMMITTED', 'AMCL_CONTROL_STATE_FINAL',
      'abandonPrefix', 'setBackendActive'])
    && /case\s+1020\s*:[\s\S]{0,950}OPENHARMONY_DeliverLook\s*\(\s*token\s*\)/.test(ohCode)
    && /if\s*\(\s*grabbing\s*\)\s*return\s*;/.test(cursorPumpText)
    && !/GetCursorSnapshot\s*\([^)]*\)[\s\S]*if\s*\(\s*grabbing\s*\)/.test(cursorPumpText)
    && !/case\s+AMCL_BACKEND_EVENT_RELATIVE\s*:[\s\S]{0,1600}SDL_SendMouseMotion\s*\([^;]*event\.wheelX/.test(typedPumpText)
    && /claim\s*\([\s\S]*SDL_SendMouseMotionWithReceipt/.test(lookEdge)
    && /receipt\.posted\s*\?\s*AMCL_CONTROL_PULL_COMMITTED/.test(lookEdge)
    && /validate\s*\(\s*&context->emission\s*\)/.test(lookCurrent);
  const legacyLookContract = !lookByOrder
    && ohCode.includes('host_grabbed_motion_delivered')
    && /case\s+AMCL_BACKEND_EVENT_RELATIVE\s*:[\s\S]{0,700}SDL_SendMouseMotion\s*\([^;]*\btrue\b/.test(typedPumpText);
  add('typed-relative-single-owner', 'physical and nonphysical motion have distinct delivery sources', check(
    hasAll(hostTypedInputCode, ['AMCL_BACKEND_INPUT_EVENT_RELATIVE',
      'AMCL_BACKEND_INPUT_RELATIVE_FLAG_HARDWARE_RAW', 'RelativeSink', 'sink.relative = RelativeSink',
      'out.wheelX', 'out.wheelY'])
      && hasAll(ohCode, ['AMCL_BACKEND_EVENT_RELATIVE', 'AMCL_BACKEND_RELATIVE_FLAG_HARDWARE_RAW',
        'AMCL_BACKEND_RELATIVE_FLAG_MASK', 'isnan', 'isinf', 'host_capture_requested', 'host_capture_active'])
      && ohRaw.includes('AMCLSDLV:3:')
      && ohRaw.includes('inputBridge_sdlGetNonPhysicalCursorSnapshot')
      && !/host_typed_relative_seen|OPENHARMONY_TypedRelativeOwnsGrabbedMotion/.test(ohCode)
      && !/if\s*\(\s*grabbing\s*&&\s*typed_relative_owner/.test(cursorPumpText)
      && (prefixLookContract || legacyLookContract)
      && /static\s+bool\s+OPENHARMONY_TypedRelativeCaptureGranted\s*\(\s*void\s*\)[\s\S]{0,240}host_capture_requested\s*&&\s*host_capture_active/.test(ohCode)
      && /OPENHARMONY_TypedRelativeCaptureGranted\s*\(\s*\)\s*&&\s*SDL_GetRelativeMouseMode/.test(typedPumpText)
      && /OPENHARMONY_PumpHostCursor\s*\(\s*bridge\s*,\s*typed_relative_owner\s*\)/.test(pumpEventsText),
    'look-v1 requires immutable virtual prefix plus ordered physical memo/SDK receipts; legacy v3 retains distinct source delivery and neither mode may suppress all grabbed sources',
  ));

  const surfaceValidatorCase = sourceFallback ? '' : extractSwitchCase(
    validateTypedText, 'AMCL_BACKEND_EVENT_SURFACE_CONTEXT',
  );
  const surfacePumpCase = sourceFallback ? '' : extractSwitchCase(
    typedPumpText, 'AMCL_BACKEND_EVENT_SURFACE_CONTEXT',
  );
  const surfaceCaseCount = count(
    ohCode, /case\s+AMCL_BACKEND_EVENT_SURFACE_CONTEXT\s*:/g,
  );
  const surfaceHost = hasAll(hostTypedInputCode, [
    'AMCL_BACKEND_INPUT_EVENT_SURFACE_CONTEXT',
    'EncodeBackendSurfaceContext',
    'SurfaceContextSink',
    'sink.surfaceContext = SurfaceContextSink',
  ]) && /#\s*define\s+AMCL_BACKEND_INPUT_EVENT_SURFACE_CONTEXT\s+9u?\b/.test(
    hostTypedInputCode,
  );
  const surfaceSdl = hasAll(ohCode, [
    'AMCL_BACKEND_EVENT_SURFACE_CONTEXT',
    'AMCL_SURFACE_CONTEXT_FIELD_WINDOW',
    'AMCL_SURFACE_CONTEXT_FIELD_DISPLAY',
    'AMCL_SURFACE_CONTEXT_FIELD_RECT',
    'AMCL_SURFACE_CONTEXT_FIELD_DENSITY',
    'AMCL_SURFACE_CONTEXT_FIELD_TRANSFORM',
    'AMCL_SURFACE_CONTEXT_FIELD_REFRESH_RATE',
    'AMCL_SURFACE_CONTEXT_FIELD_ALL',
    'host_surface_context_generation',
  ]) && /#\s*define\s+AMCL_BACKEND_EVENT_SURFACE_CONTEXT\s+9u?\b/.test(ohCode);
  const surfaceFirstRejectAt = surfaceValidatorCase.indexOf('return false');
  const surfaceHeaderAt = surfaceValidatorCase.indexOf('event->deviceId');
  const surfaceValidator = sourceFallback
    ? surfaceCaseCount >= 2 && hasAll(ohCode, [
      'event->deviceId', 'valid_fields', 'transform',
      'AMCL_SURFACE_CONTEXT_FIELD_ALL',
      'AMCL_SURFACE_CONTEXT_FIELD_WINDOW',
      'AMCL_SURFACE_CONTEXT_FIELD_DISPLAY',
      'AMCL_SURFACE_CONTEXT_FIELD_RECT',
      'AMCL_SURFACE_CONTEXT_FIELD_DENSITY',
      'AMCL_SURFACE_CONTEXT_FIELD_TRANSFORM',
      'AMCL_SURFACE_CONTEXT_FIELD_REFRESH_RATE',
      'isnan', 'isinf',
    ])
    : hasAll(surfaceValidatorCase, [
      'event->deviceId', 'valid_fields', 'transform',
      'AMCL_SURFACE_CONTEXT_FIELD_ALL',
      'AMCL_SURFACE_CONTEXT_FIELD_WINDOW',
      'AMCL_SURFACE_CONTEXT_FIELD_DISPLAY',
      'AMCL_SURFACE_CONTEXT_FIELD_RECT',
      'AMCL_SURFACE_CONTEXT_FIELD_DENSITY',
      'AMCL_SURFACE_CONTEXT_FIELD_TRANSFORM',
      'AMCL_SURFACE_CONTEXT_FIELD_REFRESH_RATE',
      'isnan', 'isinf',
    ])
      && /event->deviceId\s*==\s*0u?/.test(surfaceValidatorCase)
      && /valid_fields\s*&\s*~AMCL_SURFACE_CONTEXT_FIELD_ALL/.test(surfaceValidatorCase)
      && /event->wheelX\s*<=\s*0\.0f/.test(surfaceValidatorCase)
      && /event->wheelY\s*>\s*1000\.0f/.test(surfaceValidatorCase)
      && /transform\s*>\s*3u?/.test(surfaceValidatorCase)
      && !(surfaceFirstRejectAt >= 0 && surfaceFirstRejectAt < surfaceHeaderAt);
  const surfaceConsumer = sourceFallback
    ? surfaceCaseCount >= 2
      && /host_surface_context_generation\s*=\s*event\.deviceId/.test(ohCode)
    : surfacePumpCase.length > 0
      && /host_surface_context_generation\s*=\s*event\.deviceId/.test(surfacePumpCase)
      && !hasAny(surfacePumpCase, [
        'SDL_SendKeyboardKey', 'SDL_SendMouseButton', 'SDL_SendMouseWheel',
        'SDL_SendMouseMotion', 'OPENHARMONY_ReadAndReleaseText',
      ]);
  add('typed-surface-context',
    'typed surface-context event is encoded, validated and explicitly consumed', check(
      surfaceHost && surfaceSdl && surfaceValidator && surfaceConsumer,
      'type 9 must be wired by the host, mirrored by SDL, validate generation/mask and each present field, then consume geometry without misclassifying it as input or malformed data',
      `host=${surfaceHost} sdl=${surfaceSdl} validator=${surfaceValidator} consumer=${surfaceConsumer} cases=${surfaceCaseCount}`,
    ));

  const pointerHostTokens = hasAll(hostTypedInputCode, [
        'AMCL_BACKEND_INPUT_EVENT_DEVICE', 'DeviceSink',
        'sink.device = DeviceSink', 'event.deviceClass',
        'ClearDeviceLocked', 'GlfwDeviceSinkEvent',
      ]);
  const pointerHostOrder =
    /case\s+AMCL_INPUT_EVENT_DEVICE_CHANGED\s*:[\s\S]{0,900}ClearDeviceLocked[\s\S]{0,900}GlfwDeviceSinkEvent/.test(
      hostTypedInputCode,
    );
  const pointerSdlTokens = hasAll(sourceFallback ? ohRaw : ohCode, [
          'AMCL_BACKEND_EVENT_DEVICE', 'OPENHARMONY_MouseIDFromHost',
          'SDL_AddMouse', 'SDL_RemoveMouse',
          'AMCL_DEVICE_CLASS_MOUSE', 'AMCL_DEVICE_CLASS_TOUCHPAD',
        ]);
  const pointerSdlStructure = sourceFallback || (
          /case\s+AMCL_BACKEND_EVENT_BUTTON\s*:[\s\S]{0,500}OPENHARMONY_SendButtonFromPlane\s*\(\s*2\s*,\s*event\.deviceId/.test(
            typedPumpText,
          )
          && /case\s+AMCL_BACKEND_EVENT_WHEEL\s*:[\s\S]{0,600}OPENHARMONY_MouseIDFromHost\s*\(\s*event\.deviceId\s*\)/.test(
            typedPumpText,
          )
          && /case\s+AMCL_BACKEND_EVENT_RELATIVE\s*:[\s\S]{0,800}OPENHARMONY_MouseIDFromHost\s*\(\s*event\.deviceId\s*\)/.test(
            typedPumpText,
          )
          && /case\s+AMCL_BACKEND_EVENT_DEVICE\s*:[\s\S]{0,900}SDL_AddMouse[\s\S]{0,900}SDL_RemoveMouse/.test(
            typedPumpText,
          )
          && /OPENHARMONY_HeldMouseSource/.test(releaseHeldText)
          && /held_sources\s*\[\s*source_index\s*\]\.mouse_id\s*=\s*mouse->sources\s*\[\s*source_index\s*\]\.mouseID/.test(
            releaseHeldText,
          )
          && /SDL_SendMouseButton\s*\([\s\S]{0,500}held_sources\s*\[\s*source_index\s*\]\.mouse_id/.test(
            releaseHeldText,
          )
          && /SDL_free\s*\(\s*held_sources\s*\)/.test(releaseHeldText)
          && /if\s*\(\s*window_lost\s*\)[\s\S]{0,500}mouse->sources\s*\[\s*live_index\s*\]\.buttonstate\s*=\s*0/.test(
            releaseHeldText,
          )
        );
  add('typed-pointer-device-identity',
    'typed pointer identity and SDL mouse lifecycle stay device-scoped', check(
      pointerHostTokens && pointerHostOrder && pointerSdlTokens &&
        pointerSdlStructure,
      'host must emit releases before DEVICE_REMOVED; SDL must map each nonzero host id to its own MouseID, consume add/remove, and RESET every held source by its own id without growing the 64-byte ABI',
      `hostTokens=${pointerHostTokens} hostOrder=${pointerHostOrder} sdlTokens=${pointerSdlTokens} sdlStructure=${pointerSdlStructure}`,
    ));

  const failures = results.filter((r) => !r.ok);
  return {
    ok: failures.length === 0,
    mode: metadata.mode ?? 'fixture',
    input: metadata.input ?? '<memory>',
    patches: metadata.patches ?? [],
    scannedFiles: files.size,
    passed: results.length - failures.length,
    total: results.length,
    results,
  };
}

function parseArgs(argv) {
  const opt = { repo: null, series: null, json: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--repo') opt.repo = argv[++i];
    else if (arg === '--patch-series') opt.series = argv[++i];
    else if (arg === '--json') opt.json = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (opt.repo && opt.series) throw new Error('choose exactly one of --repo or --patch-series');
  return opt;
}

export function main(argv = process.argv.slice(2)) {
  let loaded;
  let opt;
  try {
    opt = parseArgs(argv);
    loaded = opt.repo
      ? loadRepo(opt.repo)
      : loadPatchSeries(opt.series ?? path.join(root, 'prebuilt/sdl3/patches/series'));
    mergeHostActivationSources(loaded);
  } catch (error) {
    console.error(`SDL3 multiwindow contract: FAIL\n  ${error.message}`);
    return 1;
  }

  const report = analyzeFiles(loaded.files, loaded);
  if (opt.json) {
    console.log(JSON.stringify(report, null, 2));
  } else {
    console.log(`SDL3 multiwindow contract (${report.mode})`);
    console.log(`  input: ${report.input}`);
    console.log(`  files: ${report.scannedFiles}; rules: ${report.passed}/${report.total}`);
    for (const result of report.results) {
      console.log(`  ${result.ok ? 'PASS' : 'FAIL'} ${result.id}: ${result.label}`);
      if (!result.ok) console.log(`       ${result.detail}`);
      if (!result.ok && result.evidence) console.log(`       evidence: ${result.evidence}`);
    }
    console.log(report.ok ? 'SDL3 multiwindow contract: PASS' : 'SDL3 multiwindow contract: FAIL');
  }
  return report.ok ? 0 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(scriptPath)) {
  process.exitCode = main();
}
