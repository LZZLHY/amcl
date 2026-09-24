#!/usr/bin/env node
/*
 * apply.mjs — compile (if needed) and run StackBackfill over the LWJGL jars.
 *
 * Re-adds the LWJGL 3.2.x `*Stack` static allocator API (mallocStack/callocStack)
 * to our post-3.3.1 modern-slot jars so MC 1.13–1.19.x bytecode that calls e.g.
 * `GLFWImage.mallocStack(int, MemoryStack)` links instead of crashing at boot.
 * See README.md in this folder and CHANGELOG 1000122 / the ATM8 diagnosis.
 *
 * Idempotent: skips methods that already exist; re-running adds 0.
 *
 * Usage:
 *   node scripts/lwjgl-stack-backfill/apply.mjs <dir-with-lwjgl-jars> [<dir2> ...]
 *
 * Needs a JDK (javac+java) on PATH or via JAVA_HOME. ASM is vendored in ./lib.
 */
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, renameSync, statSync, unlinkSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = join(HERE, 'out');
const SRC = join(HERE, 'StackBackfill.java');
const LIB = join(HERE, 'lib');

function jdkBin(name) {
  const home = process.env.JAVA_HOME;
  if (home) {
    const p = join(home, 'bin', process.platform === 'win32' ? `${name}.exe` : name);
    if (existsSync(p)) return p;
  }
  return name; // rely on PATH
}

function asmClasspath() {
  const jars = readdirSync(LIB).filter((f) => f.endsWith('.jar')).map((f) => join(LIB, f));
  if (jars.length === 0) throw new Error('no ASM jars vendored in ' + LIB);
  return jars.join(process.platform === 'win32' ? ';' : ':');
}

function ensureCompiled(cp) {
  const cls = join(OUT, 'StackBackfill.class');
  if (existsSync(cls) && statSync(cls).mtimeMs >= statSync(SRC).mtimeMs) return;
  mkdirSync(OUT, { recursive: true });
  execFileSync(jdkBin('javac'), ['-cp', cp, '-d', OUT, SRC], { stdio: 'inherit' });
}

function run(cp, jar) {
  const tmp = jar + '.bf.tmp';
  const runCp = (process.platform === 'win32' ? `${OUT};${cp}` : `${OUT}:${cp}`);
  const output = execFileSync(jdkBin('java'), ['-cp', runCp, 'StackBackfill', jar, tmp], {
    stdio: ['ignore', 'pipe', 'inherit'],
    encoding: 'utf8',
  });
  process.stdout.write(output);
  // Java 端为了简化实现总会写出一个 ZIP。若没有新增方法，替换原文件只会改变
  // ZIP 元数据并破坏制品 SHA-256；此时删除临时文件，保持字节级幂等。
  if (/methods added=0\b/.test(output)) {
    unlinkSync(tmp);
    return;
  }
  // 有实际回填时才原子替换。
  renameSync(tmp, jar);
}

const dirs = process.argv.slice(2);
if (dirs.length === 0) {
  console.error('usage: node apply.mjs <dir-with-lwjgl-jars> [<dir2> ...]');
  process.exit(2);
}

const cp = asmClasspath();
ensureCompiled(cp);

let total = 0;
for (const d of dirs) {
  const dir = resolve(d);
  if (!existsSync(dir)) { console.log(`[stack-backfill] skip (absent): ${dir}`); continue; }
  for (const f of readdirSync(dir)) {
    if (!f.endsWith('.jar')) continue;
    run(cp, join(dir, f));
    total++;
  }
}
console.log(`[stack-backfill] done over ${total} jar(s).`);
