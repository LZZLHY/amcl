/**
 * download_meta.cpp — 分段断点 meta 文件的 JSON 读写
 *
 * 不引入 cJSON / rapidjson 依赖。schema 是固定的，手写一个最小 parser 就够了。
 * 支持：object / array / string / number（整数） / true / false。不支持嵌套
 * 转义、不支持浮点。
 *
 * 写入：简单字符串拼接，无缩进。
 * 读取：递归下降 parser，容错（任何异常都返回 nullopt）。
 *
 * 原子写：先写 path.tmp，fsync，再 rename 到 path。Linux rename 是原子的。
 */
#include "download_meta.h"

#include <hilog/log.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <cctype>
#include <cerrno>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fstream>
#include <sstream>
#include <unordered_set>

#include "../utils/amcl_log.h"

#undef LOG_TAG
#define LOG_TAG "DL_META"

namespace download {

// ============================================================================
// 工具
// ============================================================================

std::string currentIso8601Utc() {
    std::time_t t = std::time(nullptr);
    std::tm tm{};
#ifdef _WIN32
    gmtime_s(&tm, &t);
#else
    gmtime_r(&t, &tm);
#endif
    char buf[32];
    std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &tm);
    return buf;
}

namespace {

constexpr size_t kMaxMetaBytes = 1024 * 1024;
constexpr size_t kMaxSegments = 64;
constexpr size_t kMaxUrlSources = 64;
constexpr size_t kMaxUrlBytes = 8 * 1024;
constexpr size_t kMaxCreatedAtBytes = 128;
constexpr size_t kMaxSha1Bytes = 40;
std::atomic<uint64_t> g_meta_tmp_sequence{0};

bool isBoundedText(const std::string& value, size_t max_bytes, bool allow_empty) {
    if ((!allow_empty && value.empty()) || value.size() > max_bytes) return false;
    for (unsigned char c : value) {
        if (c == 0 || c < 0x20 || c == 0x7f) return false;
    }
    return true;
}

bool isValidChecker(const FileChecker& check) {
    if (check.expected_size < -1 || check.expected_size > kMaxDownloadFileBytes ||
        check.expected_sha1.size() > kMaxSha1Bytes) {
        return false;
    }
    if (check.expected_sha1.empty()) return true;
    if (check.expected_sha1.size() != kMaxSha1Bytes) return false;
    for (unsigned char c : check.expected_sha1) {
        if (!std::isxdigit(c)) return false;
    }
    return true;
}

bool writeAll(int fd, const char* data, size_t size) {
    while (size > 0) {
        ssize_t n = ::write(fd, data, size);
        if (n < 0) { if (errno == EINTR) continue; return false; }
        if (n == 0) { errno = EIO; return false; }
        data += n;
        size -= static_cast<size_t>(n);
    }
    return true;
}

bool fsyncParent(const std::string& path) {
    size_t slash = path.find_last_of('/');
    std::string parent = slash == std::string::npos ? "." : (slash == 0 ? "/" : path.substr(0, slash));
    int fd = ::open(parent.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return false;
    int rc;
    do { rc = ::fsync(fd); } while (rc != 0 && errno == EINTR);
    int saved = errno;
    if (::close(fd) != 0 && rc == 0) { saved = errno; rc = -1; }
    errno = saved;
    return rc == 0;
}

// ---------- JSON 写入（手拼） ----------

std::string jsonEscape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 2);
    out.push_back('"');
    for (char c : s) {
        switch (c) {
            case '"':  out.append("\\\""); break;
            case '\\': out.append("\\\\"); break;
            case '\n': out.append("\\n"); break;
            case '\r': out.append("\\r"); break;
            case '\t': out.append("\\t"); break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", (unsigned char)c);
                    out.append(buf);
                } else {
                    out.push_back(c);
                }
                break;
        }
    }
    out.push_back('"');
    return out;
}

