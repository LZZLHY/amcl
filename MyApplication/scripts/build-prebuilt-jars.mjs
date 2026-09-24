// build-prebuilt-jars.mjs — 跨平台编译 prebuilt/ 下我们自家的 Java 源码到 jar
//
// 由 entry/hvigorfile.ts 的 hvigor task 在 HAP 打包前自动触发，与
// build-amcl-launcher.mjs 同 pattern。
//
// 处理的 jar：
//   1. prebuilt/lwjgl3/ohos-glfw/src/.../*.java   →  prebuilt/lwjgl3/jars/lwjgl-glfw.jar
//      (替换 LWJGL 上游 lwjgl-glfw.jar 中的 GLFW.class / CallbackBridge.class /
//       GLFWWindowProperties.class，保留其他 class 不变)
//
// 历史：曾另编 prebuilt/forge/ForgeInstaller.java → forge-install-bootstrapper.jar，供旧的
//   bangbang93 bootstrapper 同进程跑 Forge/NeoForge processors。该路径已被 ForgelikeInstaller
//   + ForgelikeProcessorRunner（自实现、每 processor 干净 classpath 独立 JVM）取代，bootstrapper
//   jar 已废弃、不再编译/部署（见 docs/adaptation/NeoForge适配方案.md 附录 Z）。
//
// 增量检查：jar mtime >= 所有 .java 源 mtime → skip
//
// 详见 docs/guides/third-party-deps-restructure-plan.md §3.4.5

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, rmSync, statSync, copyFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(SCRIPT_DIR, '..');

function optionValue(name) {
  const index = process.argv.indexOf(name);
  if (index < 0) return null;
  if (!process.argv[index + 1]) throw new Error(`${name} requires a path`);
  return resolve(process.argv[index + 1]);
}

// Upgrade tooling builds against an isolated staging directory, then swaps the
// complete modern slot into the two stable project paths. Normal hvigor builds
// omit this option and continue to use prebuilt/lwjgl3/jars.
const MODERN_JARS_DIR = optionValue('--lwjgl-dir')
  ?? join(PROJECT_ROOT, 'prebuilt', 'lwjgl3', 'jars');
// 显式兼容槽重编必须使用 Java 8 字节码；现代槽默认 17。只允许已支持的两个目标，
// 避免把宿主 JDK 版本泄漏进旧 Forge/ASM 扫描器。调用时 --force 可跳过旧 mtime 缓存。
const releaseIndex = process.argv.indexOf('--java-release');
const BRIDGE_JAVA_RELEASE = releaseIndex < 0 ? '17' : process.argv[releaseIndex + 1];
if (!['8', '17'].includes(BRIDGE_JAVA_RELEASE)) throw new Error('--java-release must be 8 or 17');

// ---- JDK tools ----
function locateJdkTool(tool) {
  const exe = process.platform === 'win32' ? `${tool}.exe` : tool;
  const javaHome = process.env.JAVA_HOME;
  if (javaHome) {
    const p = join(javaHome, 'bin', exe);
    if (existsSync(p)) return p;
  }
  try {
    const cmd = process.platform === 'win32' ? 'where' : 'which';
    const out = execFileSync(cmd, [tool], { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim();
    const first = out.split(/\r?\n/)[0].trim();
    if (first && existsSync(first)) return first;
  } catch {}
  throw new Error(`Cannot locate \`${tool}\`. Set JAVA_HOME to a JDK 17+ install, or add it to PATH.`);
}

// ---- helpers ----
function collectJavaFiles(dir) {
  const out = [];
  if (!existsSync(dir)) return out;
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, ent.name);
    if (ent.isDirectory()) out.push(...collectJavaFiles(p));
    else if (ent.isFile() && ent.name.endsWith('.java')) out.push(p);
  }
  return out;
}

function isUpToDate(outFile, srcFiles) {
  if (!existsSync(outFile)) return false;
  const outMtime = statSync(outFile).mtimeMs;
  for (const f of srcFiles) if (statSync(f).mtimeMs > outMtime) return false;
  return true;
}

function jarContainsAll(jarTool, jarFile, entries) {
  if (!existsSync(jarFile)) return false;
  try {
    const listing = execFileSync(jarTool, ['tf', jarFile], {
      stdio: ['ignore', 'pipe', 'ignore'],
      encoding: 'utf8',
    });
    const present = new Set(listing.split(/\r?\n/).filter(Boolean));
    return entries.every((entry) => present.has(entry));
  } catch {
    return false;
  }
}

