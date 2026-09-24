#!/usr/bin/env node
// Fixture tests for the AMCL MobileGlues source-list contract.

// 临时夹具及其清理边界统一使用外部宿主测试区，不修改系统 TEMP，也不回退到源码目录。
import { workspaceTempRoot } from './lib/workspace-paths.mjs';
import { spawnSync } from 'node:child_process';
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const SOURCE_GUARD = join(SCRIPT_DIR, 'check-mg-snapshot.mjs');

function runGuard(root) {
  return spawnSync(process.execPath, [join(root, 'scripts', 'check-mg-snapshot.mjs')], {
    cwd: root,
    encoding: 'utf8',
  });
}

function expectStatus(result, expected, label, outputPattern) {
  const combined = `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
  if (result.status !== expected || (outputPattern && !outputPattern.test(combined))) {
    throw new Error(
      `${label}: expected status ${expected}${outputPattern ? ` and ${outputPattern}` : ''}, ` +
      `got ${result.status}\n${combined}`,
    );
  }
  console.log(`[test-check-mg-snapshot] PASS: ${label}`);
}

// The 2.0 contract has one manifest in the MG project and a target-level host
// integration. This prevents both source drift and constructor double init.
function mgCmakeText(sources, { ohosPlatformSeam = true } = {}) {
  const platformSeam = ohosPlatformSeam
    ? `if(CMAKE_SYSTEM_NAME STREQUAL "OHOS")
    target_compile_definitions(mobileglues_core PRIVATE MG_PLATFORM_OHOS=1)
endif()
`
    : '';
  return `set(MOBILEGLUES_CORE_SOURCES\n${sources.map(path => `    ${path}`).join('\n')}\n)\n` +
    'add_library(mobileglues_core OBJECT ${MOBILEGLUES_CORE_SOURCES})\n' + platformSeam;
}

function hostCmakeText() {
  return `set(MOBILEGLUES_BUILD_STANDALONE OFF)
set(MOBILEGLUES_AUTO_INIT OFF)
add_subdirectory(\${MG_SRC_DIR} \${CMAKE_CURRENT_BINARY_DIR}/mobileglues)
target_link_libraries(glfw PRIVATE MobileGlues::Core)
`;
}

const fixture = mkdtempSync(join(workspaceTempRoot(), 'amcl-mg-snapshot-'));
const fixtureRoot = resolve(fixture);
const mgSource = join(fixtureRoot, 'prebuilt', 'mobileglues', 'mg_src', 'MobileGlues-cpp');
const cmakePath = join(fixtureRoot, 'entry', 'src', 'main', 'cpp', 'CMakeLists.txt');

try {
  mkdirSync(join(fixtureRoot, 'scripts'), { recursive: true });
  mkdirSync(mgSource, { recursive: true });
  mkdirSync(dirname(cmakePath), { recursive: true });
  copyFileSync(SOURCE_GUARD, join(fixtureRoot, 'scripts', 'check-mg-snapshot.mjs'));

  writeFileSync(join(mgSource, 'core.cpp'), '// fixture\n');
  writeFileSync(join(mgSource, 'extra.cpp'), '// fixture\n');
  writeFileSync(join(mgSource, 'init.cpp'), '// fixture\n');
  writeFileSync(
    join(fixtureRoot, 'prebuilt', 'mobileglues', 'cmake-snapshot.txt'),
    'core.cpp\nextra.cpp\ninit.cpp\n',
  );

  // Normal: upstream target owns every reviewed core source except init.cpp.
  writeFileSync(join(mgSource, 'CMakeLists.txt'), mgCmakeText(['core.cpp', 'extra.cpp']));
  writeFileSync(cmakePath, hostCmakeText());

  // 新架构的 provider 是核心唯一对象消费者；换名、重复嵌入或同时链接 glfw 均应失败。
  const providerHost = hostCmakeText().replace('target_link_libraries(glfw PRIVATE MobileGlues::Core)',
    'add_library(amcl_gl_host SHARED $<TARGET_OBJECTS:mobileglues_core> platform/gl_host.cpp)');
  writeFileSync(cmakePath, providerHost);
  expectStatus(runGuard(fixtureRoot), 0, 'isolated provider owns reviewed core exactly once', /source contract OK/);
  writeFileSync(cmakePath, providerHost.replace('add_library(amcl_gl_host', 'add_library(unreviewed'));
  expectStatus(runGuard(fixtureRoot), 1, 'another object owner is rejected', /exactly one owner/);
  writeFileSync(cmakePath, providerHost + '\nadd_library(other SHARED $<TARGET_OBJECTS:mobileglues_core>)\n');
  expectStatus(runGuard(fixtureRoot), 1, 'duplicated core object consumption is rejected', /exactly one owner/);
  writeFileSync(cmakePath, providerHost + '\ntarget_link_libraries(glfw PRIVATE MobileGlues::Core)\n');
  expectStatus(runGuard(fixtureRoot), 1, 'provider and legacy link cannot coexist', /exactly one owner/);
  writeFileSync(cmakePath, hostCmakeText());
  expectStatus(runGuard(fixtureRoot), 0, 'all reviewed sources compiled, init.cpp excluded', /source contract OK/);

  writeFileSync(
    join(mgSource, 'CMakeLists.txt'),
    mgCmakeText(['core.cpp', 'extra.cpp'], { ohosPlatformSeam: false }),
  );
  expectStatus(runGuard(fixtureRoot), 1, 'OHOS platform seam must target the MG core', /must define MG_PLATFORM_OHOS/);
  writeFileSync(join(mgSource, 'CMakeLists.txt'), mgCmakeText(['core.cpp', 'extra.cpp']));

  writeFileSync(
    cmakePath,
    hostCmakeText() + 'add_library(amcl_mg_config_json OBJECT ${MG_SRC_DIR}/config/cJSON.c)\n',
  );
  expectStatus(runGuard(fixtureRoot), 0,
    'reviewed private cJSON host helper is allowed', /source contract OK/);

  writeFileSync(
    cmakePath,
    hostCmakeText() + 'add_library(unreviewed OBJECT ${MG_SRC_DIR}/core.cpp)\n',
  );
  expectStatus(runGuard(fixtureRoot), 1,
    'unreviewed direct MG host source is rejected', /unreviewed direct MG sources\/objects: core\.cpp/);
  writeFileSync(cmakePath, hostCmakeText());

  // Omitting a reviewed source from MG's canonical manifest is rejected.
  writeFileSync(join(mgSource, 'CMakeLists.txt'), mgCmakeText(['core.cpp']));
  expectStatus(runGuard(fixtureRoot), 1, 'snapshot source omitted from core is rejected', /missing from MOBILEGLUES_CORE_SOURCES/);

  // init.cpp is constructor-wrapper-only and may not enter the embedded core.
  writeFileSync(
    join(mgSource, 'CMakeLists.txt'),
    mgCmakeText(['core.cpp', 'extra.cpp', 'init.cpp']),
  );
  expectStatus(runGuard(fixtureRoot), 1, 'compiling init.cpp is rejected (double proc_init)', /must NOT compile init\.cpp/);

  // New upstream source must first be reviewed into the snapshot.
  writeFileSync(join(mgSource, 'sneaky.cpp'), '// fixture\n');
  writeFileSync(
    join(mgSource, 'CMakeLists.txt'),
    mgCmakeText(['core.cpp', 'extra.cpp', 'sneaky.cpp']),
  );
  expectStatus(runGuard(fixtureRoot), 1, 'unreviewed upstream source is rejected', /drifted from snapshot/);
} finally {
  const tempRoot = resolve(workspaceTempRoot()).toLowerCase();
  if (!fixtureRoot.toLowerCase().startsWith(`${tempRoot}\\`) &&
      !fixtureRoot.toLowerCase().startsWith(`${tempRoot}/`)) {
    throw new Error(`refusing to remove fixture outside the OS temp directory: ${fixtureRoot}`);
  }
  rmSync(fixtureRoot, { recursive: true, force: true });
}
