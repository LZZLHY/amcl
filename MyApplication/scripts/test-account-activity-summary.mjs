/** 执行生产账户页的尝试/取消/摘要方法；只隔离账户服务及历史端口，不复制取消资格判断。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';

function fixture() {
  const source = fs.readFileSync(new URL('../entry/src/main/ets/components/AddAccountSheet.ets', import.meta.url), 'utf8');
  const ast = compiler.createSourceFile('AddAccountSheet.ets', source, compiler.ScriptTarget.Latest, true);
  const component = ast.statements.find(node => node.members?.some(value => value.name?.getText(ast) === 'recordAccountActivity_'));
  const names = ['beginAccountAttempt_', 'cancelPendingAccount_', 'requestAccountClose_', 'aboutToDisappear', 'recordAccountActivity_', 'handleAuthRedirect'];
  const body = names.map(name => component.members.find(node => node.name?.getText(ast) === name).getText(ast)).join('\n');
  const js = compiler.transpileModule('class Subject {\n' + body + '\n}\nreturn Subject;',
    { compilerOptions: { target: compiler.ScriptTarget.ES2022 } }).outputText;
  const records = []; let next = 1000;
  const Subject = new Function('getTaskActivityOwner', 'reserveTaskActivityId', 'ActivityCategory', 'ActivityStatus',
    'parseQueryParams', 'AppLogger', 'TAG', 'LOG_DOMAIN_ACCOUNT', js)(
    () => ({ recordSummary(...args) { records.push(args); } }), () => ++next,
    { ACCOUNT: 'account' }, { SUCCESS: 'success', FAILED: 'failed', ABORTED: 'aborted' },
    url => new Map(new URL(url).searchParams), { info() {}, warn() {}, error() {} }, 'account', 0);
  const page = new Subject();
  Object.assign(page, { accountAttemptStarted_: 0, busy: false, statusMsg: '', errorMsg: '', onClose() {} });
  return { page, records };
}

test('关闭授权等待只记录一次取消，真实开始身份传给摘要；在途令牌交换不误记取消', () => {
  const f = fixture();
  f.page.beginAccountAttempt_(); const id = f.page.accountAttemptStarted_;
  f.page.requestAccountClose_(); f.page.aboutToDisappear();
  assert.equal(f.records.length, 1); assert.equal(f.records[0][2], 'aborted'); assert.equal(f.records[0][4], id);
  f.page.beginAccountAttempt_(); const active = f.page.accountAttemptStarted_;
  f.page.statusMsg = '正在交换令牌'; f.page.requestAccountClose_(); f.page.aboutToDisappear();
  assert.equal(f.records.length, 1); assert.equal(f.page.accountAttemptStarted_, active);
  f.page.recordAccountActivity_('用户', '微软账户', 'success', '');
  assert.equal(f.records[1][2], 'success'); assert.equal(f.records[1][4], active);
});

test('OAuth拒绝/取消、缺code与state失配都保留对应摘要，不创建完整日志账本', async () => {
  for (const [query, status] of [['error=access_denied', 'aborted'], ['error=server_error', 'failed'], ['', 'failed'], ['code=x&state=wrong', 'failed']]) {
    const f = fixture(); f.page.beginAccountAttempt_(); f.page.pkceState = 'expected';
    await f.page.handleAuthRedirect('https://login.invalid/callback?' + query);
    assert.equal(f.records.length, 1); assert.equal(f.records[0][2], status); assert.equal(f.page.accountAttemptStarted_, 0);
  }
});