std::string buildJson(const DownloadMeta& m) {
    std::ostringstream os;
    os << "{";
    os << "\"version\":" << m.version;
    os << ",\"url_primary\":" << jsonEscape(m.url_primary);
    os << ",\"url_sources\":[";
    for (size_t i = 0; i < m.url_sources.size(); ++i) {
        if (i) os << ",";
        os << jsonEscape(m.url_sources[i]);
    }
    os << "]";
    os << ",\"file_size\":" << m.file_size;
    os << ",\"check\":{";
    os << "\"sha1\":" << jsonEscape(m.check.expected_sha1);
    os << ",\"size\":" << m.check.expected_size;
    os << "}";
    os << ",\"created_at\":" << jsonEscape(m.created_at);
    os << ",\"segments\":[";
    for (size_t i = 0; i < m.segments.size(); ++i) {
        if (i) os << ",";
        const auto& seg = m.segments[i];
        os << "{\"start\":" << seg.start
           << ",\"end\":"   << seg.end
           << ",\"done\":"  << seg.done << "}";
    }
    os << "]";
    os << "}";
    return os.str();
}

// ---------- JSON 读取（手写 parser） ----------

class JsonParser {
public:
    explicit JsonParser(const std::string& s) : s_(s), p_(0) {}

    bool eof() const { return p_ >= s_.size(); }
    char peek() const { return p_ < s_.size() ? s_[p_] : '\0'; }

    void skipWs() {
        while (p_ < s_.size() && std::isspace(static_cast<unsigned char>(s_[p_]))) ++p_;
    }

    bool expect(char c) {
        skipWs();
        if (peek() != c) return false;
        ++p_;
        return true;
    }

    bool readString(std::string& out, size_t max_bytes = kMaxMetaBytes) {
        skipWs();
        if (peek() != '"') return false;
        ++p_;
        out.clear();
        auto append = [&](char c) {
            if (out.size() >= max_bytes) return false;
            out.push_back(c);
            return true;
        };
        while (p_ < s_.size()) {
            char c = s_[p_++];
            if (c == '"') return true;
            if (static_cast<unsigned char>(c) < 0x20) return false;
            if (c == '\\') {
                if (p_ >= s_.size()) return false;
                char n = s_[p_++];
                switch (n) {
                    case '"':  if (!append('"')) return false; break;
                    case '\\': if (!append('\\')) return false; break;
                    case '/':  if (!append('/')) return false; break;
                    case 'b':  if (!append('\b')) return false; break;
                    case 'f':  if (!append('\f')) return false; break;
                    case 'n':  if (!append('\n')) return false; break;
                    case 'r':  if (!append('\r')) return false; break;
                    case 't':  if (!append('\t')) return false; break;
                    case 'u': {
                        if (p_ + 4 > s_.size()) return false;
                        for (size_t i = 0; i < 4; ++i) {
                            if (!std::isxdigit(static_cast<unsigned char>(s_[p_ + i]))) return false;
                        }
                        p_ += 4;
                        if (!append('?')) return false;
                        break;
                    }
                    default: return false;
                }
            } else if (!append(c)) {
                return false;
            }
        }
        return false;
    }

    bool readInt64(int64_t& out) {
        skipWs();
        size_t start = p_;
        if (peek() == '-') ++p_;
        while (p_ < s_.size() && std::isdigit(static_cast<unsigned char>(s_[p_]))) ++p_;
        if (p_ == start) return false;
        try {
            out = std::stoll(s_.substr(start, p_ - start));
        } catch (...) {
            return false;
        }
        return true;
    }

