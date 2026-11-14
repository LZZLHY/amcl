#pragma once
// 文件堆只改变Java堆的背书方式，不选择容量/GC，也不承诺能绕过系统内存回收。
// 解析和空间判据无副作用，供真实启动与宿主边界测试共用。
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

namespace amcl::jvm {
struct HeapBackingRequest {
    bool enabled = false;
    bool privateDirectory = false;
    std::string explicitDirectory;
};
inline bool IsHeapFileMarker(const std::string& option) { return option == "-Damcl.heapfile=1"; }
inline bool IsHeapFileLocation(const std::string& option) {
    return option.compare(0, sizeof("-XX:AllocateHeapAt=")-1, "-XX:AllocateHeapAt=") == 0;
}

/**
 * 显式文件堆采用严格VM选项合同。已核源码的17/21/25允许尝试，最终仍须核实际VM值
 * 和文件映射；major/目录名不是能力正证。8/未知包预先拒绝，不让忽略未知选项变成RAM。
 * 隐式环境或选项文件可能在JNI数组之后覆盖Xmx/目录/严格模式，本阶段不展开这些输入，
 * 明确拒绝而非清空用户环境。普通RAM启动不受这项附加限制。
 */
inline bool ResolveHeapBackingRequest(const std::vector<std::string>& options, int releaseMajor,
                                     bool classicLayout, const char* javaToolOptions,
                                     const char* javaOptions, const char* aotOptions,
                                     HeapBackingRequest& output, std::string& error) {
    HeapBackingRequest request;
    bool sawPath = false;
    error.clear();
    const auto fail = [&](const char* reason) { error=reason; return false; };
    for (const auto& option : options) {
        if (IsHeapFileMarker(option)) { request.enabled=true; request.privateDirectory=true; }
        if (IsHeapFileLocation(option)) {
            if (sawPath) return fail("heapfile_duplicate_directory");
            sawPath=true; request.enabled=true;
            request.explicitDirectory=option.substr(sizeof("-XX:AllocateHeapAt=")-1);
        }
    }
    if (!request.enabled) { output=request; return true; }
    if (classicLayout || (releaseMajor!=17 && releaseMajor!=21 && releaseMajor!=25))
        return fail("heapfile_runtime_family_unverified");
    if (request.privateDirectory && sawPath) return fail("heapfile_marker_directory_conflict");
    if (sawPath && (request.explicitDirectory.empty() || request.explicitDirectory[0]!='/' ||
                   request.explicitDirectory.find('\0')!=std::string::npos))
        return fail("heapfile_directory_invalid");
    if ((javaToolOptions && *javaToolOptions) || (javaOptions && *javaOptions) || (aotOptions && *aotOptions))
        return fail("heapfile_implicit_options_rejected");
    for (const auto& option : options) {
        if (option=="-XX:+IgnoreUnrecognizedVMOptions") return fail("heapfile_requires_strict_options");
        if (option.compare(0,10,"-XX:Flags=")==0 ||
            option.compare(0,sizeof("-XX:VMOptionsFile=")-1,"-XX:VMOptionsFile=")==0)
            return fail("heapfile_option_file_rejected");
    }
    output=request; return true;
}

// 最终Xmx之外留64MiB给VM对齐/映射前缀，再留1GiB分区余量。它是启动准入，
// 不是磁盘预留锁；真正fallocate/mmap仍可能失败，且失败不能在同进程重建RAM JVM。
constexpr uint64_t HeapFileAlignmentReserve = 64ull * 1024 * 1024;
constexpr uint64_t HeapFileDiskReserve = 1024ull * 1024 * 1024;
inline bool ValidateHeapFileSpace(uint64_t maximumBytes, bool freeKnown, uint64_t freeBytes,
                                  uint64_t& requiredBytes, std::string& error) {
    const uint64_t padding=HeapFileAlignmentReserve+HeapFileDiskReserve;
    if (!maximumBytes || maximumBytes>std::numeric_limits<uint64_t>::max()-padding) {
        error="heapfile_size_overflow"; return false;
    }
    requiredBytes=maximumBytes+padding;
    if (!freeKnown) { error="heapfile_disk_unknown"; return false; }
    if (freeBytes<requiredBytes) { error="heapfile_disk_insufficient"; return false; }
    error.clear(); return true;
}
}
