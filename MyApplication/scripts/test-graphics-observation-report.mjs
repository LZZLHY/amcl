// 对生产导出器的反例：生命周期隔离、配置错配、伪 GPU 时间、计数倒退、隐私白名单。
import assert from 'node:assert/strict';
import { observationReport, compareObservations, comparisonKeys } from './graphics-observation-report.mjs';
const sample = { schemaVersion: 1, pid: 50, profile: 'mobilegl', provider: 'GLFW', presentCount: 600,
  surfaceGeneration: 1, intervalSamples: 599, sampleWindow: 599, frameP50Us: 16000, frameP95Us: 18000,
  frameP99Us: 40000, long50ms: 1, long100ms: 0, long1000ms: 0, boundaryResets: 0,
  swapSamples: 600, segment: 1, swapFailures: 0, swapP95Us: 300, failureSequence: 0,
  failurePresentCount: 0, foreground: true, measurementScope: 'present-interval-and-swap-call',
  gpuTimeUs: null, cpuRenderTimeUs: null, uploadTimeUs: null, accessToken: 'must-never-export' };
const line = value => 'prefix graphics_frame_stats ' + JSON.stringify(value);
const config = Object.fromEntries(comparisonKeys.map(key => [key, 'same-fixture']));
config.hapSha256 = 'a'.repeat(64); config.translatorSha256 = 'b'.repeat(64); config.accessToken = 'must-never-export';
const report = observationReport('private chat\n' + line(sample), config);
assert.equal(report.segments.length, 1);
assert.equal(JSON.stringify(report).includes('must-never-export'), false);
assert.equal(compareObservations(report, report).deltasUs.frameP95Us, 0);
const change = structuredClone(report); change.configuration.renderDistance = 24;
assert.throws(() => compareObservations(report, change), /renderDistance/);
const absent = structuredClone(report); delete absent.configuration.modsSha256;
assert.throws(() => compareObservations(report, absent), /modsSha256/);
const second = { ...sample, presentCount: 900, segment: 2, intervalSamples: 100, sampleWindow: 100 };
const segmented = observationReport(line(sample) + '\n' + line(second), config);
assert.equal(segmented.segments.length, 2);
assert.throws(() => compareObservations(report, segmented), /one healthy/);
assert.equal(observationReport(line(sample) + '\n' + line(second), config, { fromLine: 2 }).segments.length, 1);
assert.throws(() => observationReport(line({ ...sample, gpuTimeUs: 0 }), config), /invalid/);
assert.throws(() => observationReport(line(sample) + '\n' + line({ ...sample, presentCount: 2 }), config), /non-monotonic/);
assert.throws(() => observationReport(line(sample), config, { pid: 10 }), /no matching/);
const disabled = observationReport(line({ ...sample, samplesEnabled: false, observerCostEnabled: false,
  droppedSamples: 2, sampledPresentCount: 598, observerCostSamples: 0, observerCostTotalNs: null, observerCostMaxNs: null }), config);
assert.equal(disabled.segments[0].last.droppedSamples, 2);
assert.throws(() => compareObservations(report, disabled), /disabled samples/);
console.log('graphics-observation-report PASS: exact configuration, lifecycle segments, metrics scope, identity and privacy');
