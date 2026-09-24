/**
 * download/hmac_sha256.h — 独立 SHA-256 / HMAC-SHA256 实现
 *
 * 为什么自己实现（与 sha1.h 同一理由）：
 *   libcurl.so 里静态内联了 OpenSSL 的符号，但 **头文件没打包进 prebuilt**，
 *   我们也不想让下载模块依赖一整棵 OpenSSL 头文件树。SHA-256 照 FIPS 180-4
 *   写下来约 120 行，HMAC 再 30 行，代价远小于引入依赖。
 *
 * 用途：AMCL 加速网关的**请求持有证明**。
 *   网关要求每个下载请求都带
 *     X-AMCL-Sig = HMAC_SHA256_HEX(sessionKey, "v1\n<METHOD>\n<PATH>\n<TS>\n<NONCE>")
 *   而分段下载里每个段都是独立 HTTP 请求（各自 nonce），签名只能在真正发请求的
 *   这一层（net_thread）计算，没法由 ArkTS 预先算好。
 */
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace download {

class Sha256 {
public:
    static constexpr size_t kDigestSize = 32;

    Sha256();
    void update(const void* data, size_t len);
    /** 写出 32 字节裸摘要；重复调用返回同一结果 */
    void finalize(uint8_t out[kDigestSize]);
    /** 64 字符小写 hex */
    std::string finalizeHex();
    void reset();

private:
    void processBlock(const uint8_t* p);

    uint32_t h_[8];
    uint8_t  buffer_[64];
    size_t   buffer_len_;
    uint64_t total_bytes_;
    bool     finalized_;
    uint8_t  digest_[kDigestSize];
};

/** HMAC-SHA256，返回 64 字符小写 hex */
std::string hmacSha256Hex(const std::string& key, const std::string& message);

} // namespace download
