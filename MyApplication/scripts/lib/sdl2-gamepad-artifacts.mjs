import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { readUniqueZipEntry } from '../zip-entry-buffer.mjs';

/** 旧模组的两个 JNI 绑定和 SDL2 共同交付；逐件比较源制品或 HAP 实际条目。 */
export function verifySdl2GamepadArtifacts(root, hapBytes) {
  const lock = JSON.parse(readFileSync(join(root,'prebuilt/mod-natives/sdl2/artifacts.json'),'utf8'));
  for (const [file, digest] of Object.entries(lock.recipeInputs)) {
    const source = readFileSync(join(root, file),'utf8').replace(/\r\n/g,'\n');
    if (createHash('sha256').update(source).digest('hex') !== digest) {
      throw new Error('SDL2 controller build recipe changed: '+file);
    }
  }
  for (const name of ['libSDL2.so','libsdl2gdx.so','libjamepad.so']) {
    const expected = lock.artifacts[name];
    const bytes = hapBytes ? readUniqueZipEntry(hapBytes,'libs/arm64-v8a/'+name)
      : readFileSync(join(root,'entry/libs/arm64-v8a',name));
    const sha = createHash('sha256').update(bytes).digest('hex');
    if (sha !== (hapBytes ? expected.hapSha256 : expected.sha256) ||
        bytes.length !== (hapBytes ? expected.hapSize : expected.size)) {
      throw new Error('SDL2 controller artifact mismatch: '+name);
    }
  }
  // JNI/JNA 由同包 Agent 在游戏类加载器中接入；HAR 固化的摘要亦须指向本包同一份资源。
  if (hapBytes) {
    const agentLock = JSON.parse(readFileSync(join(root, 'JavaCpuAgent/artifact.json'), 'utf8'));
    const agent = readUniqueZipEntry(hapBytes, 'resources/rawfile/amcl-cpu-agent.jar');
    if (agent.length !== agentLock.size || createHash('sha256').update(agent).digest('hex') !== agentLock.sha256 ||
        !readUniqueZipEntry(hapBytes, 'ets/modules.abc').includes(agentLock.sha256)) {
      throw new Error('HAP SDL2 binding agent or compiled identity differs from its lock');
    }
  }
}
