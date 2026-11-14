/* TestHooks固定诊断收据。只有控制线程写文件；callback只累加有界统计，没有IO或JNI。 */
#include "jdk_capture_diagnostics.h"
#ifdef MC_OHOS_BUILD_TESTS
#include "../javasound/ohos_capture_diagnostics.h"
#include "../platform/jdk_install_io.h"
#include <cmath>
#include <fcntl.h>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <unistd.h>

namespace amcl::jdkqualification {
void BeginCaptureDiagnostic()
{
    if (!amcl_capture_diagnostics_begin()) throw std::runtime_error("capture diagnostic can only arm once in this child");
}

std::string FinishCaptureDiagnostic(int runFd)
{
    AmclCaptureDiagnosticReport report{};
    const bool quiescent = amcl_capture_diagnostics_finish(&report) != 0;
    std::ostringstream text; text << std::setprecision(17);
    text << "{\"protocol\":\"AMCL_CAPTURE_DIAGNOSTIC_V1\",\"status\":\""
         << (quiescent ? "OBSERVED" : "INCOMPLETE") << "\",\"quiescent\":" << (quiescent ? "true" : "false")
         << ",\"selectedTables\":" << report.selectedTables << ",\"rawPcmSaved\":false,\"signalQualified\":false,\"passes\":[";
    for (unsigned index = 0; index < 2; ++index) {
        const auto &pass = report.passes[index];
        /* 总计入字节未超过整个逻辑容量，严格保证最初前缀从未被覆盖。此充分条件
         * 故意保守：超过容量可能仍被及时读取，但无安全consumed快照就不能认定可比较。 */
        const bool comparable = quiescent && report.selectedTables == 2 && !pass.flags && !pass.lineError &&
            pass.frameSize == 2 && pass.capacityBytes > 0 && pass.acceptedBytes <= pass.capacityBytes &&
            pass.measuredFrames == pass.targetFrames && pass.targetFrames > 0 &&
            pass.acceptedBytes >= pass.measuredFrames * 2 && pass.peak <= 32768 &&
            pass.sumSquares <= pass.measuredFrames * UINT64_C(1073741824);
        const double rms = pass.measuredFrames ? std::sqrt(double(pass.sumSquares) / double(pass.measuredFrames)) : 0;
        if (index) text << ',';
        text << "{\"index\":" << index << ",\"expectedRate\":" << pass.expectedRate << ",\"targetFrames\":" << pass.targetFrames
             << ",\"frameSize\":" << pass.frameSize << ",\"bufferBytes\":" << pass.capacityBytes << ",\"callbackCount\":" << pass.callbacks
             << ",\"acceptedFrames\":" << pass.acceptedBytes / 2 << ",\"measuredFrames\":" << pass.measuredFrames
             << ",\"peak\":" << pass.peak << ",\"rms\":" << rms << ",\"flags\":" << pass.flags << ",\"lineError\":" << pass.lineError
             << ",\"comparable\":" << (comparable ? "true" : "false") << '}';
    }
    text << "]}\n";
    const std::string value = text.str();
    namespace io = amcl::jdk::io;
    io::Fd output(openat(runFd, "capture-diagnostic-report.json", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600));
    io::Require(output.get() >= 0, "create exclusive capture diagnostic report failed");
    io::Write(output.get(), value.data(), value.size()); io::Sync(output.get()); io::Sync(runFd);
    return value;
}
}
#endif
