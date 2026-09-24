#!/usr/bin/env node
// check-mg-snapshot.mjs — 比对 MG 上游当前源文件清单跟提交在仓库的 snapshot 是否一致
//
// 用法：
//   node scripts/check-mg-snapshot.mjs                # 默认 check
//   node scripts/check-mg-snapshot.mjs --update       # 更新 snapshot（人工 review 后用）
//
// 上游加文件 → 这个脚本失败 → CI 红灯 → 人为决定要不要把新文件编进 libglfw.so
// （多数情况要编，但需要意识层面知道：MG 加东西是个事件，不是默认行为）。
//
// 详见 docs/guides/third-party-deps-restructure-plan.md §3.1.1

import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(SCRIPT_DIR, '..');
const MG_SRC = join(PROJECT_ROOT, 'prebuilt', 'mobileglues', 'mg_src', 'MobileGlues-cpp');
const MG_CMAKE = join(MG_SRC, 'CMakeLists.txt');
const SNAPSHOT = join(PROJECT_ROOT, 'prebuilt', 'mobileglues', 'cmake-snapshot.txt');
const AMCL_CMAKE = join(PROJECT_ROOT, 'entry', 'src', 'main', 'cpp', 'CMakeLists.txt');
// 2.0 integration contract: upstream owns the reviewed source manifest in its
// own CMake target. AMCL must consume that target instead of copying a second,
// inevitably drifting list. init.cpp remains a standalone-wrapper source and
// must not enter the embedded core; explicit mg_initialize_v1 owns host timing.
const FORBIDDEN_SOURCES = ['init.cpp'];
const FORBIDDEN_REASON = {
  'init.cpp':
    'its unguarded static constructor calls proc_init() a second time; ' +
    'proc_init must be reached only from glfwInit()',
};
// libentry performs config migration before libglfw is loaded, so it needs a
// private cJSON parser in its own DSO. This is a reviewed host helper, not a
// duplicate of the MobileGlues core target. Every other direct MG source is
// forbidden and must arrive through MobileGlues::Core.
const ALLOWED_HOST_HELPER_SOURCES = new Set(['config/cJSON.c']);

const EXCLUDE_PATTERNS = [
  /\/3rdparty\//,
  /\/test\//,
  /\/tests\//,
  /\/build\//,
  /\/cmake-build/,
  // MG bundles SPIRV-Tools / glslang vendored sources under include/—they're
  // compiled separately via add_subdirectory(.../3rdparty/glslang). Never
  // include them in MOBILEGLUES_CORE_SOURCES.
  /^include\//,
  /\/include\//,
];

function collect(dir) {
  const out = [];
  if (!existsSync(dir)) return out;
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, ent.name);
    if (ent.isDirectory()) out.push(...collect(p));
    else if (ent.isFile() && (ent.name.endsWith('.cpp') || ent.name.endsWith('.c'))) {
      out.push(p);
    }
  }
  return out;
}

function relPosix(absPath) {
  return relative(MG_SRC, absPath).split(sep).join('/');
}

