// sdl_pointer_device_id.h — SDL3 pull 通道的指针设备号压缩（只用于 SDL 通道的指针记录）
//
// 背景：SDL 补丁把宿主设备号 d 映射成 SDL_MouseID：d == 0 → 0x80000001（“未知物理输入”桶），
// 否则 d + 1；并只接受 d <= 0xFFFFFFFE。这个 +1 映射只在“宿主设备号是正的 32 位有符号数”时
// 单射，而宿主侧从未强制这个前提：d = 0x80000000 会撞进未知桶，0xFFFFFFFD / 0xFFFFFFFE 会撞上
// SDL 的 PEN / TOUCH 保留号，更大的值整包被 SDL 当成畸形丢弃（普查 I27 §2(c)）。
//
// 做法（不改 SDL 二进制）：在宿主编码边界把设备号换进一个 SDL 永远安全的值域。
//   · 0 保持 0：它的含义就是“平台没给身份”，SDL 仍映射到未知桶；
//   · 1..0x7FFFFFFF 原样透传：这是 OpenHarmony 事件设备号的全部合法值域，现有设备的
//     SDL 身份因此完全不变；
//   · 其余值（契约外）按首次出现顺序分配 0x80000001..0xFFFFFFFC 里的号，SDL 侧 +1 后落在
//     0x80000002..0xFFFFFFFD，与未知桶和两个保留号都不相交；两段值域互不重叠，所以整体单射。
//   · DEVICE_REMOVED 编码之后释放该设备的表项；通道失活时整表清空。表满时退回 0 并计数，
//     宁可合并身份也不制造撞号（撞号会让一只鼠标的抬起释放另一只的按住）。
// 键盘事件不经过这里：SDL 键事件使用默认键盘号，保留的 IME 设备号必须原样到达。
//
// 线程：无锁数据结构，调用方持 BackendChannel::mutex（所有 sink 都在该锁内同步执行）。
#ifndef AMCL_INPUT_ADAPTERS_SDL_POINTER_DEVICE_ID_H
#define AMCL_INPUT_ADAPTERS_SDL_POINTER_DEVICE_ID_H

#include <cstddef>
#include <cstdint>
#include <map>
#include <set>

namespace amcl::input {

class SdlPointerDeviceIdMap final {
public:
    static constexpr uint64_t kIdentityMax = 0x7FFFFFFFull;
    static constexpr uint64_t kRemapFirst = 0x80000001ull;
    static constexpr uint64_t kRemapLast = 0xFFFFFFFCull;
    static constexpr size_t kRemapCapacity = 64u;

    // 本次映射结果。remappedNow 表示这一次调用新分配了契约外表项，folded 表示表满退回 0。
    struct Result {
        uint64_t deviceId = 0u;
        bool remappedNow = false;
        bool folded = false;
    };

    Result Map(uint64_t hostId) {
        Result result;
        // 0（未知身份）与正 int32 区间原样返回，不占表项。
        if (hostId <= kIdentityMax) {
            result.deviceId = hostId;
            return result;
        }
        const auto found = byHost_.find(hostId);
        if (found != byHost_.end()) {
            result.deviceId = found->second;
            return result;
        }
        if (byHost_.size() >= kRemapCapacity) {
            ++folded_;
            result.folded = true;
            return result;   // deviceId = 0：退回“未知身份”，不与任何存活设备撞号
        }
        // 游标单调前进；绕回后跳过仍在使用的号。存活表项最多 kRemapCapacity 个，探测有界。
        uint64_t candidate = next_;
        while (inUse_.count(candidate) != 0u) candidate = Advance(candidate);
        next_ = Advance(candidate);
        byHost_.emplace(hostId, candidate);
        inUse_.insert(candidate);
        ++remapped_;
        result.deviceId = candidate;
        result.remappedNow = true;
        return result;
    }

    // DEVICE_REMOVED 已按旧号编码之后调用，释放该设备的表项。契约内的号没有表项，调用无副作用。
    void Release(uint64_t hostId) {
        const auto found = byHost_.find(hostId);
        if (found == byHost_.end()) return;
        inUse_.erase(found->second);
        byHost_.erase(found);
        ++released_;
    }

    // 通道失活：之后的新会话会重新收到设备基线，旧表项不再有意义。计数保留，便于诊断。
    void Clear() {
        byHost_.clear();
        inUse_.clear();
        next_ = kRemapFirst;
    }

    size_t live() const { return byHost_.size(); }
    uint64_t remapped() const { return remapped_; }
    uint64_t released() const { return released_; }
    uint64_t folded() const { return folded_; }

private:
    static uint64_t Advance(uint64_t value) {
        return value >= kRemapLast ? kRemapFirst : value + 1u;
    }

    std::map<uint64_t, uint64_t> byHost_;
    std::set<uint64_t> inUse_;
    uint64_t next_ = kRemapFirst;
    uint64_t remapped_ = 0u;
    uint64_t released_ = 0u;
    uint64_t folded_ = 0u;
};

}  // namespace amcl::input

#endif  // AMCL_INPUT_ADAPTERS_SDL_POINTER_DEVICE_ID_H
