/** TestHooks的PERM-01输入桥：只读取当前资格根固定文件，核对真正app filesDir身份，
 * 调用真实libc测量并保存独占报告。不创建JVM，不改任何权限兼容策略，不接受Want路径。
 */
#pragma once
#ifdef MC_OHOS_BUILD_TESTS
#include "../platform/jdk_install_io.h"
#include "../../../../../tests/runtime-permissions/permission_probe.h"

namespace amcl::jdkqualification {
struct PermissionRoots {
    std::string sandbox;
    std::string external;
    std::string source;
};

/** 四行UTF-8记录有硬字节界，路径字段拒绝NUL/CR/换行；缺外部路径是正常NOT-RUN输入。 */
inline PermissionRoots ParsePermissionRoots(const std::string& text) {
    namespace io = amcl::jdk::io;
    io::Require(!text.empty() && text.size() <= 8192 && text.find('\0') == std::string::npos &&
                text.find('\r') == std::string::npos, "权限根记录长度或控制字符无效");
    size_t cursor = 0;
    auto line = [&]() {
        const auto end = text.find('\n', cursor);
        io::Require(end != std::string::npos, "权限根记录缺少终止符");
        const auto value = text.substr(cursor, end - cursor); cursor = end + 1; return value;
    };
    io::Require(line() == "AMCL-PERM-ROOTS-1", "权限根记录版本不支持");
    PermissionRoots roots{line(), line(), line()};
    io::Require(cursor == text.size(), "权限根记录存在多余字段");
    auto valid = [](const std::string& path) { return !path.empty() && path.size() <= 4096 && path.front() == '/'; };
    io::Require(valid(roots.sandbox) && (roots.external.empty() || valid(roots.external)), "权限根记录不是绝对路径");
    io::Require(roots.source == "environment" || roots.source == "phone-cache", "权限根来源不是现有GameStorage路由");
    return roots;
}

/** 从既有permission-roots协议确认真实应用filesDir身份，不把nonce安装根冒称父根。 */
inline std::string VerifiedPermissionSandbox(const std::string& rootPath, const PermissionRoots& roots) {
    namespace io = amcl::jdk::io;
    const std::string marker = "/jdk-runtime-qualification/";
    const auto split = rootPath.rfind(marker);
    io::Require(split != std::string::npos && split > 0, "权限资格根不在固定应用子目录");
    auto expected = io::Directory(rootPath.substr(0, split));
    auto recorded = io::Directory(roots.sandbox);
    struct stat expectedStat{}, recordedStat{};
    io::Require(fstat(expected.get(), &expectedStat) == 0 && fstat(recorded.get(), &recordedStat) == 0 &&
                expectedStat.st_dev == recordedStat.st_dev && expectedStat.st_ino == recordedStat.st_ino &&
                recordedStat.st_uid == geteuid(), "记录的sandbox不是本次实际app filesDir对象");
    return roots.sandbox;
}

/** rootPath已经由Java NCP入口与传入root fd比对。此处再核记录sandbox与该路径的
 * app filesDir为同一目录，防止把资格安装子目录或另一位置冒称应用沙箱对照。
 * 返回完整JSON供root选择记录摘要；实际矩阵独占保存permission-report.json，失败也保存。
 */
inline std::string RunPermissionQualification(int root, int run, const std::string& rootPath, const std::string& major) {
    namespace io = amcl::jdk::io;
    using amcl::permissionprobe::detail::Quote;
    std::string result;
    const char* stage = "read-roots";
    try {
        if (!io::Exists(root, "permission-roots.txt")) {
            result = "{\"status\":\"NOT-RUN\",\"reason\":\"permission-roots-missing\"}";
        } else {
            const auto text = io::SmallFile(root, "permission-roots.txt", 8192);
            const auto roots = ParsePermissionRoots(text);
            stage = "validate-sandbox-identity";
            VerifiedPermissionSandbox(rootPath, roots);
            auto recorded = io::Directory(roots.sandbox);
            struct stat recordedStat{};
            io::Require(fstat(recorded.get(), &recordedStat) == 0, "无法重读sandbox身份");
            io::Require(major == "8" || major == "17" || major == "21" || major == "25", "权限资格major无效");
            const auto nonce = "ncp-" + major + "-" + std::to_string(getpid());
            stage = "measure-sandbox";
            const auto sandbox = amcl::permissionprobe::Run(roots.sandbox, nonce);
            std::string external;
            if (roots.external.empty()) external = "{\"status\":\"NOT-RUN\",\"reason\":\"external-root-unavailable\"}";
            else {
                try {
                    auto externalRoot = io::Directory(roots.external);
                    struct stat externalStat{};
                    io::Require(fstat(externalRoot.get(), &externalStat) == 0, "无法核对外部根对象");
                    if (externalStat.st_dev == recordedStat.st_dev && externalStat.st_ino == recordedStat.st_ino)
                        external = "{\"status\":\"NOT-RUN\",\"reason\":\"external-is-sandbox\"}";
                    else external = amcl::permissionprobe::Run(roots.external, nonce);
                } catch (const std::exception& failure) {
                    external = "{\"status\":\"NOT-RUN\",\"reason\":\"external-root-not-accessible\",\"error\":" + Quote(failure.what()) + "}";
                }
            }
            result = "{\"schema\":1,\"status\":\"OBSERVED\",\"rootsSha256\":" + Quote(io::Digest(text)) +
                ",\"source\":" + Quote(roots.source) + ",\"sandbox\":" + sandbox + ",\"external\":" + external + "}";
        }
    } catch (const std::exception& failure) {
        result = "{\"status\":\"NOT-RUN\",\"reason\":\"permission-measurement-failed\",\"stage\":" +
            Quote(stage) + ",\"error\":" + Quote(failure.what()) + "}";
    }
    io::Fd output(openat(run, "permission-report.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
    if (output.get() < 0) io::Error("权限资格报告已存在或不可创建");
    io::Write(output.get(), result.data(), result.size()); io::Sync(output.get()); io::Sync(run);
    return result;
}
} // namespace amcl::jdkqualification
#endif
