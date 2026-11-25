// 运行真实 ArkTS 调试适配器，替代设备锁、活动账本、JVM 与当前游戏宿主等平台边界。
import assert from 'node:assert/strict';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const appPid = 20;
const privatePid = 31;
const activity = 171;
const privateGame = { category: 'launch', state: 0, gameVersionId: '自定义版本',
  activityId: activity, ownerPid: privatePid, runNonce: 'game-run' };
let host;
let lock;
let lockReads = 0;
let directory = '/qa/granted';
let next = privateGame;
let rows = [privateGame];
let state = 'initializing';

const load = makePureEtsLoader({
  '@kit.CoreFileKit': { fileIo: { lstatSync() {
    if (lock === undefined) throw Object.assign(new Error('missing'), { code: 13900002 });
    return { isFile: () => true, isSymbolicLink: () => false };
  } } },
  commons: { LedgerState: { RUNNING: 0 }, ledgerLaunchManifestsAsync: async () => rows,
    ledgerManifestAsync: async () => next },
  'libentry.so': { default: { desktopProcessId: () => appPid, mcIsRunning: () => false,
    desktopGameProcessState() { lockReads++; return lock; },
    desktopProcessAlive: pid => pid === privatePid ? 1 : 0 } },
  'entry/ProductQa': { ProductQa: { sessionDirectory: () => directory } },
  './ets/runtime/GameSessionHost': { existingGameSessionHost: () => host },
  './ets/devtools/PrivateGameWitness': {},
  './ets/runtime/GraphicsRecoveryPolicy': {},
  './ets/launcherskill/NamedSkill': {
    isLauncherSkillMethod: () => true,
    callNamedLauncherSkill: async () => ({ state, reason: 'example' }),
  },
});

const { ProductQaGame } = load('entry/src/main/ProductQaGame.ets');
const current = async (args = {}) => JSON.parse(await ProductQaGame.handle('/files', 'game.current',
  JSON.stringify(args), '0'.repeat(32), () => assert.fail('观察不得启动游戏')));
assert.equal((await current({ activityId: 1 })).status, 'rejected');
assert.equal((await current()).data.state, 'idle');
assert.equal(lockReads, 0, '查询不得创建本不存在的独立游戏锁');

lock = -1;
assert.equal((await current()).status, 'unknown');
lock = 1;
const observed = await current();
assert.equal(observed.status, 'ok');
assert.deepEqual(observed.data, { state: 'running', activityId: activity, versionId: privateGame.gameVersionId,
  processRole: 'game', ownerPid: privatePid, windowId: 0 });
rows = [privateGame, { ...privateGame, activityId: activity + 1 }];
assert.equal((await current()).status, 'unknown', '多条存活候选不可认领');
rows = [privateGame];
next = { ...privateGame, runNonce: 'other' };
assert.equal((await current()).status, 'unknown', '账本换代无法认领');
lock = 0;
next = { ...privateGame, ownerPid: appPid };
host = { isRunning: () => true, sessionActivity: () => activity, runningWindow: () => 19 };
assert.equal((await current()).data.windowId, 19);
assert.equal((await current()).data.processRole, 'launcher');
directory = '';
assert.equal((await current()).status, 'rejected');

const { runQaLauncherSkill } = load('entry/src/main/QaLauncherSkill.ets');
const invoke = async () => JSON.parse(await runQaLauncherSkill('skill.example', '{}', '0'.repeat(32)));
assert.deepEqual(await invoke(), { status: 'unknown', data: { state: 'initializing', reason: 'example' }, reason: 'example' });
state = 'needsUser';
assert.equal((await invoke()).status, 'needsUser');
state = 'failed';
assert.equal((await invoke()).status, 'rejected');
console.log('QA 当前游戏活动和初始化回执通过');
