/** 将已经审核的两份独立OHOS zstd-JNI送入SDK原生输入；旧输入身份不同才原子替换。 */
import {createHash} from 'node:crypto';
import {existsSync, lstatSync, mkdirSync, readFileSync, renameSync, writeFileSync} from 'node:fs';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {checkZstdArtifacts} from './check-zstd-artifacts.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const NAMES = ['libamcl_zstdjni_std.so', 'libamcl_zstdjni_dh.so'];
const digest = data => createHash('sha256').update(data).digest('hex');

/** 只证明输入字节和目标架构；最终HAP与设备JNI执行由独立门验证。 */
export function stageZstdRuntime() {
  const folder = join(ROOT, 'prebuilt/mod-natives/zstd-jni');
  const lock = checkZstdArtifacts({root: ROOT});
  if (lock.schemaVersion !== 1 || lock.artifacts?.length !== NAMES.length) throw new Error('Incomplete zstd JNI lock');
  const destination = join(ROOT, 'entry/libs/arm64-v8a');
  mkdirSync(destination, {recursive: true});
  for (const name of NAMES) {
    const candidates = lock.artifacts.filter(x => x.filename === name);
    if (candidates.length !== 1) throw new Error('Missing/duplicate zstd JNI artifact');
    const record = candidates[0], bytes = readFileSync(join(folder, 'arm64-v8a', name));
    if (record.needed?.join(',') !== 'libc.so' || record.jniExports?.length !== 148 ||
        bytes.length !== record.size || digest(bytes) !== record.sha256 || bytes.length < 64 ||
        bytes.subarray(0, 6).toString('hex') !== '7f454c460201' || bytes.readUInt16LE(18) !== 183)
      throw new Error('zstd JNI source artifact identity mismatch: ' + name);
    const target = join(destination, name);
    if (existsSync(target)) {
      if (lstatSync(target).isSymbolicLink()) throw new Error('zstd JNI SDK input is a symlink');
      if (digest(readFileSync(target)) === record.sha256) continue;
    }
    const temporary = `${target}.stage-${process.pid}`;
    writeFileSync(temporary, bytes, {flag: 'wx'});
    renameSync(temporary, target);
  }
  console.log('[zstd-runtime] verified and staged two separate JNI providers');
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) stageZstdRuntime();