    /** 读到一个 object 的末尾 '}'（吃掉它）。用于跳过未知字段（未用，保留备用）。 */
    bool skipValue() {
        skipWs();
        char c = peek();
        if (c == '"') {
            std::string s;
            return readString(s);
        }
        if (c == '{' || c == '[') {
            char open = c, close = (c == '{') ? '}' : ']';
            ++p_;
            int depth = 1;
            while (p_ < s_.size() && depth > 0) {
                char x = s_[p_++];
                if (x == '"') {
                    // 跳过字符串，避免里面的 { 被误识别
                    while (p_ < s_.size() && s_[p_] != '"') {
                        if (s_[p_] == '\\' && p_ + 1 < s_.size()) ++p_;
                        ++p_;
                    }
                    if (p_ < s_.size()) ++p_;
                } else if (x == open) depth++;
                else if (x == close) depth--;
            }
            return depth == 0;
        }
        // number / true / false / null
        while (p_ < s_.size() &&
               !std::isspace(static_cast<unsigned char>(s_[p_])) &&
               s_[p_] != ',' && s_[p_] != '}' && s_[p_] != ']') {
            ++p_;
        }
        return true;
    }

private:
    const std::string& s_;
    size_t p_;
};

bool parseCheck(JsonParser& p, FileChecker& out) {
    if (!p.expect('{')) return false;
    bool saw_sha1 = false, saw_size = false;
    while (true) {
        p.skipWs();
        if (p.peek() == '}') { p.expect('}'); return saw_sha1 && saw_size; }
        std::string key;
        if (!p.readString(key, 64)) return false;
        if (!p.expect(':')) return false;
        if (key == "sha1") {
            if (saw_sha1 || !p.readString(out.expected_sha1, kMaxSha1Bytes)) return false;
            saw_sha1 = true;
        } else if (key == "size") {
            if (saw_size || !p.readInt64(out.expected_size)) return false;
            saw_size = true;
        } else {
            if (!p.skipValue()) return false;
        }
        if (!p.expect(',')) {
            return p.expect('}') && saw_sha1 && saw_size;
        }
    }
}

bool parseSegment(JsonParser& p, SegmentMeta& out) {
    if (!p.expect('{')) return false;
    bool saw_start = false, saw_end = false, saw_done = false;
    while (true) {
        p.skipWs();
        if (p.peek() == '}') {
            p.expect('}');
            return saw_start && saw_end && saw_done;
        }
        std::string key;
        if (!p.readString(key, 64) || !p.expect(':')) return false;
        int64_t val = 0;
        if (!p.readInt64(val)) return false;
        if (key == "start") {
            if (saw_start) return false;
            out.start = val; saw_start = true;
        } else if (key == "end") {
            if (saw_end) return false;
            out.end = val; saw_end = true;
        } else if (key == "done") {
            if (saw_done) return false;
            out.done = val; saw_done = true;
        }
        if (!p.expect(',')) return p.expect('}') && saw_start && saw_end && saw_done;
    }
}

bool parseStringArray(JsonParser& p, std::vector<std::string>& out) {
    if (!p.expect('[')) return false;
    while (true) {
        p.skipWs();
        if (p.peek() == ']') { p.expect(']'); return true; }
        if (out.size() >= kMaxUrlSources) return false;
        std::string s;
        if (!p.readString(s, kMaxUrlBytes) || !isBoundedText(s, kMaxUrlBytes, false)) {
            return false;
        }
        out.push_back(std::move(s));
        if (!p.expect(',')) {
            return p.expect(']');
        }
    }
}

bool parseSegments(JsonParser& p, std::vector<SegmentMeta>& out) {
    if (!p.expect('[')) return false;
    while (true) {
        p.skipWs();
        if (p.peek() == ']') { p.expect(']'); return true; }
        if (out.size() >= kMaxSegments) return false;
        SegmentMeta seg;
        if (!parseSegment(p, seg)) return false;
        out.push_back(seg);
        if (!p.expect(',')) return p.expect(']');
    }
}

