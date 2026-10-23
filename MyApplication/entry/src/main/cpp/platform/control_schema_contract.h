// 控件定义的语义比较及hotbar有效区域，供生产解释器与宿主回归共用。
#ifndef AMCL_CONTROL_SCHEMA_CONTRACT_H
#define AMCL_CONTROL_SCHEMA_CONTRACT_H
#include "control_schema_abi.h"
#include <vector>
namespace amcl::input {
// 已校验控件的动作/命中绑定是否一致：比较稳定ID、解释权、几何和输入动作，忽略反馈字段。
// 旧contact/toggle/期限的生存只使用此判定，不能因haptic变化撤销已经建立的贡献。
bool SameControlSchemaBinding(const AmclCtrlEntry& current, const AmclCtrlEntry& next);
// 已校验整表的动作/命中绑定比较；仍保留顺序，以免重叠命中优先级变化被当作纯反馈。
bool SameControlSchemaBindings(const std::vector<AmclCtrlEntry>& current,
                               const AmclCtrlEntry* next, int count);
// 单控件完整定义比较：在动作/命中绑定之外还比较haptic，确保新表实际安装最新反馈。
// 忽略padding及未使用key槽位；不能用于决定旧输入贡献是否生存。
bool SameControlSchemaEntry(const AmclCtrlEntry& current, const AmclCtrlEntry& next);
// 调用前必须完成schema校验（id有NUL、keys长度合法）。忽略POD padding和未使用keys槽位，
// 保留条目顺序：重叠且中心距离相同的控件仍由先出现者命中。caller持schema锁。
bool SameControlSchemaEntries(const std::vector<AmclCtrlEntry>& current,
                             const AmclCtrlEntry* next, int count);
// x/y与entry同为surface px；矩形为左上闭、右下开。-1表示无有效槽位，禁止clamp误选边缘。
int ControlHotbarSlot(const AmclCtrlEntry& entry, float x, float y);
// 触控滚轮的交互距离是12vp，native触点是surface px，按当前密度换算一次。
// 非法/未发布密度按1处理，不能产生零阈值循环或NaN累计。
float ControlScrollStepPx(double density);
}
#endif
