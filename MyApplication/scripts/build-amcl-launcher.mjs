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
  copyFileSync,
} from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';
import { productDefinition } from './product-contract.mjs';
import { stageSherpaRuntime } from './stage-sherpa-runtime.mjs';
import { stageZstdRuntime } from './stage-zstd-runtime.mjs';
import { zstdBindingResource } from './zstd-binding-contract.mjs';

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const SCRIPT_DIR = dirname(SCRIPT_PATH);
const PROJECT_ROOT = resolve(SCRIPT_DIR, '..');
const JAVA_APP = join(PROJECT_ROOT, 'JavaApp');
const SRC_DIR = join(JAVA_APP, 'src');
// 标准 Java SPI 通过资源发现 provider；资源与源码一起纳入内容身份，防止复用缺服务描述的旧 JAR。
const RESOURCE_DIR = join(JAVA_APP, 'resources');
const SHERPA_BINDINGS = join(PROJECT_ROOT, 'prebuilt/mod-natives/sherpa-onnx/verified-bindings.json');
const CLASSES_DIR = join(JAVA_APP, 'build', 'classes');
const BUILD_MANIFEST = join(JAVA_APP, 'build', 'amcl-launcher-build.json');
const JAR_MANIFEST = join(JAVA_APP, 'build', 'amcl-launcher.mf');
const OUT_JAR = join(PROJECT_ROOT, 'entry', 'src', 'main', 'resources', 'rawfile', 'amcl-launcher.jar');
const BUILD_SCHEMA = 3;
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

/** 只打包源集中显式保存的普通资源，拒绝符号链接，防止服务文件指向工作树外的任意内容。 */
function collectResources(dir) {
  if (!existsSync(dir)) return [];
  const files = [];
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, ent.name);
    if (ent.isSymbolicLink()) throw new Error(`Launcher resource may not be a symlink: ${path}`);
    if (ent.isDirectory()) files.push(...collectResources(path));
    else if (ent.isFile()) files.push(path);
  }
  return files.sort();
}

/**
 * 权威绑定清单只保存一份 JSON；本函数严格校验后生成运行时有界 properties。
 * 生成资源和原始 manifest 字节都进入 input identity，分支切换不能沿用旧 ABI 表。
 */
