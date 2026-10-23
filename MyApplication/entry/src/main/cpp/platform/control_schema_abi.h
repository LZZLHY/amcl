// control_schema_abi.h — ArkTS/NAPI/native共用的控件快照POD，不依赖OHOS平台头。
// v3增加显式滑动组与根级交互配置；旧v2入口填充缺省值，独立头供生产和宿主共同校验。
#ifndef AMCL_CONTROL_SCHEMA_ABI_H
#define AMCL_CONTROL_SCHEMA_ABI_H
#define AMCL_CONTROL_SCHEMA_VERSION 3
#define AMCL_CONTROL_SCHEMA_MAX_CONTROLS 260 // 256个用户控件及有界运行时鼠标/提示面区域；v2仍限制256。
#define AMCL_CONTROL_ID_MAX_BYTES 23
#define AMCL_CONTROL_MAX_KEYS 6
typedef struct {
    char id[24];
    int kind;       // 0按钮、1摇杆、2滚轮、3抽屉、4物品栏
    int handledBy;  // 0由native解释，1由ArkUI解释
    float x, y, w, h; // surface物理px，已包含density转换
    float hitSlop; // 仅native普通控件扩张；hotbar固定使用有效矩形
    int keyOrMouse;
    int trigger;   // 0按住、1切换、2双击、3长按
    int dragLook;
    int haptic;
    int keys[AMCL_CONTROL_MAX_KEYS];
    int keyCount;
    int swipeGroup; // v3：0 表示不参与滑动组，1..256 是本快照内的组身份。
} AmclCtrlEntry;
#endif
