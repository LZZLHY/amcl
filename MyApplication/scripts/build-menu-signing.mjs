// Local signing selection for amcl-build-menu.bat. Never prints credentials.
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { createCipheriv, randomBytes, X509Certificate } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import JSON5 from 'json5';

const require = createRequire(import.meta.url);
const readProfile = p => JSON5.parse(readFileSync(p, 'utf8').replace(/^\uFEFF/, ''));
const samePath = (a, b) => resolve(a).toLowerCase() === resolve(b).toLowerCase();

function materialFrom(profile, file, product) {
  const selected = profile.app?.products?.find(p => p.name === product);
  const signing = profile.app?.signingConfigs?.find(c => c.name === selected?.signingConfig);
  if (!signing?.material) throw new Error(`签名配置未配置产品 ${product}：${file}`);
  const material = { ...signing.material };
  for (const name of ['certpath', 'storeFile', 'profile']) {
    if (!material[name]) throw new Error(`签名配置缺少 ${name}：${file}`);
    material[name] = resolve(dirname(file), material[name]);
    if (!existsSync(material[name])) throw new Error(`签名文件不存在：${material[name]}`);
  }
  return material;
}

export function selectSigning(root, kind, product, { profilePath, certDir } = {}) {
  root = resolve(root);
  const current = join(root, 'build-profile.json5');
  if (!existsSync(current)) throw new Error(`缺少本机配置：${current}，请先在 DevEco 配置 Debug 签名。`);
  const base = readProfile(current);
  const selected = base.app?.products?.find(p => p.name === product);
  if (!selected?.signingConfig) throw new Error(`当前配置没有产品 ${product} 的签名设置。`);
  if (!['debug', 'release'].includes(kind)) throw new Error('未知签名类型');
  const candidates = profilePath ? [resolve(root, profilePath)] : kind === 'debug' ? [current] :
    [join(root, '.secrets/build-profile.release.json5'), join(root, 'build-profile.release.json5'), join(root, 'signing/build-profile.release.json5'),
     join(root, '../AMCL/build-profile.release.json5')];
  const source = candidates.find(existsSync);
  if (profilePath && !source) throw new Error(`指定的签名配置不存在：${candidates[0]}`);
  if (source) return { base, selected, source, mode: 'profile', material: materialFrom(readProfile(source), source, product) };

  // The normal workspace is AMCL/MyApplication alongside AMCL/AMCL.
  const directories = certDir ? [resolve(root, certDir)] : [resolve(root, '../AMCL'), join(root, 'AMCL')];
  for (const directory of directories) {
    const material = { certpath: join(directory, 'AMCL-release.cer'), storeFile: join(directory, 'AMCL.p12'),
      profile: join(directory, 'AMCLRelease.p7b'), signAlg: 'SHA256withECDSA' };
    if (![material.certpath, material.storeFile, material.profile].every(existsSync)) continue;
    // Reuse an existing complete local configuration when its files match.
    const existing = base.app.signingConfigs?.find(c => c.material &&
      ['certpath', 'storeFile', 'profile'].every(k => c.material[k] && samePath(resolve(root, c.material[k]), material[k])));
    if (existing?.material.keyPassword && existing.material.storePassword && existing.material.keyAlias) {
      return { base, selected, source: current, mode: 'profile', material: { ...existing.material, ...material } };
    }
    if (!existsSync(join(directory, 'material'))) throw new Error(`已找到证书，但缺少 DevEco 密码加密目录：${join(directory, 'material')}。请在 DevEco 导入这套签名材料。`);
    return { base, selected, source: directory, mode: 'certificates', material };
  }
  throw new Error(`未找到完整 Release 证书。检查目录：${directories.join('；')}。需要 AMCL-release.cer、AMCL.p12、AMCLRelease.p7b；也可设置 AMCL_RELEASE_CERT_DIR。`);
}

export function publicSelection(choice) {
  return { mode: choice.mode, source: choice.source, certpath: choice.material.certpath,
    storeFile: choice.material.storeFile, profile: choice.material.profile,
    needsPasswords: choice.mode === 'certificates' };
}

function sdkDecipher(hvigorRoot) {
  // The SDK normally installs this alias inside its build launcher. Reproduce
  // that resolution only while loading its own password decoder, then restore.
  const Module = require('node:module');
  const previous = Module._resolveFilename;
  Module._resolveFilename = function (name, ...args) {
    if (name === '@ohos/hvigor') return require.resolve(join(hvigorRoot, 'hvigor'));
    return previous.call(this, name, ...args);
  };
  try { return require(join(hvigorRoot, 'hvigor-ohos-plugin/src/utils/decipher-util.js')).DecipherUtil; }
  finally { Module._resolveFilename = previous; }
}

