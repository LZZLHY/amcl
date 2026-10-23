/** 仅供libentry内部平台与NAPI接线的触控扩展v1，不改变公共input core/host descriptor ABI。 */
#ifndef AMCL_TOUCH_PUBLICATION_H
#define AMCL_TOUCH_PUBLICATION_H
#include "touch_publication_state.h"
#include "control_schema_abi.h"
#include "touch_interaction.h"
#include "touch_group_state.h"

namespace amcl::input {
/** 以下平台入口自行持surface/mode/touch/schema事务；返回值仅为有界值对象，无私有指针。 */
TouchPublicationReceipt QueryTouchPublication();
TouchPublicationReceipt BeginTouchPublication(const std::string& operation, const std::string& candidate,
    const TouchPublicationContext& expected);
TouchPublicationReceipt PublishTouchSchema(const std::string& operation, const AmclCtrlEntry* entries,
    int count, float width, float height, int grabbed, float deadZone, int schemaVersion,
    const TouchInteractionConfig* config, const TouchGroupSchema* groups = nullptr);
/** 独立组态回执。mask/epochs 为本次读取的值，不暴露可变 Native 容器引用。 */
struct TouchGroupReceipt {
    uint64_t token = 0, revision = 0;
    bool enabled = false, pending = false;
    std::vector<uint8_t> mask;
    std::vector<uint64_t> epochs;
};
TouchGroupReceipt ReadTouchGroups(uint64_t token);
bool ConfirmTouchGroups(uint64_t token, uint64_t revision);
bool AcceptTouchGroupControl(uint64_t token, const std::string& control, uint64_t eligibility);
bool BindTouchGroupMouseOwner(uint64_t token, const std::string& control, uint64_t eligibility);
uint64_t AcquireTouchGroupSourceControl(uint64_t publication, const std::string& member, uint64_t eligibility,
    uint64_t device, const std::string& sourceControl, const int* codes, uint32_t count);
/** 无障碍/系统组管理使用同一生产入口；动作冻结于当前 schema，结果可按 producer/sequence 查询。 */
TouchGroupResult InvokeTouchGroupControl(uint64_t token, const std::string& control, uint64_t eligibility,
    uint64_t producer, uint64_t sequence, int phase);
/** 恢复入口提交明确初始目标态，不以再次 toggle 猜测回滚。 */
TouchGroupResult RestoreTouchGroups(uint64_t token, uint64_t producer, uint64_t sequence);
bool ConfirmTouchPublication(const std::string& operation, uint64_t token);
TouchPublicationReceipt AbortTouchPublication(const std::string& operation);
uint64_t AcquireTouchModal(const std::string& owner);
bool ReleaseTouchModal(uint64_t token);
/** UI控制面动作在gate内复核当前呈现token；旧节点的system onClick同样需要此资格。 */
bool AcceptTouchUiPublication(uint64_t token);
/** 只供已确认UI的工具MOVE/滚动；pending layout等待旧角色抬手时允许继续，不能用于新DOWN/注册。 */
bool AcceptTouchUiContinuation(uint64_t token);
/** 覆盖区更新只验证归属，可在当前已提交publication fence或modal中撤销自己的热区。 */
bool OwnsTouchUiPublicationToken(uint64_t token);
/** 密度/transform改变解释单位，更新policy身份；调用方提供已核验真实窗口上下文。 */
void TouchContextPolicyChanged(double density, uint32_t transform);
}
#endif
