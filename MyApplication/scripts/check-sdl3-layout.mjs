#!/usr/bin/env node
// Authoritative SDL3 ABI layout guard for LWJGL 3.4.2 on OHOS arm64.
//
// The text-level check-sdl3-abi.mjs catches source declaration changes. This
// guard closes the remaining gap: it evaluates LWJGL's generated SIZEOF and
// member-offset constants on a 64-bit JVM, generates C _Static_asserts, and
// compiles them with the real HarmonyOS aarch64 clang and the pinned SDL headers.

// 临时夹具及其清理边界统一使用外部宿主测试区，不修改系统 TEMP，也不回退到源码目录。
import { workspacePath, workspaceTempRoot } from './lib/workspace-paths.mjs';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { createWriteStream, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { get } from 'node:https';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(scriptDir, '..');
const coreJar = join(root, 'prebuilt/lwjgl3/jars/lwjgl.jar');
const sdlJar = join(root, 'prebuilt/lwjgl3/jars/lwjgl-sdl.jar');
const lwjglVersion = '3.4.2';
const hostNatives = {
  win32: {
    classifier: 'natives-windows',
    sha256: '8e48cf335d308a84d7e782f001a5a89fdc9a30766e82a9056f30300bdff70d01',
  },
  linux: {
    classifier: 'natives-linux',
    sha256: 'eb88f7341461174ec2084c41c0e1bfeeed957158e59ed55d9c34a13efcbe2665',
  },
};

const criticalTypes = [
  'SDL_Event', 'SDL_DisplayMode', 'SDL_Rect', 'SDL_PixelFormatDetails',
  'SDL_KeyboardEvent', 'SDL_MouseMotionEvent', 'SDL_MouseButtonEvent', 'SDL_MouseWheelEvent',
  'SDL_TextInputEvent', 'SDL_TextEditingEvent', 'SDL_TextEditingCandidatesEvent',
  'SDL_DropEvent', 'SDL_DisplayEvent', 'SDL_WindowEvent',
  'SDL_CommonEvent', 'SDL_KeyboardDeviceEvent', 'SDL_MouseDeviceEvent',
  'SDL_JoyAxisEvent', 'SDL_JoyBallEvent', 'SDL_JoyHatEvent', 'SDL_JoyButtonEvent',
  'SDL_JoyDeviceEvent', 'SDL_JoyBatteryEvent',
  'SDL_GamepadAxisEvent', 'SDL_GamepadButtonEvent', 'SDL_GamepadDeviceEvent',
  'SDL_GamepadTouchpadEvent', 'SDL_GamepadSensorEvent',
  'SDL_AudioDeviceEvent', 'SDL_CameraDeviceEvent', 'SDL_SensorEvent',
  'SDL_QuitEvent', 'SDL_UserEvent', 'SDL_TouchFingerEvent', 'SDL_PinchFingerEvent',
  'SDL_PenProximityEvent', 'SDL_PenTouchEvent', 'SDL_PenMotionEvent',
  'SDL_PenButtonEvent', 'SDL_PenAxisEvent', 'SDL_RenderEvent', 'SDL_ClipboardEvent',
  'SDL_Surface', 'SDL_Palette', 'SDL_Color', 'SDL_FRect', 'SDL_FPoint', 'SDL_Point',
];

function fail(message) {
  throw new Error(message);
}

function parseArgs(argv) {
  const out = { repo: null, sdk: null, keep: false };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--repo') out.repo = resolve(argv[++i]);
    else if (argv[i] === '--sdk') out.sdk = resolve(argv[++i]);
    else if (argv[i] === '--keep') out.keep = true;
    else fail(`unknown argument: ${argv[i]}`);
  }
  if (!out.repo) fail('usage: node scripts/check-sdl3-layout.mjs --repo <pinned SDL source> [--sdk <openharmony SDK>]');
  return out;
}

