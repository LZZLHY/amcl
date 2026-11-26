/**
 * 触控组的有界运行事务。由 touch_input 的 surface→touch→schema 临界区独占调用。
 * 本对象不拥有线程、锁、SDK 资源或按键账本；提交后的失效成员由原解释器定向退休。
 * v4 schema 通过独立扩展传入，AmclCtrlEntry/v2/v3 的字节布局完全保持。
 */
#ifndef AMCL_TOUCH_GROUP_STATE_H
#define AMCL_TOUCH_GROUP_STATE_H
#include "control_schema_abi.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <deque>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace amcl::input {
constexpr size_t kMaxTouchGroups = 128;
constexpr size_t kMaxTouchGroupTargets = 128;
constexpr size_t kMaxTouchGroupOperations = 1024;
constexpr size_t kTouchGroupQueueCapacity = 64;
constexpr size_t kTouchGroupResultCapacity = 64;

/** 操作值固定用于新 NAPI 协议；阶段下标依次是 press、longPress、click、doubleClick。 */
enum class TouchGroupOperation : uint8_t { Toggle, Show, Hide, ToggleSecondary, CloseSecondary };
struct TouchGroupAction {
    uint32_t target = 0;
    TouchGroupOperation operation = TouchGroupOperation::Toggle;
    bool operator==(const TouchGroupAction& b) const { return target == b.target && operation == b.operation; }
};
struct TouchGroupPhase {
    std::vector<int> keys;
    bool autoKeep = false;
    std::vector<TouchGroupAction> actions;
    bool operator==(const TouchGroupPhase& b) const { return keys == b.keys && autoKeep == b.autoKeep && actions == b.actions; }
    bool Active() const { return !keys.empty() || !actions.empty(); }
};
struct TouchGroupControl {
    int group = -1; // -1 仅供受保护系统入口与运行辅助区，不是用户可创建组。
    bool phases = false;
    bool fcl = false;
    bool mouseTool = false;
    int rank = 0;
    std::array<TouchGroupPhase, 4> bindings{};
    // 结构编译时解析为组索引。绑定期间不执行原游戏键；MOVE和命中只读此索引，不查字符串。
    int secondaryTarget = -1;
    bool secondaryReturn = false;
    bool operator==(const TouchGroupControl& b) const {
        return group == b.group && phases == b.phases && fcl == b.fcl && mouseTool == b.mouseTool && rank == b.rank && bindings == b.bindings &&
            secondaryTarget == b.secondaryTarget && secondaryReturn == b.secondaryReturn;
    }
};
struct TouchGroupDefinition {
    std::string id;
    bool initialVisible = true;
    bool secondary = false;
    bool hidePrimary = false;
    bool operator==(const TouchGroupDefinition& b) const {
        return id == b.id && initialVisible == b.initialVisible && secondary == b.secondary && hidePrimary == b.hidePrimary;
    }
};
struct TouchGroupSchema {
    std::string profile;
    std::vector<TouchGroupDefinition> groups;
    std::vector<TouchGroupControl> controls;
    // 外设精简投影仅包含系统工具和临时UI区；记录原组态供本局展开时恢复。
    bool systemControlsOnly = false;
    bool operator==(const TouchGroupSchema& b) const {
        return profile == b.profile && groups == b.groups && controls == b.controls && systemControlsOnly == b.systemControlsOnly;
    }
    bool Enabled() const { return !groups.empty(); }
};