bool validateMeta(const DownloadMeta& meta) {
    const bool unknown_size = meta.file_size == -1 || meta.file_size == -2;
    if (meta.version != DownloadMeta::kCurrentVersion ||
        !isBoundedText(meta.url_primary, kMaxUrlBytes, false) ||
        meta.url_sources.empty() || meta.url_sources.size() > kMaxUrlSources ||
        !isBoundedText(meta.created_at, kMaxCreatedAtBytes, false) ||
        meta.segments.empty() || meta.segments.size() > kMaxSegments ||
        (!unknown_size && (meta.file_size <= 0 || meta.file_size > kMaxDownloadFileBytes)) ||
        !isValidChecker(meta.check)) {
        return false;
    }
    for (const auto& url : meta.url_sources) {
        if (!isBoundedText(url, kMaxUrlBytes, false)) return false;
    }
    bool primary_found = false;
    for (const auto& url : meta.url_sources) {
        if (!isBoundedText(url, kMaxUrlBytes, false)) return false;
        if (url == meta.url_primary) primary_found = true;
    }
    if (!primary_found) return false;
    if (meta.check.expected_size >= 0 && !unknown_size &&
        meta.check.expected_size != meta.file_size) {
        return false;
    }

    // Unknown-length downloads are represented by one open-ended [0, EOF) segment.
    // Its checked progress is the only durable boundary; NetFile truncates staging to
    // exactly done before resuming so bytes beyond that boundary can never leak through.
    //
    // ⚠️ 2026-07-29 修复「下载卡在 81%~99%、进度条倒退」：
    //   open-ended 单段（end==-1）**不只出现在 unknown_size**。NetFile::initSegments 的
    //   `pieces == 1` 分支会在**已知 size** 下也建 [0,-1) 全量 GET 段，用于：
    //     · 所有源都不支持 Range（Gitee 就是：单连接全量 GET，无 Accept-Ranges）；
    //     · size < piece_min（小文件）；
    //     · onAllThreadsDone 的两条兜底 rebuildSingleSegment()（多段全失败后退化、
    //       以及 single_segment_fullget_tried_ 的「末路整文件 GET」）。
    //   这些情况 file_size 是已知正数，于是走下面的连续覆盖校验，而 end==-1 必然让
    //   `seg.end < seg.start` 成立 → validateMeta 返回 false → writeMetaFile 直接
    //   EINVAL 失败。engine 的 meta flush 每 ~2s 一次，连续 3 次失败就被
    //   LoaderDownload::reportMetaPersistenceResult 判定为 StorageIoError 并 reject 整个任务
    //   （实测日志：`StorageIoError: download meta persistence repeatedly failed`）。
    //   这解释了全部现象：
    //     · 卡死百分比不固定（81/87/95/99）——取决于 3 次 flush 窗口何时用完；
    //     · GitHub 多段路径也会中招——多段被 429 打挂后退化成单段全量 GET，立刻踩中；
    //     · 「进度条倒退」——多段(80MB)失败后 rebuild 单段从 0 重下，UI 百分比自然回退；
    //     · 取消重试仍卡同一处——.part/meta 被保留，重试后又走同一条退化路径。
    //   修法：按**段形状**判定，而不是按 size 是否已知。单个 [0,-1) 段永远合法；
    //   已知 size 时它表示"全量 GET 中，尚未收敛出精确区间"，done 仍是可信的续传边界。
    if (meta.segments.size() == 1) {
        const auto& only = meta.segments.front();
        if (only.start == 0 && only.end == -1) {
            const int64_t upper = unknown_size ? kMaxDownloadFileBytes : meta.file_size;
            return only.done >= 0 && only.done <= upper;
        }
    }
    // unknown_size 只允许上面那种 open-ended 单段形状；其余一律非法。
    if (unknown_size) return false;

    int64_t expected_start = 0;
    for (const auto& seg : meta.segments) {
        const int64_t len = seg.length();
        if (seg.start < 0 || seg.end < seg.start || seg.start != expected_start ||
            seg.end >= meta.file_size || len <= 0 || seg.done < 0 || seg.done > len) {
            return false;
        }
        expected_start = seg.end + 1;
    }
    return expected_start == meta.file_size;
}

} // namespace