export function encryptPassword(password, key) {
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-128-gcm', Buffer.from(key), iv);
  const encrypted = Buffer.concat([cipher.update(password, 'utf8'), cipher.final(), cipher.getAuthTag()]);
  const length = Buffer.alloc(4); length.writeUInt32BE(encrypted.length);
  return Buffer.concat([length, iv, encrypted]).toString('hex').toUpperCase();
}

export function matchingKeyAlias(keytoolOutput, certificateBytes) {
  const pem = text => text.match(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g) || [];
  const chain = pem(certificateBytes.toString('utf8'));
  const issued = (chain.length ? chain : [certificateBytes]).map(c => new X509Certificate(c));
  const publicKey = c => c.publicKey.export({ type: 'spki', format: 'der' });
  // A PKCS12 generated for a CSR holds a self-signed certificate. Its issued
  // replacement differs in issuer/signature/fingerprint but has the same key.
  // Huawei's CER may also contain a root-first chain, so inspect every member.
  for (const entry of keytoolOutput.split(/Alias name: /).slice(1)) {
    if (!entry.includes('PrivateKeyEntry')) continue;
    const stored = pem(entry)[0];
    if (stored && issued.some(c => publicKey(c).equals(publicKey(new X509Certificate(stored))))) {
      return entry.split(/\r?\n/)[0].trim();
    }
  }
  return undefined;
}

export function prepareProfile(choice, secrets, { hvigorRoot, keytool }) {
  if (choice.mode === 'certificates') {
    if (!secrets?.storePassword) throw new Error('证书库密码不能为空。');
    // Do not put passwords in command arguments or display keytool's raw output.
    const result = spawnSync(keytool, ['-J-Duser.language=en', '-J-Duser.country=US',
      '-J-Dfile.encoding=UTF-8', '-J-Dstdout.encoding=UTF-8', '-list', '-rfc',
      '-storetype', 'PKCS12', '-keystore', choice.material.storeFile, '-storepass:env', 'AMCL_MENU_KEYTOOL_PASSWORD'],
    { encoding: 'utf8', input: '', windowsHide: true, env: { ...process.env, AMCL_MENU_KEYTOOL_PASSWORD: secrets.storePassword } });
    if (result.status !== 0) throw new Error('无法打开 AMCL.p12：请核对证书库密码及 JDK keytool 配置。');
    const alias = matchingKeyAlias(result.stdout, readFileSync(choice.material.certpath));
    if (!alias) throw new Error('AMCL.p12 中没有与 Release 证书公钥匹配的私钥。');
    const decoder = sdkDecipher(hvigorRoot);
    const directory = dirname(choice.material.storeFile);
    const key = decoder.getKey(directory, 'build-profile.json5');
    const storePassword = encryptPassword(secrets.storePassword, key);
    const keyPlain = secrets.keyPassword || secrets.storePassword;
    const keyPassword = encryptPassword(keyPlain, key);
    if (decoder.decryptPwd(directory, storePassword, 'build-profile.json5') !== secrets.storePassword ||
        decoder.decryptPwd(directory, keyPassword, 'build-profile.json5') !== keyPlain) throw new Error('SDK 签名密码加密校验失败。');
    choice.material = { ...choice.material, keyAlias: alias, storePassword, keyPassword };
  }
  // Preserve product/toolchain/build settings; only replace the selected signer's
  // material, keeping its existing name for the authoritative product gates.
  const signer = choice.base.app.signingConfigs.find(c => c.name === choice.selected.signingConfig);
  if (!signer) throw new Error('当前产品引用的签名配置不存在。');
  signer.material = choice.material;
  return choice.base;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    const value = name => { const i = args.indexOf(`--${name}`); return i < 0 ? undefined : args[i + 1]; };
    const kind = value('kind');
    const choice = selectSigning(value('root'), kind, value('product'), {
      profilePath: kind === 'release' ? process.env.AMCL_RELEASE_PROFILE : process.env.AMCL_DEBUG_PROFILE,
      certDir: process.env.AMCL_RELEASE_CERT_DIR });
    if (args[0] === 'inspect') console.log(JSON.stringify(publicSelection(choice)));
    else if (args[0] === 'prepare') {
      let input = ''; for await (const chunk of process.stdin) input += chunk;
      const profile = prepareProfile(choice, input.trim() ? JSON.parse(input) : {}, {
        hvigorRoot: value('hvigor-root'), keytool: value('keytool') });
      writeFileSync(join(resolve(value('root')), 'build-profile.json5'), JSON.stringify(profile, null, 2) + '\n');
    } else throw new Error('未知签名菜单操作');
  } catch (error) { console.error(`[签名菜单] ${error.message}`); process.exitCode = 1; }
}