/** 最终 native 安装边界仍再次校验，不依赖 NAPI 曾经验证过引用或键列表。 */
inline bool ValidTouchGroupSchema(const TouchGroupSchema& value, size_t controls) {
    // 无组方案使用原v3；空扩展不能伪造组身份。
    if (!value.Enabled()) return value.controls.empty() && value.profile.empty() && !value.systemControlsOnly;
    if (value.profile.empty() || value.profile.size() > 192 || value.groups.size() > kMaxTouchGroups ||
        value.controls.size() != controls || controls > AMCL_CONTROL_SCHEMA_MAX_CONTROLS) return false;
    std::set<std::string> ids;
    for (const auto& group : value.groups) {
        if ((group.secondary && group.initialVisible) || (!group.secondary && group.hidePrimary)) return false;
        if (group.id.empty() || group.id.size() > 23 || !ids.insert(group.id).second) return false;
        for (unsigned char c : group.id) if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '_' || c == '-')) return false;
    }
    size_t operations = 0;
    std::set<int> openers, returns;
    for (const auto& control : value.controls) {
        // 精简表的几何均属系统区域，禁止借此开关将普通组动作附在恢复入口上。
        if (value.systemControlsOnly && (control.group != -1 || control.phases || control.mouseTool || control.secondaryTarget >= 0)) return false;
        if (control.group < -1 || control.group >= static_cast<int>(value.groups.size()) ||
            control.rank < 0 || control.rank >= AMCL_CONTROL_SCHEMA_MAX_CONTROLS ||
            control.secondaryTarget < -1 || control.secondaryTarget >= static_cast<int>(value.groups.size())) return false;
        if (control.secondaryTarget >= 0) {
            const auto target = static_cast<size_t>(control.secondaryTarget);
            if (!value.groups[target].secondary || !control.phases || control.fcl || control.mouseTool ||
                (control.secondaryReturn ? control.group != control.secondaryTarget :
                    control.group < 0 || value.groups[control.group].secondary)) return false;
            auto& seen = control.secondaryReturn ? returns : openers;
            if (!seen.insert(control.secondaryTarget).second) return false;
            for (size_t phase = 0; phase < control.bindings.size(); ++phase) {
                const auto& binding = control.bindings[phase];
                if (phase != 0) { if (binding.Active() || binding.autoKeep) return false; continue; }
                const auto operation = control.secondaryReturn ? TouchGroupOperation::CloseSecondary : TouchGroupOperation::ToggleSecondary;
                if (!binding.keys.empty() || binding.autoKeep || binding.actions.size() != 1 ||
                    binding.actions[0].target != target || binding.actions[0].operation != operation) return false;
            }
        } else if (control.secondaryReturn) return false;
        bool active = false;
        for (const auto& phase : control.bindings) {
            active |= phase.Active();
            if (phase.keys.size() > AMCL_CONTROL_MAX_KEYS || phase.actions.size() > kMaxTouchGroupTargets) return false;
            for (int key : phase.keys) if (!((key >= 32 && key <= 348) || (key >= -8 && key <= -1))) return false;
            for (const auto& action : phase.actions) {
                if (action.target >= value.groups.size() || static_cast<unsigned>(action.operation) > 4) return false;
                if (static_cast<unsigned>(action.operation) >= 3 ? control.secondaryTarget != static_cast<int>(action.target) :
                    value.groups[action.target].secondary) return false;
            }
            operations += phase.actions.size();
        }
        if ((control.phases && !active) || (!control.phases && active) || (control.fcl && !control.phases)) return false;
    }
    return operations <= kMaxTouchGroupOperations;
}

/** 已接受意图冻结来源和 payload；排队后来源被隐藏不改变这份离散动作。 */
struct TouchGroupCommand {
    uint64_t producer = 0, sequence = 0;
    int control = -1;
    uint64_t eligibility = 0;
    std::vector<TouchGroupAction> actions;
    bool SamePayload(const TouchGroupCommand& b) const {
        return producer == b.producer && sequence == b.sequence && control == b.control &&
            eligibility == b.eligibility && actions == b.actions;
    }
};
enum class TouchGroupCommandStatus { Pending, Committed, Presented, Stale, Rejected, Expired };
struct TouchGroupResult {
    TouchGroupCommand command;
    TouchGroupCommandStatus status = TouchGroupCommandStatus::Rejected;
    uint64_t revision = 0;
};

/**
 * 一个在途呈现 + FIFO。只推进离散事件；持续 MOVE 仅读现有绑定，不扫描本对象。
 * 查询不推进；确认只结束自己的 revision。上一命令无状态变化时直接完成，无需 UI ACK。
 */