function withoutComments(text) {
  return text
    .split(/\r?\n/)
    .map(line => line.replace(/#.*$/, ''))
    .join('\n');
}

function verifyAmclSourceContract(snapshotPaths) {
  if (!existsSync(MG_CMAKE) || !existsSync(AMCL_CMAKE)) {
    console.error('[check-mg-snapshot] MG or AMCL CMakeLists.txt is missing');
    return false;
  }

  const activeMgCmake = withoutComments(readFileSync(MG_CMAKE, 'utf8'));
  const manifests = [...activeMgCmake.matchAll(/\bset\s*\(\s*MOBILEGLUES_CORE_SOURCES\b([\s\S]*?)\)/g)];
  if (manifests.length !== 1) {
    console.error(
      `[check-mg-snapshot] expected exactly one MOBILEGLUES_CORE_SOURCES manifest; found ${manifests.length}`,
    );
    return false;
  }

  const references = manifests[0][1]
    .split(/\s+/)
    .map(value => value.replace(/^['"]|['"]$/g, ''))
    .filter(value => /\.(?:cpp|c)$/.test(value));
  const duplicates = [...new Set(
    references.filter((value, index) => references.indexOf(value) !== index),
  )].sort();
  const referenceSet = new Set(references);
  const expected = snapshotPaths.filter(path => !FORBIDDEN_SOURCES.includes(path));
  const expectedSet = new Set(expected);
  const missing = expected.filter(path => !referenceSet.has(path));
  const unexpected = [...referenceSet].filter(path => !expectedSet.has(path)).sort();
  let failed = false;

  for (const forbidden of FORBIDDEN_SOURCES) {
    if (referenceSet.has(forbidden)) {
      console.error(
        `[check-mg-snapshot] embedded core must NOT compile ${forbidden}: ${FORBIDDEN_REASON[forbidden]}`,
      );
      failed = true;
    }
  }
  if (duplicates.length > 0) {
    console.error('[check-mg-snapshot] duplicate sources in MOBILEGLUES_CORE_SOURCES:');
    for (const path of duplicates) console.error(`    = ${path}`);
    failed = true;
  }
  if (missing.length > 0) {
    console.error('[check-mg-snapshot] reviewed MG sources missing from MOBILEGLUES_CORE_SOURCES:');
    for (const path of missing) console.error(`    - ${path}`);
    failed = true;
  }
  if (unexpected.length > 0) {
    console.error('[check-mg-snapshot] unreviewed sources in MOBILEGLUES_CORE_SOURCES:');
    for (const path of unexpected) console.error(`    + ${path}`);
    failed = true;
  }

  // PF-01: the core OBJECT target owns the translation units, so the OHOS
  // platform macro must be attached there. Defining it only on the final GLFW
  // wrapper produces a green link while every guarded MG branch stays compiled
  // out.
  const ohosCorePlatform =
    /if\s*\(\s*CMAKE_SYSTEM_NAME\s+STREQUAL\s+["']OHOS["']\s*\)[\s\S]*?target_compile_definitions\s*\(\s*mobileglues_core\s+PRIVATE\s+MG_PLATFORM_OHOS=1\s*\)[\s\S]*?endif\s*\(\s*\)/;
  if (!ohosCorePlatform.test(activeMgCmake)) {
    console.error('[check-mg-snapshot] mobileglues_core must define MG_PLATFORM_OHOS=1 for CMAKE_SYSTEM_NAME=OHOS');
    failed = true;
  }

  const activeAmclCmake = withoutComments(readFileSync(AMCL_CMAKE, 'utf8'));
  const hostRequirements = [
    [/\bset\s*\(\s*MOBILEGLUES_BUILD_STANDALONE\s+OFF\s*\)/, 'disable the standalone MG DSO'],
    [/\bset\s*\(\s*MOBILEGLUES_AUTO_INIT\s+OFF\s*\)/, 'disable constructor initialization'],
    [/\badd_subdirectory\s*\(\s*\$\{MG_SRC_DIR\}(?:\s|\))/, 'add the upstream MG CMake project'],
  ];
  for (const [pattern, description] of hostRequirements) {
    if (!pattern.test(activeAmclCmake)) {
      console.error(`[check-mg-snapshot] AMCL must ${description}`);
      failed = true;
    }
  }
  // 共享图形运行时将翻译核心移入单独 provider。保留旧版 target 链接形态的检查，
  // 新形态只允许 amcl_gl_host 消费一次上游 OBJECT target，不能同时把核心塞回 glfw。
  // 此处检查的是对象所有权，源码清单、构造器禁用和后面的直接源文件禁令仍然生效。
  const legacyCoreLink = /\btarget_link_libraries\s*\(\s*glfw\b[^)]*\bMobileGlues::Core\b/.test(activeAmclCmake);
  const objectUses = [...activeAmclCmake.matchAll(/\$<TARGET_OBJECTS:mobileglues_core>/g)];
  const provider = /\badd_library\s*\(\s*amcl_gl_host\s+SHARED\b([^)]*)\)/.exec(activeAmclCmake);
  const ownedProvider = provider !== null && /\$<TARGET_OBJECTS:mobileglues_core>/.test(provider[1])
    && /\bplatform\/gl_host\.cpp\b/.test(provider[1]) && objectUses.length === 1 && !legacyCoreLink;
  if (!(ownedProvider || (legacyCoreLink && objectUses.length === 0))) {
    console.error('[check-mg-snapshot] AMCL must give the MG core exactly one owner: MobileGlues::Core in glfw or the isolated amcl_gl_host provider');
    failed = true;
  }
  const directHostSources = [...activeAmclCmake.matchAll(
    /\$\{MG_SRC_DIR\}\/([A-Za-z0-9_+./-]+\.(?:cpp|c))\b/g,
  )].map(match => match[1]);
  const unreviewedHostSources = directHostSources
    .filter(path => !ALLOWED_HOST_HELPER_SOURCES.has(path));
  if (unreviewedHostSources.length > 0 || (objectUses.length > 0 && !ownedProvider)) {
    console.error(
      '[check-mg-snapshot] AMCL must consume MobileGlues::Core; unreviewed direct MG ' +
      `sources/objects: ${unreviewedHostSources.join(', ') || 'mobileglues_core objects'}`,
    );
    failed = true;
  }

  if (failed) {
    console.error('[check-mg-snapshot] update the MG target, host integration and snapshot together');
    return false;
  }

  console.log(
    `[check-mg-snapshot] source contract OK (${expected.length} embedded core sources, init.cpp wrapper-only)`,
  );
  return true;
}

function main() {
  if (!existsSync(MG_SRC)) {
    console.error(`[check-mg-snapshot] MobileGlues-cpp not found at ${MG_SRC}`);
    console.error(
      '[check-mg-snapshot] initialize only the pinned MG submodule with ' +
      '`git submodule update --init --depth 1 -- prebuilt/mobileglues/mg_src`',
    );
    process.exit(2);
  }

  const all = collect(MG_SRC).map(relPosix);
  const filtered = all
    .filter(p => !EXCLUDE_PATTERNS.some(rx => rx.test('/' + p)))
    .sort();

  const update = process.argv.includes('--update');
  if (update) {
    writeFileSync(SNAPSHOT, filtered.join('\n') + '\n');
    console.log(`[check-mg-snapshot] WROTE ${SNAPSHOT} (${filtered.length} files)`);
    if (!verifyAmclSourceContract(filtered)) process.exit(1);
    return;
  }

  if (!existsSync(SNAPSHOT)) {
    console.error(`[check-mg-snapshot] snapshot not found: ${SNAPSHOT}`);
    console.error('[check-mg-snapshot] run with --update to create it');
    process.exit(1);
  }

  const expected = readFileSync(SNAPSHOT, 'utf8')
    .split(/\r?\n/)
    .map(s => s.trim())
    .filter(Boolean);

  if (new Set(expected).size !== expected.length) {
    console.error('[check-mg-snapshot] snapshot contains duplicate paths; regenerate and review it');
    process.exit(1);
  }
  const sortedExpected = [...expected].sort();
  if (expected.some((value, index) => value !== sortedExpected[index])) {
    console.error('[check-mg-snapshot] snapshot is not sorted; regenerate and review it');
    process.exit(1);
  }

  const expectedSet = new Set(expected);
  const actualSet = new Set(filtered);
  const added = filtered.filter(p => !expectedSet.has(p));
  const removed = expected.filter(p => !actualSet.has(p));

  if (added.length === 0 && removed.length === 0) {
    console.log(`[check-mg-snapshot] OK (${filtered.length} files match)`);
    if (!verifyAmclSourceContract(expected)) process.exit(1);
    return;
  }

  console.error('[check-mg-snapshot] MG source list drifted from snapshot:');
  if (added.length) {
    console.error(`  ADDED (upstream new files, ${added.length}):`);
    for (const p of added) console.error(`    + ${p}`);
  }
  if (removed.length) {
    console.error(`  REMOVED (gone from upstream, ${removed.length}):`);
    for (const p of removed) console.error(`    - ${p}`);
  }
  console.error('');
  console.error('Action:');
  console.error('  1. Review whether the changes should be compiled into libglfw.so');
  console.error('  2. If yes, run `node scripts/check-mg-snapshot.mjs --update` to refresh snapshot');
  console.error('  3. Commit the snapshot change as part of the MG version bump PR');
  process.exit(1);
}

main();
