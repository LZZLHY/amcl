/**
 * 执行生产 builder 的环境 setter、图形输入组装和真实 resolver，验证历史接线。
 * 仅构造纯数据，不加载 ArkUI、不启动 JVM、不改游戏偏好或生产代码。
 * 系统边界仅为纯数据，最终计划必须保留合法历史作用域；不冒充设备验证。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import compiler from './lib/ets-compiler.mjs';

const load = makePureEtsLoader();
const { GraphicsGameApi } = load('launch/src/main/ets/GraphicsProfileRegistry.ets');
const { resolveGraphicsPlan } = load('launch/src/main/ets/GraphicsBackendPlan.ets');
const source = fs.readFileSync(new URL('../launch/src/main/ets/LaunchProfileBuilder.ets', import.meta.url), 'utf8').replaceAll('\r\n', '\n');

// 只抽取当前生产正文，不复制字段传递算法。锚点缺失直接失败，防止审查样本默默过期。
const setterStart = source.indexOf('  setGraphicsEnvironment(');
const setterEnd = source.indexOf('\n  }', setterStart) + 4;
const inputStart = source.indexOf('    const graphicsInput: GraphicsPlanInput = {');
const inputEnd = source.indexOf('    const graphicsPlan: ResolvedGraphicsPlan =', inputStart);
assert.ok(setterStart >= 0 && setterEnd > setterStart && inputStart >= 0 && inputEnd > inputStart);
const harness = 'class Builder {\n' + source.slice(setterStart, setterEnd)
  + '\n assemble(gameFacts, lwjglVersion, needs322, usesSdl3) {\n'
  + source.slice(inputStart, inputEnd) + '\n return graphicsInput; }\n}\nreturn Builder;';
const emitted = compiler.transpileModule(harness, {
  compilerOptions: { target: compiler.ScriptTarget.ES2020 }
}).outputText;
const Builder = new Function('GraphicsGameApi', emitted)(GraphicsGameApi);

// 同一设备/版本/制品范围内，已有 MG 成功、MobileGL 连续首帧前失败的合法排序提示。
const scope = 'a'.repeat(64);
const input = {
  realMcVersion: '26.2', lwjglVersion: 3, needsLwjgl322Slot: false, usesSdl3: false,
  gameApi: 'OPENGL', userPreferredBackendId: 'auto', graphicsProfilePreference: 'auto',
  graphicsProfileExplicit: false, nativePreflightPending: true,
  deviceFacts: { platformFamily: 'MOBILE' }, availableProfileIds: ['mobilegl', 'mobileglues'],
  capabilityResults: [{ evidenceProfileId: 'mobilegl', requirementId: 'mobilegl-direct-vulkan-v1',
    windowProvider: 'GLFW', gameVersion: '26.2', loader: 'YES', instance: 'YES', windowSurface: 'YES',
    physicalDevice: 'YES', apiVersion: '1.3', deviceExtensions: 'YES', featureBits: 'YES',
    queuePresentation: 'YES', shaderToolchain: 'YES', nativeArtifacts: 'YES', lifecycleSmoke: 'NOT_RUN' }],
  graphicsHistoryScope: scope,
  graphicsHistory: [{ profile: 'mobileglues', scopeHash: scope, priority: 1, reason: 'verified-presentation' },
    { profile: 'mobilegl', scopeHash: scope, priority: -1, reason: 'repeated-startup-failure' }]
};
const builder = new Builder();
Object.assign(builder, { glRendererPref: 'auto', nativeGlAvailable: false, vulkanPolicy: 'ALLOW',
  capabilityResult: undefined, devRendererOverride: '' });
builder.setGraphicsEnvironment(input);
const reconstructed = builder.assemble(input, 3, false, false);
const direct = resolveGraphicsPlan(input).profile;
const throughBuilder = resolveGraphicsPlan(reconstructed).profile;
assert.equal(direct, 'mobileglues');
assert.equal(throughBuilder, 'mobileglues');
assert.equal(reconstructed.graphicsHistoryScope, scope);
assert.deepEqual(reconstructed.graphicsHistory, input.graphicsHistory);
// builder 保存每个记录的快照，调用方随后修改数组和对象不能改变本次启动的排序。
input.graphicsHistory[0].priority = -1;
input.graphicsHistory[1].priority = 1;
input.graphicsHistory.length = 0;
assert.equal(resolveGraphicsPlan(builder.assemble(input, 3, false, false)).profile, 'mobileglues');
// 复用 builder 时清空历史会回到静态优先级，不能借用上一局的成功证据。
builder.setGraphicsEnvironment({ ...input, graphicsHistoryScope: undefined, graphicsHistory: undefined });
assert.equal(resolveGraphicsPlan(builder.assemble(input, 3, false, false)).profile, 'mobilegl');
console.log('Graphics builder history handoff PASS: actual setter/input/resolver, immutable hint snapshot and empty reset');

// 页面给出的 API 策略必须穿过实际 setter/输入组装，避免 26.4 的游戏 OpenGL 偏好被丢弃。
builder.setGraphicsEnvironment({ ...input, vulkanPolicy: 'DISABLE_VULKAN' });
assert.equal(builder.assemble(input, 3, false, false).vulkanPolicy, 'DISABLE_VULKAN');
builder.setGraphicsEnvironment({ ...input, vulkanPolicy: 'ALLOW' });
assert.equal(builder.assemble(input, 3, false, false).vulkanPolicy, 'ALLOW');
console.log('Graphics builder API policy handoff PASS');
