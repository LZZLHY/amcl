/** 复现同一批任务对象原地变更时汇总冻结的问题，验证新快照独立驱动计数与筛选。 */
import assert from 'node:assert/strict';
import { loader } from './mod-install-test-runtime.mjs';
const core=loader()('feature_core/src/main/ets/download/UnifiedDownloadTask.ets');
const {makeDownloadTaskSnapshot}=loader({feature_core:core})('entry/src/main/ets/components/DownloadTaskSnapshot.ets');
const first=new core.UnifiedTaskView(),second=new core.UnifiedTaskView();
first.id='root';second.id='dependency';first.state=second.state=core.UnifiedTaskState.DOWNLOADING;
first.bytesTotal=100;second.bytesTotal=200;first.progress=20;second.progress=50;
const views=[first,second];const before=makeDownloadTaskSnapshot(views);
assert.equal(before.activeCount,2);assert.equal(before.done.length,0);
first.state=second.state=core.UnifiedTaskState.DONE;
const after=makeDownloadTaskSnapshot(views);
assert.notEqual(before,after);assert.notEqual(before.all,after.all);assert.equal(after.all[0],first);
assert.equal(after.activeCount,0);assert.equal(after.inProgress.length,0);assert.equal(after.done.length,2);
// 旧快照计数保持原样，卡片引用保持稳定；新状态不会混入错误的“已完成”数量。
assert.equal(before.activeCount,2);first.state=core.UnifiedTaskState.ERROR;second.state=core.UnifiedTaskState.WAITING;
const failed=makeDownloadTaskSnapshot(views);assert.equal(failed.failed.length,1);assert.equal(failed.done.length,0);
assert.equal(failed.waitingCount,1);assert.equal(failed.inProgress[0],second);
second.state=core.UnifiedTaskState.PAUSED;
assert.equal(makeDownloadTaskSnapshot(views).activeCount,1);
console.log('PASS: stable task identities with refreshed summary/filter snapshots, success/error separation, waiting and paused counts');
