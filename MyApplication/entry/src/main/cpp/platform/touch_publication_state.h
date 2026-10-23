/**
 * 触控发布与模态准入的有界状态机。
 *
 * 本模块只保存本次发布身份和具名模态租约，不持有窗口、schema、输出账本或SDK对象。
 * 平台调用方必须以 surface gate → mode → touch → schema 的顺序串行读取真实上下文，
 * 再调用本对象；不允许把一次无锁读取的零触点当成发布许可。发布屏障只关闭新认领，
 * 原角色的MOVE/UP及owner释放由平台独立放行。这里只保留一个发布记录与至多16个模态，
 * 防止重试历史或嵌套页面无限增长。uint64身份不复用，跨NAPI时使用十进制字符串。
 */
#ifndef AMCL_TOUCH_PUBLICATION_STATE_H
#define AMCL_TOUCH_PUBLICATION_STATE_H
#include <cstdint>
#include <map>
#include <string>

namespace amcl::input {

/** 每个数字分别来自真实surface、touch复位域、解释策略和schema，不互相复制。 */
struct TouchPublicationContext {
    uint64_t surface = 0, session = 0, policy = 0, schema = 0;
    uint64_t grabEpoch = 0;
    bool grabbed = false;
    int nativeTouches = 0;
    double density = 1.0;
    uint32_t transform = 0;
    bool SameIdentity(const TouchPublicationContext& other) const {
        return surface == other.surface && session == other.session &&
            policy == other.policy && schema == other.schema &&
            density == other.density && transform == other.transform &&
            grabEpoch == other.grabEpoch && grabbed == other.grabbed;
    }
};

/** Idle无在途操作；Waiting在关门之后等待旧角色抬手；成功仍需当前UI确认才能开门。 */
enum class TouchPublicationStatus { Idle, Fenced, Waiting, Committed, Unchanged, Stale, Invalid, Unavailable };
inline const char* TouchPublicationStatusName(TouchPublicationStatus status) {
    switch (status) {
        case TouchPublicationStatus::Idle: return "idle";
        case TouchPublicationStatus::Fenced: return "fenced";
        case TouchPublicationStatus::Waiting: return "waiting";
        case TouchPublicationStatus::Committed: return "committed";
        case TouchPublicationStatus::Unchanged: return "unchanged";
        case TouchPublicationStatus::Stale: return "stale";
        case TouchPublicationStatus::Invalid: return "invalid";
        case TouchPublicationStatus::Unavailable: return "unavailable";
    }
    return "invalid";
}

/** 回执包含实际上下文；JS回执丢失后查询同一个operation，不能推断Native未提交。 */
struct TouchPublicationReceipt {
    TouchPublicationContext context;
    TouchPublicationStatus status = TouchPublicationStatus::Idle;
    std::string operationId, candidateId;
    uint64_t token = 0;
    bool fenced = false;
    uint32_t modalCount = 0;
    /** 必要维护回执只带标量修订；完整组表仅在改变或恢复时读取。 */
    uint64_t groupRevision = 0;
};

class TouchPublicationState final {
public:
    /** 查询同时观察失效：surface或策略已换代时保持关门，迟到确认不能复活旧几何。 */
    TouchPublicationReceipt Query(const TouchPublicationContext& current) {
        // abort后仍有旧applied可恢复；它也必须绑定原上下文，不能因清了在途operation
        // 就让旧token在新的touch会话、density或surface上重新取得输出。
        const bool stale = !operation_.empty() ? !context_.SameIdentity(current)
            : appliedToken_ != 0 && !appliedContext_.SameIdentity(current);
        if (stale) {
            fenced_ = true;
            status_ = TouchPublicationStatus::Stale;
        }
        return Receipt(current);
    }

    /** 新操作必须绑定完整旧身份。相同操作重试仅返回原状态，不能再次分配token。 */
    TouchPublicationReceipt Begin(const std::string& operation, const std::string& candidate,
            const TouchPublicationContext& expected, const TouchPublicationContext& current) {
        if (!ValidName(operation) || !ValidName(candidate)) return Failure(current, TouchPublicationStatus::Invalid);
        if (current.surface == 0) return Failure(current, TouchPublicationStatus::Unavailable);
        if (operation == operation_) {
            if (candidate != candidate_) return Failure(current, TouchPublicationStatus::Invalid);
            return Query(current);
        }
        if (!expected.SameIdentity(current)) return Failure(current, TouchPublicationStatus::Stale);
        const uint64_t token = NextToken();
        if (!token) return Failure(current, TouchPublicationStatus::Unavailable);
        operation_ = operation;
        candidate_ = candidate;
        context_ = current;
        token_ = token;
        fenced_ = true;
        committed_ = false;
        status_ = current.nativeTouches == 0 ? TouchPublicationStatus::Fenced : TouchPublicationStatus::Waiting;
        return Receipt(current);
    }

    /** 必须在同一gate内重读真实触点。返回Fenced才可首次安装，成功回执只供幂等重放。 */
    TouchPublicationReceipt Prepare(const std::string& operation, const TouchPublicationContext& current) {
        if (operation != operation_ || operation_.empty()) return Failure(current, TouchPublicationStatus::Stale);
        if (!context_.SameIdentity(current)) return Query(current);
        if (committed_) return Receipt(current);
        status_ = current.nativeTouches == 0 ? TouchPublicationStatus::Fenced : TouchPublicationStatus::Waiting;
        return Receipt(current);
    }

