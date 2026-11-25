#!/usr/bin/env node
/**
 * 帧率设置静态接线门的承重负控。先运行真实仓库门禁，再对生产Index原字节做最小撤回，
 * 证明状态、持久化、getter身份与立即Native交接任何一环缺失都会红；不改应用文件。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { analyzeFrameCapSettings } from './check-ohos-runtime-optimizations.mjs';

const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8').replaceAll('\r\n','\n');
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
const prefix = "return this.saveLauncherChange_({'ohosFrameRateCap':fpsCap}, (): void => {";
const state = 'this.ohosFrameRateCap=this.getPrefManager_().ohosFrameRateCap;';
const native = 'testNapi.setOhosFrameRateCap(this.ohosFrameRateCap)';
const persist = 'await this.getPrefManager_().saveLauncherFields(values,active);';
check('字段空白及官方键的引号风格不影响判据', mutate(prefix, 'return this.saveLauncherChange_( { "ohosFrameRateCap" : fpsCap }, ( ) : void => {'), true);
check('惰性缓存条件加花括号仍是同一协议', mutate('if (this.prefManager_ === null) this.prefManager_ = new PreferenceManager(this.context);',
  'if (this.prefManager_ === null) { this.prefManager_ = new PreferenceManager(this.context); }'), true);
check('删除设置状态绑定被拒绝', mutate('ohosFrameRateCap: this.ohosFrameRateCap,', 'ohosFrameRateCap: 0,'), false, 'state binding');
check('删除状态更新被拒绝', mutate(state, ''), false, 'state update');
check('读取其它设置不能作为调度档位回执', mutate(state, state.replace('().ohosFrameRateCap', '().ohosFixedRefreshRate')), false, 'state update');
check('固定刷新率字段不能窃取调度档位', mutate(prefix, prefix.replace("'ohosFrameRateCap'", "'ohosFixedRefreshRate'")), false, 'persistent');
check('不同持久值不能冒充用户选择', mutate(prefix, prefix.replace(':fpsCap', ':0')), false, 'persistent');
check('丢弃调用方保存Promise被拒绝', mutate(prefix, prefix.replace('return ', '')), false, 'persistent');
check('注释伪造持久化被拒绝', mutate(persist, '/* ' + persist + ' */'), false, 'durable');
check('持久事务不得缺少await', mutate(persist, persist.replace('await ', '')), false, 'durable');
check('提交失败不能报告成功', mutate("this.safeToast_('设置保存失败，请重试');\n      return false;", "this.safeToast_('设置保存失败，请重试');\n      return true;"), false, 'durable');
check('不能先发布后保存', mutate(persist+'\n      publish();', 'publish();\n      '+persist), false, 'durable');
check('删除Native交接被拒绝', mutate(native, 'false'), false, 'native');
check('错误Native参数被拒绝', mutate(native, 'testNapi.setOhosFrameRateCap(0)'), false, 'native');
check('错误Native接收者被拒绝', mutate(native, native.replace('testNapi.', 'other.')), false, 'native');
check('字符串不能伪造Native交接', mutate(native, JSON.stringify(native)), false, 'native');
check('其他方法的Native调用不能补齐设置回调', mutate(native, 'false')+'\nfunction decoy() { '+native+'; }', false, 'native');
check('下一帧才交接Native被拒绝', mutate(native, 'this.getUIContext().postFrameCallback(() => { '+native+'; })'), false, 'deferred');
check('确认后又添加异步等待被拒绝', mutate(native, 'await barrier(); '+native), false, 'deferred');
check('Native早于状态回读被拒绝', mutate(state, native+'; '+state), false, 'ordering');
check('getter返回错误实例被拒绝', mutate('return this.prefManager_;', 'return new PreferenceManager(this.context);'), false, 'getter');
check('移除getter惰性缓存条件被拒绝', mutate('if (this.prefManager_ === null) this.prefManager_ = new PreferenceManager(this.context);',
  'this.prefManager_ = new PreferenceManager(this.context);'), false, 'getter');
console.log(`PASS OHOS settings contract negative controls: ${passed}/${passed}`);