class TouchGroupState final {
public:
    const TouchGroupSchema& Definition() const { return definition_; }
    const std::vector<uint8_t>& Mask() const { return mask_; }
    const std::vector<uint64_t>& Epochs() const { return epochs_; }
    uint64_t Revision() const { return revision_; }
    bool PendingPresentation() const { return flight_; }
    bool Enabled() const { return definition_.Enabled(); }
    bool Visible(size_t control) const {
        if (!Enabled()) return true;
        if (control >= definition_.controls.size()) return false;
        return VisibleFor(control, mask_, activeSecondary_);
    }
    /** 当前展开键高于二级成员，返回键次之；Native命中与UI绘制都读取此同一结果。 */
    int Rank(size_t control) const { return RankFor(control, activeSecondary_); }
    bool HasHiddenControls() const { return hiddenControls_; }
    uint64_t Epoch(size_t control) const {
        if (!Enabled()) return 0;
        if (control >= definition_.controls.size()) return 0;
        if (secondaryEnabled_) return controlEpochs_[control];
        const int group = definition_.controls[control].group;
        return group < 0 ? 1 : epochs_[static_cast<size_t>(group)];
    }
    const std::set<size_t>& ChangedGroups() const { return changed_; }

    /** 承接owner在当前场景可能没有几何节点，仍按原稳定组身份判断是否被当前层级隐藏。 */
    bool CarriedGroupVisible(const std::string& id) const {
        if (!Enabled()) return true;
        for (size_t group = 0; group < definition_.groups.size(); ++group) if (definition_.groups[group].id == id) {
            if (activeSecondary_ >= 0 && definition_.groups[activeSecondary_].hidePrimary &&
                static_cast<int>(group) != activeSecondary_) return false;
            return mask_[group] != 0;
        }
        return id.empty() && !(activeSecondary_ >= 0 && definition_.groups[activeSecondary_].hidePrimary);
    }

    /** 结构发布已取得零触点保护。相同 profile 按稳定组 ID 迁移；新方案取初始态。 */
    void Install(const TouchGroupSchema& next) {
        std::map<std::string, uint8_t> previous, previousBase;
        std::string previousActive;
        if (next.profile == definition_.profile) {
            for (size_t i = 0; i < mask_.size(); ++i) previous[definition_.groups[i].id] = mask_[i];
            if (activeSecondary_ >= 0) {
                previousActive = definition_.groups[activeSecondary_].id;
                for (size_t i = 0; i < secondaryBase_.size(); ++i) previousBase[definition_.groups[i].id] = secondaryBase_[i];
            }
        }
        RetireTransactions();
        // 只有安装新结构（由新 publication token 保护）才允许清生产者水位。
        // 同结构的生命周期退休仍须记住已接受序号，避免无成员的恢复初始态命令被重放。
        highWater_.clear();
        definition_ = next; mask_.clear(); epochs_.clear(); controlEpochs_.clear(); secondaryBase_.clear();
        activeSecondary_ = -1; secondaryEnabled_ = false; hiddenControls_ = false; changedControls_.clear();
        for (size_t i = 0; i < definition_.groups.size(); ++i) {
            const auto& group = definition_.groups[i]; secondaryEnabled_ |= group.secondary;
            // 精简档暂时没有展开键几何；真正回到完整投影时才按现有入口决定恢复或收起。
            if (group.secondary && group.id == previousActive && (next.systemControlsOnly ||
                std::any_of(definition_.controls.begin(), definition_.controls.end(),
                    [i](const TouchGroupControl& control) { return control.secondaryTarget == static_cast<int>(i) && !control.secondaryReturn; })))
                activeSecondary_ = static_cast<int>(i);
        }
        for (const auto& group : definition_.groups) {
            // 入口在新结构中消失时恢复展开前一级快照，不能把临时二级态带入新布局。
            const auto& source = !previousActive.empty() && activeSecondary_ < 0 ? previousBase : previous;
            const auto old = source.find(group.id);
            mask_.push_back(group.secondary ? group.id == previousActive && activeSecondary_ >= 0 :
                old == source.end() ? group.initialVisible : old->second);
            if (activeSecondary_ >= 0) {
                const auto base = previousBase.find(group.id);
                secondaryBase_.push_back(group.secondary ? 0 : base == previousBase.end() ? group.initialVisible : base->second);
            }
            epochs_.push_back(NextEpoch());
        }
        for (size_t i = 0; i < definition_.controls.size(); ++i) controlEpochs_.push_back(NextEpoch());
        ++revision_;
    }

