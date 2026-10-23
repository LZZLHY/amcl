#pragma once

// 仅供TestHooks诊断包装及独立宿主I/O控制使用。这里没有图形API、provider初始化
// 或准入逻辑；它只把已加载符号的真实文件所有者变成可由宿主独立比对的证据。
#include <array>
#include <cstdint>
#include <cstdlib>
#include <dlfcn.h>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>

namespace amcl::test_evidence {

// realpath失败必须拒绝身份，不能用字面相同路径或依赖库借出的同名符号替代。
inline std::string CanonicalImagePath(const std::string& path) {
    char* resolved = ::realpath(path.c_str(), nullptr);
    if (!resolved) throw std::runtime_error("actual image path cannot be canonicalized");
    std::string result(resolved);
    std::free(resolved);
    return result;
}

// 额外NOLOAD引用的唯一owner。显式Retire检查关闭状态；异常路径析构兜底。
// 它只释放自身引用，生产capability driver持有的静态引用不由测试接管。
class NoLoadReference {
public:
    explicit NoLoadReference(const std::string& path)
        : handle_(dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD)) {
        if (!handle_) throw std::runtime_error("requested provider is not already loaded");
    }
    NoLoadReference(const NoLoadReference&) = delete;
    NoLoadReference& operator=(const NoLoadReference&) = delete;
    ~NoLoadReference() { if (handle_) dlclose(handle_); }
    void* Symbol(const char* name) const { return dlsym(handle_, name); }
    void Retire() {
        void* retained = handle_;
        handle_ = nullptr;
        if (retained && dlclose(retained) != 0) throw std::runtime_error("NOLOAD reference close failed");
    }
private:
    void* handle_ = nullptr;
};

// dlsym(handle)允许查询依赖符号，所以还需独立dladdr+realpath核对请求DSO。
// 报告的是符号实际文件所有者；不能把facade本身的SHA当作实际driver的身份。
inline Dl_info VerifyImageOwner(const NoLoadReference& reference,
                               const std::string& requestedPath, const char* anchor) {
    void* address = reference.Symbol(anchor);
    Dl_info owner{};
    if (!address || !dladdr(address, &owner) || !owner.dli_fbase || !owner.dli_fname)
        throw std::runtime_error("actual provider symbol owner unavailable");
    if (CanonicalImagePath(owner.dli_fname) != CanonicalImagePath(requestedPath))
        throw std::runtime_error("provider symbol belongs to a dependency instead of requested image");
    return owner;
}

// 每个read/write/flush/close都有独立检查；EOF只在确认真实字节数后clear。
// 该文件副本代表dladdr对应的已安装映像文件，不声称摘要覆盖所有已映射内存字节。
inline std::uint64_t CopyImageChecked(const std::string& actualPath, const std::string& destination) {
    std::ifstream source(actualPath, std::ios::binary);
    if (!source.is_open()) throw std::runtime_error("cannot open actual loaded image");
    source.seekg(0, std::ios::end);
    const auto expected = source.tellg();
    if (!source || expected <= 0) throw std::runtime_error("actual image size invalid");
    source.seekg(0, std::ios::beg);
    if (!source) throw std::runtime_error("actual image rewind failed");
    std::ofstream target(destination, std::ios::binary | std::ios::trunc);
    if (!target.is_open()) throw std::runtime_error("cannot open unique loaded-image copy");
    std::array<char, 64 * 1024> buffer{};
    std::uint64_t copied = 0;
    for (;;) {
        source.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
        const auto bytes = source.gcount();
        if (bytes > 0) {
            target.write(buffer.data(), bytes);
            if (!target) throw std::runtime_error("loaded-image copy write failed");
            copied += static_cast<std::uint64_t>(bytes);
        }
        if (source.bad() || (source.fail() && !source.eof()))
            throw std::runtime_error("actual loaded image read failed");
        if (source.eof()) break;
    }
    if (copied != static_cast<std::uint64_t>(expected))
        throw std::runtime_error("actual loaded image byte count changed");
    source.clear();
    source.close();
    if (source.fail()) throw std::runtime_error("actual loaded image close failed");
    target.flush();
    if (!target) throw std::runtime_error("loaded-image copy flush failed");
    target.close();
    if (!target) throw std::runtime_error("loaded-image copy close failed");
    return copied;
}

// 外部RETURN只能晚于报告原字节成功关闭和完整回读；磁盘满、截断和close错误
// 不允许留下“报告里写过COMPLETE”就被宿主接受的单独资格证据。
// 已流式写出并fclose的报告只能纯读回；不得先trunc重写内存文本再检查，
// 否则第一份文件的丢失/截断会被“修复”成成功。失败也保持原文件供取证。
inline std::string ReadReportChecked(const std::string& path, const std::string& text) {
    std::ifstream input(path, std::ios::binary);
    if (!input.is_open()) throw std::runtime_error("cannot reopen qualification report");
    std::string actual;
    std::array<char, 64 * 1024> buffer{};
    for (;;) {
        input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
        actual.append(buffer.data(), static_cast<std::size_t>(input.gcount()));
        if (input.bad() || (input.fail() && !input.eof()))
            throw std::runtime_error("qualification report readback failed");
        if (input.eof()) break;
    }
    input.clear();
    input.close();
    if (input.fail() || actual != text) throw std::runtime_error("qualification report closed/readback bytes differ");
    return actual;
}

// 非流式报告的原一次写入封装：每个write/flush/close后调用同一纯读回检查。
inline std::string SaveReportChecked(const std::string& path, const std::string& text) {
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    if (!output.is_open()) throw std::runtime_error("cannot open unique qualification report");
    output.write(text.data(), static_cast<std::streamsize>(text.size()));
    if (!output) throw std::runtime_error("qualification report write failed");
    output.flush();
    if (!output) throw std::runtime_error("qualification report flush failed");
    output.close();
    if (!output) throw std::runtime_error("qualification report close failed");
    return ReadReportChecked(path, text);
}
}  // namespace amcl::test_evidence