function locateSdk(explicit) {
  const candidates = [];
  if (explicit) candidates.push(explicit);
  if (process.env.DEVECO_SDK_HOME) candidates.push(process.env.DEVECO_SDK_HOME);
  const props = join(root, 'local.properties');
  if (existsSync(props)) {
    const match = /^hwsdk\.dir=(.+)$/m.exec(readFileSync(props, 'utf8'));
    if (match) candidates.push(match[1].trim().replace(/\\\\/g, '\\'));
  }
  for (const candidate of candidates) {
    const variants = [candidate, join(candidate, 'default', 'openharmony')];
    for (const sdk of variants) {
      const native = join(sdk, 'native');
      const clang = join(native, 'llvm', 'bin', process.platform === 'win32' ? 'clang.exe' : 'clang');
      if (existsSync(clang)) return { sdk, native, clang };
    }
  }
  fail('HarmonyOS SDK not found; pass --sdk or set DEVECO_SDK_HOME');
}

function sha256(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

function download(url, target) {
  return new Promise((resolvePromise, reject) => {
    const request = get(url, (response) => {
      if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
        response.resume();
        download(new URL(response.headers.location, url), target).then(resolvePromise, reject);
        return;
      }
      if (response.statusCode !== 200) {
        response.resume();
        reject(new Error(`download failed (${response.statusCode}): ${url}`));
        return;
      }
      const file = createWriteStream(target, { flags: 'wx' });
      response.pipe(file);
      file.on('finish', () => file.close(resolvePromise));
      file.on('error', reject);
    });
    request.on('error', reject);
  });
}

async function ensureHostNativeJar() {
  const descriptor = hostNatives[process.platform];
  if (!descriptor) fail(`unsupported host for LWJGL layout reflection: ${process.platform}`);
  // 已锁哈希的宿主探针 JAR 可复用，但其下载缓存不属于 Docker 配方或工程输入。
  const cache = workspacePath('build', 'sdl-layout-cache');
  mkdirSync(cache, { recursive: true });
  const name = `lwjgl-${lwjglVersion}-${descriptor.classifier}.jar`;
  const target = join(cache, name);
  if (existsSync(target) && sha256(target) !== descriptor.sha256) rmSync(target, { force: true });
  if (!existsSync(target)) {
    const url = `https://repo1.maven.org/maven2/org/lwjgl/lwjgl/${lwjglVersion}/${name}`;
    console.log(`[sdl3-layout] downloading pinned host probe native: ${descriptor.classifier}`);
    await download(url, target);
  }
  const digest = sha256(target);
  if (digest !== descriptor.sha256) fail(`host probe native sha256=${digest}, expected=${descriptor.sha256}`);
  return target;
}

function javaSource() {
  const names = criticalTypes.map((name) => `      "${name}"`).join(',\n');
  return `
import java.lang.reflect.*;
import java.util.*;

public class LwjglSdlLayoutDump {
  private static String norm(String value) {
    return value.replace("_", "").toLowerCase(Locale.ROOT);
  }

  public static void main(String[] args) throws Exception {
    if (!"64".equals(System.getProperty("sun.arch.data.model"))) {
      throw new IllegalStateException("64-bit JVM required");
    }
    String[] names = {
${names}
    };
    for (String name : names) {
      Class<?> c = Class.forName("org.lwjgl.sdl." + name);
      int size = c.getField("SIZEOF").getInt(null);
      int align = c.getField("ALIGNOF").getInt(null);
      List<String> members = new ArrayList<>();
      for (Field field : c.getFields()) {
        int mods = field.getModifiers();
        if (field.getType() != int.class || !Modifier.isStatic(mods) || !Modifier.isPublic(mods)) continue;
        if (field.getName().equals("SIZEOF") || field.getName().equals("ALIGNOF")) continue;
        Method getter = null;
        for (Method method : c.getDeclaredMethods()) {
          if (Modifier.isStatic(method.getModifiers()) || method.getParameterCount() != 0) continue;
          if (norm(method.getName()).equals(norm(field.getName()))) { getter = method; break; }
        }
        if (getter != null) members.add(getter.getName() + "=" + field.getInt(null));
      }
      Collections.sort(members);
      System.out.println(name + "|" + size + "|" + align + "|" + String.join(",", members));
    }
  }
}
`;
}

