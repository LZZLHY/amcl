/**
 * SDL host-runtime 测试输入治理：冻结上游原始字节，并在本地仓库存在时比对同一 pin。
 * 不下载、不初始化子模块、不修改 SDL 仓库；无仓库只是换输入来源，不是跳过测试。
 */
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

export const SDL_HOST_FIXTURE_FILES = ['src/SDL.c', 'src/events/SDL_events.c', 'LICENSE.txt'];

/**
 * 对固定文件白名单做大小、SHA-256 和 Git blob SHA-1 三重检查，并绑定 deps.lock commit。
 * 原始字节不进行换行或编码规范化；坏文件不能通过“修复后再比对”被接受。
 * 返回值仍是调用者的 Buffer 集合，后续抽取生产函数时才按 UTF-8 解码。
 */
export function verifySdlHostFixture(manifest, buffers, pin) {
  assert.equal(manifest.schemaVersion, 1, 'SDL fixture schema 不支持');
  assert.match(pin, /^[a-f0-9]{40}$/, 'SDL pin 必须是完整提交');
  assert.equal(manifest.sourceCommit, pin, 'SDL fixture commit 与 deps.lock 不一致');
  assert.equal(manifest.sourceRepository, 'https://github.com/icculus/SDL', 'SDL fixture 来源仓库不符');
  assert.equal(manifest.license, 'Zlib', 'SDL fixture 许可证不符');
  assert.equal(manifest.licensePath, 'LICENSE.txt', 'SDL fixture 必须保留完整许可证');
  assert.deepEqual(manifest.files.map((entry) => entry.path), SDL_HOST_FIXTURE_FILES, 'SDL fixture 文件集合不符');
  for (const entry of manifest.files) {
    const buffer = buffers.get(entry.path);
    assert.ok(Buffer.isBuffer(buffer), `SDL fixture 缺文件: ${entry.path}`);
    assert.equal(buffer.length, entry.size, `SDL fixture 大小不符: ${entry.path}`);
    assert.match(entry.sha256, /^[a-f0-9]{64}$/, 'SDL fixture SHA-256 格式错误');
    assert.match(entry.gitBlob, /^[a-f0-9]{40}$/, 'SDL fixture Git blob 格式错误');
    assert.equal(createHash('sha256').update(buffer).digest('hex'), entry.sha256, `SDL fixture SHA-256 不符: ${entry.path}`);
    const blob = createHash('sha1').update(`blob ${buffer.length}\0`).update(buffer).digest('hex');
    assert.equal(blob, entry.gitBlob, `SDL fixture Git blob 不符: ${entry.path}`);
    assert.equal(entry.sourceUrl, `${manifest.sourceRepository}/blob/${pin}/${entry.path}`, 'SDL fixture 来源 URL 不符');
  }
  return buffers;
}

/** 读取仓库内的冻结输入；即使选了 --repo，也检查离线 fixture，防止 CI 来源静默失效。 */
export function loadSdlHostFixture(root, pin) {
  const directory = path.join(root, 'prebuilt/sdl3/tests/fixtures/e293db30d');
  const manifest = JSON.parse(fs.readFileSync(path.join(directory, 'manifest.json'), 'utf8'));
  const buffers = new Map(SDL_HOST_FIXTURE_FILES.map((name) => [name, fs.readFileSync(path.join(directory, name))]));
  verifySdlHostFixture(manifest, buffers, pin);
  return { directory, manifest, buffers };
}

/**
 * 显式路径不容许回退；默认只采用带 .git 的完整 clone/worktree。
 * 选定仓库缺少 pin 时由调用方 git show 硬失败，不能偷偷退回旧 fixture。
 * hasRepository 允许输入选择测试注入只读桩，不影响生产默认的文件系统判据。
 */
export function selectSdlHostSourceRepo({ explicitRepo, fixtureOnly, candidates,
  hasRepository = (repo) => fs.existsSync(path.join(repo, '.git')) }) {
  assert.ok(!(fixtureOnly && explicitRepo !== undefined), '--fixture-only 与 --repo 不能并用');
  if (fixtureOnly) return null;
  if (explicitRepo !== undefined) {
    assert.ok(hasRepository(explicitRepo), `显式 SDL 仓库不存在或未初始化: ${explicitRepo}`);
    return explicitRepo;
  }
  return candidates.find(hasRepository) ?? null;
}

/**
 * 负向来源回归在正常门禁中执行：坏字节、假 blob、变 pin、缺许可、错误路径都必须拒绝。
 * 只在内存复制/变更输入，不改正式 fixture，也不要求额外 SDL 仓库或网络。
 */
export function testSdlHostSourceRejections(fixture, pin) {
  for (const name of SDL_HOST_FIXTURE_FILES) {
    const corrupt = new Map(fixture.buffers);
    const bytes = Buffer.from(corrupt.get(name));
    bytes[0] ^= 1;
    corrupt.set(name, bytes);
    assert.throws(() => verifySdlHostFixture(fixture.manifest, corrupt, pin), /SHA-256 不符/);
  }
  const fakeBlob = JSON.parse(JSON.stringify(fixture.manifest));
  fakeBlob.files[0].gitBlob = '0'.repeat(40);
  assert.throws(() => verifySdlHostFixture(fakeBlob, fixture.buffers, pin), /Git blob 不符/);
  assert.throws(() => verifySdlHostFixture(fixture.manifest, fixture.buffers, '0'.repeat(40)), /commit 与 deps.lock 不一致/);
  const missingLicense = new Map(fixture.buffers);
  missingLicense.delete('LICENSE.txt');
  assert.throws(() => verifySdlHostFixture(fixture.manifest, missingLicense, pin), /缺文件/);
  const candidates = ['/preferred', '/fallback'];
  assert.equal(selectSdlHostSourceRepo({ candidates, hasRepository: () => false }), null);
  assert.equal(selectSdlHostSourceRepo({ candidates, hasRepository: (repo) => repo === '/fallback' }), '/fallback');
  assert.equal(selectSdlHostSourceRepo({ candidates, hasRepository: () => true }), '/preferred');
  assert.equal(selectSdlHostSourceRepo({ candidates, fixtureOnly: true, hasRepository: () => true }), null);
  assert.throws(() => selectSdlHostSourceRepo({ explicitRepo: '/bad', candidates, hasRepository: () => false }), /显式 SDL 仓库不存在/);
  assert.throws(() => selectSdlHostSourceRepo({ explicitRepo: '/bad', fixtureOnly: true, candidates }), /不能并用/);
}
