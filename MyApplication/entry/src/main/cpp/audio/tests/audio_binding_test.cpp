/** 实际DSO与dlmopen负例，证明客户端发现的是宿主已发布owner而不是自己的静态副本。 */
#include "../audio_runtime.h"
#include "../../tests/host/test_check.h"
#include <cstdio>
#include <cstdlib>
#include <dlfcn.h>
#include <link.h>
int main(int argc, char **argv) {
    AMCL_TEST_CHECK(argc == 3);
    auto *host = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    AMCL_TEST_CHECK(host);
    auto early = reinterpret_cast<int (*)()>(dlsym(host, "amclAudioHostPublishEarlyV1"));
    auto begin = reinterpret_cast<int (*)(uint64_t, AmclAudioRecordPermissionV1, void *, int)>(
        dlsym(host, "amclAudioHostBeginV1"));
    auto getter = reinterpret_cast<const AmclAudioApiV1 *(*)()>(dlsym(host, "amclAudioHostGetV1"));
    auto end = reinterpret_cast<int (*)(uint64_t)>(dlsym(host, "amclAudioHostEndV1"));
    AMCL_TEST_CHECK(early && begin && getter && end);
    AMCL_TEST_CHECK(early() == 0 && getter() == nullptr);
    const char *discovery = getenv(AMCL_AUDIO_HOST_ENV);
    AMCL_TEST_CHECK(discovery);
    void *clients[2]{dlopen(argv[2], RTLD_NOW | RTLD_LOCAL),
                     dlmopen(LM_ID_NEWLM, argv[2], RTLD_NOW | RTLD_LOCAL)};
    for (auto *client : clients) {
        AMCL_TEST_CHECK(client);
        auto install = reinterpret_cast<void (*)(const char *)>(dlsym(client, "testInstallAudioDiscovery"));
        auto resolve = reinterpret_cast<const AmclAudioApiV1 *(*)()>(dlsym(client, "testResolveAudio"));
        AMCL_TEST_CHECK(install && resolve);
        install(discovery);
        AMCL_TEST_CHECK(resolve() == nullptr);
    }
    AMCL_TEST_CHECK(begin(789, nullptr, nullptr, 1) == 0);
    const auto *actual = getter();
    AMCL_TEST_CHECK(actual && actual->session == 789);
    for (auto *client : clients) {
        auto resolve = reinterpret_cast<const AmclAudioApiV1 *(*)()>(dlsym(client, "testResolveAudio"));
        AMCL_TEST_CHECK(resolve() == actual);
    }
    AMCL_TEST_CHECK(end(789) == 0);
    for (auto *client : clients) {
        auto resolve = reinterpret_cast<const AmclAudioApiV1 *(*)()>(dlsym(client, "testResolveAudio"));
        AMCL_TEST_CHECK(resolve() == nullptr);
        dlclose(client);
    }
    AMCL_TEST_CHECK(begin(790, nullptr, nullptr, 1) == AMCL_AUDIO_INVALID);
    std::puts("PASS actual DSO host/client: early discovery, inactive/active/revoked, separate namespace "
              "same owner, no JVM reuse");
    // Runtime按生产生命周期存活至进程结束，不能在它的worker运行时dlclose代码。
}
