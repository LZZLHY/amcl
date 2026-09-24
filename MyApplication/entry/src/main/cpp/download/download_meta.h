/**
 * download/download_meta.h — 分段断点续传 meta 文件读写
 *
 * 每个正在下载的文件旁边都有一个 `<local_path>.download-meta` 文件，记录
 * 当前下载状态。进程重启后，Engine 先扫描这些 meta 文件来恢复任务。
 *
 * Schema（JSON v1）：见 docs/guides/download-system-redesign-v3.md §4
 * {
 *   "version": 1,
 *   "url_primary": "...",
 *   "url_sources": [...],
 *   "file_size": 45231104,
 *   "check": { "sha1": "abc...", "size": 45231104 },
 *   "created_at": "2026-04-19T21:00:00Z",
 *   "segments": [
 *     { "start": 0,        "end": 11534335, "done": 11534335 },
 *     { "start": 11534336, "end": 23068671, "done":  4194304 }
 *   ]
 * }
 *
 * 写入策略：唯一临时文件完整写入并 fsync/close，随后 rename 并 fsync 父目录。
 * 读取策略：JSON 解析失败 / 字段缺失 / 版本不匹配 → 返回 std::nullopt，
 *           调用方应该删除旧 meta 并从头开始下载。
 *
 * JSON 解析：项目里已经有 cJSON（在 MobileGlues 的 third_party 里），但
 *           为了 download/ 模块的独立性，这里自己实现一个最小解析器 —
 *           反正 schema 是固定的，不需要通用性。
 */
#pragma once

#include <cstdint>
#include <climits>
#include <optional>
#include <string>
#include <vector>

#include "file_checker.h"

namespace download {

/** 单个分段的元数据。done 相对 start 偏移（不是 end - start 的剩余） */
struct SegmentMeta {
    int64_t start = 0;
    int64_t end   = 0;   // inclusive
    int64_t done  = 0;   // 已下载字节数，0 ≤ done ≤ (end - start + 1)

    int64_t length() const {
        return (start < 0 || end < start || end == INT64_MAX) ? -1 : end - start + 1;
    }
    int64_t undone() const { const int64_t n = length(); return n < 0 ? -1 : n - done; }
    bool    isFinished() const { const int64_t n = length(); return n >= 0 && done == n; }
};

/** 整个文件的 meta 数据。存到磁盘时是一份 JSON */
struct DownloadMeta {
    static constexpr int kCurrentVersion = 1;

    int                          version = kCurrentVersion;
    std::string                  url_primary;
    std::vector<std::string>     url_sources;
    int64_t                      file_size = -1;   // -1/-2 = 未知（-2 为 HEAD 失败降级态）
    FileChecker                  check;
    std::string                  created_at;       // ISO 8601 UTC
    std::vector<SegmentMeta>     segments;

    bool isEmpty() const { return url_sources.empty() && segments.empty(); }
};

/**
 * 读 meta 文件。文件不存在 / JSON 损坏 / 版本不匹配 → nullopt。
 */
std::optional<DownloadMeta> readMetaFile(const std::string& meta_path);

/**
 * 原子写 meta 到磁盘：用 O_EXCL 创建唯一临时文件，完整写入并 fsync/close，
 * 随后 rename 到 meta_path 并 fsync 父目录。
 * 返回 true 成功。失败（磁盘满、权限问题等）返回 false 并在 hilog 里打 ERROR。
 */
bool writeMetaFile(const std::string& meta_path, const DownloadMeta& meta);

/**
 * 生成 ISO 8601 UTC 时间戳字符串（例如 "2026-04-19T21:00:00Z"）。
 * 用 std::time + gmtime_r，独立于 locale。
 */
std::string currentIso8601Utc();

/**
 * 判断已加载的 meta 和当前任务是否"兼容"：
 *   - version 必须匹配
 *   - url_sources 至少有交集（允许用户新增源）
 *   - expected_sha1 / expected_size 必须完全一致（变了说明不是同一个资源）
 *
 * 不兼容时 Engine 会废弃 meta + 删除本地 .part 从头开始。
 */
bool isMetaCompatible(const DownloadMeta& meta,
                      const std::vector<std::string>& current_urls,
                      const FileChecker& current_check);

} // namespace download