    /** schema与owner退休已在Native事务内完成；记录实际generation，保持UI完成屏障。 */
    TouchPublicationReceipt Complete(const TouchPublicationContext& current, bool unchanged) {
        context_ = current;
        committed_ = true;
        status_ = unchanged ? TouchPublicationStatus::Unchanged : TouchPublicationStatus::Committed;
        return Receipt(current);
    }

    /** 校验拒绝仍有回执，调用者只能明确abort旧有效快照或保留待修正候选。 */
    TouchPublicationReceipt Reject(const TouchPublicationContext& current) {
        status_ = TouchPublicationStatus::Invalid;
        return Receipt(current);
    }

    /** 只认当前操作、token和已安装身份；任意旧didLayout、旧页面回调均不能解封。 */
    bool Confirm(const std::string& operation, uint64_t token, const TouchPublicationContext& current) {
        if (!committed_ || operation != operation_ || token == 0 || token != token_ ||
            !context_.SameIdentity(current)) return false;
        fenced_ = false;
        appliedToken_ = token_;
        appliedContext_ = current;
        return true;
    }

    /** 只有明确未安装且旧身份仍有效才回退；安装后必须查询并确认当前UI。 */
    TouchPublicationReceipt Abort(const std::string& operation, const TouchPublicationContext& current) {
        if (operation != operation_ || committed_ || !context_.SameIdentity(current))
            return Failure(current, TouchPublicationStatus::Stale);
        operation_.clear();
        candidate_.clear();
        token_ = appliedToken_;
        // 首次发布失败时没有已确认旧UI可恢复；明确结束未提交操作，但保持关门。
        // 新的合法candidate可用Begin替换该失败记录，不能把abort成功等同于可接受DOWN。
        const bool oldAppliedValid = appliedToken_ != 0 && appliedContext_.SameIdentity(current);
        context_ = oldAppliedValid ? appliedContext_ : current;
        fenced_ = !oldAppliedValid;
        status_ = oldAppliedValid ? TouchPublicationStatus::Idle : TouchPublicationStatus::Invalid;
        return Receipt(current);
    }

    /** 嵌套owner各拿独立租约；首个模态的触控退休由平台执行，不能做全域reset。 */
    uint64_t AcquireModal(const std::string& owner) {
        if (!ValidName(owner) || modals_.size() >= 16) return 0;
        const uint64_t token = NextToken(true);
        if (token) modals_.emplace(token, owner);
        return token;
    }
    /** 迟到释放只摘自己，不恢复被退休输入，也不解开publication屏障。 */
    bool ReleaseModal(uint64_t token) {
        // 奇数是modal命名空间；原成功回执丢失后重试幂等，零/未来/非modal身份拒绝。
        // token序号永不复用，用水位证明已经分配，无须无限保留退休租约记录。
        if ((token & 1u) == 0 || (token >> 1u) == 0 || (token >> 1u) > nextToken_) return false;
        modals_.erase(token);
        return true;
    }
    bool HasModal() const { return !modals_.empty(); }
    bool BlocksNewTouch() const { return fenced_ || HasModal(); }
    /** 首次协议发布后，UI动作必须携带实际呈现token；旧节点不可借新schema取得绑定。 */
    bool AcceptsUiToken(uint64_t token) const {
        return !BlocksNewTouch() && token != 0 && token == appliedToken_;
    }

    /** 已确认旧UI的继续资格与新DOWN分开：pending fence只关新认领，不能吞掉等待抬手的MOVE。
     * token/context必须来自上一次实际Confirm，不能借待安装token或零触点猜测已有角色。
     * nativeTouches是动态接触数量，SameIdentity刻意不比较它；0→1的正常按住仍属于同一身份。
     * 仅尚未commit的Waiting/Fenced可承接旧UI。Complete即撤旧资格，即使schema unchanged，
     * 也必须等待新UI真正didLayout Confirm；真实mode/context变化或modal永不沿此例外放行。
     */
    bool AcceptsUiContinuation(uint64_t token, const TouchPublicationContext& current) const {
        if (token == 0 || token != appliedToken_ || current.surface == 0 || current.grabbed ||
            HasModal() || !appliedContext_.SameIdentity(current)) return false;
        if (!fenced_) return true;
        return !committed_ && !operation_.empty() && context_.SameIdentity(current) &&
            (status_ == TouchPublicationStatus::Waiting || status_ == TouchPublicationStatus::Fenced);
    }

private:
    static bool ValidName(const std::string& name) {
        return !name.empty() && name.size() <= 192 && name.find('\0') == std::string::npos;
    }
    uint64_t NextToken(bool modal = false) {
        // 回绕虽实际不可达，仍永久失败关闭，避免旧租约重新拥有新操作。
        if (nextToken_ == (UINT64_MAX >> 1u)) return 0;
        return (++nextToken_ << 1u) | (modal ? 1u : 0u);
    }
    TouchPublicationReceipt Receipt(const TouchPublicationContext& current) const {
        return {current, status_, operation_, candidate_, token_, fenced_, static_cast<uint32_t>(modals_.size())};
    }
    TouchPublicationReceipt Failure(const TouchPublicationContext& current, TouchPublicationStatus status) const {
        auto result = Receipt(current);
        result.status = status;
        return result;
    }
    TouchPublicationContext context_;
    TouchPublicationContext appliedContext_;
    TouchPublicationStatus status_ = TouchPublicationStatus::Idle;
    std::string operation_, candidate_;
    uint64_t nextToken_ = 0, token_ = 0, appliedToken_ = 0;
    bool fenced_ = false, committed_ = false;
    std::map<uint64_t, std::string> modals_;
};
}
#endif
