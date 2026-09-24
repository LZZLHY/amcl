/**
 * net_file.cpp — 单文件下载协调器（分段切片 + fd 管理 + 断点恢复 + 校验）
 *
 * 关键流程：
 *   start():
 *     1. 如果 local_path 已存在且 sha1 命中 → 跳过下载，Finished
 *     2. 检查 .download-meta 是否存在且兼容 → 恢复 threads_
 *     3. 否则：HEAD 请求拿 file_size → 切片 → 创建 NetThread 链表
 *     4. open local_path (O_WRONLY|O_CREAT) + ftruncate(file_size)
 *     5. 把 threads_ 送进 threads_pending_launch_，等 Engine 分发到 WorkerPool
 *
 *   reportThreadFinished():
 *     - 所有线程都结束 → onAllThreadsDone()
 *     - onAllThreadsDone 分支：
 *        * 任一 thread Failed → state=Failed
 *        * 所有 thread Finished → state=FinalCheck → sha1 校验 → Finished
 *
 * fd 管理：
 *   - 由 start() 打开，finalize() 关闭
 *   - 生命周期跨多个 NetThread，pwrite 是线程安全的（POSIX 保证）
 *   - abort() 不关 fd（可能还在写，先让线程 aborted 收敛）
 */
#include "net_file.h"

#include <curl/curl.h>
#include <fcntl.h>
#include <hilog/log.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <climits>
#include <chrono>      // M-7 修复：deleteLocalAndMeta 等 worker 收敛用
#include <cstdio>      // N-01 修复：renameat（原子替换提交）
#include <cstring>
#include <limits>      // 停滞段 ETA 用 std::numeric_limits<double>::max()
#include <thread>      // M-7 修复：std::this_thread::sleep_for
#include <unordered_map>  // 2026-08-04：allowedRoot 目录 fd 共享池

#include "config.h"
#include "download_meta.h"
#include "engine.h"
#include "http_range.h"
#include "loader_download.h"

#include "../utils/amcl_log.h"

#undef LOG_TAG
#define LOG_TAG "DL_FILE"

namespace download {

namespace {

/** 用 curl 做 HEAD 请求，取 Content-Length 和 Accept-Ranges */
enum class RangeCap { Unknown, Supported, Unsupported };

struct HeadResult {
    int64_t  size = -1;
    RangeCap range = RangeCap::Unknown;   // H-04：真实探测的 Range 能力，Unknown 时保守按支持处理
    long     http_code = 0;
};

/**
 * HEAD 响应头回调：解析 `Accept-Ranges`。
 *   - `Accept-Ranges: bytes` → 支持 Range
 *   - `Accept-Ranges: none`  → 明确不支持
 *   - 其它/缺失               → 保持 Unknown（由 0-0 探测兜底）
 */
size_t headHeaderCb(char* buffer, size_t size, size_t nitems, void* userdata) {
    const size_t total = size * nitems;
    auto* cap = static_cast<RangeCap*>(userdata);
    if (!cap) return total;
    // 归一化 header 名部分为小写后比较，值部分裁掉前后空白/CRLF。
    static const char kKey[] = "accept-ranges:";
    const size_t key_len = sizeof(kKey) - 1;
    if (total <= key_len) return total;
    for (size_t i = 0; i < key_len; ++i) {
        char c = buffer[i];
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
        if (c != kKey[i]) return total;
    }
    size_t vs = key_len;
    while (vs < total && (buffer[vs] == ' ' || buffer[vs] == '\t')) ++vs;
    size_t ve = total;
    while (ve > vs && (buffer[ve - 1] == '\r' || buffer[ve - 1] == '\n' ||
                       buffer[ve - 1] == ' ' || buffer[ve - 1] == '\t')) --ve;
    std::string value;
    value.reserve(ve - vs);
    for (size_t i = vs; i < ve; ++i) {
        char c = buffer[i];
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
        value.push_back(c);
    }
    if (value == "none") *cap = RangeCap::Unsupported;
    else if (value == "bytes") *cap = RangeCap::Supported;
    return total;
}

struct ProbeHeaders {
    ParsedContentRange content_range;
    bool content_range_seen = false;
    long response_code = 0;
    size_t body_bytes = 0;
};

size_t probeHeaderCb(char* buffer, size_t size, size_t nitems, void* userdata) {
    if (size != 0 && nitems > SIZE_MAX / size) return 0;
    const size_t total = size * nitems;
    auto* headers = static_cast<ProbeHeaders*>(userdata);
    if (!headers) return total;
    // Header callback receives the status line before this hop's headers/body. Reset all
    // per-hop evidence here so redirects can never lend Content-Range to the final response.
    if (total >= 12 && std::memcmp(buffer, "HTTP/", 5) == 0) {
        const char* space = static_cast<const char*>(std::memchr(buffer, ' ', total));
        if (space && static_cast<size_t>(buffer + total - space) >= 4 &&
            space[1] >= '0' && space[1] <= '9' &&
            space[2] >= '0' && space[2] <= '9' &&
            space[3] >= '0' && space[3] <= '9') {
            headers->response_code = (space[1] - '0') * 100 +
                                     (space[2] - '0') * 10 +
                                     (space[3] - '0');
        }
        headers->content_range = ParsedContentRange{};
        headers->content_range_seen = false;
        headers->body_bytes = 0;
        return total;
    }
    ParsedContentRange parsed;
    if (parseContentRangeHeader(buffer, total, parsed)) {
        headers->content_range = parsed;
        headers->content_range_seen = true;
    }
    return total;
}

/**
 * Range: bytes=0-0 探测最多接受一个字节。
 *
 * 支持 Range 的 206 正常只交付 1 byte；忽略 Range 的源会返回 200 + 完整对象，body
 * write callback 立即返回 0，让 curl 以 CURLE_WRITE_ERROR 停止，避免预检阶段把大文件
 * 完整下载后丢弃。调用方仍可根据 HTTP 200 将 capability 判为 Unsupported。
 */
size_t probeWriteCb(char*, size_t size, size_t nitems, void* userdata) {
    if (size != 0 && nitems > SIZE_MAX / size) return 0;
    const size_t total = size * nitems;
    auto* headers = static_cast<ProbeHeaders*>(userdata);
    if (!headers || total == 0) return total;
    // 200 means the server ignored Range. Abort before accepting any object bytes.
    if (headers->response_code == 200) return 0;
    // A valid 0-0 response must contain exactly one byte in total.
    if (headers->response_code == 206) {
        if (headers->body_bytes != 0 || total != 1) return 0;
        headers->body_bytes = 1;
        return 1;
    }
    // Redirect/error bodies are irrelevant but bounded, so a malicious hop cannot stream
    // unbounded data before the redirect loop examines CURLINFO_REDIRECT_URL.
    static constexpr size_t kMaxIgnoredBodyBytes = 4096;
    if (headers->body_bytes > kMaxIgnoredBodyBytes ||
        total > kMaxIgnoredBodyBytes - headers->body_bytes) return 0;
    headers->body_bytes += total;
    return total;
}

/**
 * 该 URL 是否属于「多线程不友好」的源 —— 即对多连接会限流、分段下载反而更慢的主机。
 *
 * 直接借鉴 PCL2 `ModNet.vb`（NetFile.TryBeginThread）的域名黑名单思路：
 *   pcl2-server / meloong.com / bmclapi / github.com / optifine.net / momot.rs
 * 命中即 `Return Nothing`（不追加线程），只用单线程下载。
 *
 * 我们在其基础上补全**全部 GitHub 代理镜像**：它们本质是 github.com 的转发层，
 * 限流特征一致（真机实测单次下载 327~887 条 429，且尾段被切碎后吞吐塌到 52KB/s）。
 * 注意匹配的是 URL 里的**首个 host**，代理 URL 形如
 * `https://gh.ddlc.top/https://github.com/...`，前缀主机才是实际连接目标。
 */
/** 从 URL 提取 host（用于 bad host 黑名单查询 / 多线程友好性判定） */
std::string extractHostFromUrl(const std::string& url) {
    size_t hs = url.find("://");
    if (hs == std::string::npos) return {};
    hs += 3;
    size_t he = url.find('/', hs);
    size_t pe = url.find(':', hs);
    if (pe != std::string::npos && (he == std::string::npos || pe < he)) he = pe;
    return url.substr(hs, he == std::string::npos ? std::string::npos : he - hs);
}

bool isMultiThreadUnfriendlyHost(const std::string& url) {
    // 匹配 URL 里的**首个** host（代理 URL 形如 https://gh.ddlc.top/https://github.com/...，
    // 前缀主机才是实际连接目标）。
    const std::string host = extractHostFromUrl(url);
    if (host.empty()) return false;

    static const char* kUnfriendly[] = {
        // PCL2 原始名单
        "github.com", "bmclapi", "optifine.net", "momot.rs",
        "pcl2-server", "meloong.com",
        // GitHub 代理镜像（本项目 MIRROR_TEMPLATES 全部成员及常见同类）
        "ghfast.top", "ghproxy.net", "ghproxy.com", "gh-proxy.com",
        "gh.ddlc.top", "moeyy.xyz", "ghps.cc", "hub.fastgit",
        "raw.githubusercontent.com", "objects.githubusercontent.com",
    };
    for (const char* k : kUnfriendly) {
        if (host.find(k) != std::string::npos) return true;
    }
    return false;
}

/**
 * 用 curl 做 HEAD 请求，取 Content-Length 和 Accept-Ranges。
 *
 * M-4 修复：
 *   1. 设 CURLOPT_SHARE（DNS / SSL session 复用），与 NetThread 走同一 share；
 *   2. 手动 follow 重定向（FOLLOWLOCATION=0），每跳前查 bad host 黑名单，
 *      命中立即返回失败，避免 30s 超时卡住整个文件初始化；
 *   3. 缩短 connect/total timeout（10s / 15s）— HEAD 只读 metadata，不该
 *      与下载等同的 30s。
 */
HeadResult doHead(const std::string& url) {
    HeadResult r;

    // 第一跳前查源 URL 本身的 host 是否在黑名单
    if (DownloadEngine::instance().isBadHost(extractHostFromUrl(url))) {
        AMCL_LOG_W(LOG_TAG, "doHead: source host is blacklisted, skip: %{public}s", url.c_str());
        return r;
    }

    CURL* easy = curl_easy_init();
    if (!easy) return r;

    std::string cur_url = url;
    const int kMaxRedir = 5;
    std::string final_url = url;   // 最终 2xx 的 URL，供 0-0 探测复用
    for (int redir = 0; redir <= kMaxRedir; ++redir) {
        curl_easy_reset(easy);
        curl_easy_setopt(easy, CURLOPT_URL, cur_url.c_str());
        curl_easy_setopt(easy, CURLOPT_NOBODY, 1L);
        curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 0L);   // 手动 follow
        curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
        // 2026-07-29：connect 10s→5s。HEAD 只读 metadata，不该比下载路径（6s）更宽松；
        // 死镜像能更快被淘汰，减少 no-expected-size 场景下的串行探测总耗时。
        curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT, 5L);
        curl_easy_setopt(easy, CURLOPT_TIMEOUT, 15L);
        curl_easy_setopt(easy, CURLOPT_FAILONERROR, 1L);
        curl_easy_setopt(easy, CURLOPT_USERAGENT, "amcl/0.1 (OHOS; libcurl/8.10.1)");
        // H-04：解析 Accept-Ranges 头，得到真实 Range 能力（而非硬编码 true）
        RangeCap header_cap = RangeCap::Unknown;
        curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, headHeaderCb);
        curl_easy_setopt(easy, CURLOPT_HEADERDATA, &header_cap);
        // M-4 修复：使用 Engine 的 curl_share 复用 DNS / SSL session
        CURLSH* sh = DownloadEngine::instance().curlShare();
        if (sh) curl_easy_setopt(easy, CURLOPT_SHARE, sh);
        // CA bundle（和 NetThread 走同一 path）
        std::string ca_path = getCaBundlePath();
        if (!ca_path.empty()) {
            curl_easy_setopt(easy, CURLOPT_CAINFO, ca_path.c_str());
        }

        CURLcode rc = curl_easy_perform(easy);
        curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &r.http_code);

        if (rc != CURLE_OK) {
            // 失败：不是 redirect，直接结束
            break;
        }

        // 成功路径：检查是否还要 follow
        if (r.http_code == 301 || r.http_code == 302 || r.http_code == 307 || r.http_code == 308) {
            if (redir == kMaxRedir) {
                AMCL_LOG_W(LOG_TAG, "doHead: too many redirects: %{public}s", url.c_str());
                r.http_code = 0;  // 视为失败
                break;
            }
            char* redir_url = nullptr;
            curl_easy_getinfo(easy, CURLINFO_REDIRECT_URL, &redir_url);
            if (!redir_url || redir_url[0] == '\0') break;
            std::string next(redir_url);
            // M-4 关键：每跳前查 bad host 黑名单
            std::string next_host = extractHostFromUrl(next);
            if (DownloadEngine::instance().isBadHost(next_host)) {
                AMCL_LOG_W(LOG_TAG, "doHead: redirect to bad host %{public}s, skip: %{public}s",
                            next_host.c_str(), next.c_str());
                r.http_code = 0;  // 视为失败
                break;
            }
            cur_url = next;
            continue;
        }

        // 2xx 正常返回
        final_url = cur_url;
        curl_off_t cl = -1;
        curl_easy_getinfo(easy, CURLINFO_CONTENT_LENGTH_DOWNLOAD_T, &cl);
        if (cl > 0) r.size = static_cast<int64_t>(cl);
        // H-04：以 Accept-Ranges 头为准；缺失/未知时用 Range: bytes=0-0 探测兜底。
        r.range = header_cap;
        break;
    }

    // HEAD 的 Accept-Ranges 只作为提示。分段能力必须由实际 0-0 请求的
    // 206 + 精确 Content-Range 证明，避免代理谎报或错误 206 被当作安全数据。
    if (r.size > 0 && r.http_code >= 200 && r.http_code < 300) {
        std::string probe_url = final_url;
        ProbeHeaders probe_headers;
        long probe_code = 0;
        bool probe_completed = false;
        for (int redir = 0; redir <= kMaxRedir; ++redir) {
            curl_easy_reset(easy);
            curl_easy_setopt(easy, CURLOPT_URL, probe_url.c_str());
            curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 0L);
            curl_easy_setopt(easy, CURLOPT_RANGE, "0-0");
            curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
            curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT, 10L);
            curl_easy_setopt(easy, CURLOPT_TIMEOUT, 15L);
            curl_easy_setopt(easy, CURLOPT_FAILONERROR, 0L);
            curl_easy_setopt(easy, CURLOPT_USERAGENT, "amcl/0.1 (OHOS; libcurl/8.10.1)");
            curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, probeWriteCb);
            curl_easy_setopt(easy, CURLOPT_WRITEDATA, &probe_headers);
            curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, probeHeaderCb);
            curl_easy_setopt(easy, CURLOPT_HEADERDATA, &probe_headers);
            CURLSH* sh = DownloadEngine::instance().curlShare();
            if (sh) curl_easy_setopt(easy, CURLOPT_SHARE, sh);
            std::string ca_path = getCaBundlePath();
            if (!ca_path.empty()) curl_easy_setopt(easy, CURLOPT_CAINFO, ca_path.c_str());

            CURLcode rc = curl_easy_perform(easy);
            curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &probe_code);
            const bool intentionally_stopped_unsupported_body =
                rc == CURLE_WRITE_ERROR && probe_code == 200;
            if (rc != CURLE_OK && !intentionally_stopped_unsupported_body) break;
            if (probe_code == 301 || probe_code == 302 || probe_code == 307 || probe_code == 308) {
                if (redir == kMaxRedir) break;
                char* redirect_url = nullptr;
                curl_easy_getinfo(easy, CURLINFO_REDIRECT_URL, &redirect_url);
                if (!redirect_url || redirect_url[0] == '\0') break;
                std::string next(redirect_url);
                if (DownloadEngine::instance().isBadHost(extractHostFromUrl(next))) break;
                probe_url = std::move(next);
                probe_headers = ProbeHeaders{};
                continue;
            }
            probe_completed = true;
            break;
        }
        if (probe_completed && probe_code == 206 && probe_headers.content_range_seen &&
            contentRangeMatches(probe_headers.content_range, 0, 0, r.size)) {
            r.range = RangeCap::Supported;
        } else if (probe_completed && probe_code == 200) {
            r.range = RangeCap::Unsupported;
        } else {
            r.range = RangeCap::Unknown;
        }
    }

    curl_easy_cleanup(easy);
    return r;
}

