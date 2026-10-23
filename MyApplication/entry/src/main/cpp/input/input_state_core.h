#ifndef AMCL_INPUT_STATE_CORE_H
#define AMCL_INPUT_STATE_CORE_H

#include "amcl_input_api.h"
#include "input_look_core_hook.h"
#include "input_text_core_hook.h"

#include <memory>

namespace amcl::input {

// core诊断快照按同一mutex取值，计数在会话开始时清零。104字节snapshot与144字节
// 函数表前缀保持稳定；有序尾表是另经能力/长度校验的扩展，不承载本C++观测结构。
// 运行时会话摘要在Impl锁内记录，公开访问器由host回归读取；不得把新取的墙钟当事件时间。
struct CoreObservabilityV1 {
    // ---- identity / ordering -------------------------------------------
    // `lastSequence` / `lastMonotonicTimeNs` are the values stamped onto the
    // most recently accepted event, not a live clock read. A summary that
    // printed a fresh clock read could not be correlated with the last event a
    // consumer actually saw, which is the whole point of §11's ordering pair.
    uint64_t sessionEpoch = 0;
    uint64_t focusEpoch = 0;
    uint64_t surfaceEpoch = 0;
    uint64_t lastSequence = 0;
    uint64_t lastMonotonicTimeNs = 0;
    // §11's `backend` identity: the consumer handle currently holding the typed
    // backend role, plus whether one is retiring. Zero means no backend has been
    // baselined, which is the normal state for a legacy-routed build.
    //
    // §11 also lists `source`. That is deliberately absent: source is a
    // per-event field (AmclInputEventHeader.source) and there is no meaningful
    // session aggregate of it. Adding a "last source" or a per-source histogram
    // here would invent a number the architecture does not own. Per-event source
    // stays observable on the event itself and in the trace-side plane.
    uint64_t backendConsumer = 0;
    uint64_t backendRetiringConsumer = 0;

    // ---- physical edges, post-arbitration ------------------------------
    // Counted as the action the event carries once core is done with it. Edges
    // that core replaced with DIAGNOSTIC_DROP are counted in `diagnosticDrops`
    // only, never here, so "applied" and "rejected" stay disjoint.
    //
    // ⚠️ The repeat promotion is KEY-ONLY, and the previous wording got this
    // wrong by saying "a DOWN on an already-held *control*":
    //   * PHYSICAL_KEY   -- a DOWN on an already-held key is rewritten to
    //                       REPEAT and lands in `physicalRepeat`.
    //   * POINTER_BUTTON -- a duplicate DOWN is NOT promoted. It becomes
    //                       DIAGNOSTIC_DROP_DUPLICATE_BUTTON_DOWN and lands in
    //                       `diagnosticDrops`, never in `physicalRepeat`.
    // GLFW has no button-repeat semantics, so the asymmetry is deliberate; only
    // the description was wrong. Saying "control" made this block contradict its
    // own next sentence for buttons. `input_trace.h` states the same thing
    // correctly ("core rewrote ... or replaced with a diagnostic") -- use that
    // phrasing as the model.
    //
    // 口径：这里只计 core **已接受**的边沿。接受前被拒的提交（STALE epoch、UNFOCUSED、
    // BACKEND_NOT_READY、非法载荷、sequence/容量耗尽）以错误码返回生产者，不进本结构，
    // 由生产者侧 `input_trace.h` 计数；两个平面须合读，单看任一个都不等于“提交数”。
    // 唯一例外是未知事件类型：生产者侧不知道它属于哪类，只有 core 能判定“本 host 不支持
    // 该类型”，所以单独计入下方 `unknownEventTypes`。
    uint64_t physicalDown = 0;
    uint64_t physicalRepeat = 0;
    uint64_t physicalUp = 0;
    // Subset of `physicalUp` that core synthesised while clearing held state on
    // the ordinary paths (reset, blur, device removal, ordinary backend retire).
    uint64_t physicalUpSynthetic = 0;
    // Held controls discarded WITHOUT any release edge. The capacity- and
    // sequence-exhaustion paths have no budget to emit one edge per control:
    // OverflowReset, the ResetThenLifecycle overflow branch, the BeginGlfwRetire
    // sequence-exhaustion branch, and AbandonGlfwConsumer. Without this field
    // those losses are invisible, which §11 forbids.
    //
    // The auditable ledger is therefore
    //
    //     physicalDown == physicalUp + heldDroppedWithoutRelease
    //
    // and NOT `physicalDown == physicalUp`, which holds only when no overflow or
    // exhaustion occurred. A non-zero value here is not corruption; it is a
    // truthful record that downstream held state was dropped en bloc and that
    // consumers were told to rebuild from a RESET instead of from per-control
    // UPs.
    uint64_t heldDroppedWithoutRelease = 0;
    uint64_t diagnosticDrops = 0;

