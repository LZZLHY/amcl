/** Linux 宿主真实 UDP 验收：执行产品头文件，不在测试侧重写发现算法。输出仅含断言结论。 */
#include "../../entry/src/main/cpp/hdc/local_discovery.h"
#include <cassert>
#include <thread>
#include <iostream>

int main() {
    using amcl::hdc::ParseLocalPort;
    assert(ParseLocalPort("OHOS HDC-38735") == 38735);
    for (const auto* bad : {"OHOS HDC-0", "OHOS HDC-65536", "OHOS HDC-12\ncmd", "OHOS HDC--1", "OTHER-1"}) assert(ParseLocalPort(bad) == 0);
    int server = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    assert(server >= 0);
    int reuse = 1; assert(setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse)) == 0);
    sockaddr_in address{}; address.sin_family = AF_INET; address.sin_port = htons(8710);
    address.sin_addr.s_addr = INADDR_ANY;
    assert(bind(server, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
    std::thread responder([&] {
        pollfd ready{server, POLLIN, 0}; assert(poll(&ready, 1, 2000) == 1);
        char query[32]{}; sockaddr_in peer{}; socklen_t size = sizeof(peer);
        auto count = recvfrom(server, query, sizeof(query), 0, reinterpret_cast<sockaddr*>(&peer), &size);
        assert(std::string_view(query, count) == "OHOS HDC");
        assert(ntohs(peer.sin_port) == 8710);
        constexpr char reply[] = "OHOS HDC-38735";
        assert(sendto(server, reply, sizeof(reply)-1, 0, reinterpret_cast<sockaddr*>(&peer), size) == sizeof(reply)-1);
    });
    assert(amcl::hdc::DiscoverLocalPort() == 38735);
    responder.join(); close(server);
    // 服务不存在也必须在固定时间内结束并释放端口，随后调用可重新绑定。
    const auto start = std::chrono::steady_clock::now();
    assert(amcl::hdc::DiscoverLocalPort() == 0);
    assert(std::chrono::steady_clock::now() - start < std::chrono::seconds(3));
    // UDP 不回答时，候选来自真实本机监听表/连接；只有协议验证者确认的端口才可返回。
    int listener = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    sockaddr_in tcp{}; tcp.sin_family = AF_INET; tcp.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(bind(listener, reinterpret_cast<sockaddr*>(&tcp), sizeof(tcp)) == 0);
    assert(listen(listener, 8) == 0); socklen_t length = sizeof(tcp);
    assert(getsockname(listener, reinterpret_cast<sockaddr*>(&tcp), &length) == 0);
    const int port = ntohs(tcp.sin_port);
    assert(amcl::hdc::DiscoverLocalHdcPort([&](int found) { return found == port ? 1 : 0; }) == port);
    close(listener);
    std::cout << "PASS strict response, shared UDP port, bounded absence, real loopback candidate and protocol gate\n";
}