bool splitTrustedRelativePath(const std::string& root, const std::string& path,
                              std::vector<std::string>& components) {
    if (root.empty() || path.size() <= root.size() || path.compare(0, root.size(), root) != 0 ||
        path[root.size()] != '/') return false;
    size_t pos = root.size() + 1;
    while (pos < path.size()) {
        size_t slash = path.find('/', pos);
        std::string part = path.substr(pos, slash == std::string::npos ? std::string::npos : slash - pos);
        if (part.empty() || part == "." || part == "..") return false;
        components.push_back(std::move(part));
        if (slash == std::string::npos) break;
        pos = slash + 1;
    }
    return !components.empty();
}

bool openTrustedParentAt(int root_fd, const std::string& root, const std::string& path,
                         bool create_dirs, int& parent_fd, std::string& leaf) {
    parent_fd = -1;
    std::vector<std::string> components;
    if (root_fd < 0 || !splitTrustedRelativePath(root, path, components)) {
        errno = EINVAL;
        return false;
    }
    leaf = components.back();
    components.pop_back();
    int current = ::dup(root_fd);
    if (current < 0) return false;
    for (const auto& component : components) {
        int next = ::openat(current, component.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC
#ifdef O_NOFOLLOW
                            | O_NOFOLLOW
#endif
        );
        if (next < 0 && create_dirs && errno == ENOENT) {
            if (::mkdirat(current, component.c_str(), 0755) != 0 && errno != EEXIST) {
                int saved = errno; ::close(current); errno = saved; return false;
            }
            next = ::openat(current, component.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC
#ifdef O_NOFOLLOW
                            | O_NOFOLLOW
#endif
            );
        }
        if (next < 0) {
            int saved = errno; ::close(current); errno = saved; return false;
        }
        ::close(current);
        current = next;
    }
    parent_fd = current;
    return true;
}

bool fsyncDirectoryFd(int fd) {
    int rc;
    do { rc = ::fsync(fd); } while (rc != 0 && errno == EINTR);
    return rc == 0;
}

// ============================================================================
//  长命 fd 治理：共享 allowedRoot 目录 fd + 把长命 fd 挪到 FD_SETSIZE 以上
//
//  背景（2026-08-04 P0 修复，真机实证 —— 这是"什么都下载不了"的真正根因）：
//    随包的 libcurl 8.10.1 是 autotools 交叉编译产物（docker/build_curl_ohos.sh）。
//    curl 的 poll 探测是**运行时**测试，交叉编译下跑不起来 → `HAVE_POLL_FINE` 未定义
//    → `Curl_poll()` 编进了 select() 分支。curl 自己在该函数上方写明：
//        Return values: -1 = system call error or fd >= FD_SETSIZE
//    （select 分支开头就是 `VERIFY_SOCK(fd)`，越界直接 EINVAL 返回 -1。）
//    llvm-objdump 反汇编本仓 entry/libs/arm64-v8a/libcurl.so 的 Curl_poll 已确认：
//    它调用的是 select@plt + __fd_chk@plt，不是 poll@plt。
//
//    于是**进程内只要出现 fd >= 1024，libcurl 的整个事件循环就废了**：
//      · curl_multi_poll   → CURLM_UNRECOVERABLE_POLL（"Unrecoverable error in select/poll"）
//      · curl_easy_perform → CURLE_BAD_FUNCTION_ARGUMENT（easy_transfer 把任何非 OOM 的
//                            CURLMcode 统一映射成它，即 "A libcurl function was given a
//                            bad argument"）—— 所有元数据请求（版本清单 / version.json /
//                            源探测）全部秒失败。
//    而且**永不自愈**：fd 号不降回 1024 以下，之后每次 poll 都同样失败，用户表现就是
//    「下载和重试全部立刻失败、点多少次都一样，必须杀进程重开」。
//
//  是怎么踩到的：
//    `NetFile::start()`（2c79620 / 2026-07-16 "harden native engine core" 引入）为
//    **每一个文件**打开一个常驻 allowedRoot 目录 fd，且只在 ~NetFile() 才关；而
//    `DownloadEngine::startupBody_` 对任务内全部文件无节流地调 start()。一个 4750 对象
//    的 assets 任务因此直接占掉约 4750 个常驻 fd。RLIMIT_NOFILE 是 32768，所以既不
//    EMFILE 也没有任何报错，socket 只是被分配到 1024 以上 —— 然后上面的连锁就发生了。
//    真机日志（_devicelog/20260804）01:27:21 journal 重放 4750 文件 assets 任务 →
//    01:27:24 起 curl_multi_poll 报 Unrecoverable → 01:27:27 起所有 fetch 永久失败。
//
//  两道修复（互相独立，都要）：
//    1. 同一个 allowedRoot 只开一个 fd，引用计数共享：4750 → 1。
//       目录 fd 只用于 dup/openat/fstat，没有文件偏移状态，多线程共享是安全的。
//    2. 所有**长命非 socket** fd 一律重定位到 FD_SETSIZE 以上，把 0..1023 这段低位号
//       留给 libcurl 的 socket。这样即使以后又有人加了常驻 fd，也不会再把 libcurl 打死。
//
//  根治仍应在重编 libcurl 时补上 poll（见 docker/build_curl_ohos.sh 的 HAVE_POLL_FINE
//  说明）；上面两条是纯源码侧、无需重编三方库、可立即生效的等价防护。
// ============================================================================

/** 与 glibc/musl 的 FD_SETSIZE 一致；libcurl 的 select 分支以此为硬上限。 */
constexpr int kFdSetSizeGuard = 1024;

/**
 * 把长命 fd 挪到 kFdSetSizeGuard 以上；成功则关掉原 fd 并返回新号。
 *
 * 这是纯优化，**绝不能成为新的失败点**：任何失败（fd 用满 / RLIMIT 本身就 <=1024 /
 * 内核不支持 F_DUPFD_CLOEXEC）都原样返回传入的 fd，调用方无需处理。
 */
int relocateFdAboveFdSetSize(int fd) {
    if (fd < 0 || fd >= kFdSetSizeGuard) return fd;
#ifdef F_DUPFD_CLOEXEC
    int high = ::fcntl(fd, F_DUPFD_CLOEXEC, kFdSetSizeGuard);
#else
    int high = ::fcntl(fd, F_DUPFD, kFdSetSizeGuard);
#endif
    if (high < 0) {
        // 只在第一次失败时告警：反复打印没有信息量，而这条信息在诊断 fd 水位时很关键。
        static std::atomic<bool> warned{false};
        bool expected = false;
        if (warned.compare_exchange_strong(expected, true)) {
            AMCL_LOG_W(LOG_TAG,
                "relocateFdAboveFdSetSize failed errno=%{public}d (fd=%{public}d); "
                "low fd numbers stay in use — libcurl select() path may break if fd >= %{public}d",
                errno, fd, kFdSetSizeGuard);
        }
        return fd;
    }
    ::close(fd);
    return high;
}

/**
 * allowedRoot 目录 fd 的持有者。最后一个持有者析构时才真正 close。
 * 由 TrustedRootFdPool 按 allowedRoot 路径共享。
 */
struct TrustedRootFd {
    int      fd = -1;
    uint64_t dev = 0;
    uint64_t ino = 0;
    TrustedRootFd() = default;
    TrustedRootFd(const TrustedRootFd&) = delete;
    TrustedRootFd& operator=(const TrustedRootFd&) = delete;
    ~TrustedRootFd() { if (fd >= 0) ::close(fd); }
};
using TrustedRootFdPtr = std::shared_ptr<TrustedRootFd>;

/**
 * 进程级 allowedRoot 目录 fd 共享池。
 *
 * 用 weak_ptr 存表：没有任何 NetFile 持有时条目自动失效，不需要显式 release，
 * 也不会出现"引用计数漏减导致 fd 永久泄漏"。
 *
 * 陈旧目录处理：命中缓存时用 stat(root) 比对 (dev, ino)。目录被删掉重建过
 * （整合包 versionDir、JDK staging 都会）时旧 fd 指向的是已删除 inode，此时把条目
 * 从表里摘掉并新开一个；仍在使用旧 fd 的 NetFile 不受影响（各自持有 shared_ptr）。
 */
class TrustedRootFdPool {
public:
    static TrustedRootFdPool& instance() {
        static TrustedRootFdPool pool;
        return pool;
    }

    /** 成功返回持有者；失败返回 nullptr 并置 out_errno。 */
    TrustedRootFdPtr acquire(const std::string& root, int& out_errno) {
        out_errno = 0;
        if (root.empty()) { out_errno = EINVAL; return nullptr; }

        struct stat live_st{};
        if (::stat(root.c_str(), &live_st) != 0 || !S_ISDIR(live_st.st_mode)) {
            out_errno = errno != 0 ? errno : ENOTDIR;
            return nullptr;
        }
        const uint64_t live_dev = static_cast<uint64_t>(live_st.st_dev);
        const uint64_t live_ino = static_cast<uint64_t>(live_st.st_ino);

        std::lock_guard<std::mutex> lk(mu_);
        auto it = entries_.find(root);
        if (it != entries_.end()) {
            if (auto cached = it->second.lock()) {
                if (cached->dev == live_dev && cached->ino == live_ino) return cached;
                // 目录被删除重建过：旧 fd 指向已删 inode，不能再复用。
                entries_.erase(it);
            } else {
                entries_.erase(it);
            }
        }

        int flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC;
#ifdef O_NOFOLLOW
        flags |= O_NOFOLLOW;
#endif
        int fd = ::open(root.c_str(), flags);
        struct stat st{};
        if (fd < 0 || ::fstat(fd, &st) != 0 || !S_ISDIR(st.st_mode)) {
            out_errno = errno != 0 ? errno : ENOTDIR;
            if (fd >= 0) ::close(fd);
            return nullptr;
        }
        auto holder = std::make_shared<TrustedRootFd>();
        holder->fd  = relocateFdAboveFdSetSize(fd);
        holder->dev = static_cast<uint64_t>(st.st_dev);
        holder->ino = static_cast<uint64_t>(st.st_ino);
        entries_[root] = holder;
        return holder;
    }

private:
    std::mutex mu_;
    std::unordered_map<std::string, std::weak_ptr<TrustedRootFd>> entries_;
};

bool fileExists(const std::string& path) {
    struct stat st{};
    return ::lstat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

ErrorKind storageErrorKind(int e) {
    if (e == ENOSPC) return ErrorKind::DiskFullError;
#ifdef EDQUOT
    if (e == EDQUOT) return ErrorKind::QuotaExceededError;
#endif
    if (e == EIO) return ErrorKind::StorageIoError;
    return ErrorKind::FileIoError;
}

bool fsyncParentDir(const std::string& path) {
    size_t slash = path.find_last_of('/');
    std::string parent = slash == std::string::npos ? "." : (slash == 0 ? "/" : path.substr(0, slash));
    int dfd = ::open(parent.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dfd < 0) return false;
    int rc;
    do { rc = ::fsync(dfd); } while (rc != 0 && errno == EINTR);
    int saved = errno;
    if (::close(dfd) != 0 && rc == 0) { saved = errno; rc = -1; }
    errno = saved;
    return rc == 0;
}

/** 确保父目录存在（仅创建直接父目录，不递归） */
bool ensureParentDir(const std::string& path) {
    auto pos = path.find_last_of("/\\");
    if (pos == std::string::npos) return true;
    std::string parent = path.substr(0, pos);
    if (parent.empty()) return true;
    struct stat st{};
    if (::stat(parent.c_str(), &st) == 0) return S_ISDIR(st.st_mode);
    // 递归 mkdir
    std::string curr;
    for (size_t i = 0; i <= parent.size(); ++i) {
        if (i == parent.size() || parent[i] == '/' || parent[i] == '\\') {
            if (!curr.empty() && curr != "." && ::stat(curr.c_str(), &st) != 0) {
                if (::mkdir(curr.c_str(), 0755) != 0 && errno != EEXIST) {
                    return false;
                }
            }
            if (i < parent.size()) curr.push_back('/');
        } else {
            curr.push_back(parent[i]);
        }
    }
    return true;
}

} // namespace

// ============================================================================
// NetFile
// ============================================================================

NetFile::NetFile(Config cfg)
    : cfg_(std::move(cfg)),
      // Engine 的 canonical path ownership 已保证同一路径单 owner；确定性名称使
      // taskId 重置后的新进程仍能找到同一 staging，与固定 meta 路径共同恢复。
      staging_path_(cfg_.local_path + ".amcl.part") {
    sources_.reserve(cfg_.urls.size());
    for (size_t i = 0; i < cfg_.urls.size(); ++i) {
        sources_.push_back(std::make_shared<NetSource>(static_cast<int>(i), cfg_.urls[i]));
    }
}

NetFile::~NetFile() {
    std::lock_guard<std::mutex> lk(fd_init_mu_);
    if (fd_ >= 0) {
        ::close(fd_);
        fd_ = -1;
    }
    // root_fd_ 是从 TrustedRootFdPool 借来的共享 fd：这里只放引用，
    // 由最后一个持有者的 TrustedRootFd 析构函数负责 close。绝不能在这里直接 close，
    // 否则同 allowedRoot 的其它 NetFile 会拿到已关闭的 fd。
    root_fd_ = -1;
    root_fd_holder_.reset();
    fd_refcount_ = 0;
}

DownloadExceptionPtr NetFile::error() const {
    std::lock_guard<std::mutex> lk(mu_);
    return error_;
}

int64_t NetFile::downloadedBytes() const {
    std::lock_guard<std::mutex> lk(mu_);
    int64_t sum = 0;
    for (const auto& t : threads_) {
        sum += t->done();
    }
    return sum;
}

double NetFile::progress() const {
    int64_t size = file_size_.load(std::memory_order_relaxed);
    if (size <= 0) return 0.0;
    int64_t done = downloadedBytes();
    double p = static_cast<double>(done) / static_cast<double>(size);
    if (p < 0.0) return 0.0;
    if (p > 1.0) return 1.0;
    return p;
}

int64_t NetFile::recentFileSpeedBps() const {
    constexpr int64_t kSpeedWindowMs = 500;
    // ⚠️ 必须在取 speed_sample_mu_ **之前**调用 downloadedBytes()（它内部取 mu_），
    //    否则与 maybeGrowThreads 等持 mu_ 的路径存在锁序反转风险。
    const int64_t done = downloadedBytes();
    const int64_t now = netThreadSteadyNowMs();

    std::lock_guard<std::mutex> lk(speed_sample_mu_);
    if (speed_sample_ms_ == 0) {
        speed_sample_ms_ = now;
        speed_sample_bytes_ = done;
        return 0;
    }
    const int64_t dt = now - speed_sample_ms_;
    if (dt >= kSpeedWindowMs) {
        const int64_t delta = done - speed_sample_bytes_;
        const int64_t inst = delta > 0 ? (delta * 1000 / dt) : 0;
        // 轻度 EWMA（新样本权重 3/5），抹掉单窗口抖动但仍能在 1~2 秒内跟上真实变化。
        speed_cached_bps_ = (speed_cached_bps_ * 2 + inst * 3) / 5;
        speed_sample_ms_ = now;
        speed_sample_bytes_ = done;
    }
    return speed_cached_bps_;
}