    // ---- held ownership -------------------------------------------------
    // `heldOwnerDeviceCount` is the distinct-device count §11 asks for. The
    // post-reset invariant is `heldControlCount == 0 && heldOwnerDeviceCount
    // == 0`; the high-water marks make a slow leak visible in a single summary
    // line even when the instantaneous counts happen to be zero at teardown.
    uint64_t heldControlCount = 0;
    uint64_t heldOwnerDeviceCount = 0;
    uint64_t maxHeldControlCount = 0;
    uint64_t maxHeldOwnerDeviceCount = 0;

    // ---- queue ----------------------------------------------------------
    // `accepted` counts every event core stamped with a sequence. `queueWrites`
    // counts the subset that reached a queue. The difference is
    // `acceptedWithoutRecipient`: no consumer was a recipient at that instant.
    // That is not a drop — held state still moved and the sequence was spent —
    // but it must not be indistinguishable from one, which is exactly what a
    // single "submitted" counter would do.
    //
    // Units differ on purpose and must not be compared directly:
    //   queueWrites      counts RECORDS enqueued
    //   queueDeliveries  counts RECIPIENT SLOTS created (one record fanned out
    //                    to N consumers is N deliveries)
    //   queueReads       counts deliveries handed to a consumer
    //   queueDiscarded   counts deliveries that will never be handed over
    //                    (consumer closed or abandoned, text dropped on reset,
    //                    whole queue cleared by an overflow reset)
    //
    // so the §11 queue ledger closes as
    //
    //     queueDeliveries == queueReads + queueDiscarded + <still pending>
    //
    // Comparing queueWrites against queueReads is meaningless with more than one
    // consumer; use queueDeliveries.
    uint64_t accepted = 0;
    uint64_t queueWrites = 0;
    uint64_t acceptedWithoutRecipient = 0;
    uint64_t queueDeliveries = 0;
    uint64_t queueReads = 0;
    uint64_t queueDiscarded = 0;
    uint64_t queuePending = 0;
    // 全局容量复位次数：`OverflowReset` 与 `ResetThenLifecycle` 溢出分支，即清掉全部
    // held/capture/text、所有接收者只收到同一条 RESET 的那一类。局部压力退休**不**计在
    // 这里（见下两项），否则会话摘要分不清“全体按键被丢”与“一个落后消费者重握手”。
    uint64_t queueOverflowResets = 0;
    // 局部压力退休：因共享队列（queue）或文本包池（blob）不足，只给积压的接收者发定向
    // RESET、随后以 STALE 收尾的次数；全局 held/capture/text 不变，该接收者重新 Open 即可。
    // 对同一资源的一次容量不足，要么由局部隔离解决、要么走唯一一次全局复位，不会先白白
    // 隔离再复位，所以它与 `queueOverflowResets` 不会为同一次不足各记一次。
    uint64_t pressureRetirementsQueue = 0;
    uint64_t pressureRetirementsBlob = 0;
    // core 实际发出的 RESET 总数（所有原因），含 OpenConsumer 的逐消费者
    // CONSUMER_BASELINE 与压力退休的定向 RESET；上面三项各自对应其中一部分。
    uint64_t resetsEmitted = 0;

    // ---- capture --------------------------------------------------------
    // `captureLostByReason` is indexed by AMCL_INPUT_CAPTURE_REASON_*. A reason outside
    // the array lands in `captureLostUnknownReason` instead of being silently
    // folded into NONE. That branch is reachable from an ordinary submitEvent:
    // ValidatePayload checks `requested`/`active` but deliberately does not
    // constrain `reason`, so a producer built against a newer reason list still
    // gets its capture loss recorded rather than dropped.
    //
    // Index AMCL_INPUT_CAPTURE_REASON_NONE is structurally always zero: a
    // publication with active==0 and reason==NONE is a neutral/never-granted
    // state, not a loss, and returns before bucketing. The slot is kept so the
    // array stays index-aligned with the ABI reason values.
    uint64_t captureRequested = 0;
    uint64_t captureActivated = 0;
    uint64_t captureLost = 0;
    uint64_t captureLostByReason[AMCL_INPUT_CAPTURE_REASON_COUNT] = {};
    uint64_t captureLostUnknownReason = 0;

    // ---- text -----------------------------------------------------------
    // Typed text lifecycle and payload edges are counted independently.  END
    // and ABORT are deliberately separate: a rejected END must not be reported
    // as a clean stop when the producer subsequently fences with ABORT.
    uint64_t textSessionStarts = 0;
    uint64_t textSessionEnds = 0;
    uint64_t textSessionAborts = 0;
    uint64_t textCommits = 0;
    uint64_t textEdits = 0;
    uint64_t textCandidates = 0;
    uint64_t textSelections = 0;

    // ---- protocol -------------------------------------------------------
    // 被拒的未知事件类型（大于本 core 认识的最大类型）。生产者比 core 新或误用 ABI 时出现；
    // 单条与批量提交都返回 AMCL_INPUT_ERROR_INVALID_ARGUMENT，并按 2 的幂节流写 WARN。
    // 类型 0 与生产者伪造的 DIAGNOSTIC_DROP 属于非法载荷，不计在这里。会话作用域，饱和不回绕。
    uint64_t unknownEventTypes = 0;
};

class InputStateCore final {
public:
    // Generic/test cores default to legacy/shadow behavior. The shipping owner
    // passes the same startup-latched route decision that it publishes through
    // the immutable host table, so capability and gate cannot diverge.
    explicit InputStateCore(bool requireGlfwReady = false,
                            bool requireTextReady = false);
    ~InputStateCore();
    InputStateCore(const InputStateCore&) = delete;
    InputStateCore& operator=(const InputStateCore&) = delete;

