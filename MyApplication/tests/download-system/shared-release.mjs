/** 共享关闭延迟的真实协调器回归；虚拟timer仅驱动既有purge等待，不模拟传输策略。 */
import assert from 'node:assert/strict';
import { loader } from '../../scripts/mod-install-test-runtime.mjs';

export async function runSharedOwnerReleaseRegression(api) {
  const timers = []; let released = false, settled = false, view;
  const load = loader({ './DownloadManager': api, commons: { AppLogger: { warn() {}, info() {}, error() {} } } },
    { setTimeout(fn, delay) { timers.push({ fn, delay }); return timers.length; } });
  const { SharedDownloadCoordinator } = load('feature_core/src/main/ets/download/SharedDownloadCoordinator.ets');
  const coordinator = new SharedDownloadCoordinator({ async run(spec, progress) {
    const physical = new api.DownloadTaskView(); physical.taskId = 7;
    physical.filesTotal = physical.filesDone = spec.files.length; physical.success = true; physical.finished = true;
    progress(physical); return physical;
  }, cancel: () => true, purge: () => released });
  const pending = coordinator.run({ name: 'delayed-parent-owner', files: [{ localPath: '/trusted/a.jar',
    allowedRoot: '/trusted', urls: ['https://fixture.invalid/a.jar'], check: { sha1: 'a'.repeat(40), size: 4 } }] },
    current => { view = current; }).then(result => { settled = true; return result; });
  // 生产模块在VM realm，backend与本测试在宿主realm；跨realm Promise采纳会额外排
  // 微任务，固定两次Promise.resolve不能证明下一次等待已登记。切到下一事件轮只让
  // 当前微任务链排空，不推进虚拟时间，也不替生产安排任何timer。取不到仍立即失败。
  const nextWait = async () => {
    await new Promise(resolve => setImmediate(resolve));
    const waiting = timers.shift(); assert(waiting, '真实Shared应继续安排收敛检查');
    assert.equal(waiting.delay, 250, '只推进生产既有的250ms收敛等待');
    return waiting.fn;
  };
  for (let tick = 0; tick < 130; tick++) {
    const next = await nextWait(); next();
  }
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(settled, false); assert.equal(view.finished, false);
  assert.equal(coordinator.purge(view.taskId), false);
  released = true;
  const next = await nextWait(); next();
  assert.equal((await pending).success, true); assert.equal(settled, true);
  assert.equal(coordinator.purge(view.taskId), true);
  return ['shared owner stays pending after original 30s boundary until actual Native release'];
}