function sherpaBindingResource() {
  const source = readFileSync(SHERPA_BINDINGS);
  const value = JSON.parse(source.toString('utf8'));
  const prefix = 'com/k2fsa/sherpa/onnx/';
  if (value.schemaVersion !== 1 || value.classPrefix !== prefix || value.classCount !== 235 ||
      !Array.isArray(value.profiles) || !value.profiles.length || value.profiles.length > 16)
    throw new Error('Invalid Sherpa verified binding manifest');
  const lines = ['schema=1', `classPrefix=${prefix}`, `manifest.sha256=${createHash('sha256').update(source).digest('hex')}`,
    `profile.count=${value.profiles.length}`];
  const ids = new Set();
  for (const [index, profile] of value.profiles.entries()) {
    const key = `profile.${index}.`;
    if (!/^[a-zA-Z0-9.-]{1,80}$/.test(profile.id) || ids.has(profile.id)) throw new Error('Duplicate or invalid Sherpa binding profile');
    ids.add(profile.id);
    const container = profile.container;
    if (!container || !['self', 'jarjar'].includes(container.kind)) throw new Error('Unknown Sherpa binding container');
    if (container.kind === 'jarjar' && (!/^META-INF\/jarjar\/[a-zA-Z0-9._-]+\.jar$/.test(container.entry) || !/^[0-9a-f]{64}$/.test(container.sha256)))
      throw new Error('Invalid Sherpa nested binding identity');
    const classes = Object.entries(profile.classSha256 || {}).sort(([left], [right]) => left.localeCompare(right, 'en'));
    if (classes.length !== 235) throw new Error('Incomplete Sherpa class identity set');
    lines.push(`${key}id=${profile.id}`, `${key}kind=${container.kind}`, `${key}entry=${container.entry || ''}`,
      `${key}sha256=${container.sha256 || ''}`, `${key}class.count=${classes.length}`);
    for (const [at, [path, digest]] of classes.entries()) {
      if (!path.startsWith(prefix) || !/^[a-zA-Z0-9_/$.-]+\.class$/.test(path) || path.includes('..') || !/^[0-9a-f]{64}$/.test(digest))
        throw new Error('Invalid Sherpa class identity');
      lines.push(`${key}class.${at}.path=${path}`, `${key}class.${at}.sha256=${digest}`);
    }
  }
  return { source, bytes: Buffer.from(`${lines.join('\n')}\n`, 'ascii') };
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

function computeInputIdentity(srcFiles, resourceFiles, bindings, zstdBindings) {
  const files = srcFiles.map(path => ({
    path,
    relativePath: relative(SRC_DIR, path).replaceAll('\\', '/'),
  })).sort((left, right) => left.relativePath.localeCompare(right.relativePath, 'en'));
  const hash = createHash('sha256');
  updateHashRecord(hash, 'schema', BUILD_SCHEMA);
  updateHashRecord(hash, 'target-release', TARGET_RELEASE);
  updateHashRecord(hash, 'product-profile', PROFILE_SOURCE);
  updateHashRecord(hash, 'builder', readFileSync(SCRIPT_PATH));
  updateHashRecord(hash, 'sherpa-binding-manifest', bindings.source);
  updateHashRecord(hash, 'sherpa-generated-resource', bindings.bytes);
  // zstd选择表与真实生成规则进入缓存身份，不能沿用上个绑定集合的启动JAR。
  updateHashRecord(hash, 'zstd-binding-manifest', zstdBindings.source);
  updateHashRecord(hash, 'zstd-generated-resource', zstdBindings.bytes);
  updateHashRecord(hash, 'zstd-binding-generator', readFileSync(join(SCRIPT_DIR, 'zstd-binding-contract.mjs')));
  for (const file of files) {
    updateHashRecord(hash, 'source-path', file.relativePath);
    updateHashRecord(hash, 'source-bytes', readFileSync(file.path));
  }
  for (const path of resourceFiles) {
    updateHashRecord(hash, 'resource-path', relative(RESOURCE_DIR, path).replaceAll('\\', '/'));
    updateHashRecord(hash, 'resource-bytes', readFileSync(path));
  }
  return {
    inputSha256: hash.digest('hex'),
    sourceFiles: files.map(file => file.relativePath),
    resourceFiles: resourceFiles.map(path => relative(RESOURCE_DIR, path).replaceAll('\\', '/')),
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

  const resourceFiles = collectResources(RESOURCE_DIR);
  const bindings = sherpaBindingResource();
  const zstdBindings = zstdBindingResource(PROJECT_ROOT);
  const inputIdentity = computeInputIdentity(javaFiles, resourceFiles, bindings, zstdBindings);
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

  // 资源明确复制到本次 classes，再作为独立目录参数交给 jar；不依赖 javac 处理非 Java 文件。
  for (const path of resourceFiles) {
    const target = join(CLASSES_DIR, relative(RESOURCE_DIR, path));
    mkdirSync(dirname(target), { recursive: true });
    copyFileSync(path, target);
  }
  const sherpaResource = join(CLASSES_DIR, 'com/amcl/launcher/sherpa-bindings.properties');
  mkdirSync(dirname(sherpaResource), { recursive: true });
  writeFileSync(sherpaResource, bindings.bytes);
  writeFileSync(join(CLASSES_DIR, 'com/amcl/launcher/zstd-bindings.properties'), zstdBindings.bytes);

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
    ['cfm', OUT_JAR, JAR_MANIFEST, '-C', CLASSES_DIR, '.'],
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
    resourceFiles: inputIdentity.resourceFiles,
    jarSha256,
  }, null, 2)}\n`, 'utf8');
  console.log(`[build-amcl-launcher] OK  ${OUT_JAR}  (${size} bytes, sha256=${jarSha256})`);
}

try {
  // Java 绑定表与本次 HAP 的真实 native 同批消费，缺失/篡改制品不能只产出可发现的 Java 门面。
  stageSherpaRuntime();
  stageZstdRuntime();
  // Fabric compatibility is a separate mod artifact; do not put its classes in
  // amcl-launcher.jar or the JVM parent classpath (Knot owns their instance state).
  const python = process.env.AMCL_PYTHON || (process.platform === 'win32' ? 'python' : 'python3');
  // CPU 兼容是全部产品共有的独立生产 Agent；与默认关闭的开发探针分别构建和交付。
  execFileSync(python, [join(SCRIPT_DIR, 'build-cpu-agent.py')], { cwd: PROJECT_ROOT, stdio: 'inherit' });
  // Forge 的实际模块加载器需要限定的 SPI 资源桥；独立 Agent 与 launcher 一起按源码身份更新。
  execFileSync(python, [join(SCRIPT_DIR, 'build-audio-service-agent.py')], { cwd: PROJECT_ROOT, stdio: 'inherit' });
  execFileSync(python, [join(SCRIPT_DIR, 'build-game-compat.py')], { cwd: PROJECT_ROOT, stdio: 'inherit' });
  main();
} catch (e) {
  console.error(`[build-amcl-launcher] FAILED: ${e.message}`);
  process.exit(1);
}
