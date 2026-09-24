/**
 * sha1.cpp — RFC 3174 SHA-1 参考实现
 */
#include "sha1.h"

#include <cstring>

namespace download {

namespace {

inline uint32_t rotl(uint32_t x, int n) {
    return (x << n) | (x >> (32 - n));
}

} // namespace

Sha1::Sha1() {
    init_();
}

void Sha1::init_() {
    h_[0] = 0x67452301;
    h_[1] = 0xEFCDAB89;
    h_[2] = 0x98BADCFE;
    h_[3] = 0x10325476;
    h_[4] = 0xC3D2E1F0;
    buffer_len_ = 0;
    total_bytes_ = 0;
    finalized_ = false;
    cached_hex_.clear();
    std::memset(buffer_, 0, sizeof(buffer_));
}

void Sha1::reset() {
    init_();
}

void Sha1::processBlock() {
    uint32_t w[80];
    for (int i = 0; i < 16; ++i) {
        w[i] = (uint32_t(buffer_[i * 4]) << 24) |
               (uint32_t(buffer_[i * 4 + 1]) << 16) |
               (uint32_t(buffer_[i * 4 + 2]) << 8) |
               uint32_t(buffer_[i * 4 + 3]);
    }
    for (int i = 16; i < 80; ++i) {
        w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }

    uint32_t a = h_[0], b = h_[1], c = h_[2], d = h_[3], e = h_[4];
    for (int i = 0; i < 80; ++i) {
        uint32_t f, k;
        if (i < 20) {
            f = (b & c) | ((~b) & d);
            k = 0x5A827999;
        } else if (i < 40) {
            f = b ^ c ^ d;
            k = 0x6ED9EBA1;
        } else if (i < 60) {
            f = (b & c) | (b & d) | (c & d);
            k = 0x8F1BBCDC;
        } else {
            f = b ^ c ^ d;
            k = 0xCA62C1D6;
        }
        uint32_t t = rotl(a, 5) + f + e + k + w[i];
        e = d;
        d = c;
        c = rotl(b, 30);
        b = a;
        a = t;
    }

    h_[0] += a;
    h_[1] += b;
    h_[2] += c;
    h_[3] += d;
    h_[4] += e;
}

void Sha1::update(const void* data, size_t len) {
    // C-3 修复：finalize 之后再 update 是误用 — 忽略而不是腐蚀状态
    if (finalized_) return;
    const uint8_t* p = static_cast<const uint8_t*>(data);
    total_bytes_ += len;

    // 若 buffer 里有残留数据，先凑满 64 字节
    if (buffer_len_ > 0) {
        size_t need = 64 - buffer_len_;
        size_t take = (len < need) ? len : need;
        std::memcpy(buffer_ + buffer_len_, p, take);
        buffer_len_ += take;
        p += take;
        len -= take;
        if (buffer_len_ == 64) {
            processBlock();
            buffer_len_ = 0;
        }
    }

    // 整块处理
    while (len >= 64) {
        std::memcpy(buffer_, p, 64);
        processBlock();
        p += 64;
        len -= 64;
    }

    // 剩余
    if (len > 0) {
        std::memcpy(buffer_ + buffer_len_, p, len);
        buffer_len_ += len;
    }
}

std::string Sha1::finalizeHex() {
    // C-3 修复：finalize 改成幂等 — 首次执行 padding 并缓存结果，
    // 后续调用直接返回缓存。原实现重入会让 buffer_len_=64 后再 ++ 越界写。
    if (finalized_) return cached_hex_;

    // Padding: 0x80 followed by zeros, then 8-byte big-endian bit count
    uint64_t total_bits = total_bytes_ * 8;

    buffer_[buffer_len_++] = 0x80;
    if (buffer_len_ > 56) {
        // 不够放 8 字节长度，补零到 64 然后 process，再来一块
        while (buffer_len_ < 64) buffer_[buffer_len_++] = 0;
        processBlock();
        buffer_len_ = 0;
    }
    while (buffer_len_ < 56) buffer_[buffer_len_++] = 0;
    for (int i = 7; i >= 0; --i) {
        buffer_[buffer_len_++] = static_cast<uint8_t>((total_bits >> (i * 8)) & 0xff);
    }
    processBlock();

    static constexpr char kHex[] = "0123456789abcdef";
    std::string out;
    out.resize(40);
    for (int i = 0; i < 5; ++i) {
        uint32_t v = h_[i];
        for (int j = 0; j < 4; ++j) {
            uint8_t b = static_cast<uint8_t>((v >> ((3 - j) * 8)) & 0xff);
            out[i * 8 + j * 2]     = kHex[(b >> 4) & 0xf];
            out[i * 8 + j * 2 + 1] = kHex[b & 0xf];
        }
    }
    cached_hex_ = out;
    finalized_ = true;
    return out;
}

} // namespace download
