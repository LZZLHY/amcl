#!/usr/bin/env node
/**
 * 执行 LayoutStore 的真实预设目录查询，守住列表渲染不能读取方案载荷的边界。
 *
 * AST 仅提取生产字段初值和生产方法，查询算法仍由原 ETS 正文执行。目录夹具只开放
 * isPreset/name；载荷成员、克隆、完整方案查询、存储及通知边界一经访问立即失败。
 * 本测试不加载完整 Store/平台服务，不读写用户方案，也不输出工程内中间文件。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import compiler from './lib/ets-compiler.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const relative = 'gamecontrol/src/main/ets/LayoutStore.ets';
const source = fs.readFileSync(path.join(root, relative), 'utf8');
const ast = compiler.createSourceFile(relative, source, compiler.ScriptTarget.Latest, true);
const owner = ast.statements.find(node => node.name?.getText(ast) === 'LayoutStore' && node.members);
assert.ok(owner, '真实 LayoutStore 类必须存在');

/** 按声明名取原文；缺失即失败，不能在生产方法改名后静默改测替身实现。 */
function member(name) {
  const declaration = owner.members.find(node => node.name?.getText(ast) === name);
  assert.ok(declaration, '真实 Store 声明缺失：' + name);
  return declaration.getText(ast);
}

const original = ['profiles', 'pendingReadSnapshot', 'getProfileNames', 'getPresetProfileNames'].map(member).join('\n');
const compiled = compiler.transpileModule('class Subject {\n' + original + '\n}\nmodule.exports=Subject;', {
  fileName: relative, reportDiagnostics: true,
  compilerOptions: { target: compiler.ScriptTarget.ES2020, module: compiler.ModuleKind.CommonJS },
});
assert.equal((compiled.diagnostics ?? []).filter(item => item.category === compiler.DiagnosticCategory.Error).length, 0,
  '提取后的生产声明必须可转译，不能靠语法失败掩盖断言');
const module = { exports: {} };

/** 模块级深拷贝也是禁止边界；若将来 getter 偷用 cloneLayout，必须立即报错。 */
const cloneLayout = () => { throw Error('目录查询不得调用 cloneLayout'); };
new Function('module', 'cloneLayout', compiled.outputText)(module, cloneLayout);
const Subject = module.exports;
let passed = 0;

/** 单条目录仅保留两个标量；任何载荷字段读取、对象枚举或写入都说明边界被突破。 */
function catalogEntry(name, isPreset, counters) {
  const data = Object.freeze({ name, isPreset });
  return new Proxy(data, {
    get(target, property) {
      if (property === 'isPreset') { counters.flags++; return target.isPreset; }
      if (property === 'name') { counters.names++; return target.name; }
      counters.payload++;
      throw Error('目录查询不得读取载荷字段：' + String(property));
    },
    ownKeys() { counters.payload++; throw Error('目录查询不得深拷贝或枚举完整方案'); },
    set() { counters.writes++; throw Error('目录元数据不得被查询修改'); },
    deleteProperty() { counters.writes++; throw Error('目录元数据不得被查询删除'); },
  });
}

/**
 * 只替代 Store 的外部边界和输入目录。待提交快照由调用方显式装配；生产 getter 自行
 * 决定读取哪份目录。方法通过只读 this 代理执行，任何 Store 写入或业务方法调用均失败。
 */
function fixture(live, pending = null) {
  const counters = { flags: 0, names: 0, payload: 0, writes: 0, services: 0 };
  const catalog = rows => Object.freeze(rows.map(([name, preset]) => catalogEntry(name, preset, counters)));
  const target = new Subject();
  target.profiles = catalog(live);
  target.pendingReadSnapshot = pending === null ? null : Object.freeze({ profiles: catalog(pending) });
  const view = new Proxy(target, {
    get(store, property, receiver) {
      if (['profiles', 'pendingReadSnapshot', 'getProfileNames', 'getPresetProfileNames'].includes(property)) {
        return Reflect.get(store, property, receiver);
      }
      counters.services++;
      throw Error('目录查询不得访问载荷/存储/通知服务：' + String(property));
    },
    set() { counters.writes++; throw Error('目录查询不得改变 Store 字段'); },
    deleteProperty() { counters.writes++; throw Error('目录查询不得删除 Store 字段'); },
  });
  return { target, view, counters };
}

/** 每组同时核对副作用计数；输出成功不能只靠返回数组恰好相同。 */
function check(name, test) {
  test();
  passed++;
  console.log('PASS ' + name);
}

check('普通目录按原顺序返回全部预设名称，未加载载荷保持不可读', () => {
  const test = fixture([['预设甲', true], ['用户甲', false], ['预设乙', true], ['用户乙', false]]);
  assert.deepEqual(test.view.getPresetProfileNames(), ['预设甲', '预设乙']);
  assert.deepEqual(test.counters, { flags: 4, names: 2, payload: 0, writes: 0, services: 0 });
});

check('mutation 公共读取优先返回上一笔快照，不触碰待提交目录', () => {
  const test = fixture([], [['原预设', true], ['原用户', false]]);
  Object.defineProperty(test.target, 'profiles', { get() { throw Error('不得读取未确认的 live 目录'); } });
  assert.deepEqual(test.view.getPresetProfileNames(), ['原预设']);
  assert.deepEqual(test.view.getProfileNames(), ['原预设', '原用户'], '与既有公共名称读取选择相同快照');
  assert.equal(test.counters.payload + test.counters.writes + test.counters.services, 0);
});

check('空事务快照仍有优先级，不能误回退到 live 目录', () => {
  const test = fixture([['待提交预设', true]], []);
  Object.defineProperty(test.target, 'profiles', { get() { throw Error('空快照也不得读取 live 目录'); } });
  assert.deepEqual(test.view.getPresetProfileNames(), []);
  assert.deepEqual(test.counters, { flags: 0, names: 0, payload: 0, writes: 0, services: 0 });
});

check('无预设或空目录返回独立空数组，不调用完整方案查询或通知', () => {
  for (const rows of [[], [['仅用户', false]]]) {
    const test = fixture(rows);
    const first = test.view.getPresetProfileNames();
    assert.deepEqual(first, []);
    assert.notEqual(first, test.view.getPresetProfileNames());
    assert.equal(test.counters.payload + test.counters.writes + test.counters.services, 0);
  }
});

check('调用方修改返回数组不污染 live 或 snapshot 目录，后续查询仍返回原值', () => {
  for (const pending of [null, [['快照预设', true], ['快照用户', false]]]) {
    const test = fixture([['live预设', true], ['live用户', false]], pending);
    const expected = pending === null ? ['live预设'] : ['快照预设'];
    const first = test.view.getPresetProfileNames();
    first[0] = '外部改名'; first.push('外部新增'); first.splice(0, 1);
    const second = test.view.getPresetProfileNames();
    assert.deepEqual(second, expected);
    assert.notEqual(first, second);
    assert.equal(second.every(value => typeof value === 'string'), true);
    assert.equal(test.counters.payload + test.counters.writes + test.counters.services, 0);
  }
});

check('快照解除后读取已确认 live 目录，不缓存旧预设标记', () => {
  const test = fixture([['新预设', true]], [['旧预设', true]]);
  assert.deepEqual(test.view.getPresetProfileNames(), ['旧预设']);
  test.target.pendingReadSnapshot = null;
  assert.deepEqual(test.view.getPresetProfileNames(), ['新预设']);
  assert.equal(test.counters.payload + test.counters.writes + test.counters.services, 0);
});

console.log('PASS ' + passed + ' production LayoutStore metadata groups; no payload IO, clone, write, notification or device/build operation');
