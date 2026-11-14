/** 直接编译生产垫片；只替换系统输入，验证并发流所有权、完整索引和失败边界。 */
#include "jvm/if_inet6_shim.h"
#include "platform/owned_read_stream.h"
#include <atomic>
#include <cassert>
#include <cerrno>
#include <cstring>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <signal.h>
#include <string>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {
std::atomic<unsigned> opened{0};
std::atomic<unsigned> freed{0};
std::atomic<int> openError{EACCES};
std::atomic<bool> failCookie{false};
thread_local unsigned latest = 0;
struct Address {
    ifaddrs record{};
    sockaddr_in6 address{};
    sockaddr_in6 mask{};
    char name[8] = "test0";
};
}

extern "C" FILE* __real_fopen(const char*, const char*);
extern "C" FILE* __real_fopencookie(void*, const char*, cookie_io_functions_t);
extern "C" FILE* __wrap_fopen(const char* path, const char* mode) {
    if (std::strcmp(path, "/proc/net/if_inet6") == 0) { errno = openError.load(); return nullptr; }
    return __real_fopen(path, mode);
}
extern "C" FILE* __wrap_fopencookie(void* cookie, const char* mode, cookie_io_functions_t io) {
    if (failCookie.load()) { errno = ENOMEM; return nullptr; }
    return __real_fopencookie(cookie, mode, io);
}
extern "C" int __wrap_access(const char*, int) { errno = ENOENT; return -1; }
extern "C" unsigned __wrap_if_nametoindex(const char*) { return latest; }
extern "C" int __wrap_getifaddrs(ifaddrs** out) {
    auto* value = new Address;
    latest = 300 + ++opened;
    value->address.sin6_family = AF_INET6;
    value->address.sin6_addr.s6_addr[0] = 0x20;
    value->address.sin6_addr.s6_addr[1] = 1;
    std::memset(value->mask.sin6_addr.s6_addr, 0xff, 8);
    value->record.ifa_name = value->name;
    value->record.ifa_addr = reinterpret_cast<sockaddr*>(&value->address);
    value->record.ifa_netmask = reinterpret_cast<sockaddr*>(&value->mask);
    *out = &value->record;
    return 0;
}
extern "C" void __wrap_freeifaddrs(ifaddrs* list) {
    ++freed;
    delete reinterpret_cast<Address*>(list);
}

/** 用生产解析器读回未截断的接口索引；每个流一直保留到后续流都打开以后。 */
void streamBatch(unsigned count) {
    std::vector<std::pair<FILE*, unsigned>> streams;
    for (unsigned i = 0; i < count; ++i) {
        FILE* stream = amclIfInet6ShimOpen("/proc/net/if_inet6", "r");
        assert(stream);
        streams.emplace_back(stream, latest);
    }
    for (const auto& item : streams) {
        char line[160];
        assert(fgets(line, sizeof(line), item.first));
        amcl::ifinet6::Entry result;
        assert(amcl::ifinet6::parseLine(line, &result));
        assert(result.ifIndex == item.second);
        assert(fseek(item.first, 0, SEEK_SET) == 0);
        assert(fgets(line, sizeof(line), item.first));
        assert(fclose(item.first) == 0);
    }
}

int main() {
    unsetenv("AMCL_JDK_IF_INET6_SHIM");
    streamBatch(64);
    // 不依赖一条很短的文件：独占流支持超过旧 4 KiB 上限的完整内容及 EOF。
    std::string large(12000, 'q');
    FILE* stream = amcl::ifinet6::openOwnedReadStream(large.data(), large.size());
    assert(stream && fseek(stream, 11000, SEEK_SET) == 0);
    char data[1001]{};
    assert(fread(data, 1, 1000, stream) == 1000);
    assert(std::string(data, 1000) == large.substr(11000));
    assert(fgetc(stream) == EOF && fclose(stream) == 0);
    const unsigned before = opened.load();
    openError = EIO;
    assert(!amclIfInet6ShimOpen("/proc/net/if_inet6", "r") && errno == EIO);
    assert(opened == before);
    openError = EACCES;
    failCookie = true;
    assert(!amclIfInet6ShimOpen("/proc/net/if_inet6", "r") && errno == ENOMEM);
    failCookie = false;
    std::vector<std::thread> readers;
    for (int i = 0; i < 12; ++i) readers.emplace_back([] {
        for (int repeat = 0; repeat < 40; ++repeat) streamBatch(16);
    });
    // 背景线程活动期间 fork，子进程有界验证模式重新识别和独立流。
    const pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        alarm(5);
        setenv("AMCL_JDK_IF_INET6_SHIM", "0", 1);
        assert(std::strcmp(amclIfInet6ShimModeName(), "off") == 0);
        _exit(0);
    }
    int status = 0;
    assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    for (auto& reader : readers) reader.join();
    assert(opened == freed);
    printf("PASS IPv6: 64 live streams, large input, full index, 12 concurrent readers, errno, fork; collected=%u freed=%u\n",
           opened.load(), freed.load());
}
