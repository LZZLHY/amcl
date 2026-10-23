/**
 * 输入宿主描述符的单次映射快照。只负责读取和查询地址权限，不发现 owner、发布 ABI 或创建运行时。
 * 一个实例只属于一次 Resolve：首次查询打开 maps，读到匹配段立即停；后续查询复用已读段，
 * 尚未见到的地址才继续同一游标。读取行数不超过原逐次查询中最长一次，避免早段+长尾退化。
 * 不跨 Resolve 保留集合，也不合并相邻映射段；发布者仍必须保持函数表不可变并进程期 pin DSO。
 */
#ifndef AMCL_INPUT_MAPPED_RANGES_H
#define AMCL_INPUT_MAPPED_RANGES_H

#include <cstdint>
#include <cstdio>
#include <exception>
#include <vector>

namespace amcl::input::detail {

/** 一条内核映射的边界及权限；保留独立段，完整请求必须被同一段覆盖。 */
struct MappedRange {
    unsigned long long begin = 0u;
    unsigned long long end = 0u;
    bool readable = false;
    bool executable = false;
};

/**
 * 只解析旧生产检查用到的三个字段，路径/设备/inode 不参与地址权限判定。
 * 地址为空、越界和整数溢出的拒绝在 Contains 统一执行；反向/空映射不会覆盖任何请求。
 */
inline bool ParseMappedRange(const char* line, MappedRange* out) {
    if (!line || !out) return false;
    unsigned long long begin = 0u;
    unsigned long long end = 0u;
    char permissions[5]{};
    if (std::sscanf(line, "%llx-%llx %4s", &begin, &end, permissions) != 3 || begin >= end) return false;
    *out = {begin, end, permissions[0] == 'r', permissions[2] == 'x'};
    return true;
}

#ifdef AMCL_INPUT_DESCRIPTOR_MAPS_TESTING
// 仅宿主测试编译此边界：Windows 没有 Linux procfs，测试提供真实文本文件替代内核读源。
// 计数只在真正 fopen 前增加，反控可识别重复扫描；正式产品没有此路径、状态或新导出。
inline const char* mappedRangesTestPath = nullptr;
inline size_t mappedRangesTestReads = 0u;
inline size_t mappedRangesTestLines = 0u;
inline size_t mappedRangesTestCloses = 0u;
#endif

/**
 * 本轮集合的读生命周期：失败也只尝试一次，读取错误/OOM 使本轮失效并关闭自有句柄。
 * 后续 Resolve 新建实例重新尝试，不能把本轮缺失或失败永久记为不可用。
 */
class MappedRangeSnapshot final {
public:
    MappedRangeSnapshot() = default;
    ~MappedRangeSnapshot() { CloseOwnedStream(); }
    MappedRangeSnapshot(const MappedRangeSnapshot&) = delete;
    MappedRangeSnapshot& operator=(const MappedRangeSnapshot&) = delete;

    bool LoadFile(const char* path) {
        if (attempted_) return ready_;
        attempted_ = true;
#ifdef AMCL_INPUT_DESCRIPTOR_MAPS_TESTING
        if (mappedRangesTestPath) path = mappedRangesTestPath;
        ++mappedRangesTestReads;
#endif
        if (!path) return false;
        stream_ = std::fopen(path, "r");
        ownsStream_ = stream_ != nullptr;
        ready_ = ownsStream_;
        return ready_;
    }

    /**
     * 绑定已打开的文本边界。默认借用句柄；显式移交时与 LoadFile 一样负责失败/EOF/析构回收。
     * 生产 Resolve 只用 LoadFile，宿主用本入口验证真实C读取错误与资源回收，不注入裁决结果。
     */
    bool LoadStream(FILE* stream, bool takeOwnership = false) {
        if (attempted_) return ready_;
        attempted_ = true;
        stream_ = stream;
        ownsStream_ = takeOwnership && stream != nullptr;
        ready_ = stream != nullptr;
        return ready_;
    }

    /** 保留原 Linux 谓词：非零且不溢出的完整区间在一条 r 或 r+x 映射内，绝不拼接相邻段。 */
    bool Contains(uintptr_t address, size_t size, bool executable) {
        if (!ready_ || address == 0u || size == 0u || address > UINTPTR_MAX - size) return false;
        if (stream_ && std::ferror(stream_)) { Invalidate(); return false; }
        for (const auto& range : ranges_) {
            if (Matches(range, address, size, executable)) return true;
        }
        // 已读段查不到才续扫；每行只消费一次，不能为了callback倒回文件起点。
        MappedRange range{};
        while (ReadNextRange(&range)) {
            if (Matches(range, address, size, executable)) return true;
        }
        return false;
    }

private:
    /** 独立段的旧资格谓词；不会因已读集合中存在相邻 r 段而扩大接受范围。 */
    static bool Matches(const MappedRange& range, uintptr_t address, size_t size, bool executable) {
        const uintptr_t limit = address + size;
        return address >= range.begin && limit <= range.end && range.readable && (!executable || range.executable);
    }

    /** 只推进一行；畸形行跳过，EOF保留已读段，读取/分配失败使整个本轮集合不可再用。 */
    bool ReadNextRange(MappedRange* out) {
        if (!stream_ || exhausted_ || !ready_) return false;
        *out = {};
        char line[2048]{};
        if (!std::fgets(line, sizeof(line), stream_)) {
            if (std::ferror(stream_)) Invalidate();
            else { exhausted_ = true; CloseOwnedStream(); }
            return false;
        }
#ifdef AMCL_INPUT_DESCRIPTOR_MAPS_TESTING
        ++mappedRangesTestLines;
#endif
        try {
            if (ParseMappedRange(line, out)) ranges_.push_back(*out);
            return true;
        } catch (const std::exception&) {
            Invalidate();
            return false;
        }
    }

    /** 自有读取句柄在EOF、失败及析构时回收；借用流仍由测试/调用者关闭。 */
    void CloseOwnedStream() {
        if (stream_ && ownsStream_) {
#ifdef AMCL_INPUT_DESCRIPTOR_MAPS_TESTING
            ++mappedRangesTestCloses;
#endif
            (void)std::fclose(stream_);
            stream_ = nullptr;
        }
    }

    /** 失败清空已读权限证明，不能在后续callback查到旧范围后继续接受本次描述符。 */
    void Invalidate() {
        ready_ = false;
        ranges_.clear();
        CloseOwnedStream();
    }

    bool attempted_ = false;
    bool ready_ = false;
    bool exhausted_ = false;
    bool ownsStream_ = false;
    FILE* stream_ = nullptr;
    std::vector<MappedRange> ranges_;
};

}  // namespace amcl::input::detail
#endif
