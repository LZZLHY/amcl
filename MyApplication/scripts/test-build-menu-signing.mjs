import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname, basename } from 'node:path';
import { spawnSync } from 'node:child_process';
import { createDecipheriv, X509Certificate } from 'node:crypto';
import { selectSigning, publicSelection, prepareProfile, encryptPassword, matchingKeyAlias } from './build-menu-signing.mjs';

const temp = mkdtempSync(join(tmpdir(), 'amcl signing & ! '));
try {
  const root = join(temp, 'MyApplication'); mkdirSync(root);
  const certDir = join(temp, 'AMCL'); mkdirSync(certDir); mkdirSync(join(certDir, 'material'));
  for (const name of ['AMCL-release.cer','AMCL.p12','AMCLRelease.p7b','debug.cer','debug.p12','debug.p7b']) writeFileSync(join(certDir, name), 'fixture');
  const material = { certpath: '../AMCL/debug.cer', storeFile: '../AMCL/debug.p12', profile: '../AMCL/debug.p7b',
    storePassword: 'encrypted-store-fixture', keyPassword: 'encrypted-key-fixture', keyAlias: 'debugKey', signAlg: 'SHA256withECDSA' };
  const base = { app: { products: ['default','desktop'].map(name => ({ name, signingConfig: 'default', compatibleSdkVersion: 'keep' })),
    signingConfigs: [{ name: 'default', type: 'HarmonyOS', material }] }, marker: 'keep build settings' };
  const profile = join(root, 'build-profile.json5');
  const original = Buffer.from('// preserve comments and bytes\r\n' + JSON.stringify(base)); writeFileSync(profile, original);
  const release = selectSigning(root, 'release', 'desktop');
  assert.equal(release.mode, 'certificates'); assert.equal(release.material.storeFile, join(certDir, 'AMCL.p12'));
  assert.equal(publicSelection(release).needsPasswords, true);
  const debug = selectSigning(root, 'debug', 'default'); assert.equal(debug.mode, 'profile');
  assert.ok(!JSON.stringify(publicSelection(debug)).includes('encrypted-store-fixture'));
  assert.throws(() => selectSigning(root, 'release', 'desktop', { profilePath: 'missing.json5' }), /指定/);
  assert.throws(() => selectSigning(root, 'release', 'desktop', { certDir: 'wrong' }), /完整 Release/);
  assert.throws(() => selectSigning(root, 'release', 'unknown'), /产品/);
  const override = join(root, 'build-profile.release.json5');
  const external = structuredClone(base); external.marker = 'must not replace build settings';
  external.app.signingConfigs[0].material = { ...material, certpath: '../AMCL/AMCL-release.cer', storeFile: '../AMCL/AMCL.p12', profile: '../AMCL/AMCLRelease.p7b', keyAlias: 'releaseKey' };
  writeFileSync(override, JSON.stringify(external));
  const prepared = prepareProfile(selectSigning(root, 'release', 'desktop'), {}, {});
  assert.equal(prepared.marker, base.marker); assert.equal(prepared.app.signingConfigs[0].material.keyAlias, 'releaseKey');
  assert.deepEqual(prepared.app.products, base.app.products);
  mkdirSync(join(root, '.secrets'));
  writeFileSync(join(root, '.secrets/build-profile.release.json5'), JSON.stringify(prepared));
  assert.equal(publicSelection(selectSigning(root, 'release', 'desktop')).needsPasswords, false);
  assert.ok(selectSigning(root, 'release', 'desktop').source.includes('.secrets'));
  const key = Buffer.alloc(16, 7); const password = 'test-only 密码 ! & %';
  const envelope = Buffer.from(encryptPassword(password, key), 'hex');
  assert.equal(envelope.readUInt32BE(0), envelope.length - 16);
  const decoder = createDecipheriv('aes-128-gcm', key, envelope.subarray(4,16));
  decoder.setAuthTag(envelope.subarray(-16));
  assert.equal(Buffer.concat([decoder.update(envelope.subarray(16,-16)), decoder.final()]).toString(), password);

  if (process.platform === 'win32') {
    const store = join(temp, 'keys.p12');
    const runKeytool = args => {
      const result = spawnSync('keytool.exe', ['-J-Duser.language=en', ...args, '-keystore', store, '-storetype', 'PKCS12',
        '-storepass:env', 'AMCL_TEST_PASS'], { encoding:'utf8', windowsHide:true, env:{...process.env,AMCL_TEST_PASS:'synthetic-test-only'} });
      assert.equal(result.status,0,result.stderr); return result.stdout;
    };
    runKeytool(['-genkeypair','-alias','test','-keyalg','EC','-dname','CN=CSR self certificate','-validity','2']);
    const self = runKeytool(['-exportcert','-rfc','-alias','test']);
    runKeytool(['-selfcert','-alias','test','-dname','CN=Different issued certificate','-validity','2']);
    const issued = runKeytool(['-exportcert','-rfc','-alias','test']);
    runKeytool(['-genkeypair','-alias','unrelated','-keyalg','EC','-dname','CN=Unrelated key','-validity','2']);
    const other = runKeytool(['-exportcert','-rfc','-alias','unrelated']);
    assert.notEqual(new X509Certificate(self).fingerprint256,new X509Certificate(issued).fingerprint256);
    const listing = `Alias name: test\nEntry type: PrivateKeyEntry\n${self}`;
    assert.equal(matchingKeyAlias(listing, Buffer.from(other+issued)), 'test');
    assert.equal(matchingKeyAlias(listing, Buffer.from(other)), undefined);
    assert.equal(matchingKeyAlias(listing.replace('PrivateKeyEntry','trustedCertEntry'),Buffer.from(issued)),undefined);
    const helper = resolve('scripts/invoke-build-menu.ps1');
    for (const status of [0, 7]) {
      writeFileSync(join(root, 'build-hap.ps1'), `param($Product,$BuildMode,$HapKind)\nif ($Product -ne 'desktop' -or $BuildMode -ne 'release' -or $HapKind -ne 'signed') { exit 20 }\n$p=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'build-profile.json5') | ConvertFrom-Json\nif ($p.app.signingConfigs[0].material.keyAlias -ne 'releaseKey') { exit 21 }\nexit ${status}\n`);
      const result = spawnSync('pwsh.exe', ['-NoProfile','-File',helper,'-ProjectRoot',root,'-Certificate','release','-Product','desktop','-BuildMode','release'], {
        cwd: tmpdir(), encoding: 'utf8', windowsHide: true, env: { ...process.env, AMCL_DEBUG_PROFILE:'', AMCL_RELEASE_PROFILE:'', AMCL_RELEASE_CERT_DIR:'' } });
      assert.equal(result.status, status, result.stdout + result.stderr);
      assert.deepEqual(readFileSync(profile), original, 'restore byte-for-byte after success/failure');
      assert.equal(existsSync(join(root, '.secrets/amcl-build-menu-profile.backup')), false);
    }
  }
  console.log('PASS: saved signing without prompts; renewed certificate public-key match and unrelated-key rejection; profile overrides; secret redaction; authoritative arguments; success/failure restore; spaces and ! paths');
} finally {
  assert.equal(dirname(resolve(temp)), resolve(tmpdir()));
  assert.ok(basename(temp).startsWith('amcl signing & ! '));
  rmSync(temp, { recursive: true, force: true });
}
