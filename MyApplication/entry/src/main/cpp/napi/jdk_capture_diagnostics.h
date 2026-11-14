/* 固定TestHooks Capture边界统计，不申请权限或启动录音。宿主必须先取得本轮用户授权。
 * Begin在Java diagnostic main前调用；Finish在main返回并已关闭两流后调用，写固定JSON。
 * 没有静止/完整前缀证据时报告不可比较，不根据两个RMS“差不多”自动授予录音资格。 */
#pragma once
#ifdef MC_OHOS_BUILD_TESTS
#include <string>
namespace amcl::jdkqualification {
void BeginCaptureDiagnostic();
std::string FinishCaptureDiagnostic(int runFd);
}
#endif
