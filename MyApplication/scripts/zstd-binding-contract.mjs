/** 由唯一的已核Java绑定清单生成有界资源；构建身份同时覆盖原JSON和实际生成字节。 */
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {join} from 'node:path';

export function zstdBindingResource(root) {
  const source = readFileSync(join(root, 'prebuilt/mod-natives/zstd-jni/verified-bindings.json'));
  const value = JSON.parse(source.toString('utf8'));
  if (value.schemaVersion !== 1 || value.property !== 'ZstdNativePath' ||
      !Array.isArray(value.profiles) || value.profiles.length < 1 || value.profiles.length > 16)
    throw new Error('Invalid zstd JNI binding registry');
  const providers = new Map([
    ['com/github/luben/zstd/', 'libamcl_zstdjni_std.so'],
    ['dhcomgithubluben/zstd/', 'libamcl_zstdjni_dh.so'],
  ]);
  const lines = ['schema=1', 'family=zstd-jni', `profile.count=${value.profiles.length}`,
    `manifest.sha256=${createHash('sha256').update(source).digest('hex')}`];
  const ids = new Set();
  for (const [i, profile] of value.profiles.entries()) {
    if (!/^[a-zA-Z0-9.-]{1,80}$/.test(profile.id) || ids.has(profile.id) ||
        providers.get(profile.classPrefix) !== profile.filename)
      throw new Error('Invalid or ambiguous zstd JNI provider');
    ids.add(profile.id);
    const classes = Object.entries(profile.classSha256 || {}).sort(([a], [b]) => a.localeCompare(b, 'en'));
    if (classes.length < 1 || classes.length > 1024 || !classes.some(([p]) => p === profile.classPrefix + 'util/Native.class'))
      throw new Error('Incomplete zstd JNI binding class set');
    const key = `profile.${i}.`;
    lines.push(`${key}id=${profile.id}`, `${key}prefix=${profile.classPrefix}`, `${key}filename=${profile.filename}`, `${key}class.count=${classes.length}`);
    for (const [n, [path, sha]] of classes.entries()) {
      if (!path.startsWith(profile.classPrefix) || !/^[a-zA-Z0-9_/$.-]+\.class$/.test(path) ||
          path.includes('..') || !/^[0-9a-f]{64}$/.test(sha)) throw new Error('Invalid zstd JNI class identity');
      lines.push(`${key}class.${n}.path=${path}`, `${key}class.${n}.sha256=${sha}`);
    }
  }
  return {source, bytes: Buffer.from(lines.join('\n') + '\n', 'ascii')};
}
