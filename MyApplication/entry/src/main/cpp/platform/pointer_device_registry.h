#ifndef AMCL_POINTER_DEVICE_REGISTRY_H
#define AMCL_POINTER_DEVICE_REGISTRY_H

#include <cstdint>
#include <map>

namespace amcl::input {

/**
 * 指针拔除的分类记忆。REMOVED 到达时平台通常已不能读取设备详情，因此保留 ADD
 * 确认过的类别，而不是拿“此刻读不到”当成非鼠标。只负责分类，不持 owner，也不做
 * 任意 inventory id→事件 id 的猜测；调用方仍按各自真实身份释放。
 *
 * 线程约束：由输入 surface gate 串行访问。未知移除只授权清未知鼠标桶；它不会
 * 返回其它已知设备的身份，因而不会把拔一只鼠标变成全端 reset。
 */
class PointerDeviceRegistry final {
public:
    enum class Kind { Unknown = -1, Other = 0, Pointer = 1 };
    struct Removal {
        bool releaseUnknown = false;
        bool classificationMissing = false;
    };

    /** Unknown 不覆盖已有确定分类；迟到的详情失败不能抹掉曾证明的指针身份。 */
    void Added(uint64_t deviceId, Kind kind) {
        if (deviceId == 0u) return;
        const auto current = devices_.find(deviceId);
        if (kind != Kind::Unknown || current == devices_.end()) devices_[deviceId] = kind;
    }

    /** 显式 override 优先；无 override 时使用 ADD 缓存，仍未知则保守清未知桶。 */
    Removal Removed(uint64_t deviceId, Kind overrideKind = Kind::Unknown) {
        Kind kind = overrideKind;
        const auto found = devices_.find(deviceId);
        if (kind == Kind::Unknown && found != devices_.end()) kind = found->second;
        if (found != devices_.end()) devices_.erase(found);
        return {kind != Kind::Other, kind == Kind::Unknown};
    }

private:
    std::map<uint64_t, Kind> devices_;
};

}  // namespace amcl::input
#endif
