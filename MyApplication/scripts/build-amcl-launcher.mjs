// build-amcl-launcher.mjs — 跨平台编译 JavaApp/*.java 并打成 amcl-launcher.jar
//
// 由 entry/hvigorfile.ts 的 hvigor task 在 HAP 打包前自动触发。
// 也可被 build-hap.ps1 直接调用（node scripts/build-amcl-launcher.mjs）。
//
// 内容身份检查：只有 source/build-script/target-release 的 SHA-256 与 JAR
// 自身 SHA-256 都匹配 sidecar manifest 时才跳过，branch switch 或时间戳恢复
// 不会复用旧 JAR。

import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import {
  readdirSync,
  statSync,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';
import { productDefinition } from './product-contract.mjs';

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const SCRIPT_DIR = dirname(SCRIPT_PATH);
const PROJECT_ROOT = resolve(SCRIPT_DIR, '..');
const JAVA_APP = join(PROJECT_ROOT, 'JavaApp');
const SRC_DIR = join(JAVA_APP, 'src');
const CLASSES_DIR = join(JAVA_APP, 'build', 'classes');
const BUILD_MANIFEST = join(JAVA_APP, 'build', 'amcl-launcher-build.json');
const JAR_MANIFEST = join(JAVA_APP, 'build', 'amcl-launcher.mf');
const OUT_JAR = join(PROJECT_ROOT, 'entry', 'src', 'main', 'resources', 'rawfile', 'amcl-launcher.jar');
const BUILD_SCHEMA = 2;
const TARGET_RELEASE = '8';
const productIndex = process.argv.indexOf('--product');
const PRODUCT = productIndex < 0 ? 'default' : process.argv[productIndex + 1];
const DEVELOPER = productDefinition(PRODUCT).developerDiagnostics;
const GENERATED_PROFILE = join(JAVA_APP, 'build', 'AmclBuildProfile.java');
const PROFILE_SOURCE = `package com.amcl.launcher; public final class AmclBuildProfile { public static final boolean DEVELOPER_DIAGNOSTICS = ${DEVELOPER}; }\n`;

// 同一个 jar 兼当 JPLIS agent（方案 §5.1：加一条清单属性即可，无需第二个 jar）。
// ⛔ 刻意**不写** Can-Retransform-Classes：目标类都是首次定义时变换，开 retransform 会让
// JVM 为它们保留更多元数据（方案 §7.2）。缺省即 false，所以这里的"不写"就是声明值。
const PREMAIN_CLASS = 'com.amcl.launcher.AmclAgentProbe';
const JAR_MANIFEST_TEXT = DEVELOPER ? `Manifest-Version: 1.0\nPremain-Class: ${PREMAIN_CLASS}\n` : `Manifest-Version: 1.0\n`;

// ---- 1. 定位 javac / jar ----
function locateJdkTool(tool) {
  const exe = process.platform === 'win32' ? `${tool}.exe` : tool;

  // 优先 JAVA_HOME（build-hap.ps1 和 CI 常见做法）
  const javaHome = process.env.JAVA_HOME;
  if (javaHome) {
    const p = join(javaHome, 'bin', exe);
    if (existsSync(p)) return p;
  }

  // 其次 PATH（`where` on Windows / `which` on POSIX）
  try {
    const cmd = process.platform === 'win32' ? 'where' : 'which';
    const out = execFileSync(cmd, [tool], { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim();
    const first = out.split(/\r?\n/)[0].trim();
    if (first && existsSync(first)) return first;
  } catch {}

  throw new Error(
    `Cannot locate \`${tool}\`. Set JAVA_HOME to a JDK 17+ install, or add it to PATH.`
  );
}

// ---- 2. 递归收集 .java 文件 ----
function collectJavaFiles(dir) {
  const files = [];
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, ent.name);
    if (ent.isDirectory()) files.push(...collectJavaFiles(p));
    else if (ent.isFile() && ent.name.endsWith('.java')) files.push(p);
  }
  return files;
}

// ---- 3. 内容身份：源文件 + 构建脚本 + target release ----
function updateHashRecord(hash, label, bytes) {
  const value = Buffer.isBuffer(bytes) ? bytes : Buffer.from(String(bytes), 'utf8');
  const length = Buffer.allocUnsafe(8);
  length.writeBigUInt64BE(BigInt(value.length));
  hash.update(label, 'utf8');
  hash.update(Buffer.from([0]));
  hash.update(length);
  hash.update(value);
}

function sha256File(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

function computeInputIdentity(srcFiles) {
  const files = srcFiles.map(path => ({
    path,
    relativePath: relative(SRC_DIR, path).replaceAll('\\', '/'),
  })).sort((left, right) => left.relativePath.localeCompare(right.relativePath, 'en'));
  const hash = createHash('sha256');
  updateHashRecord(hash, 'schema', BUILD_SCHEMA);
  updateHashRecord(hash, 'target-release', TARGET_RELEASE);
  updateHashRecord(hash, 'product-profile', PROFILE_SOURCE);
  updateHashRecord(hash, 'builder', readFileSync(SCRIPT_PATH));
  for (const file of files) {
    updateHashRecord(hash, 'source-path', file.relativePath);
    updateHashRecord(hash, 'source-bytes', readFileSync(file.path));
  }
  return {
    inputSha256: hash.digest('hex'),
    sourceFiles: files.map(file => file.relativePath),
  };
}

function isJarUpToDate(jarPath, inputIdentity) {
  if (!existsSync(jarPath) || !existsSync(BUILD_MANIFEST)) return false;
  try {
    const manifest = JSON.parse(readFileSync(BUILD_MANIFEST, 'utf8'));
    return manifest.schemaVersion === BUILD_SCHEMA &&
      manifest.targetRelease === TARGET_RELEASE &&
      manifest.inputSha256 === inputIdentity.inputSha256 &&
      manifest.sourceCount === inputIdentity.sourceFiles.length &&
      manifest.jarSha256 === sha256File(jarPath);
  } catch {
    return false;
  }
}

// ---- 4. 主流程 ----
function main() {
  if (!existsSync(SRC_DIR)) {
    console.log(`[build-amcl-launcher] JavaApp/src not found at ${SRC_DIR}, skip.`);
    return;
  }

  const javaFiles = collectJavaFiles(SRC_DIR)
    .filter(path => !path.endsWith('AmclBuildProfile.java'))
    .sort((left, right) => left.localeCompare(right, 'en'));
  if (javaFiles.length === 0) {
    console.log('[build-amcl-launcher] No .java files found, skip.');
    return;
  }

  const inputIdentity = computeInputIdentity(javaFiles);
  if (isJarUpToDate(OUT_JAR, inputIdentity)) {
    console.log(`[build-amcl-launcher] UP-TO-DATE (${javaFiles.length} src, input=${inputIdentity.inputSha256.slice(0, 16)}, ${OUT_JAR})`);
    return;
  }

  const javac = locateJdkTool('javac');
  const jar = locateJdkTool('jar');

  console.log(`[build-amcl-launcher] javac = ${javac}`);
  console.log(`[build-amcl-launcher] jar   = ${jar}`);
  console.log(`[build-amcl-launcher] sources: ${javaFiles.length} files`);

  // 清理 classes 目录
  if (existsSync(CLASSES_DIR)) rmSync(CLASSES_DIR, { recursive: true, force: true });
  mkdirSync(CLASSES_DIR, { recursive: true });

  // javac —— 用 --release 8 编译：amcl-launcher.jar 是【所有 JDK 路径共用】的启动器 jar，
  //   必须能被 JDK 8（经典布局，老 MC 1.7–1.16.5）加载。Java 8 字节码在 17/21/25 上也能正常运行，
  //   故统一目标 8。--release 8 会在用到任何 Java 9+ API 时编译失败，作为兼容性安全网。
  writeFileSync(GENERATED_PROFILE, PROFILE_SOURCE);
  execFileSync(javac,
    ['-d', CLASSES_DIR, '--release', TARGET_RELEASE, ...javaFiles, GENERATED_PROFILE],
    { stdio: 'inherit' });

  // jar cfm OUT_JAR <manifest> -C CLASSES_DIR com
  // 用 cfm 而不是 cf：Premain-Class 必须在清单里，否则 -javaagent 只会报
  // "Failed to find Premain-Class manifest attribute" 并**终止 JVM 启动**。
  if (!DEVELOPER) {
    const packageDir = join(CLASSES_DIR, 'com', 'amcl', 'launcher');
    for (const name of readdirSync(packageDir)) {
      if (/^AmclAgentProbe(?:\$.*)?\.class$/.test(name)) rmSync(join(packageDir, name));
    }
  }
  mkdirSync(dirname(OUT_JAR), { recursive: true });
  writeFileSync(JAR_MANIFEST, JAR_MANIFEST_TEXT, 'utf8');
  execFileSync(jar,
    ['cfm', OUT_JAR, JAR_MANIFEST, '-C', CLASSES_DIR, 'com'],
    { stdio: 'inherit' });

  const size = statSync(OUT_JAR).size;
  const jarSha256 = sha256File(OUT_JAR);
  mkdirSync(dirname(BUILD_MANIFEST), { recursive: true });
  writeFileSync(BUILD_MANIFEST, `${JSON.stringify({
    schemaVersion: BUILD_SCHEMA,
    targetRelease: TARGET_RELEASE,
    premainClass: DEVELOPER ? PREMAIN_CLASS : null,
    developerProduct: DEVELOPER,
    inputSha256: inputIdentity.inputSha256,
    sourceCount: inputIdentity.sourceFiles.length,
    sourceFiles: inputIdentity.sourceFiles,
    jarSha256,
  }, null, 2)}\n`, 'utf8');
  console.log(`[build-amcl-launcher] OK  ${OUT_JAR}  (${size} bytes, sha256=${jarSha256})`);
}

try {
  // Fabric compatibility is a separate mod artifact; do not put its classes in
  // amcl-launcher.jar or the JVM parent classpath (Knot owns their instance state).
  const python = process.env.AMCL_PYTHON || (process.platform === 'win32' ? 'python' : 'python3');
  execFileSync(python, [join(SCRIPT_DIR, 'build-game-compat.py')], { cwd: PROJECT_ROOT, stdio: 'inherit' });
  main();
} catch (e) {
  console.error(`[build-amcl-launcher] FAILED: ${e.message}`);
  process.exit(1);
}
