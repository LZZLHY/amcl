/**
 * 将锁定的 OHOS Sherpa 运行库同步到 SDK 正式 native 输入目录。只消费固定两件制品；
 * 对来源字节先校验，再原子替换不同内容，不按 mtime 接受过期或被改写的库。
 */
import {createHash} from 'node:crypto';
import {existsSync, lstatSync, mkdirSync, readFileSync, renameSync, writeFileSync} from 'node:fs';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const SPEC = join(ROOT, 'prebuilt/mod-natives/sherpa-onnx');
const EXPECTED = ['libonnxruntime.so', 'libsherpa-onnx-jni.so'];
const digest = bytes => createHash('sha256').update(bytes).digest('hex');

/** 构建/SDK hook 共用同一实现；返回的是已部署内容身份，不是设备装载或推理资格。 */
export function stageSherpaRuntime() {
  const lock = JSON.parse(readFileSync(join(SPEC, 'artifacts.json'), 'utf8'));
  if (!Array.isArray(lock.artifacts) || lock.artifacts.length !== EXPECTED.length)
    throw new Error('Incomplete Sherpa native artifact lock');
  const destination = join(ROOT, 'entry/libs/arm64-v8a');
  mkdirSync(destination, {recursive: true});
  for (const name of EXPECTED) {
    const records = lock.artifacts.filter(record => record.filename === name);
    if (records.length !== 1) throw new Error('Missing or duplicate native lock: ' + name);
    const record = records[0], bytes = readFileSync(join(SPEC, 'arm64-v8a', name));
    if (bytes.length !== record.size || digest(bytes) !== record.sha256 ||
        bytes.length < 64 || bytes.subarray(0, 6).toString('hex') !== '7f454c460201' || bytes.readUInt16LE(18) !== 183)
      throw new Error('Sherpa source artifact identity mismatch: ' + name);
    const target = join(destination, name);
    if (existsSync(target)) {
      if (lstatSync(target).isSymbolicLink()) throw new Error('Sherpa SDK input must be an ordinary file: ' + name);
      if (digest(readFileSync(target)) === record.sha256) continue;
    }
    const temporary = target + '.stage-' + process.pid;
    writeFileSync(temporary, bytes, {flag: 'wx'});
    renameSync(temporary, target);
  }
  console.log('[sherpa-runtime] verified and staged ' + EXPECTED.join(', '));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) stageSherpaRuntime();
