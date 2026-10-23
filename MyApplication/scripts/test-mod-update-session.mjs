/**
 * 更新会话的宿主回归：执行实际 ArkTS 策略，只替换远程仓库边界。
 * 固定元数据夹具验证既有选版语义，并用一千个已装项计数证明一轮仅读取一次依赖，
 * 不依赖运行耗时推测复杂度；额外验证并发请求复用、来源失败隔离和生命周期取消。
 */
import assert from 'node:assert/strict';
import { loader } from './mod-install-test-runtime.mjs';

const load = loader({ './ModSourceRouter': {} });
const { createModUpdateSession, pickModUpdate } = load('mods/src/main/ets/ModUpdatePolicy.ets');

/** 最小完整远程版本，时间相同，使用真实版本比较函数判断新旧与稳定通道。 */
function version(id, projectId, dependencies = [], source = 'modrinth', number = '1.0') {
  return {
    id, projectId, source, name: id, versionNumber: number, versionType: 'release',
    changelog: '', gameVersions: ['1.21.11'], loaders: ['fabric'], files: [], dependencies,
    datePublished: '2026-10-16T00:00:00Z', downloads: 0,
  };
}

/** 已装文件只在策略读取远程身份；仍提供完整 LocalMod 字段以贴近真实扫描结果。 */
function local(projectId, versionId, source = 'modrinth', enabled = true) {
  return {
    enabled, remoteSource: source, remoteProjectId: projectId, remoteVersionId: versionId,
    filename: projectId + '.jar', filePath: '/mods/' + projectId + '.jar', sizeBytes: 1, sha1: '',
  };
}

/** 单个依赖可以是 required 精确 pin 或 incompatible；不补出 API 未声明的项目 ID。 */
function dependency(projectId, dependencyType, versionId) {
  return { projectId, dependencyType, versionId };
}

/**
 * 请求计数包含失败，异步让多个 pick 有机会同时遇到同一进行中请求。
 * 若出现未登记的查询立即失败，从而捕捉禁用/异源/缺身份项被错误读取。
 */
function fixtureRouter(versions, failures = new Set()) {
  const calls = new Map();
  let active = 0;
  let maxActive = 0;
  return {
    calls,
    get maxActive() { return maxActive; },
    repoFor(source) {
      return {
        async getVersion(id) {
          const key = source + ':' + id;
          calls.set(key, (calls.get(key) ?? 0) + 1);
          active++;
          maxActive = Math.max(active, maxActive);
          try {
            await new Promise(resolve => setTimeout(resolve, 0));
            if (failures.has(key)) throw new Error('fixture failed: ' + key);
            assert.ok(versions.has(key), 'Unexpected metadata query: ' + key);
            return versions.get(key);
          } finally {
            active--;
          }
        },
      };
    },
  };
}

/** 并行同一目标、重复已装身份、后续重复检查都必须共享一个具体版本请求。 */
{
  const old = version('old', 'target');
  const next = version('next', 'target', [], 'modrinth', '2.0');
  const router = fixtureRouter(new Map([['modrinth:old', old]]));
  const session = createModUpdateSession([local('target', 'old'), local('target', 'old'), local('alias', 'old')], router);
  const results = await Promise.all(Array.from({ length: 24 }, () => session.pick('modrinth', 'target', 'old', [old, next])));
  assert.ok(results.every(result => result.id === 'next'));
  assert.equal((await session.pick('modrinth', 'target', 'old', [old, next])).id, 'next');
  assert.equal(router.calls.get('modrinth:old'), 1, 'In-flight and parsed metadata must both be cached');
}

/**
 * 一千个可更新模组以四条外部 worker 消费，模拟 Sheet 的有界检查。
 * dependencies getter 的计数独立于网络缓存，能发现“缓存了请求却仍 N² 遍历依赖”的回退。
 */
{
  const count = 1000;
  let dependencyReads = 0;
  const installed = [];
  const versions = new Map();
  const candidates = [];
  for (let i = 0; i < count; i++) {
    const project = 'p' + i;
    const old = version('old' + i, project);
    Object.defineProperty(old, 'dependencies', { get() { dependencyReads++; return []; } });
    versions.set('modrinth:' + old.id, old);
    installed.push(local(project, old.id));
    candidates.push([old, version('new' + i, project, [], 'modrinth', '2.0')]);
  }
  const router = fixtureRouter(versions);
  const session = createModUpdateSession(installed, router);
  let cursor = 0;
  const worker = async () => {
    while (cursor < count) {
      const index = cursor++;
      const picked = await session.pick('modrinth', 'p' + index, 'old' + index, candidates[index]);
      assert.equal(picked.id, 'new' + index);
    }
  };
  await Promise.all(Array.from({ length: 4 }, worker));
  assert.equal(router.calls.size, count);
  assert.ok([...router.calls.values()].every(calls => calls === 1));
  assert.equal(dependencyReads, count, 'Reverse dependency index must be built once per source');
  assert.ok(router.maxActive <= 7, 'Four current-version requests plus three indexing workers remain bounded');
  console.log(`PASS: ${count} installed mods -> ${router.calls.size} getVersion calls, ${dependencyReads} dependency reads, peak ${router.maxActive} requests`);
}

/**
 * required 无 pin / optional / embedded 不限制更新；required 精确 pin 收紧候选；
 * incompatible 精确版本只排除该版本，无具体版本则排除该项目的全部候选。
 */
