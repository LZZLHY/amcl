#!/usr/bin/env node
/**
 * 审核 Pages 实际要发布的静态更新数据。推荐按产品/通道独立存在，日志 latest 只描述
 * 展示顺序；旧 update.json 只与 sideload stable 的原件身份对应。此工具不联网、不改头。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const PRODUCTS = ['sideload', 'desktop'];
const CHANNELS = ['stable', 'preview'];
const VERSION = /^\d+\.\d+\.\d+(?:-(?:pre[1-9]\d*|(?:alpha|beta|rc|pre)\.\d+))?$/;
const HASH = /^[a-f0-9]{64}$/;

/** 结构断言集中保留字段语境，坏文件必须让 CI 失败，不能把解析失败当作没有推荐。 */
function requireValue(condition, message) { if (!condition) throw new Error(message); }
function object(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function stage(name) { return name.includes('-'); }

/** 限制输入体积并拒绝链接，避免稀疏发布夹具意外读取仓库外的文件。 */
function readJson(root, relative, limit) {
  const file = path.join(root, relative), stat = fs.lstatSync(file);
  requireValue(stat.isFile() && !stat.isSymbolicLink() && stat.size > 0 && stat.size <= limit, `${relative}: invalid file`);
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

/**
 * 验证一个准确推荐，而不是从日志或文件时间推断最新。历史兼容清单允许没有 delivery；
 * 一旦有 delivery，就完整核对所有资产与推荐身份，不让损坏的新字段被旧兼容分支吞掉。
 */
function validateManifest(manifest, product, channel, label, { legacy = false } = {}) {
  requireValue(object(manifest), `${label}: manifest object required`);
  requireValue(Number.isSafeInteger(manifest.versionCode) && manifest.versionCode > 0, `${label}: invalid code`);
  requireValue(typeof manifest.versionName === 'string' && VERSION.test(manifest.versionName), `${label}: invalid version`);
  requireValue(manifest.tag === 'v' + manifest.versionName, `${label}: tag/version mismatch`);
  requireValue(!stage(manifest.versionName) || channel === 'preview', `${label}: stable must not contain prerelease`);
  requireValue(manifest.prerelease === undefined || manifest.prerelease === stage(manifest.versionName), `${label}: prerelease mismatch`);
  requireValue(manifest.updateChannel === channel || (legacy && manifest.updateChannel === undefined), `${label}: wrong channel`);
  requireValue(!['developer', 'dev'].includes(manifest.releaseKind ?? manifest.releaseType), `${label}: developer is manual only`);
  const projection = { versionCode: manifest.versionCode, versionName: manifest.versionName, tag: manifest.tag };
  if (manifest.delivery === undefined) {
    requireValue(legacy, `${label}: published product feed requires delivery`);
    return projection;
  }
  requireValue(manifest.delivery.schema === 1 && manifest.delivery.ready === true && Array.isArray(manifest.delivery.assets) && manifest.delivery.assets.length > 0,
    `${label}: delivery is not ready`);
  requireValue(typeof manifest.publicationId === 'string' && /^[A-Za-z0-9._:-]{1,128}$/.test(manifest.publicationId), `${label}: publication identity missing`);
  const seen = new Set();
  for (const asset of manifest.delivery.assets) {
    requireValue(object(asset) && PRODUCTS.includes(asset.product) && !seen.has(asset.product), `${label}: ambiguous product asset`);
    seen.add(asset.product);
    requireValue(asset.versionCode === manifest.versionCode && asset.versionName === manifest.versionName && asset.tag === manifest.tag,
      `${label}: asset version mismatch`);
    requireValue(HASH.test(asset.sha256) && Number.isSafeInteger(asset.sizeBytes) && asset.sizeBytes > 0, `${label}: invalid asset identity`);
    const named = `amcl-v${manifest.versionName}-${asset.product}-unsigned.hap`;
    const old = `amcl-v${manifest.versionName}-unsigned.hap`;
    requireValue(asset.name === named || (asset.product === 'sideload' && asset.legacyUniversal === true && asset.name === old), `${label}: wrong asset name`);
    requireValue(asset.url === `https://github.com/LZZLHY/amcl/releases/download/${manifest.tag}/${asset.name}`, `${label}: wrong GitHub original`);
    if (asset.websiteUrl !== undefined) requireValue(asset.websiteUrl === `https://amcl.lovedhy.cn/api/packages/files/${asset.sha256}/${encodeURIComponent(asset.name)}`,
      `${label}: wrong website content identity`);
    requireValue(Array.isArray(asset.mirrors) && asset.mirrors.some(mirror => object(mirror) && mirror.ready === true), `${label}: no historical ready mirror receipt`);
    if (asset.product === product) Object.assign(projection, {
      publicationId: manifest.publicationId, sha256: asset.sha256, sizeBytes: asset.sizeBytes,
      name: asset.name, url: asset.url, websiteUrl: asset.websiteUrl ?? '', legacyUniversal: asset.legacyUniversal === true,
    });
  }
  requireValue(seen.has(product), `${label}: expected product is missing`);
  return projection;
}

/** 完整检查当前导出集合；缺省产品不补占位文件，不把不同产品的日志进度强行绑定。 */
export function validateUpdateFeeds(root) {
  root = fs.realpathSync(root);
  const update = readJson(root, 'update.json', 256 * 1024);
  const changelog = readJson(root, 'changelog.json', 8 * 1024 * 1024);
  const legacy = validateManifest(update, 'sideload', 'stable', 'update.json', { legacy: true });
  requireValue(object(changelog.latest) && Array.isArray(changelog.releases) && changelog.releases.length > 0, 'changelog: missing releases');
  const hasRelease = identity => changelog.releases.some(release => object(release) && release.versionName === identity.versionName &&
    release.versionCode === identity.versionCode && release.tag === identity.tag);
  requireValue(hasRelease(changelog.latest), 'changelog: latest is not a published release');
  requireValue(hasRelease(legacy), 'update.json: stable release missing from changelog');
  const checked = ['update.json'];
  const identities = [legacy];
  const updates = path.join(root, 'updates');
  if (fs.existsSync(updates)) {
    requireValue(fs.lstatSync(updates).isDirectory() && !fs.lstatSync(updates).isSymbolicLink(), 'updates: invalid directory');
    for (const entry of fs.readdirSync(updates, { withFileTypes: true })) {
      requireValue(entry.isDirectory() && !entry.isSymbolicLink() && PRODUCTS.includes(entry.name), 'updates: unknown product');
      const directory = path.join(updates, entry.name);
      for (const file of fs.readdirSync(directory, { withFileTypes: true })) {
        const channel = file.name.replace(/\.json$/, '');
        requireValue(file.isFile() && !file.isSymbolicLink() && file.name === channel + '.json' && CHANNELS.includes(channel), 'updates: unknown channel or entry');
        const relative = `updates/${entry.name}/${file.name}`;
        const candidate = readJson(root, relative, 256 * 1024);
        const identity = validateManifest(candidate, entry.name, channel, relative);
        requireValue(hasRelease(identity), `${relative}: published release missing from changelog`);
        if (entry.name === 'sideload' && channel === 'stable') {
          // 旧入口只有在同一正式原件时才可继续服务；notes/date 的兼容展示投影允许不同。
          for (const key of Object.keys(identity)) requireValue(legacy[key] === identity[key], `update.json: differs from sideload stable (${key})`);
        }
        checked.push(relative);
        identities.push(identity);
      }
    }
  }
  return { schemaVersion: 1, ok: true, checked, identities, latestLogVersion: changelog.latest.versionName, legacyStableVersion: update.versionName };
}

/**
 * 公开源码对应它自己的实际发行，不一定对应 sideload stable 或全局日志 latest。
 * 随包日志是该源码构建时的冻结快照，后续新增其它产品/预览日志不能倒逼旧包改变字节。
 */
export function validatePublishedSourceVersion(app, bundledChangelog, publicChangelog, feedReport) {
  const matches = value => object(value) && value.versionCode === app.versionCode &&
    value.versionName === app.versionName && value.tag === 'v' + app.versionName;
  requireValue(Array.isArray(feedReport.identities) && feedReport.identities.some(matches), 'source version does not match any published product recommendation');
  requireValue(Array.isArray(publicChangelog.releases) && publicChangelog.releases.some(matches), 'source version is absent from published changelog');
  requireValue(matches(bundledChangelog.latest) && Array.isArray(bundledChangelog.releases) && bundledChangelog.releases.some(matches),
    'bundled changelog is not bound to the source release');
}

/** CLI 只接受明确的仓库根；JSON 报告可供 CI 审核，不存在跳过断言的开关。 */
if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  try {
    const args = process.argv.slice(2);
    requireValue(args.length === 2 && args[0] === '--root', 'Usage: node tools/validate-update-feeds.mjs --root <repository>');
    console.log(JSON.stringify(validateUpdateFeeds(args[1])));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
