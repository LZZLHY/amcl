#!/usr/bin/env node
/**
 * 帧率设置静态接线门的承重负控。先运行真实仓库门禁，再对生产Index原字节做最小撤回，
 * 证明状态、持久化、getter身份与立即Native交接任何一环缺失都会红；不改应用文件。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { analyzeFrameCapSettings } from './check-ohos-runtime-optimizations.mjs';

const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
let passed = 0;
/** 撤回必须击中当前真实源码；源码结构变化时不能让一项没有生效的负控悄悄通过。 */
function mutate(from, to) {
  assert.ok(source.includes(from), '负控定位失效：'+from);
  const changed = source.replace(from, to);
  assert.notEqual(changed, source); return changed;
}
/** 每项只断言纯生产分析器的结果，禁止复写分析器或全局篡改process.exitCode。 */
function check(name, text, expected, diagnostic = '') {
  const result = analyzeFrameCapSettings(text);
  assert.equal(result.ok, expected, name+': '+JSON.stringify(result.errors));
  if (diagnostic) assert.ok(result.errors.some(error => error.includes(diagnostic)), name+'必须指出缺失环节');
  passed++; console.log('PASS OHOS settings contract: '+name);
}

check('真实惰性getter回调仍保留全部接线', source, true);
check('只改变空白和分号不影响判据', source.replace('this.getPrefManager_().ohosFrameRateCap = fpsCap',
  'this.getPrefManager_( ).ohosFrameRateCap = fpsCap;'), true);
check('惰性缓存条件加花括号仍是同一协议', mutate('if (this.prefManager_ === null) this.prefManager_ = new PreferenceManager(this.context);',
  'if (this.prefManager_ === null) { this.prefManager_ = new PreferenceManager(this.context); }'), true);
check('删除设置状态绑定被拒绝', mutate('ohosFrameRateCap: this.ohosFrameRateCap,',
  'ohosFrameRateCap: 0,'), false, 'state binding');
check('删除状态更新被拒绝', mutate('this.ohosFrameRateCap = fpsCap', ''), false, 'state update');
check('删除持久化被拒绝', mutate('this.getPrefManager_().ohosFrameRateCap = fpsCap', ''), false, 'persistent');
check('删除Native交接被拒绝', mutate('testNapi.setOhosFrameRateCap(fpsCap)', 'false'), false, 'native');
check('错误Native参数被拒绝', mutate('testNapi.setOhosFrameRateCap(fpsCap)', 'testNapi.setOhosFrameRateCap(0)'), false, 'native');
check('错误Native接收者被拒绝', mutate('testNapi.setOhosFrameRateCap(fpsCap)', 'other.setOhosFrameRateCap(fpsCap)'), false, 'native');
check('注释不能伪造持久化', mutate('this.getPrefManager_().ohosFrameRateCap = fpsCap',
  '// this.getPrefManager_().ohosFrameRateCap = fpsCap'), false, 'persistent');
check('字符串不能伪造Native交接', mutate('testNapi.setOhosFrameRateCap(fpsCap)',
  '"testNapi.setOhosFrameRateCap(fpsCap)"'), false, 'native');
check('其他方法的Native调用不能补齐设置回调', mutate('testNapi.setOhosFrameRateCap(fpsCap)', 'false')+
  '\nfunction decoy(fpsCap) { testNapi.setOhosFrameRateCap(fpsCap); }', false, 'native');
check('延迟任务中的Native交接被拒绝', mutate('accepted = testNapi.setOhosFrameRateCap(fpsCap)',
  'setTimeout(() => { accepted = testNapi.setOhosFrameRateCap(fpsCap); }, 0)'), false, 'deferred');
check('await后才交接Native被拒绝', mutate('accepted = testNapi.setOhosFrameRateCap(fpsCap)',
  'await barrier(); accepted = testNapi.setOhosFrameRateCap(fpsCap)'), false, 'deferred');
check('下一帧才交接Native被拒绝', mutate('accepted = testNapi.setOhosFrameRateCap(fpsCap)',
  'this.getUIContext().postFrameCallback(() => { accepted = testNapi.setOhosFrameRateCap(fpsCap); })'), false, 'deferred');
check('Native早于持久化被拒绝', mutate('this.getPrefManager_().ohosFrameRateCap = fpsCap',
  'testNapi.setOhosFrameRateCap(fpsCap); this.getPrefManager_().ohosFrameRateCap = fpsCap'), false, 'ordering');
check('getter返回错误实例被拒绝', mutate('return this.prefManager_;', 'return new PreferenceManager(this.context);'), false, 'getter');
check('移除getter惰性缓存条件被拒绝', mutate('if (this.prefManager_ === null) this.prefManager_ = new PreferenceManager(this.context);',
  'this.prefManager_ = new PreferenceManager(this.context);'), false, 'getter');
console.log(`PASS OHOS settings contract negative controls: ${passed}/${passed}`);
