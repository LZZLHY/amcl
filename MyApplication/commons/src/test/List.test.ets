/**
 * commons 本身没有需要在 Hypium 里执行的 UI 单测，但测试工程要求每个模块
 * 都提供一个可导入的 suite 入口。保留空 suite 比让生成的测试页引用不存在
 * 的 `src/test/List.test` 更诚实，也不会把 entry 的业务测试重复跑一遍。
 */
export default function testsuite(): void {
  // 公共纯函数测试由 scripts/test-*.mjs 和 entry suite 按职责执行。
}