for (const [dependencies, expected] of [
  [[dependency('target', 'required')], 'next'],
  [[dependency('target', 'optional', 'old')], 'next'],
  [[dependency('target', 'embedded', 'old')], 'next'],
  [[dependency('target', 'required', 'middle')], 'middle'],
  [[dependency('target', 'required', 'old')], null],
  [[dependency('target', 'required', 'middle'), dependency('target', 'required', 'next')], null],
  [[dependency('target', 'incompatible', 'next')], 'middle'],
  [[dependency('target', 'incompatible')], null],
  [[dependency(undefined, 'required', 'old')], 'next'],
]) {
  const old = version('old', 'target');
  const middle = version('middle', 'target', [], 'modrinth', '2.0');
  const next = version('next', 'target', [], 'modrinth', '3.0');
  const router = fixtureRouter(new Map([
    ['modrinth:old', old], ['modrinth:owner1', version('owner1', 'owner', dependencies)],
  ]));
  const installed = [local('owner', 'owner1'), local('disabled', 'unknown', 'modrinth', false),
    local('otherSource', 'unknown', 'curseforge'), local('missing', '')];
  const result = await createModUpdateSession(installed, router).pick('modrinth', 'target', 'old', [old, next, middle]);
  assert.equal(result?.id ?? null, expected);
  assert.equal(router.calls.size, 2, 'Disabled, other-source and incomplete identities do not constrain this source');
}

/** 同项目自身声明继续排除，创建后修改扫描对象也不能改变当前会话快照。 */
{
  const old = version('old', 'target', [dependency('target', 'incompatible')]);
  const next = version('next', 'target', [], 'modrinth', '2.0');
  const owner = version('owner1', 'owner', [dependency('target', 'required', 'old')]);
  const router = fixtureRouter(new Map([['modrinth:old', old], ['modrinth:owner1', owner]]));
  const installed = [local('target', 'old'), local('owner', 'owner1')];
  const session = createModUpdateSession(installed, router);
  installed[1].enabled = false;
  installed[1].remoteVersionId = 'mutated';
  assert.equal(await session.pick('modrinth', 'target', 'old', [old, next]), null);
  assert.equal((await createModUpdateSession([installed[0]], router).pick('modrinth', 'target', 'old', [old, next])).id, 'next');
}

/** 保留单项兼容入口与稳定通道规则：release 不跳 beta，beta 可升 release。 */
{
  const stable = version('stable', 'target');
  const beta = { ...version('beta', 'target', [], 'modrinth', '2.0-beta'), versionType: 'beta' };
  const next = version('next', 'target', [], 'modrinth', '3.0');
  const router = fixtureRouter(new Map([['modrinth:stable', stable], ['modrinth:beta', beta]]));
  assert.equal(await pickModUpdate('modrinth', 'target', 'stable', [stable, beta], [], router), null);
  assert.equal((await pickModUpdate('modrinth', 'target', 'beta', [beta, next], [], router)).id, 'next');
}

/**
 * 一个来源读取不到约束时复用失败且不推荐未知 pin 下的更新；另一个来源继续成功。
 * 两源相同具体版本 id 的记录不能共用，CurseForge 请求必须保留 project/fileId 路径。
 */
{
  const mrOld = version('same', 'target');
  const mrNew = version('mrNew', 'target', [], 'modrinth', '2.0');
  const cfOld = version('same', 'target', [], 'curseforge');
  const cfNew = version('cfNew', 'target', [], 'curseforge', '2.0');
  const router = fixtureRouter(new Map([
    ['modrinth:same', mrOld], ['curseforge:target/same', cfOld],
  ]), new Set(['modrinth:broken']));
  const session = createModUpdateSession([local('brokenOwner', 'broken'), local('target', 'same', 'curseforge')], router);
  await assert.rejects(session.pick('modrinth', 'target', 'same', [mrOld, mrNew]), /fixture failed/);
  await assert.rejects(session.pick('modrinth', 'target', 'same', [mrOld, mrNew]), /fixture failed/);
  assert.equal((await session.pick('curseforge', 'target', 'same', [cfOld, cfNew])).id, 'cfNew');
  assert.equal(router.calls.get('modrinth:broken'), 1, 'Rejected metadata must not be retried by every row');
  assert.equal(router.calls.get('modrinth:same'), 1);
  assert.equal(router.calls.get('curseforge:target/same'), 1);
}

/** 取消前零请求，取消在途检查后不发布建议，也不再领取整包剩余元数据。 */
{
  let calls = 0;
  let canceled = true;
  const old = version('old', 'target');
  const next = version('next', 'target', [], 'modrinth', '2.0');
  const installed = Array.from({ length: 30 }, (_, index) => local('dep' + index, 'dep' + index));
  const session = createModUpdateSession(installed, {
    repoFor: () => ({ async getVersion(id) {
      calls++;
      await new Promise(resolve => setTimeout(resolve, 0));
      if (id.startsWith('dep')) canceled = true;
      return id === 'old' ? old : version(id, id);
    } }),
  }, () => canceled);
  await assert.rejects(session.pick('modrinth', 'target', 'old', [old, next]), /已取消/);
  assert.equal(calls, 0);
  canceled = false;
  await assert.rejects(session.pick('modrinth', 'target', 'old', [old, next]), /已取消/);
  assert.ok(calls <= 4, 'Cancellation stops scheduling beyond current version and three index workers');
  const afterCancel = calls;
  await assert.rejects(session.pick('modrinth', 'target', 'old', [old, next]), /已取消/);
  assert.equal(calls, afterCancel);
}

console.log('PASS: update sessions preserve pin/incompatible/stable semantics, snapshot identity, cached failure, per-source isolation and cancellation');
