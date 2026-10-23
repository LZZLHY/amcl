#include "control_schema_contract.h"
#include <cmath>
#include <cstring>
namespace amcl::input {
// 旧接触按DOWN时快照收尾。只有身份、命中、解释权或有效输入动作变化才退休贡献；
// haptic只是低频观察副作用，新的反馈不撤销旧owner，也不改写旧接触的冻结快照。
bool SameControlSchemaBinding(const AmclCtrlEntry& a, const AmclCtrlEntry& b) {
    if (std::strcmp(a.id, b.id) || a.kind != b.kind || a.handledBy != b.handledBy ||
        a.x != b.x || a.y != b.y || a.w != b.w || a.h != b.h || a.hitSlop != b.hitSlop ||
        a.trigger != b.trigger || a.dragLook != b.dragLook ||
        a.keyCount != b.keyCount || a.swipeGroup != b.swipeGroup) return false;
    if (a.keyCount == 0 && a.keyOrMouse != b.keyOrMouse) return false;
    for (int k = 0; k < a.keyCount; ++k) if (a.keys[k] != b.keys[k]) return false;
    return true;
}

// 完整定义还包含反馈：只移除生存判定中的haptic，不能让新触点永久沿用旧开关。
bool SameControlSchemaEntry(const AmclCtrlEntry& a, const AmclCtrlEntry& b) {
    return SameControlSchemaBinding(a, b) && a.haptic == b.haptic;
}

// 纯反馈整表变化保留菜单/工具的合法前缀；顺序仍属于输入绑定，因为它裁决重叠DOWN。
bool SameControlSchemaBindings(const std::vector<AmclCtrlEntry>& current,
                               const AmclCtrlEntry* next, int count) {
    if (count < 0 || current.size() != static_cast<size_t>(count) || (count && !next)) return false;
    for (int i = 0; i < count; ++i)
        if (!SameControlSchemaBinding(current[static_cast<size_t>(i)], next[i])) return false;
    return true;
}

// 整表等价仍比较顺序，以保留重叠且等距时的DOWN命中优先级；持有保留另按单控件快照判断。
bool SameControlSchemaEntries(const std::vector<AmclCtrlEntry>& current,
                             const AmclCtrlEntry* next, int count) {
    if (count < 0 || current.size() != static_cast<size_t>(count) || (count && !next)) return false;
    for (int i = 0; i < count; ++i) {
        const auto& a = current[static_cast<size_t>(i)];
        const auto& b = next[i];
        if (!SameControlSchemaEntry(a, b)) return false;
    }
    return true;
}

int ControlHotbarSlot(const AmclCtrlEntry& entry, float x, float y) {
    if (!std::isfinite(x) || !std::isfinite(y) || entry.w <= 0 || entry.h <= 0 ||
        x < entry.x || y < entry.y || x >= entry.x + entry.w || y >= entry.y + entry.h) return -1;
    const int slot = static_cast<int>(std::floor((x - entry.x) * 9.0 / entry.w));
    return slot >= 0 && slot < 9 ? slot : -1;
}
float ControlScrollStepPx(double density) {
    const double usable = std::isfinite(density) && density > 0.0 && density <= 100.0 ? density : 1.0;
    return static_cast<float>(12.0 * usable);
}
}
