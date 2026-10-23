/** 复用原有系统mock故障语义，只新增实际注册回调地址观察；不复制生产后端。 */
#include "../ohaudio-host/mock_ohaudio.cpp"
extern "C" AUDIT_EXPORT void* auditCurrentWriteAddress() {
    std::lock_guard<std::mutex> lock{mutex};
    return active ? reinterpret_cast<void*>(active->write) : reinterpret_cast<void*>(lateWrite);
}
