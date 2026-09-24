/**
 * download/hmac_sha256.cpp — SHA-256 / HMAC-SHA256（FIPS 180-4 / RFC 2104）
 */
#include "hmac_sha256.h"

#include <cstring>

namespace download {

namespace {

constexpr uint32_t K[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu, 0x59f111f1u,
    0x923f82a4u, 0xab1c5ed5u, 0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u, 0xe49b69c1u, 0xefbe4786u,
    0x0fc19dc6u, 0x240ca1ccu, 0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u,
    0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u, 0xa2bfe8a1u, 0xa81a664bu,
    0xc24b8b70u, 0xc76c51a3u, 0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au,
    0x5b9cca4fu, 0x682e6ff3u, 0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
};

inline uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

const char* kHex = "0123456789abcdef";

} // namespace

Sha256::Sha256() { reset(); }

void Sha256::reset() {
    h_[0] = 0x6a09e667u; h_[1] = 0xbb67ae85u; h_[2] = 0x3c6ef372u; h_[3] = 0xa54ff53au;
    h_[4] = 0x510e527fu; h_[5] = 0x9b05688cu; h_[6] = 0x1f83d9abu; h_[7] = 0x5be0cd19u;
    buffer_len_ = 0;
    total_bytes_ = 0;
    finalized_ = false;
    std::memset(digest_, 0, sizeof(digest_));
}

void Sha256::processBlock(const uint8_t* p) {
    uint32_t w[64];
    for (int i = 0; i < 16; ++i) {
        w[i] = (static_cast<uint32_t>(p[i * 4]) << 24) |
               (static_cast<uint32_t>(p[i * 4 + 1]) << 16) |
               (static_cast<uint32_t>(p[i * 4 + 2]) << 8) |
               static_cast<uint32_t>(p[i * 4 + 3]);
    }
    for (int i = 16; i < 64; ++i) {
        uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }

    uint32_t a = h_[0], b = h_[1], c = h_[2], d = h_[3];
    uint32_t e = h_[4], f = h_[5], g = h_[6], hh = h_[7];

    for (int i = 0; i < 64; ++i) {
        uint32_t S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        uint32_t ch = (e & f) ^ ((~e) & g);
        uint32_t t1 = hh + S1 + ch + K[i] + w[i];
        uint32_t S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = S0 + maj;
        hh = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }

    h_[0] += a; h_[1] += b; h_[2] += c; h_[3] += d;
    h_[4] += e; h_[5] += f; h_[6] += g; h_[7] += hh;
}

void Sha256::update(const void* data, size_t len) {
    if (finalized_ || data == nullptr || len == 0) return;
    const uint8_t* p = static_cast<const uint8_t*>(data);
    total_bytes_ += len;

    if (buffer_len_ > 0) {
        size_t need = 64 - buffer_len_;
        size_t take = len < need ? len : need;
        std::memcpy(buffer_ + buffer_len_, p, take);
        buffer_len_ += take;
        p += take;
        len -= take;
        if (buffer_len_ == 64) {
            processBlock(buffer_);
            buffer_len_ = 0;
        }
    }
    while (len >= 64) {
        processBlock(p);
        p += 64;
        len -= 64;
    }
    if (len > 0) {
        std::memcpy(buffer_, p, len);
        buffer_len_ = len;
    }
}

void Sha256::finalize(uint8_t out[kDigestSize]) {
    if (!finalized_) {
        const uint64_t bit_len = total_bytes_ * 8ull;
        // padding：0x80 后补 0，直到长度 ≡ 56 (mod 64)，最后 8 字节写 big-endian 位长
        uint8_t pad[128];
        size_t pad_len = 0;
        pad[pad_len++] = 0x80;
        size_t rem = (buffer_len_ + 1) % 64;
        size_t zeros = (rem <= 56) ? (56 - rem) : (120 - rem);
        std::memset(pad + pad_len, 0, zeros);
        pad_len += zeros;
        for (int i = 7; i >= 0; --i) {
            pad[pad_len++] = static_cast<uint8_t>((bit_len >> (i * 8)) & 0xff);
        }
        // 直接走 update 会被 finalized_ 拦住，这里手动喂
        const uint8_t* p = pad;
        size_t len = pad_len;
        if (buffer_len_ > 0) {
            size_t need = 64 - buffer_len_;
            size_t take = len < need ? len : need;
            std::memcpy(buffer_ + buffer_len_, p, take);
            buffer_len_ += take;
            p += take;
            len -= take;
            if (buffer_len_ == 64) {
                processBlock(buffer_);
                buffer_len_ = 0;
            }
        }
        while (len >= 64) {
            processBlock(p);
            p += 64;
            len -= 64;
        }
        for (int i = 0; i < 8; ++i) {
            digest_[i * 4]     = static_cast<uint8_t>((h_[i] >> 24) & 0xff);
            digest_[i * 4 + 1] = static_cast<uint8_t>((h_[i] >> 16) & 0xff);
            digest_[i * 4 + 2] = static_cast<uint8_t>((h_[i] >> 8) & 0xff);
            digest_[i * 4 + 3] = static_cast<uint8_t>(h_[i] & 0xff);
        }
        finalized_ = true;
    }
    std::memcpy(out, digest_, kDigestSize);
}

std::string Sha256::finalizeHex() {
    uint8_t d[kDigestSize];
    finalize(d);
    std::string s;
    s.reserve(kDigestSize * 2);
    for (size_t i = 0; i < kDigestSize; ++i) {
        s.push_back(kHex[(d[i] >> 4) & 0xf]);
        s.push_back(kHex[d[i] & 0xf]);
    }
    return s;
}

std::string hmacSha256Hex(const std::string& key, const std::string& message) {
    constexpr size_t kBlock = 64;
    uint8_t k[kBlock];
    std::memset(k, 0, kBlock);

    if (key.size() > kBlock) {
        Sha256 kh;
        kh.update(key.data(), key.size());
        uint8_t kd[Sha256::kDigestSize];
        kh.finalize(kd);
        std::memcpy(k, kd, Sha256::kDigestSize);
    } else if (!key.empty()) {
        std::memcpy(k, key.data(), key.size());
    }

    uint8_t ipad[kBlock];
    uint8_t opad[kBlock];
    for (size_t i = 0; i < kBlock; ++i) {
        ipad[i] = static_cast<uint8_t>(k[i] ^ 0x36);
        opad[i] = static_cast<uint8_t>(k[i] ^ 0x5c);
    }

    Sha256 inner;
    inner.update(ipad, kBlock);
    inner.update(message.data(), message.size());
    uint8_t id[Sha256::kDigestSize];
    inner.finalize(id);

    Sha256 outer;
    outer.update(opad, kBlock);
    outer.update(id, Sha256::kDigestSize);
    return outer.finalizeHex();
}

} // namespace download