    /** 生命周期撤销只清在途意图与呈现门，保持本局开关；新控件资格使旧节点不能复活。 */
    void RetireTransactions() {
        queue_.clear(); results_.clear(); changed_.clear(); changedControls_.clear(); hiddenControls_ = false; flight_ = false;
        for (auto& epoch : epochs_) epoch = NextEpoch();
        for (auto& epoch : controlEpochs_) epoch = NextEpoch();
        // mask 不变也有新的成员资格。原维护回执以 revision 判断是否读取完整 epochs，
        // 必须一起前移，否则生命周期恢复后 UI 会一直拿旧 epoch 请求同一可见成员。
        // 这不是一次显隐呈现，不设置 flight，也不要求新的 didLayout 才能恢复。
        if (Enabled() && revision_ != UINT64_MAX) ++revision_;
    }

    /** 幂等窗口先于当前资格校验；已完成命令不会因 revision 前进再次执行。 */
    TouchGroupResult Query(const TouchGroupCommand& command) const {
        for (const auto& result : results_) {
            if (result.command.producer == command.producer && result.command.sequence == command.sequence)
                return result.command.SamePayload(command) ? result : Result(command, TouchGroupCommandStatus::Rejected);
        }
        for (const auto& queued : queue_) {
            if (queued.producer == command.producer && queued.sequence == command.sequence)
                return Result(command, queued.SamePayload(command) ? TouchGroupCommandStatus::Pending : TouchGroupCommandStatus::Rejected);
        }
        const auto high = highWater_.find(command.producer);
        return Result(command, high != highWater_.end() && command.sequence <= high->second ?
            TouchGroupCommandStatus::Expired : TouchGroupCommandStatus::Rejected);
    }

    /** 预留在新增键输出之前完成。false 表示没有接受，不能随后发送键或副作用。 */
    bool CanAccept(const TouchGroupCommand& command) const {
        if (!Enabled() || command.producer == 0 || command.sequence == 0 || queue_.size() >= kTouchGroupQueueCapacity ||
            command.actions.size() > kMaxTouchGroupTargets || revision_ == UINT64_MAX || nextEpoch_ == UINT64_MAX) return false;
        const auto high = highWater_.find(command.producer);
        if (high != highWater_.end() && command.sequence <= high->second) return false;
        if (high == highWater_.end() && highWater_.size() >= 256) return false;
        if (command.control >= 0 && (!Visible(command.control) || Epoch(command.control) != command.eligibility)) return false;
        for (const auto& action : command.actions) {
            if (action.target >= mask_.size() || static_cast<unsigned>(action.operation) > 4) return false;
            if (static_cast<unsigned>(action.operation) >= 3) {
                if (command.control < 0 || static_cast<size_t>(command.control) >= definition_.controls.size()) return false;
                const auto& member = definition_.controls[command.control];
                if (member.secondaryTarget != static_cast<int>(action.target) ||
                    member.secondaryReturn != (action.operation == TouchGroupOperation::CloseSecondary)) return false;
            } else if (definition_.groups[action.target].secondary && (command.control >= 0 || action.operation != TouchGroupOperation::Hide)) return false;
        }
        return true;
    }

    /** caller 持同一锁，已完成 CanAccept 和按键接受，期间没有其它调用者可消耗预留容量。 */
    bool Accept(const TouchGroupCommand& command) {
        if (!CanAccept(command)) return false;
        // 水位分配先于队列，失败最多消耗序号，不留下没有幂等身份的已接受项。
        highWater_[command.producer] = command.sequence; queue_.push_back(command);
        return true;
    }