int64_t NetFile::sumRecentSpeedBps() const {
    std::lock_guard<std::mutex> lk(mu_);
    int64_t sum = 0;
    for (const auto& t : threads_) {
        NetState ts = t->state();
        if (ts == NetState::Downloading || ts == NetState::Connecting ||
            ts == NetState::Reading) {
            sum += t->recentSpeedBps();
        }
    }
    return sum;
}

NetSourcePtr NetFile::pickBestSource(bool needs_range, int preferred_idx) {
    // Phase 8（2026-05-06）：改用综合评分选源（score = rtt/100 + 1MB/throughput + fail_count，越低越优）
    //   - NetSource::computeScore() 内含"无数据中性回退"：首次选源时所有源同分 → 按 id 稳定 → 与旧版
    //     "按声明顺序"效果一致；样本累积后，快源/失败少的源胜出。
    //   - fail_count 仍然是 score 的一部分 → v4.6 重试阈值翻转逻辑依然生效（失败越多 → score 越高 → 越难被选）。
    //   - needs_range / no_range_support 语义保留：分段任务优先支持 Range 的源，全挂了才退 fallback。
    std::lock_guard<std::mutex> lk(mu_);
    // v6（PCL2 多源轮询）：优先返回调用方指定的首选源（段i→源i），让不同段并发走不同源，
    // 带宽相加 + 避免同一源被并发 Range 命中（规避 mcimirror 缓存代理对并发 Range 返回
    // 不一致字节导致的拼接损坏）。仅当该源当前可用且满足 Range 需求时生效；否则落到下面的
    // 综合评分选源（失败重试时也会回到这里换更优源）。
    if (preferred_idx >= 0 && preferred_idx < (int)sources_.size()) {
        const auto& ps = sources_[preferred_idx];
        if (ps && !ps->checksum_bad.load(std::memory_order_relaxed) &&
            !DownloadEngine::instance().isBadHost(extractHostFromUrl(ps->url))) {
            int64_t now_ms0 = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now().time_since_epoch()).count();
            bool range_ok = !(needs_range && ps->no_range_support.load(std::memory_order_relaxed));
            if (ps->isAvailable(now_ms0) && range_ok) return ps;
        }
    }
    NetSourcePtr best;
    NetSourcePtr best_fallback;
    double best_score = 0.0;
    double fb_score   = 0.0;
    int64_t now_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    // ⚠️ 2026-07-29：选源必须跳过熔断中的坏主机。此前只有 doHead 与重定向跳转会查
    //   isBadHost，下载线程选源时**完全不查** —— 于是彻底连不上的镜像（真机：
    //   github.moeyy.xyz 每次 `Failed to connect ... after 6001 ms: Timeout`）会被
    //   每个段反复选中，每次白等 6 秒 connect 超时，表现为速度在几十 MB/s 与几 KB/s
    //   之间剧烈抖动。改动一让 JDK 走 expected_size 快路径后不再经 doHead，
    //   这个缺口彻底暴露，故在此补齐。
    for (const auto& s : sources_) {
        if (!s) continue;
        if (!s->isAvailable(now_ms)) continue;
        const std::string sh = extractHostFromUrl(s->url);
        if (DownloadEngine::instance().isBadHost(sh)) continue;
        // 主机级 429 退避未到期 → 本轮跳过该源（源级 cooldown 已同步，这里是双保险）。
        if (DownloadEngine::instance().hostRateLimitUntilMs(sh) > now_ms) continue;
        double sc = s->computeScore();
        if (needs_range && s->no_range_support.load(std::memory_order_relaxed)) {
            // 放入 fallback（万一所有支持 Range 的源都挂了，还能用这个）
            if (!best_fallback || sc < fb_score
                || (sc == fb_score && s->id < best_fallback->id)) {
                best_fallback = s;
                fb_score = sc;
            }
            continue;
        }
        if (!best || sc < best_score
            || (sc == best_score && s->id < best->id)) {
            best = s;
            best_score = sc;
        }
    }
    // 如果没有支持 Range 的可用源，退而用 fallback（会触发数据错位检测→SizeMismatch→最终 Failed）
    // 都没有时，最后再退到"正在冷却"的源（避免全部冷却时无源可用整文件卡死）。
    if (best) return best;
    if (!needs_range && best_fallback) return best_fallback;

    // ⚠️ 2026-07-29：这里**不能**再写"忽略熔断兜底选一个"。
    //   我上一轮加过那样的兜底，结果它把熔断机制整体废掉了，正是「卡在 8x% + 速度
    //   在 20MB/s 与 0 之间抖动」的真正病根：
    //     · 429 让健康代理进 cooldown（isAvailable=false）；
    //     · 彻底连不上的 github.moeyy.xyz 已被 addBadHost 熔断（真机：16 次、TTL 300s）；
    //     · 于是上面两轮筛选都选不出 best → 落进"忽略熔断"兜底 → **又选中那台死主机**
    //       → 每次白等 6s connect 超时 → 段永不推进，而其它段在健康源上仍跑得飞快
    //       → 聚合速度剧烈抖动、尾段几乎不动。
    //   正确语义：此刻确实"暂时无源可用"，应当返回 nullptr。NetThread 的调用方已有
    //   完备处理——它会经 nextSourceReadyMs 拿到最近的冷却/熔断到期时刻并**等待**，
    //   而不是去撞一台已知不可达的主机（见 net_thread.cpp 的 `if (!src)` 分支）。
    return nullptr;
}

// ----------------------------------------------------------------------------
// start()
// ----------------------------------------------------------------------------

DownloadExceptionPtr NetFile::preCheckExistingFile() {
    if (!cfg_.check.needsAnyCheck()) return nullptr;
    if (!fileExists(cfg_.local_path)) return nullptr;
    auto ex = cfg_.check.check(cfg_.local_path);
    if (!ex) {
        AMCL_LOG_I(LOG_TAG, "preCheckExistingFile: local file hit sha1, skip download: %{public}s",
                    cfg_.local_path.c_str());
        state_.store(NetState::Finished, std::memory_order_release);
        struct stat st{};
        if (::lstat(cfg_.local_path.c_str(), &st) == 0 && S_ISREG(st.st_mode)) {
            file_size_.store(static_cast<int64_t>(st.st_size), std::memory_order_release);
        }
        return nullptr;  // 不报错，但 state 已是 Finished，调用者看 state
    }
    // 校验不过：删掉重下（可能是部分数据残留）
    AMCL_LOG_I(LOG_TAG, "preCheckExistingFile: local file check failed (%{public}s), will re-download",
                errorKindToString(ex->kind));
    ::unlink(cfg_.local_path.c_str());
    return nullptr;
}

DownloadExceptionPtr NetFile::validatePaths() const {
    if (cfg_.local_path.empty()) return makeException(ErrorKind::InvalidConfig, "empty local path");
    auto rejectSpecial = [](const std::string& path) -> DownloadExceptionPtr {
        struct stat st{};
        if (::lstat(path.c_str(), &st) == 0 && !S_ISREG(st.st_mode)) {
            return makeException(ErrorKind::FileIoError, "refusing symlink/non-regular path: " + path);
        }
        return nullptr;
    };
    if (auto ex = rejectSpecial(cfg_.local_path)) return ex;
    if (auto ex = rejectSpecial(staging_path_)) return ex;
    if (!cfg_.allowed_root.empty()) {
        std::string root = cfg_.allowed_root;
        while (root.size() > 1 && root.back() == '/') root.pop_back();
        if (cfg_.local_path.compare(0, root.size(), root) != 0 ||
            (cfg_.local_path.size() > root.size() && cfg_.local_path[root.size()] != '/')) {
            return makeException(ErrorKind::InvalidConfig, "local path escapes allowed root");
        }
    }
    return nullptr;
}

int64_t NetFile::nextSourceReadyMs(bool needs_range) const {
    int64_t ready = INT64_MAX;
    for (const auto& src : sources_) {
        if (!src || src->checksum_bad.load(std::memory_order_acquire) ||
            src->is_failed.load(std::memory_order_acquire) ||
            (needs_range && src->no_range_support.load(std::memory_order_acquire))) continue;
        // ⚠️ 2026-07-29：必须把**主机熔断**到期时刻也算进来。
        //   源级 cooldown（429 的 Retry-After）与主机级熔断（连不上）是两套独立机制：
        //   熔断源的 NetSource::readyAtMs() 通常是 0，若只看它，调用方会以为该源
        //   "现在就能用"，于是 pickBestSource 返回 nullptr 后又立刻重试、空转刷日志；
        //   取两者较大值才是该源真正可用的时刻。
        int64_t src_ready = src->readyAtMs();
        const std::string h = extractHostFromUrl(src->url);
        int64_t host_ready = std::max(
            DownloadEngine::instance().badHostReadyAtMs(h),
            DownloadEngine::instance().hostRateLimitUntilMs(h));   // 主机级 429 退避
        ready = std::min(ready, std::max(src_ready, host_ready));
    }
    return ready == INT64_MAX ? -1 : ready;
}

void NetFile::discardStaging() {
    std::lock_guard<std::mutex> lk(fd_init_mu_);
    // 仅允许在 startup 尚未打开 fd，或所有 segment 已收敛并完成最后 release 后调用。
    if (fd_refcount_ != 0) {
        AMCL_LOG_E(LOG_TAG,
            "discardStaging rejected with active fd refs=%{public}d: %{public}s",
            fd_refcount_, staging_path_.c_str());
        return;
    }
    if (fd_ >= 0) {
        ::close(fd_);
        fd_ = -1;
    }
    if (::unlink(staging_path_.c_str()) != 0 && errno != ENOENT) {
        AMCL_LOG_W(LOG_TAG, "discardStaging unlink failed errno=%{public}d: %{public}s",
                    errno, staging_path_.c_str());
    }
    staging_identity_set_ = false;
    staging_device_ = 0;
    staging_inode_ = 0;
    fd_error_ = 0;
}

void NetFile::rebuildSingleSegment() {
    std::lock_guard<std::mutex> lk(mu_);
    threads_.clear();
    threads_pending_launch_.clear();
    completed_threads_.clear();
    auto t = std::make_shared<NetThread>(this, 0, -1, 0);
    threads_.push_back(t);
    threads_done_count_.store(0, std::memory_order_release);
    target_connections_ = 1;
    resume_from_meta_ = false;
}

DownloadExceptionPtr NetFile::syncCloseAndCommit() {
    // 恢复自 meta 且所有 segment 已完成时，本进程可能从未 acquireFd；提交前仍必须
    // 对 staging 本体执行一次显式 fsync，不能仅相信旧 meta 的完成位。
    int durable_error = syncStagingDurable();
    if (durable_error == 0) durable_error = fdError();
    if (durable_error != 0) {
        auto ex = makeException(storageErrorKind(durable_error),
                                "durable write failed errno=" + std::to_string(durable_error));
        ex->native_code = durable_error;
        return ex;
    }
    struct stat part_st{};
    if (::lstat(staging_path_.c_str(), &part_st) != 0 || !S_ISREG(part_st.st_mode)) {
        return makeException(ErrorKind::FileIoError, "staging is missing or non-regular");
    }
    int parent_fd = -1;
    std::string final_leaf;
    if (!openTrustedParentAt(root_fd_, cfg_.allowed_root, cfg_.local_path,
                             false, parent_fd, final_leaf)) {
        int e = errno;
        auto ex = makeException(storageErrorKind(e),
                                "open trusted commit parent failed errno=" + std::to_string(e));
        ex->native_code = e;
        return ex;
    }
    const std::string staging_leaf = final_leaf + ".amcl.part";
    // ⚠️ N-01 修复（2026-07-29）：目标已存在时不能把整个文件判死。
    //
    // 旧行为：final 一存在就返回 FileIoError("refusing to replace existing final path")。
    // 而 preCheckExistingFile 在**无 checker**时（不传 check → needsAnyCheck() 为 false）
    // 既不跳过也不删除旧文件。于是「无 sha1/size 的文件 + 目标已存在」必然：
    //   整文件下完 → 提交被拒 → FileIoError 被 onAllThreadsDone 归为不可重试的本地存储
    //   错误 → 永久失败；且 .amcl.part + meta 被保留，下次重试从 meta 恢复后所有段判完成、
    //   直奔提交，0 字节再复现同一错误。
    // 受害面：老格式（FML ≤1.12）libraries、**全部加载器库**（MavenSpecBuilder 对无
    // sha1/size 的条目不带 check）、无 sha1 且 size<=0 的模组、引擎自带 smoke test。
    // 加载器安装的「第一轮失败就整批重试」会把它放大成必然失败且自我触发。
    //
    // 新行为：本文件已通过 Engine 的 canonical path ownership 独占该最终路径
    // （engine.cpp createTask 的 path_owners_），覆盖自己的目标是安全的，改用原子替换。
    // 保留的安全约束（H-12）：final 若存在但不是**单链接普通文件**（symlink / FIFO /
    // 目录 / 多硬链接），一律拒绝，绝不跟随链接写到可信根之外。
    struct stat final_st{};
    if (::fstatat(parent_fd, final_leaf.c_str(), &final_st, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!S_ISREG(final_st.st_mode) || final_st.st_nlink != 1) {
            ::close(parent_fd);
            return makeException(ErrorKind::FileIoError,
                                 "refusing to replace non-regular or hard-linked final path");
        }
        // 普通单链接文件 → 落到下面的原子替换。
    } else if (errno != ENOENT) {
        int e = errno; ::close(parent_fd);
        auto ex = makeException(storageErrorKind(e),
                                "safe final lookup failed errno=" + std::to_string(e));
        ex->native_code = e;
        return ex;
    }
    // POSIX renameat 对已存在的普通文件是**原子覆盖**，且失败时不破坏原文件。
    // 不再走 RENAME_NOREPLACE / linkat+unlinkat —— 那条路径正是 N-01 的成因。
    if (::renameat(parent_fd, staging_leaf.c_str(), parent_fd, final_leaf.c_str()) != 0) {
        int e = errno; ::close(parent_fd);
        auto ex = makeException(storageErrorKind(e),
                                "staging commit rename failed errno=" + std::to_string(e));
        ex->native_code = e;
        return ex;
    }
    if (!fsyncDirectoryFd(parent_fd)) {
        int e = errno; ::close(parent_fd);
        auto ex = makeException(storageErrorKind(e),
                                "parent directory fsync failed errno=" + std::to_string(e));
        ex->native_code = e;
        return ex;
    }
    ::close(parent_fd);
    return nullptr;
}

