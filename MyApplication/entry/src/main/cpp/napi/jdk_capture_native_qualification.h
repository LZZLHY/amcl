/* TestHooks固定原生录音对照。调用者必须绑定本轮短录音授权和10s子进程看门狗；
 * 本接口不申请权限，只创建48k/S16LE/mono/MIC/RAW的NORMAL/FAST两条顺序流，
 * 各统计首9600帧，不存原始PCM。成功返回并独占写JSON；失败先写FAILED再抛异常。 */
#pragma once
#ifdef MC_OHOS_BUILD_TESTS
#include <string>
namespace amcl::jdkqualification {
std::string RunCaptureNativeQualification(int runFd);
/* 固定两臂都FAST/48k/mono；首臂显式MONO，次臂保留builder默认layout。各200ms且分5×40ms统计，
 * 不丢首段、不改生产。输出capture-layout-report.json，失败同样先落盘再抛异常。 */
std::string RunCaptureLayoutQualification(int runFd);
/* 必须另获1秒录音同意的固定启动观察：单流FAST/48k/S16LE/mono/MIC/RAW，
 * builder默认layout，统计首48000帧和25×40ms，不丢首帧、不保存PCM。
 * 调用方仍须10s独占NCP看门狗；本函数不申请权限或自动扩大旧200ms入口。
 * 输出capture-startup-report.json；完成Stop/Release并静止回调后才读/写统计。 */
std::string RunCaptureStartupQualification(int runFd);
/* 新一轮必须另获授权的固定通道对照：stereo-first/mono-second，均48k/S16LE/MIC/RAW/FAST、
 * 默认layout，各首9600帧和5×40ms。要求三个实际getter快照匹配通道数与FAST、流ID稳定；
 * 不满足是对照前提失败，不能据此推断mono异常成因。每声道及同帧double算术平均只输出统计，
 * 不量化/播放/保存PCM，不把平均当生产修复。复用原10s owner与Stop/Release静止合同。
 * 输出capture-channels-report.json；失败先写FAILED再抛异常。 */
std::string RunCaptureChannelsQualification(int runFd);
}
#endif
