#!/usr/bin/env node
/**
 * 直接执行 Pages 的生产验证/暂存函数，覆盖预览、独立电脑与正式收敛接缝。
 * 所有夹具只写显式运行容器；成功后关闭句柄、保存小收据并回收自有目录，失败保留现场。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { validateUpdateFeeds, validatePublishedSourceVersion } from './validate-update-feeds.mjs';
import { stageUpdatePages } from './stage-update-pages.mjs';

const parent = path.resolve(process.env.AMCL_RUN_DIR || os.tmpdir());
fs.mkdirSync(parent, { recursive: true });
const owned = fs.mkdtempSync(path.join(parent, 'public-update-feeds-'));
const checks = [];

/** 生成最小但完整的公开收据，两个产品/通道使用独立原件和发布身份。 */
function manifest(product = 'sideload', channel = 'stable', version = '1.0.6', code = 1000910) {
  const sha256 = (product === 'sideload' ? 'a' : 'b').repeat(64);
  const name = `amcl-v${version}-${product}-unsigned.hap`, tag = 'v' + version;
  return { schema: 1, versionName: version, versionCode: code, tag, updateChannel: channel, prerelease: version.includes('-'),
    publicationId: createHash('sha256').update(`${product}-${channel}-${version}-${code}`).digest('hex'), delivery: { schema: 1, ready: true, assets: [{
      product, versionName: version, versionCode: code, tag, name, sha256, sizeBytes: 123,
      url: `https://github.com/LZZLHY/amcl/releases/download/${tag}/${name}`,
      websiteUrl: `https://amcl.lovedhy.cn/api/packages/files/${sha256}/${name}`,
      legacyUniversal: false, mirrors: [{ provider: 'fixture', ready: true }],
    }] } };
}
function identity(m) { return { versionName: m.versionName, versionCode: m.versionCode, tag: m.tag, prerelease: m.prerelease }; }
function write(root, relative, value) {
  const target = path.join(root, relative); fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, typeof value === 'string' ? value : JSON.stringify(value));
}
function fixture(name, feeds = []) {
  const root = path.join(owned, name); fs.mkdirSync(root);
  const stable = manifest(), releases = [stable, ...feeds].map(identity);
  write(root, 'update.json', stable); write(root, 'updates/sideload/stable.json', stable);
  for (const f of feeds) write(root, `updates/${f.delivery.assets[0].product}/${f.updateChannel}.json`, f);
  write(root, 'changelog.json', { latest: releases.at(-1), releases });
  return root;
}
function run(name, body) { body(); checks.push(name); }

