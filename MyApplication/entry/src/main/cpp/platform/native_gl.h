#pragma once
#include <string>

namespace amcl::desktop {
struct NativeGlCapability {
    // 启动声明与设备能力分开；清理错误独立记录，不能覆盖首个渲染/驱动错误。
    bool bootstrapConfigured = false;
    bool systemLibrary = false;
    bool ready = false;
    bool queryAvailable = false;
    bool querySupported = false;
    bool contextCreated = false;
    bool pixelVerified = false;
    int error = 0;
    bool cleanupComplete = true;
    bool restartRequired = false;
    int cleanupError = 0;
    std::string errorDomain, cleanupStage;
    std::string stage = "query", version, vendor, renderer;
    std::string renderDiagnostics;
};
bool NativeGlValidationEnabled();
bool NativeGlRequired();
bool NativeGlRequested();
void* NativeGlProc(const char* name);
NativeGlCapability QueryNativeGlCapability(bool detailed = false, bool availabilityOnly = false);
/** 仅格式化已有失败事实供启动页与日志使用，不重新查询驱动或改变错误状态。 */
std::string NativeGlFailureDetail(const NativeGlCapability& capability);
}
