import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/** SDL 自身的构建门与 LWJGL 消费门共用已提交的制品锁；遇到同名节或重复键拒绝选择。 */
function readNativeSection(root, section) {
  const fields = new Map();
  let active = false;
  let found = false;
  for (const raw of readFileSync(join(root, 'deps.lock'), 'utf8').split(/\r?\n/)) {
    const line = raw.split('#', 1)[0].trim();
    if (!line) continue;
    if (line.startsWith('[')) {
      active = line === '[' + section + ']';
      if (active && found) throw new Error('deps.lock duplicates [' + section + ']');
      if (active) found = true;
    } else if (active) {
      const equals = line.indexOf('=');
      const key = line.slice(0, equals).trim();
      if (equals < 1 || fields.has(key)) throw new Error('deps.lock invalid or duplicate ' + section + ' key: ' + key);
      fields.set(key, line.slice(equals + 1).trim());
    }
  }
  if (!found) throw new Error('deps.lock missing [' + section + ']');
  return fields;
}

/** SDL 构建调用者继续读取原节，其他模块不会借用这份身份。 */
export function readSdl3ArtifactLock(root, controller = false) {
  return readNativeSection(root, controller ? 'sdl3-controller' : 'sdl3-native');
}

/** 分别锁定打包前后身份的库只接受所属模块、固定路径和锁节的组合。 */
export function resolveBundleFileLock(root, moduleName, native) {
  const lockedProviders = [
    ['lwjgl-sdl', 'entry/libs/arm64-v8a/libSDL3.so', 'sdl3-native'],
    ['lwjgl-jemalloc', 'entry/libs/arm64-v8a/libamcl_lwjgl_jemalloc.so', 'jemalloc-native'],
  ];
  const provider = lockedProviders.find(([module, path]) => moduleName === module || native.artifact === path);
  if (!provider && !('lockSection' in native)) return { size: native.size, sha256: native.sha256 };
  if (!provider || moduleName !== provider[0] || native.artifact !== provider[1] ||
      native.lockSection !== provider[2] || 'size' in native || 'sha256' in native) {
    throw new Error(moduleName + ': bundle provider must use deps.lock [' + (provider?.[2] || 'unknown') + '] without inline identity');
  }
  const fields = readNativeSection(root, provider[2]);
  return {
    size: Number(fields.get('size')), sha256: fields.get('sha256'),
    hap: { size: Number(fields.get('hap_size')), sha256: fields.get('hap_sha256') },
  };
}
