/** 同应用UID的固定原生文件时间入口；只消费宿主记录的两个根，不接收任意Want路径。 */
#pragma once
#ifdef MC_OHOS_BUILD_TESTS
#include "jdk_permission_qualification.h"
#include "../../../../../tests/runtime-permissions/native_time_probe.h"

namespace amcl::jdkqualification {
/**
 * 在官方NCP的新鲜进程中对真实libc执行两根对照。JVM/归档/音频尚未启动；返回的是
 * 完整观察原文，其单项errno仍是事实，不按filesystem类型推导权限豁免或运行时资格。
 */
inline std::string RunNativeFileTimesQualification(int root, int run, const std::string& rootPath) {
    namespace io = amcl::jdk::io;
    using amcl::permissionprobe::detail::Quote;
    const auto text = io::SmallFile(root, "permission-roots.txt", 8192);
    const auto roots = ParsePermissionRoots(text);
    VerifiedPermissionSandbox(rootPath, roots);
    io::Require(!roots.external.empty(), "原生时间对照缺少已授权外部根");
    auto sandbox = io::Directory(roots.sandbox), external = io::Directory(roots.external);
    struct stat inside{}, outside{};
    io::Require(fstat(sandbox.get(), &inside) == 0 && fstat(external.get(), &outside) == 0,
                "原生时间对照根身份不可读");
    io::Require(inside.st_dev != outside.st_dev || inside.st_ino != outside.st_ino,
                "原生时间对照不能把相同对象当两种存储");
    const auto nonce = "ncp-" + std::to_string(getpid());
    const auto privateResult = amcl::nativetimeprobe::Run(roots.sandbox, nonce);
    const auto publicResult = amcl::nativetimeprobe::Run(roots.external, nonce);
    const auto result = "{\"protocol\":\"AMCL_NATIVE_FILE_TIMES_OBSERVATION_V1\",\"jvmStarted\":false,\"source\":" +
        Quote(roots.source) + ",\"rootsSha256\":" + Quote(io::Digest(text)) +
        ",\"sandbox\":" + privateResult + ",\"external\":" + publicResult + "}";
    io::Fd output(openat(run, "native-file-times.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
    if (output.get() < 0) io::Error("原生时间报告已存在或不可创建");
    io::Write(output.get(), result.data(), result.size()); io::Sync(output.get()); io::Sync(run);
    return result;
}
} // namespace amcl::jdkqualification
#endif