    /** 组合动作先预留队尾，再调用原按键事务；键拒绝时原样撤销这条尚未执行的意图。 */
    void RejectReserved(const TouchGroupCommand& command) {
        if (!queue_.empty() && queue_.back().SamePayload(command)) {
            queue_.pop_back(); Remember(Result(command, TouchGroupCommandStatus::Rejected));
        }
    }

    /** 有界推进到一项真实变化。返回被隐藏组，调用方随后在同一临界区退休全部成员。 */
    std::set<size_t> Advance() {
        std::set<size_t> hidden;
        hiddenControls_ = false;
        if (flight_) return hidden;
        size_t budget = kTouchGroupQueueCapacity;
        while (!queue_.empty() && budget-- > 0) {
            const auto command = queue_.front();
            auto next = mask_;
            auto nextBase = secondaryBase_;
            int nextSecondary = activeSecondary_;
            // 无成员命令只由“恢复初始显隐”入口产生，先收起二级，再执行完整初始目标态。
            if (command.control < 0 && nextSecondary >= 0) { next = nextBase; nextBase.clear(); nextSecondary = -1; }
            for (const auto& action : command.actions) {
                if (action.operation == TouchGroupOperation::ToggleSecondary || action.operation == TouchGroupOperation::CloseSecondary) {
                    if (nextSecondary == static_cast<int>(action.target)) {
                        next = nextBase; nextBase.clear(); nextSecondary = -1;
                    } else if (action.operation == TouchGroupOperation::ToggleSecondary) {
                        if (nextSecondary < 0) nextBase = next;
                        for (size_t group = 0; group < next.size(); ++group) if (definition_.groups[group].secondary) next[group] = 0;
                        next[action.target] = 1; nextSecondary = static_cast<int>(action.target);
                    }
                    continue;
                }
                auto& visible = next[action.target];
                visible = action.operation == TouchGroupOperation::Toggle ? !visible : action.operation == TouchGroupOperation::Show;
            }
            std::set<size_t> changed;
            std::set<size_t> changedControls;
            for (size_t i = 0; i < next.size(); ++i) if (next[i] != mask_[i]) changed.insert(i);
            bool retiresControls = false;
            for (size_t i = 0; i < definition_.controls.size(); ++i) {
                const bool before = VisibleFor(i, mask_, activeSecondary_), after = VisibleFor(i, next, nextSecondary);
                const int group = definition_.controls[i].group;
                if (before != after || RankFor(i, activeSecondary_) != RankFor(i, nextSecondary) ||
                    (group >= 0 && changed.count(static_cast<size_t>(group)))) changedControls.insert(i);
                if (before && !after) { retiresControls = true; if (group >= 0) hidden.insert(static_cast<size_t>(group)); }
            }
            if (changed.empty() && changedControls.empty() && nextSecondary == activeSecondary_) {
                Remember(Result(command, TouchGroupCommandStatus::Presented)); queue_.pop_front(); continue;
            }
            for (size_t group : changed) if (!next[group]) hidden.insert(group);
            auto receipt = Result(command, TouchGroupCommandStatus::Committed); receipt.revision = revision_ + 1;
            // 所有分配均在提交前完成。结果分配失败保留队首，下一次维护仍可执行同一意图。
            Remember(std::move(receipt));
            for (size_t group : changed) {
                epochs_[group] = NextEpoch();
            }
            for (size_t control : changedControls) controlEpochs_[control] = NextEpoch();
            changed_.swap(changed); changedControls_.swap(changedControls); hiddenControls_ = retiresControls;
            mask_.swap(next); secondaryBase_.swap(nextBase); activeSecondary_ = nextSecondary;
            queue_.pop_front(); ++revision_; flight_ = true;
            break;
        }
        return hidden;
    }

