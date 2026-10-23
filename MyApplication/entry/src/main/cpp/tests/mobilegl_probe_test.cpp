#include "tests.h"
#include "../platform/mobilegl_capability.h"
#include "../utils/amcl_log.h"
#include "test_loaded_image_evidence.h"
#include <chrono>
#include <cerrno>
#include <mutex>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace {
constexpr const char* kDirectory = "/data/storage/el2/base/haps/entry/files/mobilegl-capability-probe";
std::mutex evidenceMutex;

// NativeProbeHost以libentry目录加载libmobilegl.so；包装函数也属于同libentry映像，
// 此处从真实dladdr取得相同目录，不引入任意路径参数或另一个provider搜索策略。
std::string RequestedMobileGlPath() {
    Dl_info entry{};
    if (!dladdr(reinterpret_cast<void*>(&runMobileglProbe), &entry) || !entry.dli_fname)
        throw std::runtime_error("libentry image identity unavailable");
    const std::string path = entry.dli_fname;
    const auto slash = path.rfind('/');
    if (slash == std::string::npos) throw std::runtime_error("libentry native directory unavailable");
    return path.substr(0, slash) + "/libmobilegl.so";
}
}  // namespace

// 两个历史UI按钮仍调用同一production capability executor，原报告/admission原样
// 保留。TestHooks只追加独立实际库取证：先合法完成诊断，再NOLOAD引用已有DSO。
// 每次run使用新目录，失败/拒绝不可能回读旧copy或旧COMPLETE；宿主按实际UI返回、
// HDC PID及最终HAP独立取证。本函数的完成不代表应用自然退出或lifecycle_smoke已测。
const char* runMobileglProbe(void) {
    std::lock_guard<std::mutex> lock(evidenceMutex);
    static thread_local std::string report;
    const auto steadyNs = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    const auto unixNs = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    const std::string runId = std::to_string(getpid()) + "-" + std::to_string(steadyNs);
    const std::string header = "MOBILEGL_QUAL_RUN runId=" + runId + " processPid=" + std::to_string(getpid()) +
        " startUnixNs=" + std::to_string(unixNs) + " startSteadyNs=" + std::to_string(steadyNs) + "\n";
    const std::string directory = std::string(kDirectory) + "/" + runId;
    // 生产调用本身不为取证创建/修改图形状态；无论copy成功与否，原功能文本均保留。
    const std::string capability = amcl::graphics::MobileGlCapabilityDiagnosticReport();
    report = header + capability;
    if (report.empty() || report.back() != '\n') report += '\n';
    bool copied = false;
    try {
        if (mkdir(kDirectory, 0700) != 0 && errno != EEXIST)
            throw std::runtime_error("cannot create qualification root");
        if (mkdir(directory.c_str(), 0700) != 0)
            throw std::runtime_error("cannot create unique qualification run directory");
        if (capability.find("\nadmission=PASS reason=mobilegl_launch_prerequisites_verified\n") == std::string::npos)
            throw std::runtime_error("production capability did not admit this experiment");
        const std::string requested = RequestedMobileGlPath();
        amcl::test_evidence::NoLoadReference reference(requested);
        const Dl_info owner = amcl::test_evidence::VerifyImageOwner(reference, requested, "eglGetDisplay");
        const std::string actual = amcl::test_evidence::CanonicalImagePath(owner.dli_fname);
        const std::string destination = directory + "/loaded-libmobilegl.so";
        const auto bytes = amcl::test_evidence::CopyImageChecked(actual, destination);
        std::ostringstream identity;
        identity << "MOBILEGL_QUAL_IMAGE library=libmobilegl.so anchor=eglGetDisplay image=" << actual
            << " imageBase=" << owner.dli_fbase << " bytes=" << bytes << " path=" << destination << '\n';
        report += identity.str();
        reference.Retire();
        copied = true;
    } catch (const std::exception& error) {
        report += "MOBILEGL_QUAL_FAILURE reason=" + std::string(error.what()) + "\n";
    }
    report += "MOBILEGL_QUAL_END runId=" + runId + " processPid=" + std::to_string(getpid()) +
        " imageCopyComplete=" + std::to_string(copied) + " verdict=" + (copied ? "COMPLETE" : "INCOMPLETE") + "\n";
    try {
        report = amcl::test_evidence::SaveReportChecked(directory + "/result.txt", report);
        const std::size_t reportBytes = report.size();
        // 这个RETURN只出现在真实NAPI返回/hilog；文件END不能自行证明close及回读成功。
        report += "MOBILEGL_QUAL_RETURN runId=" + runId + " processPid=" + std::to_string(getpid()) +
            " reportBytes=" + std::to_string(reportBytes) + " returned=1 verdict=" +
            (copied ? "COMPLETE" : "INCOMPLETE") + "\n";
    } catch (const std::exception& error) {
        report = header + capability + "\nMOBILEGL_QUAL_FAILURE reason=" + std::string(error.what()) +
            "\nMOBILEGL_QUAL_RETURN runId=" + runId + " processPid=" + std::to_string(getpid()) +
            " returned=0 verdict=INCOMPLETE\n";
    }
    std::istringstream lines(report);
    std::string line;
    while (std::getline(lines, line)) AMCL_LOG_I("MOBILEGL_QUAL", "%{public}s", line.c_str());
    return report.c_str();
}

// 保留历史alias，只是同一诊断入口的另一个可见按钮，不产生第二套context资格。
const char* runMobileglPbufferProbe(void) {
    return runMobileglProbe();
}
