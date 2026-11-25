#ifndef AMCL_INPUT_MENU_CURSOR_SNAPSHOT_H
#define AMCL_INPUT_MENU_CURSOR_SNAPSHOT_H
#include <stdint.h>

// 选定游戏输入consumer的成对“已领取/已回调”菜单游标。不得把生产desired或任意backend latest当ACK。
// GLFW在cursor callback返回且生命周期仍匹配后commit；L2/SDL在Next返回不可变1010/按钮载荷时commit。
// 它不证明Java/SDL队列或游戏业务已经处理，只证明该实际consumer已从neutral通道不可撤回地领取。
#define AMCL_MENU_CURSOR_SNAPSHOT_VERSION 1u
#define AMCL_MENU_CURSOR_BACKEND_GLFW 1u
#define AMCL_MENU_CURSOR_BACKEND_LWJGL2 2u
#define AMCL_MENU_CURSOR_BACKEND_SDL3 3u
#define AMCL_MENU_CURSOR_COMMITTED 1u
#if defined(__GNUC__)
#define AMCL_MENU_CURSOR_PUBLIC __attribute__((visibility("default")))
#else
#define AMCL_MENU_CURSOR_PUBLIC
#endif
typedef struct AmclCommittedMenuCursorV1 {
    uint32_t structSize, abiVersion, backend, flags;
    uint64_t processId, gameSession, logicalTarget, inputPublication;
    uint64_t activationEpoch, interactionOrder, menuScopeEpoch, toolScopeEpoch;
    // menuScopeEpoch冻结于实际出口并参与资格：完整policy/modal退休使旧ACK/cookie失效但保current。
    // toolScopeEpoch描述读取时工具域；tool-only取消保留已交付坐标及direct callback cookie资格。
    double x, y; // 同一次consumer出口的MC窗口/framebuffer px；Native必须用同一renderScale快照成对逆变换。
} AmclCommittedMenuCursorV1;

#ifdef __cplusplus
extern "C" {
#endif
// entry按本局已激活GraphicsPlan的slot/window和真实session配置；同PID不同局拒绝，不偷偷重选。
AMCL_MENU_CURSOR_PUBLIC int inputBridge_configureMenuCursorConsumerV1(uint32_t backend, uint64_t gameSession);
// caller先设置structSize；返回1才有资格，其它情况清空前缀并返回0，不能沿用上一份ACK。
AMCL_MENU_CURSOR_PUBLIC int inputBridge_getCommittedMenuCursorV1(AmclCommittedMenuCursorV1* snapshot);
// GLFW产品wrapper显式报告actual游戏callback是否调用并返回；null callback只能更新current，不发布ACK。
// 旧void回调前缀保持；追加receipt注册未启用时，既有直达callback继续按返回边界确认。
typedef int (*AmclGlfwCursorReceiptCallbackV1)(void* window, double x, double y);
// libentry 核真实承接鼠键，在原触点事务内用本次栈请求入队。整个准入调用同步完成，不保留request。
typedef uint64_t (*AmclEnqueueMenuWarpV1)(void* request);
typedef uint64_t (*AmclClaimMenuWarpV1)(AmclEnqueueMenuWarpV1 enqueue, void* request);
AMCL_MENU_CURSOR_PUBLIC void inputBridge_setCarriedMenuWarpClaimV1(AmclClaimMenuWarpV1 claim);
// 返回已入队定位的公共顺序，GLFW可在不重入回调的情况下用原有序泵派发到该处。
AMCL_MENU_CURSOR_PUBLIC uint64_t inputBridge_requestGlfwMenuWarpV1(void* window, double x, double y);
// 三种ABI共用触控准入。target为GLFW/L2实际窗口指针或SDL_WindowID，坐标为左上原点窗口像素。
AMCL_MENU_CURSOR_PUBLIC uint64_t inputBridge_requestCarriedMenuWarpV1(uint32_t backend, uint64_t target, double x, double y);
// SDL只在本次读取选择专用格式时，用1019标明承接指MOVE；普通有序Next仍返回1010。
AMCL_MENU_CURSOR_PUBLIC int inputBridge_sdlNextCarriedThroughV1(int* type, int* a, int* b, int* c, int* d, uint64_t maxOrder);
// L2同步设位只解算/交付到请求返回的order，普通nNext继续使用原帧边界。
AMCL_MENU_CURSOR_PUBLIC int inputBridge_l2NextThroughV1(int* type, int* a, int* b, int* c, int* d, uint64_t maxOrder);
AMCL_MENU_CURSOR_PUBLIC void inputBridge_setCursorReceiptCallbackV1(AmclGlfwCursorReceiptCallbackV1 callback);
// typed absolute真实sink两阶段：begin在callback前同步current，complete在callback后才发布ACK。
// cookie是consumer activation，logical/pub/WSI/order都用调用前已冻结值，禁止回调后解引用窗口。
AMCL_MENU_CURSOR_PUBLIC uint64_t inputBridge_beginGlfwMenuCursorV1(uint64_t logicalTarget,
    uint64_t inputPublication, uint64_t wsiIdentity, uint64_t interactionOrder, double x, double y);
AMCL_MENU_CURSOR_PUBLIC int inputBridge_completeGlfwMenuCursorV1(uint64_t logicalTarget,
    uint64_t inputPublication, uint64_t wsiIdentity, uint64_t cookie, uint64_t interactionOrder, double x, double y);
#ifdef __cplusplus
}
static_assert(sizeof(AmclCommittedMenuCursorV1) == 96, "menu cursor V1 layout drift");
#else
_Static_assert(sizeof(AmclCommittedMenuCursorV1) == 96, "menu cursor V1 layout drift");
#endif
#endif