// ============================================================
// Build 1: lwjgl-glfw.jar （方案 B，唯一方案）
//
// 保留上游原版 GLFW.class（252 方法全在），只往 baseline jar 里注入我们的桥接类
// CallbackBridge / GLFWWindowProperties（ArkTS/NAPI 触摸注入桥，与 GLFW.class 来源无关）。
// GLFW 的 C 符号由 libglfw.so 导出，上游 Java 绑定经 org.lwjgl.glfw.libname + libffi 直接调。
//
// 历史：曾有"方案 A（手写 GLFW.java fork 覆写上游）+ glfw_mode 切换"。2026-05-30 方案 B
// 真机进游戏后收敛为单一方案 B，A 残留已清除（回退靠 git）。详见 docs/archive/lwjgl-3.4.1-upgrade/LWJGL_PLAN_B_EXECUTION_LOG.md。
// ============================================================
function buildLwjglGlfw(javac, jar) {
  const SRC_DIR = join(PROJECT_ROOT, 'prebuilt', 'lwjgl3', 'ohos-glfw', 'src');
  const CLASSES_DIR = join(PROJECT_ROOT, 'prebuilt', 'lwjgl3', 'ohos-glfw', 'classes');
  const JARS_DIR = MODERN_JARS_DIR;
  const OUT_JAR = join(JARS_DIR, 'lwjgl-glfw.jar');
  // 编译时需要的 LWJGL classpath（运行时由 RuntimeDeployer 从 rawfile 解包）
  const LWJGL_CORE_JAR = join(JARS_DIR, 'lwjgl.jar');

  // 只编译桥接类（CallbackBridge.java + GLFWWindowProperties.java）。
  const javaFiles = collectJavaFiles(SRC_DIR);
  if (javaFiles.length === 0) {
    console.log('[build-prebuilt-jars/lwjgl-glfw] no .java in src/, skip');
    return;
  }

  const bridgeEntries = [
    'org/lwjgl/glfw/CallbackBridge.class',
    'org/lwjgl/glfw/GLFWWindowProperties.class',
  ];
  // A freshly downloaded upstream baseline is newer than our sources but does
  // not contain AMCL's bridge classes. mtime alone would incorrectly skip the
  // injection after every LWJGL upgrade, so require both conditions.
  const force = process.argv.includes('--force');
  if (!force && isUpToDate(OUT_JAR, javaFiles) && jarContainsAll(jar, OUT_JAR, bridgeEntries)) {
    console.log(`[build-prebuilt-jars/lwjgl-glfw] UP-TO-DATE (${javaFiles.length} src)`);
    return;
  }

  // 必须先有 lwjgl.jar 在 classpath（提供 org.lwjgl.system.* 等基类）。
  if (!existsSync(LWJGL_CORE_JAR)) {
    console.warn(`[build-prebuilt-jars/lwjgl-glfw] missing ${LWJGL_CORE_JAR}`);
    console.warn(`[build-prebuilt-jars/lwjgl-glfw] run \`bash setup_deps.sh\` to fetch LWJGL jars first`);
    console.warn('[build-prebuilt-jars/lwjgl-glfw] skipping lwjgl-glfw.jar build');
    return;
  }

  // baseline = 上游原版 lwjgl-glfw-<ver>.jar（含原版 GLFW.class），我们只往里追加桥接类。
  if (!existsSync(OUT_JAR)) {
    console.error(`[build-prebuilt-jars/lwjgl-glfw] baseline ${OUT_JAR} missing`);
    console.error(`[build-prebuilt-jars/lwjgl-glfw] fetch the upstream jar matching deps.lock [lwjgl-jars].version, e.g.:`);
    console.error(`    curl -fLo ${OUT_JAR} \\`);
    console.error('      https://repo1.maven.org/maven2/org/lwjgl/lwjgl-glfw/<version>/lwjgl-glfw-<version>.jar');
    process.exit(1);
  }

  console.log(`[build-prebuilt-jars/lwjgl-glfw] sources: ${javaFiles.length} files (upstream GLFW.class kept; injecting bridge classes)`);

  if (existsSync(CLASSES_DIR)) rmSync(CLASSES_DIR, { recursive: true, force: true });
  mkdirSync(CLASSES_DIR, { recursive: true });

  // javac
  const sep = process.platform === 'win32' ? ';' : ':';
  const cp = [OUT_JAR, LWJGL_CORE_JAR].join(sep);
  execFileSync(javac,
    ['--release', BRIDGE_JAVA_RELEASE, '-cp', cp, '-d', CLASSES_DIR, ...javaFiles],
    { stdio: 'inherit' });

  // jar uf 增量更新（保留上游原版 GLFW.class + META-INF + 其他 class），只注入桥接类
  const injectArgs = [
    '-C', CLASSES_DIR, 'org/lwjgl/glfw/CallbackBridge.class',
    '-C', CLASSES_DIR, 'org/lwjgl/glfw/GLFWWindowProperties.class',
  ];
  // 固定 ZIP entry 时间，避免同一份 bridge class 因构建时间不同产生不同 jar SHA-256。
  // 现代槽位 manifest 锁的是最终后处理制品，因此这里必须做到可复现。
  execFileSync(jar, [
    '--update', '--file', OUT_JAR, '--date=2000-01-01T00:00:00Z', ...injectArgs,
  ], { stdio: 'inherit' });

  const size = statSync(OUT_JAR).size;
  console.log(`[build-prebuilt-jars/lwjgl-glfw] OK  ${OUT_JAR}  (${size} bytes)`);
}

// ============================================================
// 主流程
// ============================================================
try {
  const javac = locateJdkTool('javac');
  const jar = locateJdkTool('jar');
  console.log(`[build-prebuilt-jars] javac = ${javac}`);
  console.log(`[build-prebuilt-jars] jar   = ${jar}`);
  buildLwjglGlfw(javac, jar);
} catch (e) {
  console.error(`[build-prebuilt-jars] FAILED: ${e.message}`);
  process.exit(1);
}
