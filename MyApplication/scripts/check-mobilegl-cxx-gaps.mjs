#!/usr/bin/env node
// scripts/check-mobilegl-cxx-gaps.mjs
//
// ============================ 它挡的是什么 ============================
//
// OHOS SDK 的 clang 15 缺两个 C++20 特性（P0960R3 括号初始化聚合体、P1091R3 lambda
// 捕获结构化绑定），且 libc++ 15 没有 <expected> 头。fork 提交栈里的绕行改动
// （方案 §3.2/§3.3）**只在 clang 15 上是编译错误** —— 升级 submodule 时若把它们
// rebase 掉，本机 CI 用 clang 16+ 完全不报错，坏在几周后的 OHOS 构建上。
// 这与 `1000548`（源码级门禁全绿不等于修复在出货链上）同族（方案 §4.7）。
//
// ⇒ 本门禁直接断言那些绕行改动**仍在源码树里**，纯文本判定，不依赖任何编译器。
// 同时断言两条只有阅读顺序才能保证的结构事实：
//   * Includes.h 的 __OHOS__ Vulkan 分支必须出现在 __linux__ 分支**之前**
//     （OHOS 同时预定义两者，顺序错了会静默选中 XLIB —— gl4es 补丁 0001 同族坑）
//   * CMake 的 _LIBCPP_ENABLE_EXPERIMENTAL 与 c++experimental 链接必须**成对**存在
//     （libc++ 15 把 <format> 运行时符号放在 libc++experimental.a）
//
// ============================ 它不能证明什么 ============================
//
// ❌ 不证明这些改动语义正确（那由上游构建 + OHOS 构建证明）。
// ❌ 不证明产物里真的编进了它们（产物级归 check-mobilegl-build-contract，Phase 2b 前落地）。
//
// 用法：node scripts/check-mobilegl-cxx-gaps.mjs [--json]

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
export const SUB_REL = 'prebuilt/mobilegl/src';

/**
 * 断言表。id 稳定（自测引用它）；needle 是**源码文本必须包含的字面片段**。
 * 刻意用"短且唯一"的锚（构造函数签名、宏名），不锚注释 —— 注释措辞会改。
 */
export const REQUIRED_SNIPPETS = [
  {
    id: 'cmake-provider-local-binding',
    file: 'CMakeLists.txt',
    needle: '"LINKER:-Bsymbolic-functions"',
    why: 'eglGetProcAddress 的 GL 函数不得被系统 GLES/MobileGlues 抢占',
  },
  {
    id: 'aggregate-range1d',
    file: 'MobileGL/MG_Util/Types.h',
    needle: 'constexpr Range1D(SizeT s, SizeT e)',
    why: 'P0960R3 绕行（clang 15 无括号初始化聚合体）',
  },
  {
    id: 'aggregate-error',
    file: 'MobileGL/MG_State/GLState/ErrorState/Error.h',
    needle: 'Error(ErrorCode c, UniquePtr<ErrorInfo> i)',
    why: 'P0960R3 绕行',
  },
  {
    id: 'aggregate-default-framebuffer-info',
    file: 'MobileGL/MG_Impl/GLImpl/Framebuffer/GL_Framebuffer.h',
    needle: 'DefaultFramebufferInfo(SharedPtr<MG_State::GLState::FramebufferObject> fbo,',
    why: 'P0960R3 绕行',
  },
  {
    id: 'structured-binding-copy',
    file: 'MobileGL/MG_Util/ShaderTranspiler/SpirvPasses/FlattenAtomicCounterBlockPass.cpp',
    needle: 'const uint32_t capturedVariableId = variableId;',
    why: 'P1091R3 绕行（clang 15 无 lambda 捕获结构化绑定）',
  },
  {
    id: 'expected-conditional-include',
    file: 'MobileGL/Includes.h',
    needle: '#if __has_include(<expected>)',
    why: 'libc++ 15 没有 <expected> 头文件，include 必须条件化',
  },
  {
    id: 'expected-tl-fallback',
    file: 'MobileGL/MG_Util/ShaderTranspiler/Types.h',
    needle: 'using Result = tl::expected<T, ResultInfo>;',
    why: '无 __cpp_lib_expected 时落 vendored tl::expected',
  },
  {
    id: 'expected-unexpected-alias',
    file: 'MobileGL/MG_Util/ShaderTranspiler/Types.h',
    needle: 'using Unexpected = tl::unexpected<ResultInfo>;',
    why: '5 处错误返回点经 Unexpected 别名，rebase 掉会连 ShaderCompiler.cpp 一起坏',
  },
  {
    id: 'cmake-ohos-detect',
    file: 'CMakeLists.txt',
    needle: 'CMAKE_SYSTEM_NAME STREQUAL "OHOS"',
    why: 'OHOS 平台检测（CMake 不认识该系统名，UNIX/ANDROID 均不置位）',
  },
  {
    id: 'cmake-libcpp-experimental-define',
    file: 'CMakeLists.txt',
    needle: 'add_compile_definitions(_LIBCPP_ENABLE_EXPERIMENTAL)',
    why: '解锁 libc++ 15 被 gate 的 <format>',
  },
  {
    id: 'cmake-libcpp-experimental-link',
    file: 'CMakeLists.txt',
    needle: 'target_link_libraries(${CMAKE_PROJECT_NAME} PUBLIC c++experimental)',
    why: '与上一条成对：<format> 运行时符号在 libc++experimental.a',
  },
  {
    id: 'cmake-exclude-libs',
    file: 'CMakeLists.txt',
    needle: '--exclude-libs,ALL',
    why: '静态嵌入的 glslang/SPIRV-*/libc++ 不得泄漏进导出面（实测 10801 个符号）',
  },
];

