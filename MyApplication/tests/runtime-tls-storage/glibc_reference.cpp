/** 与真实 glibc 的合法单线程 module churn 对照。地址只作为整数身份统计；dlclose
 * 后不解引用旧TLS地址，不调用已卸载函数，不用非法访问迫使产品永久pin整个DSO。
 */
#include <cassert>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <dlfcn.h>
#include <gnu/libc-version.h>
#include <link.h>
#include <malloc.h>
#include <set>
#include <string>
#include <thread>

struct ImageCount { const char* path; size_t count; };
static int countImage(dl_phdr_info* info, size_t, void* opaque) {
    auto& result = *static_cast<ImageCount*>(opaque);
    if (info->dlpi_name && std::strcmp(info->dlpi_name, result.path) == 0) ++result.count;
    return 0;
}
int main(int argc, char** argv) {
    assert(argc == 2);
    std::thread worker([&] {
        std::set<uintptr_t> addresses;
        size_t before = 0, after = 0;
        for (unsigned i = 0; i < 72; ++i) {
            void* handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL); assert(handle);
            auto touch = reinterpret_cast<unsigned char*(*)(unsigned char)>(dlsym(handle, "ordinary_tls_touch")); assert(touch);
            unsigned char* bytes = touch(static_cast<unsigned char>(i));
            assert(bytes[0] == i && bytes[16383] == i);
            if (i >= 8) addresses.insert(reinterpret_cast<uintptr_t>(bytes));
            assert(dlclose(handle) == 0);
            ImageCount images{argv[1], 0}; dl_iterate_phdr(countImage, &images);
            assert(images.count == 0);
            if (i == 7) before = mallinfo2().uordblks;
        }
        after = mallinfo2().uordblks;
        std::printf("REFERENCE glibc=%s cycles=64 tlsBytes=16384 distinctAddresses=%zu heapBefore=%zu heapAfter=%zu imagesAfterClose=0\n",
                    gnu_get_libc_version(), addresses.size(), before, after);
        // 对照的回收/复用是实际环境测量，不据此外推其它libc，也不声明所有TLS必须立刻回收。
        assert(addresses.size() < 64 && "reference did not demonstrate storage reuse; retain unresolved resource gate");
    }); worker.join();
}
