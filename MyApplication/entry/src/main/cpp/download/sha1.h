/**
 * download/sha1.h — 独立 SHA-1 实现
 *
 * 为什么不用 OpenSSL EVP？
 *   libcurl.so 里虽然静态内联了 OpenSSL 3.3.2 的 *符号*（EVP_sha1 等），
 *   但 OpenSSL 的 *头文件*（openssl/evp.h）没打包进 prebuilt，我们也不
 *   想让下载模块依赖一份大尺寸的 OpenSSL 头文件树。
 *
 * SHA-1 算法简单，自实现只需要 ~80 行。照 RFC 3174 参考实现改写。
 * 虽然安全领域 SHA-1 已被视为不安全（2017 SHAttered），但 MC 下载的
 * 校验用途仅仅是防传输损坏，不涉及对抗性攻击，继续用即可（Mojang 官方
 * version.json 里所有 hash 也都是 sha1）。
 */
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace download {

class Sha1 {
public:
    Sha1();

    /** 追加待哈希数据。finalize 之后调用会被忽略（避免误用） */
    void update(const void* data, size_t len);

    /**
     * 返回 40 字符 hex 小写。C-3 修复：
     *   - 首次调用：执行 padding + 最终 block 处理，结果缓存到 cached_hex_，置 finalized_=true
     *   - 二次及之后调用：直接返回缓存（之前的实现会越界写 buffer_[64]）
     *   - 需要复用 hasher 计算新数据：调 reset() 显式重置
     */
    std::string finalizeHex();

    /** 显式复位到初始状态，可重新 update + finalize */
    void reset();

    /** 是否已 finalize（finalize 之后 update 无效，必须 reset） */
    bool finalized() const { return finalized_; }

private:
    void processBlock();
    void init_();   // 由 ctor 和 reset() 共用

    uint32_t    h_[5];
    uint8_t     buffer_[64];
    size_t      buffer_len_;
    uint64_t    total_bytes_;
    bool        finalized_;
    std::string cached_hex_;   // finalizeHex 首次结果缓存
};

} // namespace download
