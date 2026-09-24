#!/usr/bin/env node
/** 无需 SDK 或私有仓权限，核对公开源码身份、版本、子模块及已附许可正文。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { parseJson5 } from '../MyApplication/scripts/product-contract.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = relative => fs.readFileSync(path.join(root, relative), 'utf8').replace(/\r\n/g, '\n');
const json = relative => JSON.parse(read(relative));
const update = json('update.json');
const app = parseJson5(read('MyApplication/AppScope/app.json5')).app;
const snapshot = json('MyApplication/SOURCE_SNAPSHOT.json');
assert.equal(snapshot.sourceDirty, false, 'a published snapshot must identify a clean source commit');
assert.match(snapshot.sourceCommit, /^[a-f0-9]{40}$/);
assert.equal(app.versionName, update.versionName);
assert.equal(app.versionCode, update.versionCode);
assert.equal(update.tag, `v${app.versionName}`);
assert.equal(update.url, 'https://github.com/LZZLHY/amcl/releases/latest');
const displayed = read('MyApplication/commons/src/main/ets/common/Constants.ets').match(/APP_VERSION\s*=\s*'([^']+)'/);
assert.equal(displayed?.[1], app.versionName);
const changelog = json('changelog.json');
assert.equal(changelog.latest.versionCode, app.versionCode);
assert.equal(changelog.latest.versionName, app.versionName);
assert.deepEqual(json('MyApplication/entry/src/main/resources/rawfile/changelog.json'), changelog);
assert(Buffer.byteLength(read('update.json')) < 8192, 'older clients need a bounded update manifest');
// 不依赖子模块是否已下载：Git 索引中的不可变 gitlink 必须与公开清单相同。
for (const dependency of snapshot.dependencyWorktrees) {
  const output = execFileSync('git', ['-C', root, 'ls-files', '--stage', '--', `MyApplication/${dependency.path}`], { encoding: 'utf8' });
  assert.equal(output.match(/^160000 ([a-f0-9]{40}) /)?.[1], dependency.baseCommit, dependency.path);
}
assert.equal(read('LICENSE'), read('MyApplication/LICENSE'));
const notices = json('MyApplication/third-party-notices/manifest.json');
for (const notice of notices.files) {
  const filename = path.resolve(root, 'MyApplication/third-party-notices', notice.file);
  assert(filename.startsWith(path.join(root, 'MyApplication/third-party-notices') + path.sep));
  const bytes = fs.readFileSync(filename, 'utf8').replace(/\r\n/g, '\n');
  assert.equal(createHash('sha256').update(bytes).digest('hex'), notice.sha256, notice.file);
}
console.log(`PASS public release ${update.tag}/${app.versionCode}: clean source identity, gitlinks, bundled changelog and ${notices.files.length} notice copies`);
