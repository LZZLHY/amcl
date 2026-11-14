/** 执行真实roots解析器；仅校验固定协议的边界，不把它冒称设备目录/权限测量通过。 */
#define MC_OHOS_BUILD_TESTS 1
#include "../../entry/src/main/cpp/napi/jdk_permission_qualification.h"
#include <cassert>
#include <cstdio>
#include <vector>

int main() {
    using amcl::jdkqualification::ParsePermissionRoots;
    const std::string normal = "AMCL-PERM-ROOTS-1\n/app/files\n/public/中文&目录\nenvironment\n";
    const auto parsed = ParsePermissionRoots(normal);
    assert(parsed.sandbox == "/app/files" && parsed.external == "/public/中文&目录" && parsed.source == "environment");
    const auto unavailable = ParsePermissionRoots("AMCL-PERM-ROOTS-1\n/app/files\n\nphone-cache\n");
    assert(unavailable.external.empty());
    const std::vector<std::string> invalid = {
        "", normal + "extra\n", normal.substr(0, normal.size() - 1),
        "AMCL-PERM-ROOTS-2\n/app/files\n/public\nenvironment\n",
        "AMCL-PERM-ROOTS-1\nrelative\n/public\nenvironment\n",
        "AMCL-PERM-ROOTS-1\n/app/files\nrelative\nenvironment\n",
        "AMCL-PERM-ROOTS-1\n/app/files\n/public\nguessed-download\n",
        "AMCL-PERM-ROOTS-1\r\n/app/files\n/public\nenvironment\n",
        normal + std::string(1, '\0'), std::string(8193, 'x'),
        "AMCL-PERM-ROOTS-1\n/" + std::string(4096, 'x') + "\n\nenvironment\n"
    };
    for (const auto& input : invalid) {
        bool rejected = false;
        try { (void)ParsePermissionRoots(input); } catch (const std::exception&) { rejected = true; }
        assert(rejected);
    }
    std::puts("PASS real permission roots parser: 2 accepted and 11 invalid records rejected");
}
