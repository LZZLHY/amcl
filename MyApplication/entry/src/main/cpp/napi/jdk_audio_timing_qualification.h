/** 固定TestHooks播放时钟观察。独立profile调用，不参与正常JavaSound播放判定。
 * 仅输出真实SDK返回值/计数，无Capture、无PCM落盘；外层NCP watchdog约束系统API卡住。 */
#pragma once
#ifdef MC_OHOS_BUILD_TESTS
#include <string>
namespace amcl::jdkqualification {
/** runFd为已经核验的独占资格运行目录；固定创建audio-timing-report.json并返回同一正文。 */
std::string RunAudioTimingQualification(int runFd);
}
#endif
