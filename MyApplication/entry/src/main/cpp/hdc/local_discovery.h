/** 本机 HDC UDP 发现。POSIX 在 bind 前设复用，避开旧 ArkTS socket 选项依赖已创建 fd 的限制。 */
#pragma once
#include <arpa/inet.h>
#include <sys/socket.h>
#include <poll.h>
#include <unistd.h>
#include <chrono>
#include <cerrno>
#include <string_view>
#include <string>
#include <vector>
#include <array>
#include <set>
#include <cstdio>

namespace amcl::hdc {
/** 发现响应只是候选端口；拒绝尾随内容、溢出和来自其他设备的响应。 */
inline int ParseLocalPort(std::string_view text) {
    constexpr std::string_view prefix = "OHOS HDC-";
    if (text.substr(0, prefix.size()) != prefix) return 0;
    text.remove_prefix(prefix.size());
    if (text.empty() || text.size() > 5) return 0;
    int port = 0;
    for (char c : text) { if (c < '0' || c > '9') return 0; port = port * 10 + c - '0'; }
    return port > 0 && port <= 65535 ? port : 0;
}

/**
 * daemon 将结果发回请求源 IP 的 8710，而不是源端口，因此必须绑定独立 loopback 别名。
 * 只发往 127.0.0.1:8710；不广播、不枚举网段、不读取隐藏系统参数。超时/失败返回 0。
 * 使用单个 RAII fd 和单调时钟，最多 1.6 秒；不得在 ArkUI 主线程直接调用。
 */
inline int DiscoverLocalPort() {
    const int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return 0;
    struct Close { int fd; ~Close() { close(fd); } } closeFd{fd};
    int enabled = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled)) != 0) return 0;
    sockaddr_in local{}; local.sin_family = AF_INET; local.sin_port = htons(8710);
    inet_pton(AF_INET, "127.0.0.2", &local.sin_addr);
    if (bind(fd, reinterpret_cast<sockaddr*>(&local), sizeof(local)) != 0) return 0;
    sockaddr_in daemon{}; daemon.sin_family = AF_INET; daemon.sin_port = htons(8710);
    inet_pton(AF_INET, "127.0.0.1", &daemon.sin_addr);
    constexpr char query[] = "OHOS HDC";
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1600);
    // 丢包时最多重发两次，始终共享一个截止时间，不累积后台发现任务。
    for (int attempt = 0; attempt < 3; ++attempt) {
        if (sendto(fd, query, sizeof(query) - 1, 0, reinterpret_cast<sockaddr*>(&daemon), sizeof(daemon)) < 0) return 0;
        const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now()).count();
        if (remaining <= 0) break;
        pollfd wait{fd, POLLIN, 0};
        const int ready = poll(&wait, 1, static_cast<int>(remaining > 530 ? 530 : remaining));
        if (ready < 0 && errno != EINTR) return 0;
        if (ready <= 0 || !(wait.revents & POLLIN)) continue;
        char response[65]{}; sockaddr_in peer{}; socklen_t size = sizeof(peer);
        const ssize_t count = recvfrom(fd, response, sizeof(response), MSG_DONTWAIT, reinterpret_cast<sockaddr*>(&peer), &size);
        if (count <= 0 || count > 64 || peer.sin_addr.s_addr != daemon.sin_addr.s_addr || peer.sin_port != daemon.sin_port) continue;
        const int port = ParseLocalPort(std::string_view(response, static_cast<size_t>(count)));
        if (port > 0) return port;
    }
    return 0;
}

/** /proc 只作为本机监听端口提示；有些系统不允许应用读取，失败时继续有界 loopback 探测。 */
inline std::vector<int> LocalListenerHints() {
    std::vector<int> ports;
    FILE* file = fopen("/proc/net/tcp", "r");
    if (!file) return ports;
    char line[512]{};
    for (int count = 0; count < 4096 && fgets(line, sizeof(line), file); ++count) {
        unsigned address = 0, port = 0, state = 0;
        if (sscanf(line, "%*u: %8x:%4x %*s %2x", &address, &port, &state) != 3) continue;
        if (state == 10 && (address == 0 || address == 0x0100007f) && port > 0 && port <= 65535) ports.push_back(port);
        if (ports.size() >= 64) break;
    }
    fclose(file); return ports;
}

/**
 * UDP 无响应时，最多 64 个并发 TCP connect 只探测 127.0.0.1。开放端口还必须通过 HDC
 * 协议介绍响应验证；普通 HTTP/代理服务不会被当作调试端口，也不向其发送 shell 命令。
 * 全轮最多八秒、至多验证十六个开放端口；fd 在每批和提前成功时完整释放。高端口先行是
 * 随机系统端口的效率选择，随后仍覆盖其余合法范围，不把固定端口段作为正确性条件。
 */
template <typename Verify>
inline int DiscoverLocalHdcPort(Verify verify) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(8);
    std::set<int> checked;
    int checks = 0;
    const auto test = [&](int port) {
        if (port <= 0 || !checked.insert(port).second || checks >= 16 || std::chrono::steady_clock::now() >= deadline) return false;
        ++checks; return verify(port) == 1;
    };
    const int discovered = DiscoverLocalPort();
    if (test(discovered)) return discovered;
    for (int port : LocalListenerHints()) if (test(port)) return port;
    for (int offset = 0; offset < 65535 && checks < 16 && std::chrono::steady_clock::now() < deadline; offset += 64) {
        std::array<pollfd, 64> sockets{}; std::array<int, 64> ports{};
        for (auto& value : sockets) value.fd = -1;
        struct CloseBatch {
            std::array<pollfd,64>& sockets;
            ~CloseBatch() { for (auto& value : sockets) if (value.fd >= 0) close(value.fd); }
        } batch{sockets};
        for (int index = 0; index < 64 && offset + index < 65535; ++index) {
            const int position = offset + index;
            const int port = position < 32768 ? 32768 + position : position - 32767;
            if (checked.count(port)) continue;
            const int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
            if (fd < 0) continue;
            sockets[index] = pollfd{fd, POLLOUT, 0}; ports[index] = port;
            sockaddr_in address{}; address.sin_family = AF_INET; address.sin_port = htons(port);
            address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            if (connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0 && errno != EINPROGRESS) {
                close(fd); sockets[index].fd = -1;
            }
        }
        if (poll(sockets.data(), sockets.size(), 8) <= 0) continue;
        for (int index = 0; index < 64; ++index) {
            if (sockets[index].fd < 0 || !(sockets[index].revents & POLLOUT)) continue;
            int error = -1; socklen_t size = sizeof(error);
            const bool open = getsockopt(sockets[index].fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0;
            close(sockets[index].fd); sockets[index].fd = -1;
            if (open && test(ports[index])) return ports[index];
        }
    }
    return 0;
}
}
