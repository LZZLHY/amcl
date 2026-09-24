/**
 * download_tests.h — 下载子系统测试模块的统一入口头
 *
 * 测试模式（沿用现有 cpp/tests/tests.h 风格）：
 *   - 每个测试函数 extern "C" 返回 const char*（结果文本，按行分隔）
 *   - 内部用静态 std::string g_xxx_results 累积
 *   - 通过 DevToolsPage NAPI 触发，结果展示在 UI
 *
 * 实施计划：docs/guides/download-system-implementation-plan.md
 *
 * 创建日期：2026-05-05（TDD 红阶段）
 */
#ifndef AMCL_DOWNLOAD_TESTS_H
#define AMCL_DOWNLOAD_TESTS_H

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Phase 4 — 增量 SHA1 测试
 *
 * 验证 Sha1 类的多次 update 与一次性 update 结果一致。
 * 不依赖文件系统，仅在内存里跑。
 */
const char* runSha1IncrementalTests();

/**
 * Phase 3 — engine.fetchToBuffer 文本下载测试
 *
 * @param caBundlePath  cacert.pem 路径（必填，否则 HTTPS 全失败）
 *
 * 依赖 httpbin.org / postman-echo 等公开服务，需真实网络。
 */
const char* runDownloadTextFetchTests(const char* caBundlePath);

/**
 * Phase 8 — NetSource 源评分测试（滑动窗口 RTT/throughput）
 *
 * 不依赖网络，纯内存逻辑。
 */
const char* runSourceScoringTests();

/**
 * Phase 7.4 — 引擎单元测试集合
 *
 * 包含 NetSource / NetFile / DownloadMeta 的纯内存单元测试。
 */
const char* runDownloadEngineUnitTests();

/**
 * Phase 7 — exception + NetSource 生命周期（recordFailure/recordSuccess）
 *
 * 纯内存单元测试：errorKindToString 全值、DownloadException::toString、
 * recordFailure 阈值翻转与去重、recordSuccess 清零 fail_count 但保留 is_failed。
 */
const char* runErrorAndSourceLifecycleTests();

#ifdef __cplusplus
}
#endif

#endif // AMCL_DOWNLOAD_TESTS_H