/**
 * Includes.h 的顺序断言：__OHOS__ 分支必须先于 __linux__ 分支被测试。
 * 返回 null = 通过；否则返回问题描述。纯函数，自测直接喂文本。
 */
export function checkOhosBeforeLinux(includesText) {
  const ohosAt = includesText.indexOf('#elif defined(__OHOS__)');
  const linuxAt = includesText.indexOf('#elif defined(__linux__)');
  if (ohosAt < 0) return 'Includes.h 没有 __OHOS__ Vulkan 平台分支';
  if (linuxAt < 0) return 'Includes.h 没有 __linux__ Vulkan 平台分支（上游结构变了，人工复核）';
  if (ohosAt > linuxAt) {
    return '__OHOS__ 分支排在 __linux__ 之后 —— OHOS 预定义两者，会静默选中 XLIB';
  }
  return null;
}

/**
 * 主判定。`readFile` 可注入（自测喂构造内容）。
 */
export function analyze({ root = ROOT, readFile = null } = {}) {
  const problems = [];
  const read = readFile || ((rel) => {
    const abs = path.join(root, ...SUB_REL.split('/'), ...rel.split('/'));
    return fs.existsSync(abs) ? fs.readFileSync(abs, 'utf8') : null;
  });

  const byFile = new Map();
  for (const snip of REQUIRED_SNIPPETS) {
    if (!byFile.has(snip.file)) byFile.set(snip.file, read(snip.file));
    const text = byFile.get(snip.file);
    if (text === null) {
      problems.push(`${snip.id}: 文件不存在 ${snip.file}`);
      continue;
    }
    if (!text.includes(snip.needle)) {
      problems.push(`${snip.id}: ${snip.file} 缺少锚 '${snip.needle}'（${snip.why}）`);
    }
  }

  const includes = byFile.get('MobileGL/Includes.h') ?? read('MobileGL/Includes.h');
  if (includes !== null) {
    const orderProblem = checkOhosBeforeLinux(includes);
    if (orderProblem) problems.push(`ohos-before-linux: ${orderProblem}`);
  }

  return { ok: problems.length === 0, problems, checked: REQUIRED_SNIPPETS.length + 1 };
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === url.fileURLToPath(import.meta.url);
if (isMain) {
  const res = analyze({});
  if (process.argv.includes('--json')) {
    console.log(JSON.stringify(res, null, 2));
  } else {
    for (const p of res.problems) console.error(`  FAIL: ${p}`);
    console.log(res.ok
      ? `check-mobilegl-cxx-gaps PASS (${res.checked} 条断言)`
      : `check-mobilegl-cxx-gaps FAIL (${res.problems.length} 处)`);
  }
  process.exitCode = res.ok ? 0 : 1;
}