// ============================================================================
// Public API
// ============================================================================

std::optional<DownloadMeta> readMetaFile(const std::string& meta_path) {
    struct stat before{};
    if (::lstat(meta_path.c_str(), &before) != 0 || !S_ISREG(before.st_mode) ||
        before.st_size <= 0 || static_cast<uint64_t>(before.st_size) > kMaxMetaBytes) {
        AMCL_LOG_W(LOG_TAG, "readMetaFile: invalid type/size: %{public}s", meta_path.c_str());
        return std::nullopt;
    }
    int flags = O_RDONLY | O_CLOEXEC | O_NONBLOCK;
#ifdef O_NOFOLLOW
    flags |= O_NOFOLLOW;
#endif
    int fd = ::open(meta_path.c_str(), flags);
    if (fd < 0) return std::nullopt;

    struct stat opened{};
    if (::fstat(fd, &opened) != 0 || !S_ISREG(opened.st_mode) ||
        opened.st_dev != before.st_dev || opened.st_ino != before.st_ino ||
        opened.st_size <= 0 || static_cast<uint64_t>(opened.st_size) > kMaxMetaBytes) {
        ::close(fd);
        AMCL_LOG_W(LOG_TAG, "readMetaFile: file changed or is unsafe: %{public}s", meta_path.c_str());
        return std::nullopt;
    }

    std::string content;
    content.reserve(static_cast<size_t>(opened.st_size));
    char buffer[16 * 1024];
    while (true) {
        ssize_t n = ::read(fd, buffer, sizeof(buffer));
        if (n > 0) {
            const size_t count = static_cast<size_t>(n);
            if (count > kMaxMetaBytes - content.size()) {
                ::close(fd);
                AMCL_LOG_W(LOG_TAG, "readMetaFile: exceeds 1 MiB: %{public}s", meta_path.c_str());
                return std::nullopt;
            }
            content.append(buffer, count);
            continue;
        }
        if (n == 0) break;
        if (errno == EINTR) continue;
        ::close(fd);
        return std::nullopt;
    }
    if (::close(fd) != 0 || content.empty()) return std::nullopt;

    JsonParser p(content);
    if (!p.expect('{')) return std::nullopt;
    DownloadMeta meta;
    bool saw_version = false, saw_primary = false, saw_sources = false;
    bool saw_file_size = false, saw_check = false, saw_created = false, saw_segments = false;
    while (true) {
        p.skipWs();
        if (p.peek() == '}') { p.expect('}'); break; }
        std::string key;
        if (!p.readString(key, 64) || !p.expect(':')) return std::nullopt;
        bool ok = true;
        if (key == "version") {
            int64_t v = 0; ok = !saw_version && p.readInt64(v) && v >= INT_MIN && v <= INT_MAX;
            meta.version = static_cast<int>(v); saw_version = true;
        } else if (key == "url_primary") {
            ok = !saw_primary && p.readString(meta.url_primary, kMaxUrlBytes); saw_primary = true;
        } else if (key == "url_sources") {
            ok = !saw_sources && parseStringArray(p, meta.url_sources); saw_sources = true;
        } else if (key == "file_size") {
            ok = !saw_file_size && p.readInt64(meta.file_size); saw_file_size = true;
        } else if (key == "check") {
            ok = !saw_check && parseCheck(p, meta.check); saw_check = true;
        } else if (key == "created_at") {
            ok = !saw_created && p.readString(meta.created_at, kMaxCreatedAtBytes); saw_created = true;
        } else if (key == "segments") {
            ok = !saw_segments && parseSegments(p, meta.segments); saw_segments = true;
        } else {
            ok = p.skipValue();
        }
        if (!ok) return std::nullopt;
        if (!p.expect(',')) {
            if (!p.expect('}')) return std::nullopt;
            break;
        }
    }
    p.skipWs();
    if (!p.eof() || !saw_version || !saw_primary || !saw_sources || !saw_file_size ||
        !saw_check || !saw_created || !saw_segments || !validateMeta(meta)) {
        AMCL_LOG_W(LOG_TAG, "readMetaFile: missing/invalid fields: %{public}s", meta_path.c_str());
        return std::nullopt;
    }
    return meta;
}