    bool Confirm(uint64_t revision) {
        if (!flight_ || revision != revision_) return false;
        for (auto& result : results_) if (result.status == TouchGroupCommandStatus::Committed && result.revision == revision)
            result.status = TouchGroupCommandStatus::Presented;
        flight_ = false; changed_.clear(); changedControls_.clear(); hiddenControls_ = false; return true;
    }

    /** 变化区域含原/新热区的 slop；交叠 UI 控件也必须关闭准入，不能仅检查其自身组。 */
    bool BlocksPoint(float x, float y, const std::vector<AmclCtrlEntry>& entries) const {
        if (!flight_) return false;
        for (size_t i = 0; i < entries.size() && i < definition_.controls.size(); ++i) {
            if (changedControls_.count(i) == 0) continue;
            const auto& e = entries[i]; const float p = e.hitSlop;
            if (x >= e.x-p && x < e.x+e.w+p && y >= e.y-p && y < e.y+e.h+p) return true;
        }
        return false;
    }

    bool BlocksControl(size_t index, const std::vector<AmclCtrlEntry>& entries) const {
        if (!flight_) return false;
        if (index >= entries.size()) return true;
        const auto& target = entries[index];
        for (size_t i = 0; i < entries.size() && i < definition_.controls.size(); ++i) {
            if (changedControls_.count(i) == 0) continue;
            const auto& e = entries[i];
            if (target.x-target.hitSlop < e.x+e.w+e.hitSlop && target.x+target.w+target.hitSlop > e.x-e.hitSlop &&
                target.y-target.hitSlop < e.y+e.h+e.hitSlop && target.y+target.h+target.hitSlop > e.y-e.hitSlop) return true;
        }
        return false;
    }

private:
    /** 有界索引投影，不重建组表。当前展开键是隐藏一级时的收起入口，返回键只在所属层展开时可见。 */
    bool VisibleFor(size_t index, const std::vector<uint8_t>& mask, int active) const {
        if (definition_.systemControlsOnly) return true;
        const auto& control = definition_.controls[index];
        if (control.secondaryTarget >= 0 && !control.secondaryReturn && control.secondaryTarget == active) return true;
        if (control.secondaryReturn) return control.secondaryTarget == active;
        if (control.group >= 0 && definition_.groups[control.group].secondary)
            return control.group == active && mask[control.group] != 0;
        if (active >= 0 && definition_.groups[active].hidePrimary) return false;
        return control.group < 0 || mask[control.group] != 0;
    }
    int RankFor(size_t index, int active) const {
        if (index >= definition_.controls.size()) return 0;
        const auto& control = definition_.controls[index];
        return control.rank + (active >= 0 && control.secondaryTarget == active ?
            (control.secondaryReturn ? AMCL_CONTROL_SCHEMA_MAX_CONTROLS : 2 * AMCL_CONTROL_SCHEMA_MAX_CONTROLS) : 0);
    }
    uint64_t NextEpoch() { return nextEpoch_ == UINT64_MAX ? 0 : ++nextEpoch_; }
    TouchGroupResult Result(const TouchGroupCommand& command, TouchGroupCommandStatus status) const {
        return {command, status, revision_};
    }
    void Remember(TouchGroupResult result) {
        if (results_.size() == kTouchGroupResultCapacity) results_.pop_front();
        results_.push_back(std::move(result));
    }
    TouchGroupSchema definition_;
    std::vector<uint8_t> mask_;
    std::vector<uint64_t> epochs_;
    std::vector<uint64_t> controlEpochs_;
    std::vector<uint8_t> secondaryBase_;
    int activeSecondary_ = -1;
    bool secondaryEnabled_ = false, hiddenControls_ = false;
    uint64_t revision_ = 0, nextEpoch_ = 0;
    bool flight_ = false;
    std::set<size_t> changed_;
    std::set<size_t> changedControls_;
    std::deque<TouchGroupCommand> queue_;
    std::deque<TouchGroupResult> results_;
    std::map<uint64_t, uint64_t> highWater_;
};
}
#endif
