/** 相同合法深路径ZIP、相同96MiB地址空间：当前真实预检应完成，历史真实实现应OOM。
 * 无解压/写树/目标代码执行；纯元数据压力不创建192000个目录，不改变产品接受预算。 */
#ifndef AMCL_ARCHIVE_PARSER
#error "test requires explicitly selected real parser source"
#endif
#include AMCL_ARCHIVE_PARSER
#include <iostream>
#include <sys/resource.h>
int main(int argc, char **argv) {
    if (argc != 2)
        return 2;
    const rlimit limit{96ULL * 1024 * 1024, 96ULL * 1024 * 1024};
    if (setrlimit(RLIMIT_AS, &limit))
        return 3;
    try {
        amcl::jdk::io::Fd fd(open(argv[1], O_RDONLY | O_CLOEXEC));
        struct stat st {};
        if (fd.get() < 0 || fstat(fd.get(), &st))
            return 4;
        uint64_t total = 0;
        size_t paths = 0;
        const auto entries = amcl::jdk::Inspect(fd.get(), st.st_size, total, paths);
        if (entries.size() != 3000 || paths != 192000 || total != 0)
            return 5;
        rusage usage{};
        getrusage(RUSAGE_SELF, &usage);
        std::cout << "PATH-MEMORY PASS entries=" << entries.size() << " uniquePaths=" << paths
                  << " addressSpaceLimit=" << limit.rlim_cur << " maxRssKiB=" << usage.ru_maxrss << '\n';
        return 0;
    } catch (const std::bad_alloc &) {
        rusage usage{};
        getrusage(RUSAGE_SELF, &usage);
        std::cout << "PATH-MEMORY ALLOCATION-FAILED addressSpaceLimit=" << limit.rlim_cur
                  << " maxRssKiB=" << usage.ru_maxrss << '\n';
        return 77;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 6;
    }
}