DownloadExceptionPtr NetFile::determineFileSize() {
    const int64_t expected_size = cfg_.check.expected_size;

    // ⚠️ 2026-07-29 优化「镜像模式先长时间 0%，再突然跳到 30%」：
    //   调用方已给出**精确期望大小**（JDK/模组的 check.size 来自 deps.lock / manifest）时，
    //   不再为"拿 size"而串行 doHead 所有源。旧行为在 mirror 模式（6 个代理源）下要
    //   逐个 HEAD（每个 CONNECTTIMEOUT+TIMEOUT，且成功后还要再发一次 Range: 0-0 探测），
    //   代理 TTFB 实测 3~10s → 首字节前可空等数十秒；这段时间 file_size_ 未定，
    //   overall_progress 回退到 files_done/files_total = 0/1 = 0% → UI 长时间 0%，
    //   探测结束后 16 段一起起飞，首帧一次性结算 → 观感上"突然跳到 30%"。
    //
    //   安全性：H-04「Range 能力必须实测证明」并未被绕过，只是从**事前证明**改为
    //   **事中证明 + 强制回滚**——这条路径引擎本来就完备：
    //     · 206 响应必须带精确 Content-Range 且 contentRangeMatches，否则标
    //       no_range_support + resetDone() + 报 SizeMismatch（net_thread.cpp）；
    //     · 200 + requested_offset>0 直接判数据错位并拒绝；
    //     · 多段在所有源上失败后 rebuildSingleSegment() 退化为单段全量 GET；
    //     · 最终 SHA-256/SHA-1 终检兜底，任何错位拼接都会被拦下并重下。
    //   因此这里按"乐观假设支持 Range"起步：range_verified 保持 false（未证明），
    //   no_range_support 也保持 false（未否证），首个真实响应即给出结论。
    //
    //   各源大小一致性校验（旧逻辑用 HEAD 的 Content-Length 比对 expected_size）同样
    //   由下载期承接：引擎层 DownloadCheck.size 会在收尾校验总字节，镜像返回错误对象
    //   （如 HTML 错误页）必然 size 不符而失败换源。
    if (expected_size > 0) {
        file_size_.store(expected_size, std::memory_order_release);
        all_sources_range_unsupported_ = false;
        AMCL_LOG_I(LOG_TAG,
            "determineFileSize: using expected size %{public}lld, skipping serial HEAD probe: %{public}s",
            (long long)expected_size, cfg_.local_path.c_str());
        return nullptr;
    }

    int successful_probes = 0;
    int unsupported_probes = 0;
    bool size_set = false;

    // 能力必须按源记录。无 expected_size 时仍需 HEAD 拿 size，顺带实测 Range 能力；
    // 单源 Unsupported 不得把支持 Range 的备源一起降级。
    for (const auto& src : sources_) {
        if (!src || src->is_failed.load(std::memory_order_relaxed)) continue;
        HeadResult result = doHead(src->url);
        if (result.size <= 0) {
            AMCL_LOG_W(LOG_TAG, "HEAD/probe failed on %{public}s (http=%{public}ld, size=%{public}lld)",
                        src->url.c_str(), result.http_code, (long long)result.size);
            continue;
        }
        if (expected_size > 0 && result.size != expected_size) {
            AMCL_LOG_W(LOG_TAG,
                "source size mismatch during probe expected=%{public}lld got=%{public}lld: %{public}s",
                (long long)expected_size, (long long)result.size, src->url.c_str());
            continue;
        }
        if (!size_set) {
            file_size_.store(expected_size > 0 ? expected_size : result.size,
                             std::memory_order_release);
            size_set = true;
        }
        ++successful_probes;
        if (result.range == RangeCap::Supported) {
            src->range_verified.store(true, std::memory_order_release);
            src->no_range_support.store(false, std::memory_order_release);
        } else if (result.range == RangeCap::Unsupported) {
            src->no_range_support.store(true, std::memory_order_release);
            ++unsupported_probes;
        }
    }

    if (expected_size > 0 && !size_set) {
        file_size_.store(expected_size, std::memory_order_release);
        size_set = true;
    }
    all_sources_range_unsupported_ = successful_probes > 0 &&
                                     unsupported_probes == successful_probes;
    if (size_set) return nullptr;

    file_size_.store(-2, std::memory_order_release);
    AMCL_LOG_W(LOG_TAG, "all HEAD/probe failed, falling back to single-thread full download");
    return nullptr;
}

// v4.9 (2026-06-06)：高并发模式下的分段大小下限。比默认 2MB 小，让 Forge installer
// 这类大文件能切出 max_connections 个段（如 8MB → 8 段 × 1MB），用并发抵消慢速镜像的
// 单连接限速。
//
// ⚠️ 2026-07-31（二次修正，回退当日早些时候的 384KB→2MiB）：改为 256KiB。
//   当日把它提到 2MiB 的理由（"小模组切太碎、每段付 3s TTFB 纯亏"）经真机复盘是**错的**，
//   它建立在两个错误前提上：
//     ① 误读 PCL2：旧注释称"2MiB 让 1.2MB 模组走 1 段，与 PCL2 一致"。但 PCL2 的口径是
//        `IsNoSplit = FileSize < 1MB`（ModNet.vb:750），1.2MB **大于** 1MB，PCL2 会**分段**，
//        并在慢时追加线程（碎片下限 FilePieceLimit = 256KB）。2MiB 单段恰恰**背离** PCL2。
//     ② 只算 TTFB、没算劣质路由下单连接的持续慢。真机实测（MatePad Pro，2026-07-31 20:52）：
//        `sodium-neoforge-…jar` 1,204,654B 走 2MiB 单段，耗时 **646,152ms（1.8KB/s）**。
//        根因：Modrinth 的 mcim/官方源最终都 302/307 汇聚到 cdn-alt.modrinth.com
//        （平板解析到 203.10.96.211，RTT 395ms 的劣质跨境路由），单连接被丢包压到 1.8KB/s，
//        而单段全量 GET（end=-1）**无法被 maybeGrowThreads 追加并发**（它跳过 end<0 的段）
//        → 只有一条慢连接干等。同一文件在开发机（好路由）单连接 3.9s / 302KB/s 就下完，
//        证明慢的是**这条路由**，不是文件或 CDN。对抗劣质路由的唯一客户端手段就是多连接
//        并发（每条连接独立拥塞控制），这正是 PCL2 / aria2 / IDM 多线程下载的立身之本。
//   取 256KiB（对齐 PCL2 FilePieceLimit）后：1.2MB 模组 → min(8, ⌈1.2M/256K⌉=5)=5 段并发、
//   5MB → 8 段、8MB Forge → 8 段、JDK 100MB → 仍 min(16, …)=16 段。
//   TTFB 顾虑对 friendly CDN（modrinth/mojang，TTFB ~0.5~2s）可忽略：多段 TTFB 并行只付一次，
//   之后多连接对冲丢包，净收益远大于成本；对多线程不友好的源（GitHub 代理 / BMCLAPI）另有
//   isMultiThreadUnfriendlyHost → 强制单段的独立护栏，不受本值影响。
//   数据完整性（v4.7 曾担心"1-2MB 分段 CDN 拼接损坏"）由每段 Content-Range 校验 +
//   全文件 SHA1/size 终检兜底，实测 cdn-alt 对 Range 请求返回正确的 206 + Content-Range。
static constexpr int64_t kHighParallelPieceMinBytes = 256 * 1024;
// 高并发段数硬上限，避免调用方传入异常大的值打爆 worker 池（worker_pool_size 默认 16）。
static constexpr int     kHighParallelMaxConnections = 16;

void NetFile::initSegments() {
    int64_t size = file_size_.load(std::memory_order_relaxed);

    // v4.9 / 2026-07-29：显式 max_connections 始终是硬上限；只有上限高于默认
    // piece_limit(4) 时才进入高并发模式并降低最小分段大小。这样 1 可强制单连接，4 可恢复
    // client 的 beta.5 连接规模，而 8/16 仍保留 Forge/模组已验证的高并发能力。
    int     piece_limit = cfg_.piece_limit;
    int64_t piece_min   = cfg_.piece_min_bytes;
    if (cfg_.max_connections > 0) {
        piece_limit = std::min(cfg_.max_connections, kHighParallelMaxConnections);
    }
    if (isHighParallel()) {
        piece_min = kHighParallelPieceMinBytes;
    }

    int pieces;
    if (size <= 0 || size < piece_min || all_sources_range_unsupported_) {
        // 只有所有成功探测的源均明确不支持 Range 才强制单段；Unknown 或混合能力
        // 保留分段，并由每个 NetSource 的运行期严格响应校验继续筛选。
        pieces = 1;
    } else {
        pieces = std::min(piece_limit,
                          (int)((size + piece_min - 1) / piece_min));
        if (pieces < 1) pieces = 1;
    }

    // v7.4：目标并发（IDM/aria2 式「保持 N 条连接满负荷」）。按文件大小/模式分级——
    // 只让真正拖时间的大单文件（JDK / client.jar / 大安装器）打满，避免原版 libraries
    // 多小文件并行时每文件都开 16 条把 worker 池 / 官方 CDN 握手打爆（见 v7.2 教训）。
    //   - 显式上限（max_connections>0）：min(max_connections, 16)，不再按文件大小扩张
    //   - 默认路径大文件（≥8MB）：16
    //   - 1~8MB：8
    //   - <1MB：不额外并发（走 multi 或单段）
    static constexpr int64_t kSaturateFileBytes = 8 * 1024 * 1024;
    if (cfg_.max_connections > 0) {
        target_connections_ = std::min(cfg_.max_connections, kHighParallelMaxConnections);
    } else if (size >= kSaturateFileBytes) {
        target_connections_ = 16;
    } else if (size >= 1 * 1024 * 1024) {
        target_connections_ = 8;
    } else {
        target_connections_ = pieces;
    }
    if (target_connections_ < pieces) target_connections_ = pieces;  // 目标不低于初始段数

    if (pieces == 1) {
        // 单段：不发 Range 请求（end=-1），server 返回完整 Content-Length 全量。
        // 避免 Range 请求在某些 CDN（如 Mojang piston-data）的 partial EOF bug。
        auto t = std::make_shared<NetThread>(this, 0, -1, 0);
        threads_.push_back(t);
        threads_pending_launch_.push_back(t);
        AMCL_LOG_I(LOG_TAG, "initSegments: %{public}s size=%{public}lld pieces=1 (no Range, full GET)",
                    cfg_.local_path.c_str(), (long long)size);
        return;
    }

    // ⚠️ 2026-07-29：曾在此实现「两阶段探测 + 按吞吐加权分配」（方案 A），**已整体回退**。
    //   回退原因（真机实测 + 阅读 PCL2 `ModNet.vb` 后确认方向错误）：
    //     · 阶段 1 每源只铺 1 个探测段 → 并发从 16 掉到 5，**前期速度也塌了**；
    //     · 慢源的探测段要几十秒，阶段 1 实测耗时 76 秒，期间只有 5 条连接；
    //     · 分配结果 `src#1 20761B/s -> 4549KB` + `src#2 469096B/s -> 102807KB`，
    //       102MB 压在单源单段上，等于退化成单线程。
    //   更重要的是：PCL2 在同一位置留下注释
    //     'FUTURE: 下载引擎重做，计算下载源平均链接时间和线程下载速度，按最高时间节省来开启多线程
    //   —— 即「按吞吐加权」是它评估过但**没有实施**的方案。成熟实现选择的是另一条路：
    //   对 GitHub / BMCLAPI 这类源**直接禁用多段并发**（见下方 isMultiThreadUnfriendlyHost）。
    int nsrc = static_cast<int>(sources_.size());

    // ========================================================================
    //  借鉴 PCL2：对「多线程不友好」的源禁用分段并发
    // ========================================================================
    //
    // PCL2 `ModNet.vb` / NetFile.TryBeginThread 的真实做法：
    //   Dim TargetUrl As String = Source.Url
    //   If TargetUrl.Contains("pcl2-server") OrElse TargetUrl.Contains("meloong.com") OrElse
    //      TargetUrl.Contains("bmclapi") OrElse TargetUrl.Contains("github.com") OrElse
    //      TargetUrl.Contains("optifine.net") OrElse TargetUrl.Contains("momot.rs") Then Return Nothing
    // `Return Nothing` = 不追加任何线程，这些源只用单线程下载。
    //
    // 为什么：这类源（含全部 GitHub 代理）对多连接的反应是**限流**，越并发越慢。
    // 我们对 GitHub 代理开 16 段的真机后果：
    //   · 单次下载 327~887 条 HTTP 429；
    //   · 尾段被反复切成 170~450KB 碎片，每段付 ~290ms TTFB 只搬 176KB
    //     → 有效吞吐从 2.4MB/s 塌到 52KB/s（即「前面 MB、后面 KB」）。
    // 因此：只要**所有**候选源都是这类主机，就强制单段全量 GET，彻底避开限流与碎片化。
    if (pieces > 1 && nsrc > 0) {
        bool all_unfriendly = true;
        for (const auto& s : sources_) {
            if (!s) continue;
            if (!isMultiThreadUnfriendlyHost(s->url)) { all_unfriendly = false; break; }
        }
        if (all_unfriendly) {
            pieces = 1;
            target_connections_ = 1;
            AMCL_LOG_I(LOG_TAG,
                "initSegments: %{public}s all sources are multi-thread unfriendly (GitHub/proxy/BMCLAPI) -> single segment",
                cfg_.local_path.c_str());
        }
    }

    if (pieces == 1) {
        auto t = std::make_shared<NetThread>(this, 0, -1, 0);
        threads_.push_back(t);
        threads_pending_launch_.push_back(t);
        AMCL_LOG_I(LOG_TAG, "initSegments: %{public}s size=%{public}lld pieces=1 (no Range, full GET)",
                    cfg_.local_path.c_str(), (long long)size);
        return;
    }

    int64_t piece_sz = size / pieces;
    int64_t start = 0;
    for (int i = 0; i < pieces; ++i) {
        int64_t end = (i == pieces - 1) ? (size - 1) : (start + piece_sz - 1);
        auto t = std::make_shared<NetThread>(this, start, end, 0);
        // v7.5 / 2026-07-29：真正的高并发路径（上限 > 默认 4）才把初始段轮询分配到
        // 不同镜像，以绕开慢镜像的单 IP 限速。1..4 是纯上限模式，不钉源，继续交给
        // pickBestSource 按吞吐收敛到最快源；否则 client 的 BMCLAPI + Mojang 混合源会被
        // 强制各占一部分段，整文件被慢源拖尾。
        if (isHighParallel() && nsrc > 1) {
            t->setPreferredSourceIdx(i % nsrc);
        }
        threads_.push_back(t);
        threads_pending_launch_.push_back(t);
        start = end + 1;
    }
    AMCL_LOG_I(LOG_TAG, "initSegments: %{public}s size=%{public}lld pieces=%{public}d",
                cfg_.local_path.c_str(), (long long)size, pieces);
}

void NetFile::restoreFromMeta(const DownloadMeta& meta) {
    // 显式 max_connections 也必须约束断点续传。旧版本可能留下 16 个未完成段；若直接
    // 全部恢复，会绕过 client=4 的调用点上限。已完成段只是本地占位，不占网络连接，
    // 因此仅统计未完成段；超限时让 start() 丢弃旧 meta/part 并按新策略重新切片。
    if (cfg_.max_connections > 0) {
        size_t unfinished_segments = 0;
        for (const auto& seg : meta.segments) {
            if (!seg.isFinished()) ++unfinished_segments;
        }
        if (unfinished_segments > static_cast<size_t>(cfg_.max_connections)) {
            AMCL_LOG_I(LOG_TAG,
                "restoreFromMeta: discard %{public}zu unfinished segments above explicit cap %{public}d: %{public}s",
                unfinished_segments, cfg_.max_connections, cfg_.local_path.c_str());
            return;
        }
        target_connections_ = std::min(cfg_.max_connections, kHighParallelMaxConnections);
    }

    if (meta.file_size > 0) {
        file_size_.store(meta.file_size, std::memory_order_release);
    }
    for (const auto& seg : meta.segments) {
        if (seg.isFinished()) {
            // 已完成的段：创建一个 "dummy" 线程，done = length，run 时秒结束
            auto t = std::make_shared<NetThread>(this, seg.start, seg.end, seg.length());
            threads_.push_back(t);
            // 不推进 pending_launch_，稍后 launchMissingThreads 会跳过它
            // 为了统一流程，仍然 push 进去，NetThread run 开头会判 done >= length 直接 Finished
            threads_pending_launch_.push_back(t);
        } else {
            auto t = std::make_shared<NetThread>(this, seg.start, seg.end, seg.done);
            threads_.push_back(t);
            threads_pending_launch_.push_back(t);
        }
    }
    AMCL_LOG_I(LOG_TAG, "restoreFromMeta: %{public}s restored %{public}zu segments",
                cfg_.local_path.c_str(), meta.segments.size());
}