    int32_t BeginSession(uint64_t* outSessionEpoch);
    int32_t EndSession(uint64_t sessionEpoch);
    int32_t SubmitEvent(const AmclInputEvent* event);
    int32_t SubmitBatch(const AmclInputEvent* events, uint32_t count);
    int32_t SubmitTextPacket(const AmclInputEvent* event,
                             const uint8_t* bytes, uint32_t byteCount);
    int32_t PublishSurface(const AmclInputSurfacePayload* surface);
    int32_t PublishFocus(uint32_t focused);
    int32_t PublishDeviceChange(uint64_t deviceId, uint32_t change,
                                uint32_t capabilities);
    int32_t RequestReset(uint32_t reason);
    int32_t OpenConsumer(AmclInputConsumerHandle* outConsumer);
    // peekOnly不消费、不转移blob所有权；maxOrder之外的队首保留，outOrder只在成功时填写。
    int32_t NextEvent(AmclInputConsumerHandle consumer,
                      AmclInputEvent* outEvent, uint64_t* outOrder = nullptr,
                      uint64_t maxOrder = UINT64_MAX, bool peekOnly = false);
    int32_t ReadPacketBlob(AmclInputConsumerHandle consumer,
                           const AmclInputBlobRef* blob, uint8_t* outBytes,
                           uint32_t outCapacity, uint32_t* outByteCount);
    int32_t ReleasePacket(AmclInputConsumerHandle consumer,
                          uint64_t packetId);
    int32_t CloseConsumer(AmclInputConsumerHandle consumer);
    int32_t GetSnapshot(AmclInputSnapshotV1* outSnapshot);
    // 私有metadata读取，不扩展公开snapshot/host表；caller不得持core mutex，不解释成有序坐标交付。
    int32_t ReadCurrentSurfaceContext(AmclInputSurfaceContextPayload* outContext);
    /** 私有look资格读取：在同一锁内核活surface、focus、context和全部epoch，不扩104-byte ABI。 */
    int32_t ReadLookResource(AmclInputLookCoreResourceV1* resource);
    /** 私有文字原事实及无锁围栏；Source不得在order/push内回取Core mutex。 */
    int32_t ReadTextResource(AmclInputTextCoreResourceV1* resource);
    int32_t ValidateTextScope(uint64_t scope);
    /** 私有Keyboard事实投影与原读取侧带；不进入冻结host表或公开事件。 */
    uint64_t L2KeyboardScope() const;
    bool CompareL2KeyboardScope(uint64_t expected,uint64_t desired);
    void SelectKeyboardBackend(uint32_t backend);
    uint32_t SelectedKeyboardBackend() const;
    int32_t ReadL2KeyStamp(uint64_t consumer,uint64_t sequence,uint64_t* scope);
    /** 新L2 Keyboard基线仅读仍合法物理事实；不重放旧队列或生成新的硬件owner。 */
    int32_t ReadL2HeldKey(int32_t key);
    // §11 metrics. Not reachable through the frozen C function table by design
    // (see CoreObservabilityV1). Takes the core mutex, so a caller must not
    // hold it.
    //
    // ⚠️ "in practice only teardown paths and tests call this" was wrong: the
    // only caller is `input_state_core_test.cpp`. Product teardown does not go
    // through this accessor -- it uses the private `Impl::LogObservabilityLocked`
    // (already holding the mutex) from BeginSession/EndSession. Same correction
    // applies to LogObservabilitySummary below, which also has zero product
    // callers.
    int32_t GetObservability(CoreObservabilityV1* outObservability);
    // Emits the §11 metric block to hilog. Separate from GetObservability so the
    // numbers stay assertable in host tests where hilog is a no-op stub and the
    // formatted text is unobservable.
    //
    // Cost: three hilog records written while holding the core mutex, so every
    // producer blocks for the duration. That is acceptable at a session boundary
    // and is NOT acceptable on a periodic path. If this ever needs to run
    // periodically, snapshot with GetObservability first and format outside the
    // lock.
    //
    // ⚠️ "(which is where core calls it)" referred to the session boundary, but
    // core reaches that boundary through the private `LogObservabilityLocked`,
    // not through this public entry. This one has zero product callers.
    void LogObservabilitySummary(const char* reason);

#ifdef AMCL_INPUT_HOST_TESTING
    void TestSetNextSequence(uint64_t value);
    void TestSetNextPacket(uint64_t value);
    void TestSetEpochs(uint64_t session, uint64_t focus, uint64_t surface);
#endif

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

InputStateCore& HostInputStateCore();

}  // namespace amcl::input

#endif
