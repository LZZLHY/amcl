/** 整合包元数据回归：执行生产解析器、探针和CF仓库，只替换HTTP边界，不复制领域算法。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { loader, productionPathPolicy } from './mod-install-test-runtime.mjs';
import { assertExternalOutputPath } from './lib/workspace-paths.mjs';

const argument = process.argv.indexOf('--output-dir');
if (argument < 0 || !process.argv[argument + 1]) throw new Error('需要显式 --output-dir 外置输出');
const output = assertExternalOutputPath(process.argv[argument + 1]); fs.mkdirSync(output, { recursive: true });
const cases = [], pass = name => { cases.push(name); console.log('PASS: ' + name); };
const cf = { manifestType: 'minecraftModpack', manifestVersion: 1, name: 'CF', minecraft: { version: '1.20.1' }, files: [] };
const load = loader({ feature_core: productionPathPolicy() });
const M = load('mods/src/main/ets/ModpackManifest.ets');

// 同一来源身份才合并；required在两种顺序下均不得被optional覆盖，其他项目/文件保持独立。
for (const sequence of [[false, true, false], [true, false]]) {
  const files = sequence.map(required => ({ projectID: 10, fileID: 20, required }));
  files.push({ projectID: 11, fileID: 20, required: true }, { projectID: 10, fileID: 21, required: false });
  const plan = M.parseCurseForgeManifest(JSON.stringify({ ...cf, files })).plan;
  assert.equal(plan.files.length, 3); assert.equal(plan.files[0].env, M.ModpackEnv.REQUIRED);
  assert.equal(plan.files[1].cfProjectId, 11); assert.equal(plan.files[2].cfFileId, 21);
}
pass('CF exact identity deduplication preserves stable order and required precedence');

// 只有目录字段获得别名兼容，所有真正父目录/绝对路径与控制字符仍拒绝；通用文件策略不变。
for (const [input, expected] of [['overrides', 'overrides'], ['overrides/', 'overrides'],
  ['./overrides', 'overrides'], ['overrides\\', 'overrides'], ['.', '.'], ['./', '.'],
  ['.minecraft/', '.minecraft'], ['a/b/', 'a/b']]) {
  const plan = M.parseCurseForgeManifest(JSON.stringify({ ...cf, overrides: input })).plan;
  assert.equal(plan.overrideDirs[0], expected); assert.equal(plan.problems.length, 0);
}
for (const input of ['../bad', 'overrides/../bad', '/etc', '\\root', 'C:/root', 'a//b', 'a\u0000b']) {
  const plan = M.parseCurseForgeManifest(JSON.stringify({ ...cf, overrides: input })).plan;
  assert.equal(plan.overrideDirs.length, 0, input); assert.equal(plan.problems.length, 1);
}
assert.equal(M.safeRelPath('overrides/'), ''); assert.equal(M.safeRelPath('./overrides'), '');
assert.throws(() => M.parseCurseForgeManifest(JSON.stringify({ ...cf, overrides: 5 })), /目录字符串/);
pass('CF override directory aliases are normalized without weakening canonical file paths');

assert.equal(M.parseCurseForgeManifest('\ufeff' + JSON.stringify(cf)).plan.gameVersion, '1.20.1');
const mr = { game: 'minecraft', formatVersion: 1, name: 'MR', versionId: '1', dependencies: { minecraft: '1.20.1' }, files: [] };
assert.equal(M.parseModrinthIndex('\ufeff' + JSON.stringify(mr)).plan.gameVersion, '1.20.1');
assert.equal(M.stripModpackTextBom('x\ufeffy'), 'x\ufeffy');
pass('CF and Modrinth tolerate a leading BOM while retaining JSON string content');

// HTTP夹具返回真实形状；归档补链不需要普通资源目录，但精确身份/客户端边界依然生效。
let file = { id: 6000001, modId: 123, fileName: 'ClientPack.zip', downloadUrl: null, fileLength: 1024, hashes: [], modules: [] };
let classId = 4471, probeHealthy = false;
const requests = [];
const dm = { isCaBundleInitialized: () => true, async fetchTextEx(url) {
  requests.push(url); return { statusCode: 200, headers: {}, body: JSON.stringify({ data: url.includes('/files/') ? file : { id: 123, classId } }) };
} };
const repoLoad = loader({ '@kit.NetworkKit': { http: {} }, feature_core: { buildConditionalRequest: () => ({}) } });
const { CurseForgeRepository } = repoLoad('mods/src/main/ets/CurseForgeRepository.ets');
const repo = new CurseForgeRepository(dm, {}, 'AMCL-test', () => probeHealthy, () => false);
assert.equal(repo.isAvailable(), true);
const archive = await repo.resolveArchiveDownloadInfo('123', '6000001');
assert.equal(archive.filename, 'ClientPack.zip'); assert.equal(archive.urls.length, 2);
assert.equal(requests.length, 1, '归档补链不得调用项目分类端点');
await assert.rejects(repo.resolveFileDownloadInfo('123', '6000001'), /客户端资源类型/);
classId = 6; assert.equal((await repo.resolveFileDownloadInfo('123', '6000001')).targetDirectory, 'mods');
file = { ...file, id: 6000002 }; await assert.rejects(repo.resolveArchiveDownloadInfo('123', '6000001'), /身份不符/);
file = { ...file, id: 6000001, isServerPack: true }; await assert.rejects(repo.resolveArchiveDownloadInfo('123', '6000001'), /服务端/);
pass('CF archive address resolution bypasses resource classification but preserves exact client identity');

// 执行真实探针缓存：Modrinth镜像500后CF仍能实际发起请求，不等待30分钟或重启应用。
let healthy = false;
const http = { RequestMethod: { GET: 0 }, createHttp: () => ({
  request: async url => ({ responseCode: !healthy && url.includes('mcimirror') ? 500 : 200 }), destroy() {},
}) };
const healthLoad = loader({ '@kit.NetworkKit': { http }, feature_core: { buildConditionalRequest: () => ({}) } });
const probe = healthLoad('mods/src/main/ets/ModSourceProber.ets');
await probe.ensureModrinthRanking(); healthy = true; assert.equal(probe.isMcimAvailable(), false);
const HealthRepo = healthLoad('mods/src/main/ets/CurseForgeRepository.ets').CurseForgeRepository;
file = { ...file, isServerPack: false }; const count = requests.length;
const recovered = new HealthRepo(dm, {}, 'AMCL-test', () => probe.isMcimAvailable(), () => false);
assert.equal(recovered.isAvailable(), true); await recovered.resolveArchiveDownloadInfo('123', '6000001');
assert.equal(requests.length, count + 1);
pass('negative Modrinth probe cache no longer blocks actual CurseForge recovery requests');

fs.writeFileSync(path.join(output, 'metadata-result.json'), JSON.stringify({ cases, count: cases.length }, null, 2));