const opt = parseArgs(process.argv.slice(2));
if (!existsSync(join(opt.repo, 'include', 'SDL3', 'SDL.h'))) fail(`not an SDL source tree: ${opt.repo}`);
for (const jar of [coreJar, sdlJar]) if (!existsSync(jar)) fail(`missing jar: ${jar}`);
const sdk = locateSdk(opt.sdk);
const hostNativeJar = await ensureHostNativeJar();
const work = mkdtempSync(join(workspaceTempRoot(), 'amcl-sdl3-layout-'));

try {
  const javaFile = join(work, 'LwjglSdlLayoutDump.java');
  writeFileSync(javaFile, javaSource(), 'utf8');
  const sep = process.platform === 'win32' ? ';' : ':';
  const cp = [coreJar, sdlJar, hostNativeJar].join(sep);
  const java = spawnSync('java', ['-cp', cp, javaFile], { cwd: root, encoding: 'utf8' });
  if (java.error) fail(`java unavailable: ${java.error.message}`);
  if (java.status !== 0) fail(`LWJGL layout reflection failed:\n${java.stderr || java.stdout}`);

  const assertions = [];
  let typeCount = 0;
  let memberCount = 0;
  for (const line of java.stdout.split(/\r?\n/).filter(Boolean)) {
    const [type, sizeText, alignText, membersText = ''] = line.split('|');
    if (!criticalTypes.includes(type)) fail(`unexpected reflection output: ${line}`);
    const size = Number(sizeText);
    const align = Number(alignText);
    if (!Number.isInteger(size) || !Number.isInteger(align)) fail(`invalid layout numbers: ${line}`);
    assertions.push(`_Static_assert(sizeof(${type}) == ${size}, "${type}.SIZEOF");`);
    assertions.push(`_Static_assert(_Alignof(${type}) == ${align}, "${type}.ALIGNOF");`);
    typeCount++;
    for (const member of membersText.split(',').filter(Boolean)) {
      const equals = member.lastIndexOf('=');
      const name = member.slice(0, equals);
      const offset = Number(member.slice(equals + 1));
      assertions.push(`_Static_assert(offsetof(${type}, ${name}) == ${offset}, "${type}.${name}");`);
      memberCount++;
    }
  }
  if (typeCount !== criticalTypes.length) fail(`reflected ${typeCount}/${criticalTypes.length} critical types`);

  const cFile = join(work, 'sdl3_layout_probe.c');
  const objectFile = join(work, 'sdl3_layout_probe.o');
  writeFileSync(cFile, [
    '#include <stddef.h>',
    '#include <SDL3/SDL.h>',
    '',
    ...assertions,
    '',
    'int amcl_sdl3_layout_probe(void) { return 0; }',
    '',
  ].join('\n'), 'utf8');

  const sysroot = join(sdk.native, 'sysroot');
  const compile = spawnSync(sdk.clang, [
    '--target=aarch64-linux-ohos',
    `--sysroot=${sysroot}`,
    '-std=c11',
    '-D__OHOS__',
    '-DOHOS',
    `-I${join(opt.repo, 'include')}`,
    '-c', cFile,
    '-o', objectFile,
  ], { cwd: root, encoding: 'utf8' });
  if (compile.error) fail(`OHOS clang unavailable: ${compile.error.message}`);
  if (compile.status !== 0) fail(`SDL/LWJGL layout mismatch:\n${compile.stderr || compile.stdout}`);

  console.log(`[sdl3-layout] PASS: ${typeCount} critical types, ${memberCount} member offsets, OHOS aarch64 clang`);
  if (opt.keep) console.log(`[sdl3-layout] generated probe kept at ${work}`);
} finally {
  if (!opt.keep) rmSync(work, { recursive: true, force: true });
}
