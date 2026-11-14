/* 调用真实Native探针，动态库由host runner精确指向测试替身。没有真实录音。 */
#include "jdk_capture_native_qualification.h"
#include <cassert>
#include <dlfcn.h>
#include <fcntl.h>
#include <iostream>
#include <string>
#include <unistd.h>
int main(int argc, char **argv)
{
    assert(argc == 3); int fd = open(argv[1], O_RDONLY | O_DIRECTORY | O_CLOEXEC); assert(fd >= 0);
    bool failed = false;
    const std::string mode = argv[2];
    try { std::cout << (mode.rfind("channels-", 0) == 0 ? amcl::jdkqualification::RunCaptureChannelsQualification(fd) :
                       mode.rfind("startup-", 0) == 0 ? amcl::jdkqualification::RunCaptureStartupQualification(fd) :
                       mode.rfind("layout-", 0) == 0 ? amcl::jdkqualification::RunCaptureLayoutQualification(fd)
                                                  : amcl::jdkqualification::RunCaptureNativeQualification(fd)); }
    catch (const std::exception &error) { failed = true; std::cout << "EXPECTED_OBSERVATION_FAILURE " << error.what() << '\n'; }
    close(fd);
    assert(failed == (mode != "normal" && mode != "swapped" && mode != "float-payload" && mode != "fast-fallback" &&
                      mode != "layout-response" && mode != "layout-windows" && mode != "startup-normal" &&
                      mode != "startup-windows" && mode != "startup-split" && mode != "channels-normal" &&
                      mode != "channels-first-window" && mode != "channels-extremes" && mode != "channels-split"));
    if (mode == "release-failure" || mode == "startup-release-failure" || mode == "channels-release-failure") {
        void *handle = dlopen("libohaudio.so", RTLD_NOW | RTLD_NOLOAD); assert(handle);
        auto late = reinterpret_cast<void (*)()>(dlsym(handle, "amcl_capture_native_test_late_callback")); assert(late);
        late(); dlclose(handle);
    }
    return 0;
}
