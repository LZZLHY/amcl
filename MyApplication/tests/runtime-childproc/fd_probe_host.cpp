/** 宿主真实内核执行，不启用会在fork后插入运行时回调的ASan。
 * ASan/UBSan用于旁边的纯故障测试；此入口证明真实FD表隔离和真实wait退出。
 */
#include "fd_probe.hpp"
#include <cassert>
#include <dirent.h>
#include <iostream>
static unsigned fdCount() {
    DIR* directory = opendir("/proc/self/fd");
    assert(directory);
    unsigned result = 0;
    while (readdir(directory)) ++result;
    assert(closedir(directory) == 0);
    return result;
}
int main() {
    const unsigned before = fdCount();
    const std::string result = amcl::childfdprobe::run();
    std::cout << result;
    assert(before == fdCount());
    unsigned passed = 0;
    for (size_t at = 0; (at = result.find("\"passed\":true", at)) != std::string::npos; ++at) ++passed;
    assert(passed == 3); // 本标准Linux QA内核应能实际运行两个分支；目标平台另存实际结果。
}