bool writeMetaFile(const std::string& meta_path, const DownloadMeta& meta) {
    if (!validateMeta(meta)) {
        errno = EINVAL;
        AMCL_LOG_E(LOG_TAG, "writeMetaFile: invalid meta: %{public}s", meta_path.c_str());
        return false;
    }
    const std::string data = buildJson(meta);
    if (data.size() > kMaxMetaBytes) {
        errno = EFBIG;
        AMCL_LOG_E(LOG_TAG, "writeMetaFile: serialized meta exceeds 1 MiB: %{public}s",
                     meta_path.c_str());
        return false;
    }

    std::string tmp;
    int fd = -1;
    for (int i = 0; i < 32 && fd < 0; ++i) {
        const uint64_t seq = g_meta_tmp_sequence.fetch_add(1, std::memory_order_relaxed);
        const auto now = static_cast<unsigned long long>(std::time(nullptr));
        tmp = meta_path + ".tmp." + std::to_string(static_cast<long long>(::getpid())) +
              "." + std::to_string(now) + "." +
              std::to_string(static_cast<unsigned long long>(seq));
        int flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC;
#ifdef O_NOFOLLOW
        flags |= O_NOFOLLOW;
#endif
        fd = ::open(tmp.c_str(), flags, 0600);
        if (fd < 0 && errno != EEXIST) break;
    }
    if (fd < 0) {
        AMCL_LOG_E(LOG_TAG, "writeMetaFile: create tmp failed: %{public}s errno=%{public}d",
                     meta_path.c_str(), errno);
        return false;
    }

    bool ok = writeAll(fd, data.data(), data.size());
    int failure_errno = ok ? 0 : errno;
    if (ok) {
        int rc;
        do { rc = ::fsync(fd); } while (rc != 0 && errno == EINTR);
        if (rc != 0) {
            ok = false;
            failure_errno = errno;
        }
    }
    if (::close(fd) != 0) {
        if (ok) failure_errno = errno;
        ok = false;
    }
    if (ok && ::rename(tmp.c_str(), meta_path.c_str()) != 0) {
        ok = false;
        failure_errno = errno;
    }
    if (ok && !fsyncParent(meta_path)) {
        ok = false;
        failure_errno = errno;
    }
    if (!ok) {
        ::unlink(tmp.c_str());
        errno = failure_errno == 0 ? EIO : failure_errno;
        AMCL_LOG_E(LOG_TAG, "writeMetaFile: atomic write failed: %{public}s errno=%{public}d",
                     meta_path.c_str(), errno);
    }
    return ok;
}

bool isMetaCompatible(const DownloadMeta& meta,
                      const std::vector<std::string>& current_urls,
                      const FileChecker& current_check) {
    if (!validateMeta(meta) || current_urls.empty() ||
        current_urls.size() > kMaxUrlSources || !isValidChecker(current_check)) {
        return false;
    }
    for (const auto& url : current_urls) {
        if (!isBoundedText(url, kMaxUrlBytes, false)) return false;
    }
    if (meta.check.expected_sha1 != current_check.expected_sha1 ||
        meta.check.expected_size != current_check.expected_size) return false;
    std::unordered_set<std::string> curr(current_urls.begin(), current_urls.end());
    for (const auto& old_url : meta.url_sources) {
        if (curr.count(old_url) > 0) return true;
    }
    return false;
}

} // namespace download
