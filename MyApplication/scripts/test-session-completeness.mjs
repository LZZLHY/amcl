/** 会话完整性与 AI 输入契约；直接执行生产 ETS，网络只用内存假服务，不外发任何日志。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';
const common = name => 'commons/src/main/ets/utils/' + name + '.ets';

test('internal recovery receipts never become launcher logs or exported evidence', async () => {
  const f = evidenceRuntime();
  try {
    f.write('logs/ledger/101/launcher/recovery-receipt.json', '{"schema":1,"activityId":101,"source":"internal-recovery"}');
    f.write('logs/ledger/101/launcher/launcher-game.log', '[INFO] GAME_LOG\n');
    f.write('logs/ledger/101/capture-game.json', JSON.stringify({ sealed: true, dropped: 0, writeFailures: 0, truncated: 0 }));
    const e = f.load(common('SessionEvidence')), x = f.load(common('EvidenceExportSnapshot'));
    const files = e.listSessionEvidence(f.directory, 101);
    assert(!files.some(file => file.path.includes('recovery-receipt')));
    const snapshot = await x.createEvidenceExportSnapshot(f.directory, f.context.tempDir, e.evidenceSelectionOf(f.directory, 101, files), '');
    assert(!snapshot.files.some(file => fs.readFileSync(file.path, 'utf8').includes('internal-recovery')));
    x.disposeEvidenceExportSnapshot(snapshot);
  } finally { f.close(); }
});

test('production environment collector populates ledger metadata and keeps host facts distinct from runtime plans', () => {
  const f = evidenceRuntime({ imports: {
    '@ohos.deviceInfo': { default: { chipType: 'SYNTHETIC_SOC', abiList: 'arm64-v8a' } },
    'libentry.so': { default: { getDeviceMemoryMB: () => 8192 } },
    '../product/ProductIdentityCollector': { collectProductIdentity: () => ({ product: 'default', storeChannel: false,
      osFullName: 'HarmonyOS synthetic', apiVersion: 24, deviceModel: 'TEST_DEVICE', deviceBrand: 'TEST_BRAND' }) },
  } });
  try {
    const collector = f.load('entry/src/main/ets/runtime/SessionEnvironmentCollector.ets');
    const repository = f.load(common('SessionEnvironment'));
    const meta = collector.enrichSessionEnvironment(f.context, 201, { category: 'launch', title: 'instance', gameVersionId: 'instance' }, {
      version: 'instance', baseGameVersion: '1.21.1', loaderType: 'fabric', loaderVersion: '0.19.5', generation: 'fabric-knot',
      jdkVersion: '21', xmxMb: 2048, extraJvmArgs: ['-Xmx2048m'], graphicsPlan: { requestedProfile: 'mobileglues', profile: 'mobileglues',
        apiFamily: 'OPENGL', actualProvider: 'mobileglues', windowProvider: 'GLFW' },
    });
    assert.equal(meta.deviceModel, 'TEST_DEVICE'); assert.equal(meta.appVersion, 'synthetic');
    assert.equal(meta.osVersion, 'HarmonyOS synthetic'); assert.equal(meta.loaderVersion, '0.19.5');
    const env = repository.readSessionEnvironment(f.directory, 201);
    assert.equal(repository.environmentValue(env, 'host.os'), 'HarmonyOS');
    assert.equal(repository.environmentValue(env, 'cpu.model'), 'SYNTHETIC_SOC');
    assert.equal(repository.environmentValue(env, 'game.version'), '1.21.1');
    assert.equal(env.facts.find(fact => fact.key === 'graphics.profile').status, 'planned');
    assert.equal(env.facts.find(fact => fact.key === 'gpu.model').status, 'unavailable');
    f.write('logs/ledger/201/environment-observed.log', 'AMCL_ENV_V1\tgpu.model\tACTUAL_GPU\tGLFW.current-context\nAMCL_ENV_V1\tjava.guestOs\tLinux\tJVM.System.getProperty\n');
    const actual = repository.readObservedSessionEnvironment(f.directory, 201);
    assert.equal(repository.environmentValue(actual, 'gpu.model'), 'ACTUAL_GPU');
    assert.equal(repository.environmentValue(actual, 'host.os'), 'HarmonyOS');
    assert.equal(repository.environmentValue(actual, 'java.guestOs'), 'Linux');
  } finally { f.close(); }
});

test('sealed receipt rejects shortening, equal-length rewrite and disappearance without resigning damaged bytes', () => {
  for (const damage of ['short', 'same-size', 'missing']) {
    const f = evidenceRuntime();
    try {
      const ledger = f.load(common('ActivityLedger')), evidence = f.load(common('SessionEvidence'));
      const id = Date.now() - 3000;
      ledger.ledgerBegin(f.directory, id, { category: 'launch', title: 'integrity', gameDir: f.directory + '/mc' });
      f.write('mc/logs/latest.log', 'FIRST\nMIDDLE\nLAST\n');
      ledger.ledgerEnd(f.directory, id, { state: 1, source: 'test', summary: 'finished' });
      const planBefore = f.load(common('SessionCapture')).readSessionCapture(f.directory, id);
      const before = planBefore.sources.find(item => item.destination === 'game/logs/latest.log').capturedSha256;
      const path = `${f.directory}/logs/ledger/${id}/game/logs/latest.log`;
      if (damage === 'missing') fs.unlinkSync(path);
      else fs.writeFileSync(path, damage === 'short' ? 'LAST\n' : 'XIRST\nMIDDLE\nLAST\n');
      const report = evidence.refreshSessionEvidence(f.directory, id, 'sealed', 'complete');
      assert.equal(report.integrityState, 'partial');
      assert.equal(report.files.find(file => file.path === 'game/logs/latest.log').state, 'partial');
      ledger.ledgerArchiveCompletedSessions(f.directory);
      const planAfter = f.load(common('SessionCapture')).readSessionCapture(f.directory, id);
      assert.equal(planAfter.sources.find(item => item.destination === 'game/logs/latest.log').capturedSha256, before);
      assert.equal(fs.existsSync(path), damage !== 'missing', '校验不能偷偷覆盖或重建已封账原件');
    } finally { f.close(); }
  }
});

test('owned output survives next launch and unclean exit remains partial; early failure defaults include stdio/JVM', () => {
  for (const ended of [true, false]) {
    const f = evidenceRuntime();
    try {
      const ledger = f.load(common('ActivityLedger')), evidence = f.load(common('SessionEvidence'));
      const id = Date.now() - 3000;
      ledger.ledgerBegin(f.directory, id, { category: 'launch', title: 'owned', gameDir: f.directory + '/mc' });
      f.write(`logs/ledger/${id}/native-io.json`, JSON.stringify({ schema: 1, activityId: id, pid: 101, consoleReady: true, javaAttached: true, ended, ioError: 0 }));
      f.write(`logs/ledger/${id}/game/mc_output.log`, `##AMCL-SESSION-BEGIN {"activityId":${id}}\nEARLY_FAILURE\n`);
      f.write(`logs/ledger/${id}/jvm/jvm-stderr.log`, 'JVM_INITIALIZATION\n');
      ledger.ledgerEnd(f.directory, id, { state: 2, source: 'test', summary: 'early failure' });
      ledger.ledgerBegin(f.directory, id + 1, { category: 'launch', title: 'next' });
      f.write('mc/mc_output.log', 'OTHER_ATTEMPT');
      const files = evidence.listSessionEvidence(f.directory, id);
      for (const role of ['minecraft-output', 'jvm-stderr']) {
        const file = files.find(item => item.role === role);
        assert.equal(file.attribution, 'exact'); assert.equal(file.defaultSelected, true);
        assert.equal(file.state, ended ? 'complete' : 'partial');
        assert.equal(file.verification, 'verified');
      }
    } finally { f.close(); }
  }
});

test('environment, overview and full files reach the actual request; remote byte changes never verify as complete', async () => {
  const f = evidenceRuntime();
  try {
    const ledger = f.load(common('ActivityLedger')), e = f.load(common('SessionEvidence'));
    const env = f.load(common('SessionEnvironment')), x = f.load(common('EvidenceExportSnapshot'));
    const client = f.load('entry/src/main/ets/components/LogShareClient.ets');
    ledger.ledgerBegin(f.directory, 101, { category: 'launch', title: 'environment test' });
    env.updateSessionEnvironment(f.directory, 101, [
      env.sessionEnvironmentFact('launcher.version', '1.0.4-test', 'test'),
      env.sessionEnvironmentFact('host.os', 'HarmonyOS', 'test'),
      env.sessionEnvironmentFact('cpu.model', 'TEST_CPU', 'test'),
      env.sessionEnvironmentFact('gpu.model', 'TEST_GPU', 'test'),
    ]);
    f.write('logs/ledger/101/game/mc_output.log', '##AMCL-SESSION-BEGIN {"activityId":101}\nFIRST\nMIDDLE\nLAST\n');
    const selection = e.evidenceSelectionOf(f.directory, 101);
    const snapshot = await x.createEvidenceExportSnapshot(f.directory, f.context.tempDir, selection, 'outcome=failed');
    const files = await x.snapshotShareFiles(snapshot, 12 * 1024 * 1024, 200000);
    const result = await client.submitLogFiles(files, 'amcl-launcher');
    assert.equal(result.ok, true);
    assert.match(f.control.main, /HarmonyOS/); assert.match(f.control.main, /TEST_CPU/); assert.match(f.control.main, /TEST_GPU/);
    assert.match(f.control.main, /1\.0\.4-test/);
    assert(f.control.files.find(file => file.name === 'game/mc_output.log').content.includes('FIRST\nMIDDLE\nLAST'));
    assert.equal((await client.verifyLogShareContents(result.id, result.uploadedReceipts, result.apiBaseUrl)).contentStatus, 'content-verified');
    f.control.remoteTransform = (_name, text) => text.replace(/[\r\n]+$/, '');
    const normalized = await client.verifyLogShareContents(result.id, result.uploadedReceipts, result.apiBaseUrl);
    assert.equal(normalized.verified, true); assert.equal(normalized.contentStatus, 'boundary-newlines-normalized');
    f.control.remoteTransform = (name, text) => name === 'game/mc_output.log' ? text.replace('MIDDLE', 'ALTERD') : text;
    const changed = await client.verifyLogShareContents(result.id, result.uploadedReceipts, result.apiBaseUrl);
    assert.equal(changed.verified, false); assert.equal(changed.contentStatus, 'server-changed');
    x.disposeEvidenceExportSnapshot(snapshot);
    selection.includePublicSummary = false;
    const privateSnapshot = await x.createEvidenceExportSnapshot(f.directory, f.context.tempDir, selection, '');
    const privateFiles = await x.snapshotShareFiles(privateSnapshot, 1024 * 1024, 200000);
    assert(!privateFiles.some(file => file.name === '_amcl/environment.json'));
    assert(!privateFiles.find(file => file.name === x.EVIDENCE_DIAGNOSIS_NAME).content.includes('TEST_CPU'));
    assert.equal(env.readSessionEnvironment(f.directory, 102).facts.length, 0, '历史缺失不能读取另一局或当前环境');
    x.disposeEvidenceExportSnapshot(privateSnapshot);
  } finally { f.close(); }
});

test('known Log4j configuration is derived without editing original semantics, unknown/custom is explicit', () => {
  const f = evidenceRuntime();
  try {
    const logging = f.load('launch/src/main/ets/SessionLoggingConfig.ets');
    const xml = '<Configuration><RollingFile fileName="logs/latest.log" filePattern="logs/%d-%i.log.gz"><DefaultRolloverStrategy max="7"><Delete basePath="logs"><IfFileName glob="*.gz"/></Delete></DefaultRolloverStrategy></RollingFile></Configuration>';
    const rewritten = logging.rewriteSessionLoggingXml(xml, '/session/game/logs');
    assert.equal(rewritten.owned, true); assert(rewritten.text.includes('/session/game/logs/latest.log'));
    assert(!rewritten.text.includes('<Delete')); assert(rewritten.text.includes('2147483647'));
    const custom = '<Configuration><File fileName="custom/my.log"/></Configuration>';
    const untouched = logging.rewriteSessionLoggingXml(custom, '/session');
    assert.equal(untouched.owned, false); assert.equal(untouched.text, custom);
  } finally { f.close(); }
});
