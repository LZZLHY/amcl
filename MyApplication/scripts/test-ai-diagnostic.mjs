// 1.8.x LogShare 结构化诊断块回归：只接受明确的公开正文 fenced JSON，失败回退 Markdown。
import assert from 'node:assert/strict';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

const mocks = {};
const fixture = evidenceRuntime({ imports: mocks });
try {
  const parser = fixture.load('entry/src/main/ets/components/AiDiagnostic.ets');
  const result = parser.parseAiStructuredDiagnosis([
    '# 分析',
    '',
    '```json',
    JSON.stringify({
      rootCause: '渲染器初始化失败',
      confidence: 0.87,
      steps: ['检查 Vulkan 准入', '保留原始崩溃报告'],
      evidence: ['launcher/amcl.log:42 · VK_ERROR_INITIALIZATION_FAILED'],
      caveats: ['第三方模型建议，需结合设备日志核对'],
    }),
    '```',
  ].join('\n'));
  assert.equal(result.rootCause, '渲染器初始化失败');
  assert.equal(result.confidence, '0.87');
  assert.deepEqual(result.troubleshooting, ['检查 Vulkan 准入', '保留原始崩溃报告']);
  assert.deepEqual(result.evidence, ['launcher/amcl.log:42 · VK_ERROR_INITIALIZATION_FAILED']);
  assert.deepEqual(result.caveats, ['第三方模型建议，需结合设备日志核对']);

  assert.equal(parser.parseAiStructuredDiagnosis('```json\n{"tool":"read_log_file"}\n```'), undefined,
    '工具回执不能伪装成诊断卡片');
  assert.equal(parser.parseAiStructuredDiagnosis('```json\n{"rootCause":"截断'), undefined,
    '半截 JSON 必须回退 Markdown');
  assert.equal(parser.parseAiStructuredDiagnosis('```text\n{"rootCause":"普通代码块"}\n```'), undefined,
    '非 JSON fenced block 不应被提取');
  assert.equal(parser.parseAiStructuredDiagnosis('```\n{"rootCause":"无语言代码块"}\n```'), undefined,
    '无语言 fenced block 不应被升级为诊断');
  assert.equal(parser.parseAiStructuredDiagnosis([
    '```',
    '普通代码块',
    '```json',
    '{"rootCause":"不应从无语言代码块内部提取"}',
    '```',
    '```',
  ].join('\n')), undefined, '无语言围栏内部的 json 不能越级配对');
  assert.equal(parser.parseAiStructuredDiagnosis('```json\n{"rootCause":true}\n```'), undefined,
    'rootCause 必须是服务端约定的非空字符串');
  assert.equal(parser.parseAiStructuredDiagnosis('```json\n{"rootCause":123}\n```'), undefined,
    '数字 rootCause 不能伪装为诊断文本');
  assert.equal(parser.parseAiStructuredDiagnosis('```json\n{"cause":"别名"}\n```'), undefined,
    '非官方 cause 别名不能伪造根因字段');
  assert.equal(parser.parseAiStructuredDiagnosis('```json\n{"rootCause":"x","confidence":"0.8"}\n```'), undefined,
    'confidence 必须是 0 到 1 的数字');
  assert.equal(parser.parseAiStructuredDiagnosis('```json\n{"rootCause":"x","confidence":1.1}\n```'), undefined,
    'confidence 不得超出 0 到 1');
  assert.equal(parser.parseAiStructuredDiagnosis([
    '```text',
    '```json',
    '{"rootCause":"不应从普通代码块内部提取"}',
    '```',
    '```',
  ].join('\n')), undefined, '非 JSON 围栏必须成对跳过');
  assert.equal(parser.parseAiStructuredDiagnosis([
    '前置正文 '.repeat(100000),
    '```json',
    '{"rootCause":"位于旧前缀限制之后","steps":[],"evidence":[]}',
    '```',
  ].join('\n')).rootCause, '位于旧前缀限制之后', '不能只扫描正文前 256 KiB');
  assert.equal(parser.parseAiStructuredDiagnosis([
    '```json',
    JSON.stringify({ rootCause: '过多步骤', steps: ['1', '2', '3', '4', '5', '6', '7', '8', '9'] }),
    '```',
  ].join('\n')), undefined, '超出数组上限时拒绝而不是静默截断');
  assert.equal(parser.parseAiStructuredDiagnosis(''), undefined);
  console.log('PASS official structured diagnosis shape, strict fences, full-document scan and Markdown fallback');
} finally {
  fixture.close();
}