DownloadExceptionPtr NetFile::start() {
    terminal_reported_.store(false, std::memory_order_release);
    {
        std::lock_guard<std::mutex> lk(mu_);
        completed_threads_.clear();
        threads_done_count_.store(0, std::memory_order_release);
    }
    state_.store(NetState::CheckingLocal, std::memory_order_release);

    if (auto ex = validatePaths()) {
        std::lock_guard<std::mutex> lk(mu_);
        error_ = ex;
        state_.store(NetState::Failed, std::memory_order_release);
        return ex;
    }

    if (sources_.empty()) {
        auto ex = makeException(ErrorKind::InvalidConfig, "no URLs provided");
        {
            std::lock_guard<std::mutex> lk(mu_);
            error_ = ex;
        }
        state_.store(NetState::Failed, std::memory_order_release);
        return ex;
    }

    // 1. 已有文件 sha1 预检
    if (auto ex = preCheckExistingFile()) {
        std::lock_guard<std::mutex> lk(mu_);
        error_ = ex;
        state_.store(NetState::Failed, std::memory_order_release);
        return ex;
    }
    if (state_.load(std::memory_order_relaxed) == NetState::Finished) {
        return nullptr;  // preCheck 已经把 state 翻到 Finished
    }

    // 2. 从可信 allowedRoot fd 逐级 no-follow 创建/打开父目录。后续 staging open、
    // durable reopen 和 commit 都复用该 root identity，不再通过绝对路径解析父目录。
    {
        std::lock_guard<std::mutex> lk(fd_init_mu_);
        if (root_fd_ < 0) {
            // 2026-08-04 P0：改走进程级共享池。原实现每个文件独占一个常驻目录 fd，
            // 4750 对象的 assets 任务就是 4750 个 fd，把 socket 号推到 FD_SETSIZE
            // 之上、直接打死 libcurl 的 select 版 Curl_poll（详见本文件 fd 治理注释）。
            int open_errno = 0;
            auto root = TrustedRootFdPool::instance().acquire(cfg_.allowed_root, open_errno);
            if (!root) {
                auto ex = makeException(ErrorKind::FileIoError,
                    "open trusted root failed errno=" + std::to_string(open_errno));
                ex->native_code = open_errno;
                error_ = ex;
                state_.store(NetState::Failed, std::memory_order_release);
                return ex;
            }
            root_fd_holder_ = root;               // 引用计数持有；最后一个持有者才 close
            root_fd_ = root->fd;                  // 借用的 fd，不由本对象负责关闭
            root_device_ = root->dev;
            root_inode_ = root->ino;
        }
        int parent_fd = -1;
        std::string leaf;
        if (!openTrustedParentAt(root_fd_, cfg_.allowed_root, cfg_.local_path,
                                 true, parent_fd, leaf)) {
            int saved = errno;
            auto ex = makeException(ErrorKind::FileIoError,
                "open trusted parent failed errno=" + std::to_string(saved));
            ex->native_code = saved;
            error_ = ex;
            state_.store(NetState::Failed, std::memory_order_release);
            return ex;
        }
        ::close(parent_fd);
    }

    // 3. 尝试从 meta 恢复
    bool restored = false;
    if (auto meta_opt = readMetaFile(metaPath())) {
        struct stat part_st{};
        bool safe_part = ::lstat(staging_path_.c_str(), &part_st) == 0 &&
                         S_ISREG(part_st.st_mode);
        if (safe_part && isMetaCompatible(*meta_opt, cfg_.urls, cfg_.check)) {
            if (meta_opt->file_size > 0) {
                safe_part = part_st.st_size == meta_opt->file_size;
            } else {
                const int64_t checked_done = meta_opt->segments.front().done;
                safe_part = part_st.st_size >= checked_done &&
                            part_st.st_size <= 1LL * 1024 * 1024 * 1024 * 1024;
            }
        }
        if (safe_part && isMetaCompatible(*meta_opt, cfg_.urls, cfg_.check)) {
            restoreFromMeta(*meta_opt);
            restored = !threads_.empty();
            resume_from_meta_ = restored;
        }
        if (!restored) {
            AMCL_LOG_I(LOG_TAG, "meta/part incompatible, discarding: %{public}s",
                        metaPath().c_str());
            ::unlink(metaPath().c_str());
            discardStaging();
        }
    }

    // 4. 若没恢复，清掉任何无匹配 meta 的陈旧/碰撞 staging，再确定 size + 切片。
    if (!restored) {
        discardStaging();
        if (auto ex = determineFileSize()) {
            std::lock_guard<std::mutex> lk(mu_);
            error_ = ex;
            state_.store(NetState::Failed, std::memory_order_release);
            return ex;
        }
        initSegments();
    }

    // 5. v4.2: 不再在这里 open fd——延迟到 NetThread::run() 调 acquireFd() 时打开。
    //    避免 3000+ assets 一次性耗尽进程 fd 配额（默认 ulimit 1024）。
    state_.store(NetState::Downloading, std::memory_order_release);
    return nullptr;
}

