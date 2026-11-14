/**
 * 游戏原生对话框的同进程版本化C ABI。TinyFD与NAPI必须链接同一个共享库实例。
 * 结构只承载有界UTF-8文本和整数身份；所有权留在broker，不传ArkTS/Java裸对象。
 * Message仅阻塞调用者；UI线程用Take/Reply。Detach取消原窗口的全部等待者。
 */
#pragma once
#include <stdint.h>

#if defined(__GNUC__)
#define AMCL_DIALOG_API __attribute__((visibility("default")))
#else
#define AMCL_DIALOG_API
#endif
#ifdef __cplusplus
extern "C" {
#endif

enum AmclGameDialogKindV1 {
    AMCL_DIALOG_OK = 1, AMCL_DIALOG_OK_CANCEL = 2, AMCL_DIALOG_YES_NO = 3,
    AMCL_DIALOG_YES_NO_CANCEL = 4, AMCL_DIALOG_NOTIFY = 5
};
typedef struct AmclGameDialogRequestV1 {
    uint32_t size;
    uint32_t kind;
    uint64_t generation;
    uint64_t requestId;
    int32_t defaultButton;
    char title[1024];
    char message[32768];
} AmclGameDialogRequestV1;

/** UI事件线程挂接当前会话；返回窗口代次，0代表拒绝。新代次不能接管仍活动的旧窗口。 */
AMCL_DIALOG_API uint64_t AmclGameDialogAttachV1(uint64_t session);
/** 仅原UI线程按原代次取消；重复调用无副作用，不得退休后来窗口。 */
AMCL_DIALOG_API int AmclGameDialogDetachV1(uint64_t generation);
/** 只读当前是否有活跃UI窗口；fork继承实例始终不可用。 */
AMCL_DIALOG_API int AmclGameDialogAvailableV1(void);
/** FIFO一次交付一个请求；0为暂时没有，负数为身份/参数错误。out由调用者持有。 */
AMCL_DIALOG_API int AmclGameDialogTakeV1(uint64_t generation, AmclGameDialogRequestV1* out);
/** 只接受当前已交付请求的合法返回值。返回1才表示回包被接受；迟到/重复返回0。 */
AMCL_DIALOG_API int AmclGameDialogReplyV1(uint64_t generation, uint64_t requestId, int result);
/** 平台复制/显示失败或通知完成的非用户回包；ABI映射0，但内部不能冒记为用户点击。 */
AMCL_DIALOG_API int AmclGameDialogCancelV1(uint64_t generation, uint64_t requestId);
/** TinyFD语义：1确认/是，0取消/否，三按钮的否为2；失败只能返回取消。 */
AMCL_DIALOG_API int AmclGameDialogMessageV1(const char* title, const char* message,
    int kind, int defaultButton);
/** 非阻塞通知入队；返回1只表示已排队，不是已展示/用户确认。 */
AMCL_DIALOG_API int AmclGameDialogNotifyV1(const char* title, const char* message);

#ifdef __cplusplus
}
#endif
