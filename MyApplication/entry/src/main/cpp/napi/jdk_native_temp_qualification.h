/**
 * 仅TestHooks的native temp平台前置桥。复用现有资格NCP的root/run目录fd及真实
 * Context-derived permission-roots.txt；没有任意Want路径，也不需要安装或装载JDK。
 * root所有者必须在native-temp-main阶段施加10秒父看门狗并监督真实退出。
 */
#pragma once
#ifdef MC_OHOS_BUILD_TESTS
#include "jdk_permission_qualification.h"
#include "../../../../../tests/runtime-native-temp/native_temp_probe.h"

namespace amcl::jdkqualification {
inline std::string RunNativeTempQualification(int root, int run, const std::string& rootPath) {
    namespace io = amcl::jdk::io;
    namespace probe = amcl::nativetempprobe;
    const std::string text = io::SmallFile(root, "permission-roots.txt", 8192);
    const PermissionRoots roots = ParsePermissionRoots(text);
    const std::string marker = "/jdk-runtime-qualification/";
    const auto split = rootPath.rfind(marker);
    io::Require(split != std::string::npos && split > 0, "native temp资格根不在固定应用子目录");
    const auto nonce = rootPath.substr(split + marker.size());
    io::Require(probe::ValidNonce(nonce), "native temp nonce不符合固定合同");
    auto expected = io::Directory(rootPath.substr(0, split));
    auto sandbox = io::Directory(roots.sandbox);
    struct stat expectedInfo{}, sandboxInfo{};
    io::Require(fstat(expected.get(), &expectedInfo) == 0 && fstat(sandbox.get(), &sandboxInfo) == 0 &&
                expectedInfo.st_dev == sandboxInfo.st_dev && expectedInfo.st_ino == sandboxInfo.st_ino &&
                sandboxInfo.st_uid == geteuid(), "native temp输入不是本应用实际filesDir对象");
    io::Fd output(openat(run, "native-temp-report.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
    if (output.get() < 0) io::Error("native temp报告已存在或无法独占创建");
    const std::string observation = probe::Run(sandbox.get(), roots.sandbox, nonce);
    const std::string report = "{\"protocol\":\"AMCL_NATIVE_TEMP_QUALIFICATION_V1\",\"nativeOnly\":true,"
        "\"rootsSha256\":" + probe::Quote(io::Digest(text)) + ",\"observation\":" + observation + "}\n";
    io::Write(output.get(), report.data(), report.size()); io::Sync(output.get()); io::Sync(run);
    return report;
}
} // namespace amcl::jdkqualification
#endif