try {
  run('preview retains legacy stable and stages the actual production files', () => {
    const root = fixture('preview', [manifest('sideload', 'preview', '1.0.7-pre1')]);
    const original = fs.readFileSync(path.join(root, 'update.json'));
    const result = stageUpdatePages(root, path.join(owned, 'staged-preview'));
    assert.equal(result.latestLogVersion, '1.0.7-pre1'); assert.equal(result.legacyStableVersion, '1.0.6');
    assert.deepEqual(fs.readFileSync(path.join(result.staged, 'update.json')), original);
    assert(fs.existsSync(path.join(result.staged, 'updates/sideload/preview.json')));
    assert.throws(() => stageUpdatePages(root, result.staged), /already exist/);
  });
  run('desktop-only stable progresses without changing sideload compatibility', () => {
    const desktop = manifest('desktop', 'stable', '1.0.7', 1000911);
    const root = fixture('desktop', [desktop]), report = validateUpdateFeeds(root);
    assert.equal(report.latestLogVersion, '1.0.7');
    const frozen = { latest: identity(desktop), releases: [identity(desktop)] };
    validatePublishedSourceVersion({ versionName: '1.0.7', versionCode: 1000911 }, frozen,
      JSON.parse(fs.readFileSync(path.join(root, 'changelog.json'))), report);
  });
  run('preview source identity can differ from stable, while bundled snapshot stays frozen', () => {
    const preview = manifest('sideload', 'preview', '1.0.7-pre2');
    const root = fixture('source-preview', [preview]), log = JSON.parse(fs.readFileSync(path.join(root, 'changelog.json')));
    const frozen = { latest: identity(preview), releases: [identity(preview)] };
    validatePublishedSourceVersion({ versionName: preview.versionName, versionCode: preview.versionCode }, frozen, log, validateUpdateFeeds(root));
    assert.throws(() => validatePublishedSourceVersion({ versionName: '9.0.0', versionCode: 9 }, frozen, log, validateUpdateFeeds(root)), /source version/);
    assert.throws(() => validatePublishedSourceVersion({ versionName: preview.versionName, versionCode: preview.versionCode },
      { ...frozen, latest: identity(manifest()) }, log, validateUpdateFeeds(root)), /bundled/);
  });
  run('preview can explicitly converge to a formal release', () => {
    const root = fixture('converge', [manifest('sideload', 'preview', '1.0.6')]);
    assert.equal(validateUpdateFeeds(root).ok, true);
  });
  run('stable cannot publish preview or developer originals', () => {
    for (const kind of ['preview', 'developer']) {
      const bad = manifest('desktop', 'stable', kind === 'preview' ? '1.0.7-pre1' : '1.0.7');
      if (kind === 'developer') bad.releaseKind = 'developer';
      const root = fixture('bad-' + kind, [bad]);
      assert.throws(() => validateUpdateFeeds(root), /stable|manual only/);
      const out = path.join(owned, 'bad-output-' + kind);
      assert.throws(() => stageUpdatePages(root, out)); assert.equal(fs.existsSync(out), false);
    }
  });
  run('legacy entry is compared to stable original, including digest and publication identity', () => {
    for (const [key, value] of [['sha256', 'f'.repeat(64)], ['sizeBytes', 456]]) {
      const root = fixture('drift-' + key), update = JSON.parse(fs.readFileSync(path.join(root, 'update.json')));
      update.delivery.assets[0][key] = value;
      if (key === 'sha256') update.delivery.assets[0].websiteUrl = update.delivery.assets[0].websiteUrl.replace('a'.repeat(64), value);
      write(root, 'update.json', update); assert.throws(() => validateUpdateFeeds(root), /differs from sideload stable/);
    }
  });
  run('wrong product/source, unready mirrors and invalid digest fail closed', () => {
    for (const [name, mutate] of [
      ['source', f => { f.delivery.assets[0].url = f.delivery.assets[0].url.replace('LZZLHY/amcl', 'other/repo'); }],
      ['mirror', f => { f.delivery.assets[0].mirrors = []; }],
      ['hash', f => { f.delivery.assets[0].sha256 = 'bad'; }],
      ['product', f => { f.delivery.assets[0].product = 'store'; }],
    ]) {
      const root = fixture('invalid-' + name), broken = manifest(); mutate(broken);
      write(root, 'updates/sideload/stable.json', broken); assert.throws(() => validateUpdateFeeds(root));
    }
  });
  run('developer feed and unpublished changelog targets are rejected', () => {
    const root = fixture('dev-feed'); write(root, 'updates/sideload/developer.json', manifest());
    assert.throws(() => validateUpdateFeeds(root), /unknown channel/);
    const absent = fixture('absent-log'); write(absent, 'changelog.json', { latest: identity(manifest('desktop', 'stable', '9.0.0', 9)), releases: [identity(manifest())] });
    assert.throws(() => validateUpdateFeeds(absent), /latest/);
  });
  run('legacy-only exports remain readable without fabricating product feeds', () => {
    const root = path.join(owned, 'legacy-only'); fs.mkdirSync(root);
    const old = { versionCode: 1, versionName: '1.0.0', tag: 'v1.0.0' };
    write(root, 'update.json', old); write(root, 'changelog.json', { latest: old, releases: [old] });
    assert.equal(validateUpdateFeeds(root).ok, true);
  });
  run('empty latest identity and recursive output paths fail before staging', () => {
    const malformed = fixture('empty-latest'); write(malformed, 'changelog.json', { latest: {}, releases: [{}] });
    assert.throws(() => validateUpdateFeeds(malformed), /invalid latest/);
    const root = fixture('recursive-output'); fs.mkdirSync(path.join(root, 'assets'));
    const target = path.join(root, 'assets', 'generated');
    assert.throws(() => stageUpdatePages(root, target), /nested/); assert.equal(fs.existsSync(target), false);
  });
  run('modern product feeds require one exact product and a real publication digest', () => {
    const multiple = fixture('multiple-products'), bad = manifest();
    bad.delivery.assets.push(manifest('desktop').delivery.assets[0]);
    write(multiple, 'updates/sideload/stable.json', bad);
    assert.throws(() => validateUpdateFeeds(multiple), /exactly one/);
    const arbitrary = fixture('bad-publication'), unknown = manifest(); unknown.publicationId = 'made-up-publication';
    write(arbitrary, 'updates/sideload/stable.json', unknown);
    assert.throws(() => validateUpdateFeeds(arbitrary), /publication identity/);
  });
  const receipt = path.join(parent, path.basename(owned) + '.json');
  fs.writeFileSync(receipt, JSON.stringify({ schemaVersion: 1, ok: true, observedAt: new Date().toISOString(), checks,
    scope: 'production Pages validation and staging; no GitHub upload/deploy' }, null, 2) + '\n', { flag: 'wx' });
  // owned 是本轮 mkdtemp 的实际目录；先核绝对父路径，绝不清共享父容器。
  assert(path.dirname(fs.realpathSync(owned)) === fs.realpathSync(parent)); fs.rmSync(owned, { recursive: true });
  console.log(JSON.stringify({ ok: true, passed: checks.length, receipt }));
} catch (error) { console.error(`Pages fixture retained: ${owned}`); throw error; }
