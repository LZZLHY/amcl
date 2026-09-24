import assert from 'node:assert/strict';
import { productBenchmarkIssues, productVersionScript } from './check-mg-build-contract.mjs';
const names = new Set(['mg_multidraw_bench_progress', 'mg_multidraw_bench_run', 'glfwAMCLMobileGluesBenchmarkRunV1']);
const rows = [{ file: '/source/bench/multidraw_bench.cpp' }];
assert.deepEqual(productBenchmarkIssues('default', rows, names), []);
assert.ok(productBenchmarkIssues('default', [], names).length);
assert.ok(productBenchmarkIssues('default', rows, new Set()).length);
for (const product of ['sideload', 'store', 'desktop']) {
  assert.deepEqual(productBenchmarkIssues(product, [], new Set()), []);
  assert.ok(productBenchmarkIssues(product, rows, new Set()).length);
  for (const name of names) assert.ok(productBenchmarkIssues(product, [], new Set([name])).length);
}
const script = 'LIB {\n mg_initialize_v1;\n mg_multidraw_bench_run;\n mg_multidraw_bench_progress;\n gl[A-Z]*;\n};\n';
assert.equal(productVersionScript(script, 'default'), script);
assert.equal(productVersionScript(script, 'sideload'), 'LIB {\n mg_initialize_v1;\n gl[A-Z]*;\n};\n');
assert.equal(productVersionScript(script.replaceAll('\n', '\r\n'), 'store').replaceAll('\r\n', '\n'), productVersionScript(script, 'store'));
console.log('product benchmark contract: compile/ABI inclusion and exact export projection PASS');