// 延迟打开 staging。获取与最后释放统一由 fd_init_mu_ 串行化。
int NetFile::openAndTruncate() {
    const bool first_create = !resume_from_meta_ && !staging_identity_set_;
    int flags = O_WRONLY | O_CLOEXEC;
#ifdef O_NOFOLLOW
    flags |= O_NOFOLLOW;
#endif
    // 新下载必须原子创建，拒绝已有 regular/hardlink 碰撞；后续 fd 重开则通过
    // dev+ino identity 校验确认仍是首次创建的同一个 staging。
    if (first_create) flags |= O_CREAT | O_EXCL;
    int parent_fd = -1;
    std::string final_leaf;
    if (!openTrustedParentAt(root_fd_, cfg_.allowed_root, cfg_.local_path,
                             false, parent_fd, final_leaf)) return -1;
    const std::string staging_leaf = final_leaf + ".amcl.part";
    int new_fd = ::openat(parent_fd, staging_leaf.c_str(), flags, 0644);
    int open_errno = errno;
    ::close(parent_fd);
    if (new_fd < 0) { errno = open_errno; return -1; }
    // staging fd 会活到整段下载结束（跨多个 NetThread），属于长命 fd：挪到 FD_SETSIZE
    // 以上，把低位号留给 libcurl 的 socket。详见本文件顶部 fd 治理注释。
    new_fd = relocateFdAboveFdSetSize(new_fd);
    struct stat st{};
    if (::fstat(new_fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_nlink != 1) {
        int saved = errno == 0 ? EMLINK : errno;
        ::close(new_fd); errno = saved; return -1;
    }
    const uint64_t opened_device = static_cast<uint64_t>(st.st_dev);
    const uint64_t opened_inode = static_cast<uint64_t>(st.st_ino);
    if (staging_identity_set_) {
        if (staging_device_ != opened_device || staging_inode_ != opened_inode) {
            ::close(new_fd);
            errno = ESTALE;
            return -1;
        }
    } else {
        staging_identity_set_ = true;
        staging_device_ = opened_device;
        staging_inode_ = opened_inode;
    }
    int64_t size = file_size_.load(std::memory_order_relaxed);
    int64_t truncate_to = size;
    if (size <= 0 && resume_from_meta_) {
        std::lock_guard<std::mutex> lk(mu_);
        if (threads_.size() != 1 || threads_[0]->start() != 0 || threads_[0]->end() != -1 ||
            threads_[0]->done() < 0) {
            int saved = EINVAL;
            ::close(new_fd);
            errno = saved;
            return -1;
        }
        truncate_to = threads_[0]->done();
    }
    if (truncate_to >= 0 && ::ftruncate(new_fd, truncate_to) != 0) {
        int saved = errno; ::close(new_fd); errno = saved; return -1;
    }
    return new_fd;
}

int NetFile::fd() const {
    std::lock_guard<std::mutex> lk(fd_init_mu_);
    return fd_;
}

int NetFile::fdError() const {
    std::lock_guard<std::mutex> lk(fd_init_mu_);
    return fd_error_;
}

int NetFile::syncStagingDurable() {
    std::lock_guard<std::mutex> lk(fd_init_mu_);
    if (fd_error_ != 0) return fd_error_;

    int sync_fd = fd_;
    bool owns_fd = false;
    if (sync_fd < 0) {
        int flags = O_RDONLY | O_CLOEXEC | O_NONBLOCK;
#ifdef O_NOFOLLOW
        flags |= O_NOFOLLOW;
#endif
        int parent_fd = -1;
        std::string final_leaf;
        if (!openTrustedParentAt(root_fd_, cfg_.allowed_root, cfg_.local_path,
                                 false, parent_fd, final_leaf)) {
            fd_error_ = errno;
            return fd_error_;
        }
        const std::string staging_leaf = final_leaf + ".amcl.part";
        sync_fd = ::openat(parent_fd, staging_leaf.c_str(), flags);
        int open_errno = errno;
        ::close(parent_fd);
        if (sync_fd < 0) {
            fd_error_ = open_errno;
            return fd_error_;
        }
        owns_fd = true;
    }

    struct stat st{};
    int failure = 0;
    if (::fstat(sync_fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_nlink != 1) {
        failure = errno == 0 ? EMLINK : errno;
    }
    if (failure == 0) {
        const uint64_t opened_device = static_cast<uint64_t>(st.st_dev);
        const uint64_t opened_inode = static_cast<uint64_t>(st.st_ino);
        if (staging_identity_set_ &&
            (staging_device_ != opened_device || staging_inode_ != opened_inode)) {
            failure = ESTALE;
        } else if (!staging_identity_set_) {
            staging_identity_set_ = true;
            staging_device_ = opened_device;
            staging_inode_ = opened_inode;
        }
    }
    if (failure == 0) {
        int rc;
        do { rc = ::fsync(sync_fd); } while (rc != 0 && errno == EINTR);
        if (rc != 0) failure = errno;
    }
    if (owns_fd && ::close(sync_fd) != 0 && failure == 0) failure = errno;
    if (failure != 0 && fd_error_ == 0) fd_error_ = failure;
    return failure;
}

int NetFile::acquireFd() {
    std::lock_guard<std::mutex> lk(fd_init_mu_);
    if (fd_ < 0) {
        fd_ = openAndTruncate();
        if (fd_ < 0) {
            fd_error_ = errno;
            return -1;
        }
    }
    ++fd_refcount_;
    return fd_;
}

void NetFile::releaseFd() {
    std::lock_guard<std::mutex> lk(fd_init_mu_);
    if (fd_refcount_ <= 0) return;
    --fd_refcount_;
    if (fd_refcount_ != 0 || fd_ < 0) return;

    if (file_size_.load(std::memory_order_relaxed) <= 0) {
        int64_t actual = downloadedBytes();
        if (::ftruncate(fd_, actual) != 0) {
            if (fd_error_ == 0) fd_error_ = errno;
        } else {
            file_size_.store(actual, std::memory_order_release);
        }
    }
    int rc;
    do { rc = ::fsync(fd_); } while (rc != 0 && errno == EINTR);
    if (rc != 0 && fd_error_ == 0) fd_error_ = errno;
    rc = ::close(fd_);
    if (rc != 0 && fd_error_ == 0) fd_error_ = errno;
    fd_ = -1;
}

std::vector<NetThreadPtr> NetFile::threadsToLaunch() {
    std::lock_guard<std::mutex> lk(mu_);
    auto out = std::move(threads_pending_launch_);
    threads_pending_launch_.clear();
    return out;
}

void NetFile::reportTerminalOnce() {
    bool expected = false;
    if (!terminal_reported_.compare_exchange_strong(expected, true,
                                                     std::memory_order_acq_rel,
                                                     std::memory_order_acquire)) {
        return;
    }
    if (owner_) owner_->reportFileFinished(this);
}

int NetFile::activeSegmentCount() const {
    std::lock_guard<std::mutex> lk(mu_);
    int active = 0;
    for (const auto& t : threads_) {
        if (!t) continue;
        NetState s = t->state();
        if (s == NetState::Connecting || s == NetState::Reading || s == NetState::Downloading) {
            ++active;
        }
    }
    return active;
}

bool NetFile::isExecutionSettled() const {
    std::lock_guard<std::mutex> lk(mu_);
    return std::all_of(threads_.begin(), threads_.end(), [](const NetThreadPtr& thread) {
        return !thread || thread->executionSettled();
    });
}

void NetFile::reportThreadFinished(NetThread* thr) {
    // run()/multi completion 可能先设置终态；只有 worker 已返回或 easy handle 已从
    // CURLM 移除后，markExecutionSettled() 才允许该终态进入文件 barrier。
    if (!thr || !thr->executionTransportSettled()) return;

    size_t completed = 0;
    size_t total = 0;
    {
        std::lock_guard<std::mutex> lk(mu_);
        const auto current = std::find_if(threads_.begin(), threads_.end(),
            [thr](const NetThreadPtr& item) { return item.get() == thr; });
        if (current == threads_.end() || !completed_threads_.insert(thr).second) {
            return;
        }
        completed = completed_threads_.size();
        total = threads_.size();
        threads_done_count_.store(static_cast<int>(completed), std::memory_order_release);
    }

    if (completed >= total) {
        onAllThreadsDone();
        return;
    }

    // v7.4：段完成即补位（IDM「空闲连接立刻接管最大剩余段」）。刚下完这一段的 worker
    // 马上会回队列取下一条，此时若活跃段 < 目标数就切最大剩余段补上——不必等最多 200ms
    // 的 ticker，尾段/中段一直保持满并发。maybeGrowThreads 自身线程安全（同 mu_ + 锁外入队），
    // 且只在文件未完成、必有活跃段的分支调用，不会引发提前终检。
    maybeGrowThreads();
}

void NetFile::onAllThreadsDone() {
    // 检查各线程结果
    bool any_failed = false;
    bool any_aborted = false;
    DownloadExceptionPtr agg_ex;
    {
        std::lock_guard<std::mutex> lk(mu_);
        for (const auto& t : threads_) {
            NetState s = t->state();
            if (s == NetState::Failed) {
                any_failed = true;
                if (!agg_ex) agg_ex = t->error();
            } else if (s == NetState::Aborted) {
                any_aborted = true;
            }
        }
    }

    if (any_aborted) {
        state_.store(NetState::Aborted, std::memory_order_release);
        reportTerminalOnce();
        return;
    }
    if (any_failed) {
        // 本地存储错误不可通过换源修复，也不应惩罚源或消耗网络重试。
        if (agg_ex && (agg_ex->kind == ErrorKind::DiskFullError ||
                       agg_ex->kind == ErrorKind::QuotaExceededError ||
                       agg_ex->kind == ErrorKind::StorageIoError ||
                       agg_ex->kind == ErrorKind::FileIoError)) {
            {
                std::lock_guard<std::mutex> lk(mu_);
                error_ = agg_ex;
            }
            state_.store(NetState::Failed, std::memory_order_release);
            reportTerminalOnce();
            return;
        }

        // 所有源均不支持 Range 时，清理分段数据并退化为单段 full GET。
        bool was_multi = false;
        bool any_range_source = false;
        {
            std::lock_guard<std::mutex> lk(mu_);
            was_multi = threads_.size() > 1;
            for (const auto& src : sources_) {
                if (src && !src->checksum_bad.load(std::memory_order_relaxed) &&
                    !src->no_range_support.load(std::memory_order_relaxed)) {
                    any_range_source = true;
                    break;
                }
            }
        }
        if (was_multi && !any_range_source) {
            discardStaging();
            rebuildSingleSegment();
            state_.store(NetState::Downloading, std::memory_order_release);
            std::vector<NetThreadPtr> retry_threads;
            { std::lock_guard<std::mutex> lk(mu_); retry_threads = threads_; }
            DownloadEngine::instance().enqueueThreads(std::move(retry_threads));
            return;
        }

        // v4.6: 多轮重试（对齐 HMCL/PCL2 的多次重试策略）
        // 所有源可能因瞬时网络抖动或 Mojang 慢连接被标记 is_failed，文件永久失败。
        // 给 kMaxFileRetries 轮重试机会：只重置非 404 源状态，重新入队。
        // 404 源不重置——该镜像确实没这个文件，重试也是 404 浪费时间。
        if (retry_count_ < kMaxFileRetries) {
            retry_count_++;

            // 1. 只重置非 404 源的失败状态（404 源保持 is_failed）
            bool any_source_reset = false;
            {
                std::lock_guard<std::mutex> lk(mu_);
                for (auto& src : sources_) {
                    // 跳过因 HTTP 404 被禁用的源（该镜像确实没这个文件）
                    // C-1 修复：last_error 现在通过 lastError() 走 mutex 保护读
                    auto last_err = src->lastError();
                    if (src->is_failed.load(std::memory_order_relaxed) &&
                        last_err && last_err->http_status == 404) {
                        continue;
                    }
                    if (src->fail_count.load(std::memory_order_relaxed) > 0 ||
                        src->is_failed.load(std::memory_order_relaxed)) {
                        src->fail_count.store(0, std::memory_order_relaxed);
                        src->is_failed.store(false, std::memory_order_relaxed);
                        src->no_range_support.store(false, std::memory_order_relaxed);
                        any_source_reset = true;
                    }
                }
            }

            if (!any_source_reset) {
                // 所有失败源都是 404，没有可重试的源，直接放弃
                AMCL_LOG_W(LOG_TAG, "file retry %{public}d/%{public}d: all failed sources are 404, giving up: %{public}s",
                            retry_count_, kMaxFileRetries, cfg_.local_path.c_str());
            } else {
                // 2. 只重试 Failed 的 thread，保留 Finished 的（多段大文件场景）
                std::vector<NetThreadPtr> retry_threads;
                int already_done = 0;
                bool retry_round_ready = true;
                {
                    std::lock_guard<std::mutex> lk(mu_);
                    // 新执行轮次必须重建 completion identity。已成功段预先计入 barrier；
                    // 待重试段从 settled 重新取得 NetFile keepalive 后才允许入队。
                    completed_threads_.clear();
                    for (auto& t : threads_) {
                        if (t->state() == NetState::Finished) {
                            completed_threads_.insert(t.get());
                            already_done++;
                        } else {
                            if (!t->prepareForRetryExecution()) {
                                retry_round_ready = false;
                                break;
                            }
                            t->setState(NetState::WaitingForSchedule);
                            t->setError(nullptr);
                            retry_threads.push_back(t);
                        }
                    }
                    threads_done_count_.store(already_done, std::memory_order_release);
                }

                if (!retry_round_ready) {
                    AMCL_LOG_E(LOG_TAG,
                        "file retry rejected: previous execution not settled: %{public}s",
                        cfg_.local_path.c_str());
                    retry_threads.clear();
                }

                if (!retry_threads.empty()) {
                    AMCL_LOG_W(LOG_TAG, "file RETRYING %{public}d/%{public}d: %{public}zu/%{public}zu threads (reset non-404 sources): %{public}s",
                                retry_count_, kMaxFileRetries,
                                retry_threads.size(), retry_threads.size() + already_done,
                                cfg_.local_path.c_str());

                    threads_done_count_.store(already_done, std::memory_order_release);

                    // 3. 重新入队
                    state_.store(NetState::Downloading, std::memory_order_release);
                    int64_t fsize = fileSize();
                    bool use_multi = (fsize > 0 && fsize < 1024 * 1024 && retry_threads.size() == 1 && !isHighParallel());
                    if (use_multi) {
                        DownloadEngine::instance().enqueueMulti(std::move(retry_threads));
                    } else {
                        DownloadEngine::instance().enqueueThreads(std::move(retry_threads));
                    }
                    return;  // 不上报完成，等重试结果
                }
            }
        }

        // 末路兜底：分段下载彻底失败时，退化为单段整文件 GET 再试一次。
        // 实测部分源（如 forgecdn 对含 '+' 文件名的对象）对 Range 请求返回 404、416，
        // 却能对整文件 GET 返回 200；也可能是代理/边缘节点对 Range 的其它不兼容。整文件 GET
        // 兼容性最强，作为最后一搏能救回这类源。一次性（single_segment_fullget_tried_）且仅
        // 从多段收敛，避免循环；复位非 checksum_bad 源的瞬时失败/Range 标记让整文件 GET 重新选它们。
        if (was_multi && !single_segment_fullget_tried_) {
            single_segment_fullget_tried_ = true;
            bool have_usable = false;
            {
                std::lock_guard<std::mutex> lk(mu_);
                for (auto& src : sources_) {
                    if (!src || src->checksum_bad.load(std::memory_order_relaxed)) continue;
                    // 坏内容源（checksum_bad）保持排除；其余复位瞬时状态供整文件 GET 重选。
                    src->fail_count.store(0, std::memory_order_relaxed);
                    src->is_failed.store(false, std::memory_order_relaxed);
                    src->no_range_support.store(false, std::memory_order_relaxed);
                    src->cooldown_until_ms.store(0, std::memory_order_relaxed);
                    src->failed_until_ms.store(0, std::memory_order_relaxed);
                    have_usable = true;
                }
            }
            if (have_usable) {
                AMCL_LOG_W(LOG_TAG,
                    "multi-segment download failed on all sources; falling back to single full-GET: %{public}s",
                    cfg_.local_path.c_str());
                discardStaging();
                rebuildSingleSegment();
                state_.store(NetState::Downloading, std::memory_order_release);
                std::vector<NetThreadPtr> retry_threads;
                { std::lock_guard<std::mutex> lk(mu_); retry_threads = threads_; }
                DownloadEngine::instance().enqueueThreads(std::move(retry_threads));
                return;
            }
        }

        // 达到最大重试次数，真正放弃
        {
            std::lock_guard<std::mutex> lk(mu_);
            error_ = agg_ex ? agg_ex : makeException(ErrorKind::InternalError, "thread failed");
            // v5: 把所有试过的源 URL 灌进异常对象，供 NAPI 上报给 UI
            if (error_) {
                for (const auto& s : sources_) {
                    // 去重插入
                    bool seen = false;
                    for (const auto& u : error_->tried_urls) {
                        if (u == s->url) { seen = true; break; }
                    }
                    if (!seen) error_->tried_urls.push_back(s->url);
                }
            }
        }
        state_.store(NetState::Failed, std::memory_order_release);
        reportTerminalOnce();
        return;
    }

    // 全部 Finished：做最终 sha1 校验
    state_.store(NetState::FinalCheck, std::memory_order_release);

    // 最后一个 NetThread 的 releaseFd 已完成 ftruncate/fsync/close；任何延迟错误阻止成功。
    if (int e = fdError(); e != 0) {
        auto ex = makeException(storageErrorKind(e),
                                "fsync/close failed errno=" + std::to_string(e));
        ex->native_code = e;
        {
            std::lock_guard<std::mutex> lk(mu_);
            error_ = ex;
        }
        state_.store(NetState::Failed, std::memory_order_release);
        reportTerminalOnce();
        return;
    }

    // 如果 file_size_ 之前是 -2（HEAD 失败的 fallback），现在下完了可以
    // 用累计的 downloadedBytes 更新，方便 UI 展示"总字节"。
    if (file_size_.load(std::memory_order_relaxed) <= 0) {
        file_size_.store(downloadedBytes(), std::memory_order_release);
    }

    if (cfg_.check.needsAnyCheck()) {
        DownloadExceptionPtr ex;

        // v4.6: 单段文件用增量 SHA1 快速校验（对齐 PCL2 内存缓存策略）
        // 3000+ asset 文件每个 fopen+fread+sha1+fclose → 数千次阻塞 syscall 堵住事件循环
        // 增量 SHA1 在 onWrite 中已算好，checkFast 只需 stat + strcmp，零文件 re-read
        bool used_fast_path = false;
        {
            std::lock_guard<std::mutex> lk(mu_);
            if (!resume_from_meta_ && threads_.size() == 1 && threads_[0]->isSingleSegment() &&
                threads_[0]->canUseFastHash() &&
                threads_[0]->state() == NetState::Finished &&
                !cfg_.check.expected_sha1.empty()) {
                std::string precomputed = threads_[0]->finalSha1();
                ex = cfg_.check.checkFast(staging_path_, precomputed);
                used_fast_path = true;
            }
        }

        // 多段文件或无 SHA1 要求时：传统 re-read 校验（libraries、client.jar 等大文件）
        if (!used_fast_path) {
            ex = cfg_.check.check(staging_path_);
        }

        if (ex) {
            // 校验失败：删 meta + 删损坏 staging，并重置 inode identity 后再重试。
            ::unlink(metaPath().c_str());
            discardStaging();

            // v4.7: 多段下载 SHA1 失败时，退化为单段重试（不消耗 retry_count_）
            // 原因：某些 CDN（如 BMCLAPI 镜像）对 Range 请求返回错误数据，
            // 导致拼接后大小正确但 SHA1 不匹配。退化为 full GET 可避免此问题。
            bool was_multi_segment = false;
            {
                std::lock_guard<std::mutex> lk(mu_);
                was_multi_segment = threads_.size() > 1;
            }

            if (was_multi_segment && sha1_fallback_to_single_ == 0) {
                sha1_fallback_to_single_++;
                AMCL_LOG_W(LOG_TAG, "final check FAILED (multi-seg, fallback to single-seg): %{public}s: %{public}s",
                            cfg_.local_path.c_str(), ex->toString().c_str());

                // 重建为单段线程
                {
                    std::lock_guard<std::mutex> lk(mu_);
                    threads_.clear();
                    completed_threads_.clear();
                    auto t = std::make_shared<NetThread>(this, 0, -1, 0);
                    threads_.push_back(t);
                    threads_done_count_.store(0, std::memory_order_release);
                    error_ = nullptr;
                    resume_from_meta_ = false;
                }
                { std::lock_guard<std::mutex> fd_lk(fd_init_mu_); fd_error_ = 0; }

                // 重置所有源的失败状态
                {
                    std::lock_guard<std::mutex> lk(mu_);
                    for (auto& src : sources_) {
                        src->fail_count.store(0, std::memory_order_relaxed);
                        src->is_failed.store(false, std::memory_order_relaxed);
                        src->no_range_support.store(false, std::memory_order_relaxed);
                    }
                }

                state_.store(NetState::Downloading, std::memory_order_release);

                // 入队单段线程
                std::vector<NetThreadPtr> retry_threads;
                {
                    std::lock_guard<std::mutex> lk(mu_);
                    retry_threads = threads_;
                }

                int64_t fsize = fileSize();
                bool use_multi = (fsize > 0 && fsize < 1024 * 1024 && retry_threads.size() == 1 && !isHighParallel());
                if (use_multi) {
                    DownloadEngine::instance().enqueueMulti(std::move(retry_threads));
                } else {
                    DownloadEngine::instance().enqueueThreads(std::move(retry_threads));
                }
                return;  // 等待单段重试结果
            }

            // AMCL: SHA1 终检失败换源。到这里说明：要么本就单段（如 log4j 1.79MB < 2MB
            // 不分段，跳过了上面的多段→单段退化），要么多段退化后单段仍校验失败。此时
            // 大概率是"当前源交付的内容不对"（如某镜像给了 Log4Shell 补丁版 log4j，而
            // Forge 期望 Maven Central 原版哈希）。把交付坏内容的源标记 checksum_bad
            // （pickBestSource 永久跳过、不被瞬时失败重置清除），换下一个未排除源重下。
            // 仅 ChecksumMismatch 触发（size 不符走线程内 SizeMismatch 逻辑）；bounded。
            if (ex->kind == ErrorKind::ChecksumMismatch
                    && checksum_source_swaps_ < kMaxChecksumSourceSwaps) {
                // 定位交付坏内容的源：单段场景 = 唯一线程的 lastUsedSource。
                NetSourcePtr culprit;
                {
                    std::lock_guard<std::mutex> lk(mu_);
                    if (threads_.size() == 1 && threads_[0]) {
                        culprit = threads_[0]->lastUsedSource();
                    }
                }
                if (culprit) {
                    culprit->checksum_bad.store(true, std::memory_order_release);
                    // 统计还剩几个未排除（非 checksum_bad）的源。
                    int usable = 0;
                    {
                        std::lock_guard<std::mutex> lk(mu_);
                        for (const auto& s : sources_) {
                            if (s && !s->checksum_bad.load(std::memory_order_relaxed)) usable++;
                        }
                    }
                    if (usable > 0) {
                        checksum_source_swaps_++;
                        AMCL_LOG_W(LOG_TAG,
                            "checksum mismatch from source %{public}s; marked bad, swapping source "
                            "(swap %{public}d/%{public}d, %{public}d usable left): %{public}s",
                            culprit->url.c_str(), checksum_source_swaps_, kMaxChecksumSourceSwaps,
                            usable, cfg_.local_path.c_str());

                        // 重建单段线程（与多段→单段退化同款），并重置其余源的"瞬时失败态"
                        // 给它们再次机会；但 checksum_bad 保持不清，pickBestSource 仍跳过坏源。
                        {
                            std::lock_guard<std::mutex> lk(mu_);
                            threads_.clear();
                            completed_threads_.clear();
                            auto t = std::make_shared<NetThread>(this, 0, -1, 0);
                            threads_.push_back(t);
                            threads_done_count_.store(0, std::memory_order_release);
                            error_ = nullptr;
                            resume_from_meta_ = false;
                            for (auto& src : sources_) {
                                if (!src) continue;
                                src->fail_count.store(0, std::memory_order_relaxed);
                                src->is_failed.store(false, std::memory_order_relaxed);
                                src->no_range_support.store(false, std::memory_order_relaxed);
                                // checksum_bad 不重置：坏内容源在本文件生命周期内持续排除。
                            }
                        }

                        state_.store(NetState::Downloading, std::memory_order_release);
                        std::vector<NetThreadPtr> retry_threads;
                        {
                            std::lock_guard<std::mutex> lk(mu_);
                            retry_threads = threads_;
                        }
                        int64_t fsize = fileSize();
                        bool use_multi = (fsize > 0 && fsize < 1024 * 1024 && retry_threads.size() == 1 && !isHighParallel());
                        if (use_multi) {
                            DownloadEngine::instance().enqueueMulti(std::move(retry_threads));
                        } else {
                            DownloadEngine::instance().enqueueThreads(std::move(retry_threads));
                        }
                        return;  // 等待换源重试结果
                    }
                    AMCL_LOG_W(LOG_TAG,
                        "checksum mismatch: all sources excluded (no usable left), giving up: %{public}s",
                        cfg_.local_path.c_str());
                }
            }

            {
                std::lock_guard<std::mutex> lk(mu_);
                error_ = ex;
            }
            state_.store(NetState::Failed, std::memory_order_release);
            AMCL_LOG_E(LOG_TAG, "final check FAILED (%{public}s, deleted): %{public}s: %{public}s",
                         used_fast_path ? "incremental" : "re-read",
                         cfg_.local_path.c_str(), ex->toString().c_str());
            reportTerminalOnce();
            return;
        }
    }

    // 校验通过后才原子发布；rename 与父目录 fsync 任一失败都阻止成功。
    if (auto ex = syncCloseAndCommit()) {
        {
            std::lock_guard<std::mutex> lk(mu_);
            error_ = ex;
        }
        state_.store(NetState::Failed, std::memory_order_release);
        reportTerminalOnce();
        return;
    }
    ::unlink(metaPath().c_str());
    state_.store(NetState::Finished, std::memory_order_release);
    AMCL_LOG_I(LOG_TAG, "file finished: %{public}s", cfg_.local_path.c_str());
    if (owner_) owner_->reportFileFinished(this);
}

DownloadExceptionPtr NetFile::finalize() {
    // 此方法目前主要在 onAllThreadsDone 里被内联，外部一般不显式调
    return error();
}

// ============================================================================
// v4.10 自适应分段（PCL2 ModNet 风格的"速度不足就追加线程"）
// ============================================================================

// 段数硬上限（含已完成段）。v7.2：48→16，防止自适应在连接建立期把段 churn 到几十条
// （实测几十条段会把官方 CDN 的并发 TLS 握手打爆、互相抢带宽反而更慢）。16 条足够把
// 单连接 ~180KB/s 叠加到 ~2-3MB/s，对齐 PCL2 的合理并发区间。
static constexpr int     kAdaptiveMaxThreads     = 16;
// 只对剩余 >= 此值的大段做拆分。v7.6：回到均衡的 256KB（1MB 太大→慢连接霸占大段不被切、
// 聚合被慢长杆拖住更慢；128KB 太小→高 TTFB 代理下碎片化 TTFB 浪费）。256KB 配合下面「按 ETA
// 最差选段 + 减半切」：只切真正拖后腿的慢长杆、且不切成碎片。
static constexpr int64_t kAdaptiveMinSplitBytes  = 256 * 1024;
// 只对 >= 此大小的文件启用自适应。v6：4MB→1MB，让模组（多 1~3MB）也能享受"慢就加线程"。
// 仍 >0，<1MB 的小文件走 MultiDownloader 64 路并发，不需要单文件分段。
static constexpr int64_t kAdaptiveMinFileBytes   = 1 * 1024 * 1024;

// 「停滞段」阈值：段处于 Connecting/Reading/Downloading 但 done==0 且本轮 transfer 已超过
// 此时长 = 一直没拿到任何字节（典型：被 HTTP 429 反复拒绝、每次瞬间失败后退避 sleep）。
// 取 12s：既明显长于正常 TTFB（代理实测 3~10s）+ 一两轮退避，又不至于让真正卡住的段
// 长时间霸占并发名额。
static constexpr int64_t kStalledSegmentMs       = 12 * 1000;

// ============================================================================
//  切分下界（2026-07-29，修复「前面 MB 级、后面只剩 KB 级」）
// ============================================================================
//
// 每个段 = 一次独立 HTTP 请求，固定成本无法摊薄：
//   · TTFB ≈ 290ms（代理转发 GitHub，真机实测 ttfb_ms=240~290）；
//   · TCP 慢启动：连接刚建立时拥塞窗口很小，要若干个 RTT 才能涨到满速。
// 真机对照（同一个 gh-proxy.com、ttfb 几乎相同，仅段大小不同）：
//   7.3MB 大段 → KBps=2472（2.4MB/s）
//   176KB 碎片 → KBps=57、total_ms=3376（≈52KB/s，与 176KB/3.4s 完全吻合）
// 即「后段只有 KB 级」不是网络退化、也不是代理限速，而是**段被切成碎片后
// TTFB 占比失控**：290ms 握手只换来 176KB 数据。
//
// 因此切分必须有下界：新段不得小于 kMinSplitPieceBytes，且只有剩余量足够切出
// 两个这么大的块时才允许切（否则切完必然产生碎片）。2MB 使 TTFB 占比 <15%，
// 且足够让 TCP 窗口打开。
static constexpr int64_t kMinSplitPieceBytes     = 2 * 1024 * 1024;

// 「收尾阶段」不再一刀切禁止拆分，而是要求剩余慢段的 ETA 足以覆盖新连接成本。
// 8MiB 只定义进入收益判断的范围；快尾段继续原连接，慢尾段才允许空闲连接接管。
static constexpr int64_t kEndgameRemainBytes          = 8 * 1024 * 1024;
static constexpr double  kEndgameMinSplitEtaSeconds   = 8.0;
// 慢尾段接管时，旧慢连接仅保留 256KiB（无新握手成本），新连接至少接管 1MiB，
// 避免再次制造真机上已经证实会被 TTFB 吞噬的 170~450KiB 新请求。
static constexpr int64_t kStragglerKeepBytes          = kAdaptiveMinSplitBytes;
static constexpr int64_t kStragglerMinNewBytes        = 1 * 1024 * 1024;
static constexpr int64_t kStragglerMinSampleMs        = 2500;



void NetFile::maybeGrowThreads() {
    // 廉价快筛（无锁）：绝大多数文件（已完成 / 等待 / 小文件）在这里直接返回，
    // 不进临界区。一个任务里同时处于 Downloading 的大文件通常只有个位数。
    if (state_.load(std::memory_order_relaxed) != NetState::Downloading) return;
    // Without an integrity checker, a dynamically split boundary cannot be proven
    // equivalent after retries/source changes. Keep the original non-overlapping plan.
    if (!cfg_.check.needsAnyCheck()) return;
    int64_t fsize = file_size_.load(std::memory_order_relaxed);
    if (fsize < kAdaptiveMinFileBytes) return;

    // ========================================================================
    //  速度门控：PCL2 的规则 + 自校准地板 + 螺旋刹车
    // ========================================================================
    //
    // PCL2 原式（`ModNet.vb:1825`）：`If Speed >= NetTaskSpeedLimitLow Then Continue While`，
    // `NetTaskSpeedLimitLow = 256 * 1024L`（`ModNet.vb:395`）—— 跑得够快就一条也不多加。
    // 直接照搬这个**固定** 256KB/s 地板在本项目上偏低，真机实测（2026-07-31 00:00，client.jar
    // 37.4MB/18.6s）：4 个初始段前 5 秒各跑 1675~2114KB/s（聚合 ≈5.4MB/s），3 段收工后剩下
    // 那一段独自跑了 13.5 秒、577KB/s —— 此时聚合 577KB/s 仍 > 256KB/s，固定地板把**本该做的
    // 尾段救援**也一起挡住了，总耗时被这条长尾决定。
    //
    // 所以地板改成**自校准**：`max(256KB/s, 本文件历史峰值 / 2)`。文件自己证明过能跑 5.4MB/s，
    // 那么掉到 2.7MB/s 以下就说明有段在拖后腿，值得补连接；而慢链路上峰值本来就低，地板自动
    // 退化回 256KB/s，行为与 PCL2 一致。
    //
    // 配套**螺旋刹车**（必须有）：本设备网络上同一 CDN 的并发越多越慢，实测
    //   4 连接 21.8s(1.71MB/s) → 9 连接 43.2s(0.86MB/s) → 12 连接 92.5s(0.42MB/s)，
    // 纯"慢就加"会形成正反馈死螺旋。因此每次补段都记下当时速度，下次进来若没有比上次改善
    // 10% 以上就记一次退化，连续两次退化即**永久停止本文件的补段**（见下方 growth_disabled_）。
    //
    // ⚠️ 两个实现约束：
    //   · 必须用 recentFileSpeedBps()（累计字节时间差）而不是各段瞬时速率求和 —— 后者在段处于
    //     TTFB（真机 1~4.4s）时假性跌到 0，用它做门控等于给死螺旋点火；
    //   · 必须在取 mu_ **之前**调用（它内部会取 mu_）。
    static constexpr int64_t kGrowthSpeedFloorBps = 256 * 1024;   // = PCL2 NetTaskSpeedLimitLow
    const int64_t cur_speed = recentFileSpeedBps();
    {
        int64_t peak = peak_speed_bps_.load(std::memory_order_relaxed);
        while (cur_speed > peak &&
               !peak_speed_bps_.compare_exchange_weak(peak, cur_speed,
                                                      std::memory_order_relaxed)) {
        }
    }
    const int64_t growth_floor = std::max<int64_t>(
        kGrowthSpeedFloorBps, peak_speed_bps_.load(std::memory_order_relaxed) / 2);
    if (cur_speed >= growth_floor) return;

    NetThreadPtr new_thread;
    {
        std::lock_guard<std::mutex> lk(mu_);

        // 统计活跃段 + 找「ETA 最差（剩余/速度最大）的慢长杆段」。
        // v7.6：从「切最大段」改为「切最慢段」（IDM「优先切慢段」的真正做法）。根因（hdc
        // 日志）：初始大段落在慢代理连接上（如 5MB@43KB/s 跑 112s）会长时间霸占，聚合被这几条
        // 慢长杆拖住；只按「最大剩余」选段会误切另一条其实很快的段。改按 ETA=剩余/速度 选最慢的，
        // 把它的尾部减半交给一条全新连接（大概率更快）→ 慢长杆完成时间直接砍半。
        // v7.3：段数上限按【活跃段】计数（不含已完成段），慢尾段可持续被切给最多 16 条新连接。
        int        downloading = 0;
        int        preparing   = 0;
        int        stalled     = 0;   // 长时间没拿到任何字节的段（典型：被 429 反复拒绝）
        int64_t    speed       = 0;
        NetThread* worst        = nullptr;   // ETA 最差（最慢长杆）的可拆段
        int64_t    worst_undone = 0;
        double     worst_eta    = -1.0;
        bool       worst_is_straggler = false;
        bool       worst_has_stable_sample = false;
        const int64_t now_ms = netThreadSteadyNowMs();
        // ⚠️ 2026-07-29：识别「停滞段」并把它从并发名额里剔除。
        //   根因（真机日志 + 代码核对）：NetState::Downloading 只在 onWrite 首次写入成功时
        //   由 CAS 设置（net_thread.cpp），且**没有任何地方设回**。被 HTTP 429 反复拒绝的段
        //   永远收不到响应体 → onWrite 从不触发 → 状态停留在 performOnce 设的 Reading
        //   （退避 sleep 期间也不改状态）。于是它被计入 preparing，触发下面两道门槛：
        //       if (downloading + preparing >= target) return;             // 名额被占满
        //       if (downloading == 0 || preparing > downloading) return;   // 或直接挡死
        //   → maybeGrowThreads 再也补不了段；而 worst 只从 Downloading 段里挑，
        //   这些段持有的字节区间既不被切分转移、也无人接手 → 表现为"后段极慢/几乎不动"。
        //   注意：429 是**瞬间返回**（实测 ttfb≈240ms），不触发 stall 看门狗（那个只管
        //   "连上却不吐字节"的挂死连接），所以必须在这里按"久未取得字节"判定。
        for (auto& t : threads_) {
            NetState ts = t->state();
            bool is_stalled = false;
            if (ts == NetState::Reading || ts == NetState::Connecting || ts == NetState::Downloading) {
                // done==0 且距本轮 transfer 起点已超阈值 = 一直没拿到任何字节。
                int64_t base = t->transferStartMs();
                if (t->done() <= 0 && base > 0 && now_ms - base > kStalledSegmentMs) {
                    is_stalled = true;
                }
            }
            if (is_stalled) {
                stalled++;
                // ⚠️ 2026-07-29 修正（回退我上一轮的错误做法）：
                //   停滞段**不再**参与切分竞选。此前把它纳入 worst 且 ETA 视为极大值，
                //   使它总是优先被切；但停滞段的本质是 done==0、**源不可用**（429/连不上），
                //   切它毫无意义 —— 新段仍会撞同一批被限流的代理，只是把尾巴切得更碎。
                //   真机后果：32 次切分把尾段切成 170~450KB 的碎片，每段付 290ms TTFB
                //   却只搬 176KB → 有效吞吐塌到 52KB/s，形成"越慢越切、越切越慢"的正反馈。
                //   正确处置：只把它从并发名额里剔除（下面 continue），让 NetThread 自己
                //   走换源/退避重试；名额释放给健康段或新段。
                continue;   // 不计入 downloading / preparing，也不作为切分候选
            }
            if (ts == NetState::Downloading) {
                downloading++;
                int64_t sp = t->recentSpeedBps();
                speed += sp;
                int64_t e = t->end();
                if (e >= t->start()) {  // 仅 Range 段可拆（全量段 end<0 跳过）
                    int64_t undone = e - (t->start() + t->done()) + 1;
                    const int64_t sample_age = t->transferStartMs() > 0
                        ? now_ms - t->transferStartMs() : 0;
                    const bool stable_sample = sp > 1024 && sample_age >= kStragglerMinSampleMs;
                    // 常规段仍要求切完两侧都至少 2MiB。收尾慢段则采用“接管”而非均分：
                    // 已有慢连接保留 256KiB，新连接接管至少 1MiB；且必须已有段完成、
                    // 有稳定速度样本、剩余 ETA >= 8s，避免冷启动或快尾段被误切。
                    const bool regular_split = undone >= 2 * kMinSplitPieceBytes;
                    const double eta = static_cast<double>(undone) /
                        static_cast<double>(sp > 1024 ? sp : 1024);
                    const bool straggler_takeover = !regular_split &&
                        !completed_threads_.empty() && stable_sample &&
                        undone >= kStragglerKeepBytes + kStragglerMinNewBytes &&
                        eta >= kEndgameMinSplitEtaSeconds;
                    if ((regular_split || straggler_takeover) && eta > worst_eta) {
                        worst_eta = eta;
                        worst = t.get();
                        worst_undone = undone;
                        worst_is_straggler = straggler_takeover;
                        worst_has_stable_sample = stable_sample;
                    }
                }
            } else if (ts == NetState::Connecting || ts == NetState::Reading) {
                preparing++;
            }
        }

        // ========================================================================
        //  速度门控（恢复 PCL2 的核心规则；1000368 曾把它删掉，这是本轮回归的真因）
        // ========================================================================
        //
        // PCL2 `ModNet.vb:1825`（StartManager 的 ThreadStarter）在给**进行中的文件**追加
        // 线程之前只有一句：
        //     If Speed >= NetTaskSpeedLimitLow Then Continue While '下载速度足够，无需新增
        // 其中 `NetTaskSpeedLimitLow = 256 * 1024L`（`ModNet.vb:395`）。也就是说 PCL2 的
        // 多线程是**救急手段**：跑得够快就一条连接也不多加；只有慢下来才去切最大剩余段。
        // 配套还有 `ModNet.vb:928-930`——源是 bmclapi / github / optifine 这类时
        // `Return Nothing`，**永远不追加线程**。
        //
        // 1000368 把这条地板门控改成了"目标并发驱动"（"去掉速度地板门控，改为目标并发驱动"），
        // 从此只要活跃段 < target 就无条件补连接。真机实测这在本设备网络上是净损失，
        // 因为同一 CDN 的并发越多越慢（典型的 per-IP 限流）：
        //   2026-07-30 22:53  4 连接   37.4MB / 21.8s = 1.71 MB/s
        //   2026-07-30 23:50  9 连接   37.4MB / 43.2s = 0.86 MB/s
        //   2026-07-30 23:36  12 连接  37.4MB / 92.5s = 0.42 MB/s
        // 而设备 shell 裸 openssl 单连接对同一 URL 是 1378 KB/s —— 4 条并发（1.71MB/s）
        // 只比单条好一点，再往上就是**倒退**，形成"越慢越切、越切越慢"的正反馈死螺旋。
        //
        // ⚠️ 同时纠正一处此前的误判：曾以 2026-07-15 的 `client.jar 36.3MB/4.0s = 8.99MB/s`
        //   作为"以前很快"的基线并据此放开并发。复核同一 run 的兄弟阶段后确认那是**缓存命中**
        //   而非网络下载：同批 `libraries 46 files 60.4MB/1.716s = 35MB/s`、
        //   `assets 4750 files 453MB/22.5s = 20MB/s`，这两个速度物理上不可能来自网络，
        //   说明整个 run 都走了 sha1 预检短路。真实网络上限就是上面那组数。
        //
        // 与 PCL2 的唯一偏差：这里用**本文件**的聚合速度而不是全局速度做判据，更有针对性
        //（一个已经跑到 1.7MB/s 的文件不该再加连接，哪怕别的文件很慢）。
        //
        // 门控本体已上移到函数开头的无锁快筛区（用 recentFileSpeedBps()，见那里的注释）。
        // 本地累加的 `speed` 只保留给日志展示，**不**再用于补段判定 —— 它是各段 200ms
        // 瞬时速率之和，段处于 TTFB 时会假性跌到 0，用它做门控等于给死螺旋点火。

        // PCL2 的第二条规则（`ModNet.vb:928-930`）：新线程要用的源属于
        // bmclapi / github / optifine.net / momot.rs / pcl2-server / meloong.com 时
        // `Return Nothing` —— 这些源对多连接的反应是限流，越并发越慢，一条也不多加。
        // 我们在 initSegments 里已有「全部源都不友好 → 强制单段」，但补段路径此前漏了同款
        // 判断：只要还有一个友好源就会持续补段，而实际接管的连接可能又落回不友好源。
        // 这里按同样口径拦住：当前可用源全是不友好主机时不再补段。
        {
            bool any_friendly_usable = false;
            for (const auto& s : sources_) {
                if (!s) continue;
                if (s->checksum_bad.load(std::memory_order_relaxed)) continue;
                if (s->is_failed.load(std::memory_order_relaxed)) continue;
                if (!isMultiThreadUnfriendlyHost(s->url)) { any_friendly_usable = true; break; }
            }
            if (!any_friendly_usable) return;
        }

        // ========================================================================
        //  防死螺旋：硬上限，而不是"猜因果"
        // ========================================================================
        //
        // ⚠️ 2026-07-31：**删除**上一版基于"补段后速度没改善 10% 就记退化、两次退化即永久
        //   禁用"的刹车。它在真机上误触发得非常离谱（00:17:38.308 → 00:17:39.188，**下载开
        //   始 8 秒**就把补段永久关掉），随后长尾无人接管，同一文件从 11.0s 退化到 47.1s：
        //     00:17:38.308 split(1->2) file_speed=3711964  → 记 speed_at_last_growth_
        //     00:17:38.786 split(2->3) file_speed=2016378  → 判"未改善" = 退化 1
        //     00:17:39.188 growth disabled  speed=2016378 last=2016378 → 退化 2 → 永久禁用
        //   两处硬伤：① 两次补段只隔 478ms，而速度采样窗口是 500ms，`recentFileSpeedBps()`
        //   返回的是**同一个缓存值**，于是"未改善"必然成立；② 新连接的 TTFB 实测 1~2s，
        //   在 478ms 后去评价它"有没有帮上忙"，本身就没有意义。
        //   更根本的是：收尾期段陆续完成，聚合速度**天然下降**，"未改善"是常态而非病态，
        //   拿它当因果判据从一开始就是错的。
        //
        // 换成不需要因果推断的两道硬约束：
        //   ① 默认路径（调用方未显式给上限，如 client.jar）活跃段硬上限 6。真机实测本设备
        //      网络上同一 CDN 并发越多越慢：4 连接 21.8s(1.71MB/s) → 9 连接 43.2s(0.86MB/s)
        //      → 12 连接 92.5s(0.42MB/s)；而表现最好的 11.0s(3.41MB/s) 那次活跃段峰值是 5。
        //      6 给尾段接管留了余量，又不会滑到 9+ 的倒退区间。
        //   ② 两次补段之间至少间隔 kGrowthGraceMs，让新连接付完 TTFB、窗口 ramp 起来再考虑
        //      下一条，避免 478ms 内连开三条的握手风暴。
        static constexpr int  kDefaultPathMaxActive = 6;
        static constexpr int64_t kGrowthGraceMs     = 1200;
        if (!isHighParallel() && cfg_.max_connections == 0 &&
            (downloading + preparing) >= kDefaultPathMaxActive) {
            return;
        }
        if (last_split_ms_ > 0 && now_ms - last_split_ms_ < kGrowthGraceMs) return;

        // v7.4：目标并发驱动（IDM/aria2 式「保持 N 条连接满负荷」）——只要活跃段(下载中+
        // 准备中) < 目标数就补段，**不再要求速度低于地板**。目标由 initSegments 按文件大小/模式设定。
        int target = target_connections_ > 0 ? target_connections_ : kAdaptiveMaxThreads;
        if (target > kAdaptiveMaxThreads) target = kAdaptiveMaxThreads;  // 硬上限兜底
        // 对 1..默认段数 的纯上限模式，停滞段仍占调用方预算：即使它正在退避，也不能
        // 通过“剔除停滞段”把 client=4 再扩成 5+ 条连接。默认/高并发路径保留原补位策略。
        int active_for_target = downloading + preparing;
        if (cfg_.max_connections > 0 && !isHighParallel()) active_for_target += stalled;

        // 小慢段接管只复用初始分段释放出的连接槽，不借默认 8/16 目标额外扩张。
        //
        // ⚠️ 2026-07-30：该收紧**只在调用方显式给了硬上限时**生效（`max_connections > 0`，
        //   如 JdkInstaller 的 1）。原实现对 `max_connections == 0` 的默认路径也套用
        //   `replacement_target = piece_limit(4)`，后果是收尾期彻底停止补段：
        //
        //   真机实测（2026-07-30 23:36:32~23:38:05，client.jar 39MB 用了 92.5s）：
        //     23:36:35~23:36:43  balanced 拆段，active 一路涨到 12（目标 16 正常工作）
        //     23:37:08.695       mode=straggler active=3->4 —— 最后一次拆段
        //     23:37:08 → 23:38:05  **57 秒零动作**：没有拆段、没有新连接、没有段完成
        //   同期 `perform PERF` 抓到那条僵尾：`bmclapi KBps=7 total_ms=82980`
        //   （单条连接跑了 83 秒、7KB/s），另有 `KBps=56 total_ms=45305`、
        //   `KBps=52 total_ms=50439`。也就是 92.5s 里约 57s 是被 3~4 条僵尾连接独占。
        //   原因：收尾期 ETA 最差的候选几乎必然落进 straggler 分支 → effective_target
        //   被压回 4 → `active_for_target(3~4) >= 4` 直接 return，再也不补段；而低速看门狗
        //   是 1KB/s 绝对地板、stall 看门狗要求 20s 零字节，7KB/s 的僵尾两条都躲得过。
        //
        //   放开后仍有多重保护，不会退回 07-16 那种碎片化：`kStragglerKeepBytes` 保留
        //   256KB 给旧连接、新段至少 `kStragglerMinNewBytes(1MiB)`、ETA 必须 ≥8s
        //   （`kEndgameMinSplitEtaSeconds`）、要求已有稳定速度样本、每 400ms 全局最多切一条、
        //   段总数 ≤48。
        int effective_target = target;
        if (worst_is_straggler && cfg_.max_connections > 0 && !isHighParallel()) {
            int replacement_target = std::max(1, cfg_.piece_limit);
            replacement_target = std::min(replacement_target, cfg_.max_connections);
            int64_t fsz_now = file_size_.load(std::memory_order_relaxed);
            if (fsz_now > 0 && cfg_.piece_min_bytes > 0) {
                int64_t pieces_by_size = (fsz_now - 1) / cfg_.piece_min_bytes + 1;
                replacement_target = static_cast<int>(std::min<int64_t>(
                    replacement_target, std::max<int64_t>(1, pieces_by_size)));
            }
            effective_target = std::min(effective_target, replacement_target);
        }
        if (active_for_target >= effective_target) return;

        // 收尾不再按固定 8MiB 硬拒绝。进入该范围后，仅当候选段已有稳定样本且
        // ETA 至少 8 秒才值得支付一次新连接成本；快尾段继续沿用已热身的连接。
        {
            int64_t fsz_now = file_size_.load(std::memory_order_relaxed);
            if (fsz_now > 0) {
                int64_t done_now = 0;
                for (const auto& t : threads_) done_now += std::max<int64_t>(0, t->done());
                int64_t remaining_now = std::max<int64_t>(0, fsz_now - done_now);
                if (remaining_now <= kEndgameRemainBytes &&
                    (!worst_has_stable_sample || worst_eta < kEndgameMinSplitEtaSeconds)) {
                    return;
                }
            }
        }

        // ⚠️ 段总数硬上限：download_meta 的 validateMeta 限制 kMaxSegments=64，
        //   一旦 threads_ 超过它，writeMetaFile 会持续判非法 → 连败 3 次即被
        //   reportMetaPersistenceResult 判为 StorageIoError 把整个任务打死
        //   （真机曾在 94.5% 处因段爆炸触发）。留出余量停在 48。
        static constexpr size_t kMaxSegmentsForMeta = 48;
        if (threads_.size() >= kMaxSegmentsForMeta) return;

        // 切分全局节流（同上：本函数会被 worker + ticker 并发进入）。持 mu_ 检查并抢占
        // 时间戳，保证任意 kMinSplitIntervalMs 窗口内全进程只切出一条新段。
        static constexpr int64_t kMinSplitIntervalMs = 400;
        if (last_split_ms_ > 0 && now_ms - last_split_ms_ < kMinSplitIntervalMs) return;

        // 还没有段进入稳定下载 → 本轮不加（冷启动防握手风暴）；在途"准备中"的段已不少于
        // "下载中"的段 → 本轮不加，让已发起的连接先 ramp 起来（每 tick 至多 +1 条）。
        //
        // ⚠️ 2026-07-29：存在停滞段时必须放宽这两条，否则"全部段都被 429 卡住"
        // （downloading==0）会永远进不到补位逻辑 —— 那正是需要补位的时刻。
        // 有停滞段时只保留"在途准备中的段别堆太多"这一条软约束（避免握手风暴）。
        if (stalled > 0) {
            if (preparing > downloading + 1) return;
        } else if (downloading == 0 || preparing > downloading) {
            return;
        }
        // 没有满足常规下界或慢尾段收益门槛的候选 → 保持当前连接继续下载。
        if (!worst) return;

        // 常规大段继续均分；慢尾段采用定向接管：旧慢连接只完成紧邻当前位置的
        // 256KiB，新连接接管其余至少 1MiB。这样既把慢杆压到约 10 秒以内，又不会
        // 新建 170~450KiB 的 TTFB 碎片请求。
        int64_t e = worst->end();
        int64_t cur = worst->start() + worst->done();
        if (e < cur) return;
        int64_t split_start = worst_is_straggler
            ? cur + kStragglerKeepBytes
            : cur + worst_undone / 2;
        const int64_t min_keep = worst_is_straggler
            ? kStragglerKeepBytes : kMinSplitPieceBytes;
        const int64_t min_new = worst_is_straggler
            ? kStragglerMinNewBytes : kMinSplitPieceBytes;
        int64_t keep_len = split_start - cur;
        int64_t new_len = e - split_start + 1;
        if (split_start <= cur || keep_len < min_keep || new_len < min_new) return;

        int64_t old_end = worst->shrinkEndTo(split_start - 1);
        if (old_end < 0) return;  // 竞态：该段刚下过头或已变更，本轮放弃

        new_thread = std::make_shared<NetThread>(this, split_start, old_end, 0);
        threads_.push_back(new_thread);
        last_split_ms_ = now_ms;   // 抢占节流窗口（仍在 mu_ 内）
        AMCL_LOG_D(LOG_TAG,
            "adaptive split: %{public}s mode=%{public}s eta_ms=%{public}lld "
            "file_speed=%{public}lldB/s floor=%{public}lldB/s seg_speed_sum=%{public}lldB/s "
            "active=%{public}d->%{public}d new seg [%{public}lld-%{public}lld]",
            cfg_.local_path.c_str(), worst_is_straggler ? "straggler" : "balanced",
            (long long)(worst_eta * 1000.0), (long long)cur_speed, (long long)growth_floor,
            (long long)speed,
            downloading + preparing, downloading + preparing + 1,
            (long long)split_start, (long long)old_end);
    }

    // 锁外入队（enqueueThreads 自身线程安全）。大文件走 worker 池。
    if (new_thread) {
        DownloadEngine::instance().enqueueThreads({ new_thread });
    }
}

void NetFile::abort() {
    std::lock_guard<std::mutex> lk(mu_);
    for (auto& t : threads_) {
        t->abort();
    }
}

int64_t NetFile::deleteLocalAndMeta() {
    NetState s = state_.load(std::memory_order_acquire);
    if (s == NetState::Finished) {
        // 不碰下好的文件
        return 0;
    }

    // M-7：unlink 前要求 execution 双阶段 barrier 完整收敛。
    //   1. abort() 让 worker/curl 尽快退出；
    //   2. 最多等待 2 秒；超时保留文件并返回 0，调用方可稍后重试；
    //   3. 只有 transport 和 completion callback 都结束后才关闭 fd/unlink。
    // 绝不再以 POSIX 匿名 inode 为理由强行清理，因为那会提前释放路径 ownership，
    // 并允许新任务与旧 worker 在同一最终路径上并发。

    // 这条路径只在 Aborted/Failed 后用户主动清理时进入，性能不敏感。
    abort();

    size_t total_threads = 0;
    {
        std::lock_guard<std::mutex> lk(mu_);
        total_threads = threads_.size();
    }
    if (total_threads > 0) {
        auto t0 = std::chrono::steady_clock::now();
        const auto kTimeout = std::chrono::milliseconds(2000);
        while (threads_done_count_.load(std::memory_order_acquire) <
                   static_cast<int>(total_threads)) {
            if (std::chrono::steady_clock::now() - t0 > kTimeout) {
                AMCL_LOG_W(LOG_TAG,
                    "deleteLocalAndMeta: execution quiescence timeout (done=%{public}d "
                    "total=%{public}zu), retaining files for retry: %{public}s",
                    threads_done_count_.load(std::memory_order_acquire),
                    total_threads, cfg_.local_path.c_str());
                return 0;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
    }

    if (!isExecutionSettled()) {
        AMCL_LOG_W(LOG_TAG,
            "deleteLocalAndMeta: completion callback still active, retaining: %{public}s",
            cfg_.local_path.c_str());
        return 0;
    }

    // 所有 execution epoch 已完成，随后关 fd 与 unlink 不会和 worker/curl 回调竞态。
    {
        std::lock_guard<std::mutex> lk(fd_init_mu_);
        if (fd_ >= 0) {
            ::close(fd_);
            fd_ = -1;
        }
        fd_refcount_ = 0;
    }

    // 真正 unlink（最终文件、staging 和 meta）
    int64_t freed = 0;
    struct stat st{};
    for (const std::string* path : {&cfg_.local_path, &staging_path_}) {
        if (::lstat(path->c_str(), &st) == 0 && S_ISREG(st.st_mode)) {
            freed += st.st_size;
            if (::unlink(path->c_str()) != 0) {
                AMCL_LOG_W(LOG_TAG, "deleteLocalAndMeta: unlink %{public}s failed errno=%{public}d",
                            path->c_str(), errno);
            }
        }
    }
    std::string mp = metaPath();
    if (::stat(mp.c_str(), &st) == 0) {
        freed += st.st_size;
        if (::unlink(mp.c_str()) != 0) {
            AMCL_LOG_W(LOG_TAG, "deleteLocalAndMeta: unlink %{public}s failed errno=%{public}d",
                        mp.c_str(), errno);
        }
    }
    return freed;
}

bool NetFile::resetForRetry() {
    NetState s = state_.load(std::memory_order_acquire);
    if (s == NetState::Finished) {
        return false;  // 不碰已完成的
    }
    if (!isExecutionSettled()) {
        AMCL_LOG_W(LOG_TAG,
            "resetForRetry rejected while execution is still active: %{public}s",
            cfg_.local_path.c_str());
        return false;
    }
    // 清 error + 计数
    {
        std::lock_guard<std::mutex> lk(mu_);
        error_.reset();
    }
    threads_done_count_.store(0, std::memory_order_release);
    retry_count_ = 0;
    sha1_fallback_to_single_ = 0;
    single_segment_fullget_tried_ = false;  // 用户重试/续传时允许再次走整文件 GET 兜底
    // 清理 threads_ 和 pending：让下次 start() 重新切片。
    // 文件本身（local_path + meta）保留，start() 会走断点续传逻辑。
    {
        std::lock_guard<std::mutex> lk(mu_);
        threads_.clear();
        threads_pending_launch_.clear();
        completed_threads_.clear();
        resume_from_meta_ = false;
    }
    {
        std::lock_guard<std::mutex> lk(fd_init_mu_);
        fd_error_ = 0;
    }
    // file_size_ 保留；下次 start 会重新切片或读取严格 meta
    state_.store(NetState::WaitingForSchedule, std::memory_order_release);
    return true;
}

NetFile::MetaSnapshot NetFile::snapshotForMeta() const {
    MetaSnapshot out;
    out.file_size = file_size_.load(std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lk(mu_);
        out.segments.reserve(threads_.size());
        for (const auto& t : threads_) {
            out.segments.push_back(t->snapshot());
        }
    }
    // 关键修复：自适应拆段（maybeGrowThreads）会把新段 push 到 threads_ 末尾，导致
    // threads_ 不再按 start 升序。writeMetaFile→validateMeta 要求段严格连续升序覆盖
    // [0,file_size)，乱序会被判 invalid meta，连续写失败后误报 StorageIoError 把正在
    // 正常下载的任务判死。这里在快照阶段按 start 归一化排序，使持久化格式始终合法。
    std::sort(out.segments.begin(), out.segments.end(),
              [](const NetThread::Snapshot& a, const NetThread::Snapshot& b) {
                  return a.start < b.start;
              });
    return out;
}

} // namespace download


