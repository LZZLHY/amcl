/*
 * AMCL的OHOS TinyFileDialogs后端，使用上游3.19.3头和未修改的LWJGL生成JNI。
 * 这是独立适配实现，不是Guillaume Vareille的桌面实现；上游许可仍见随源头文件。
 * OHOS应用没有桌面shell/zenity/osascript，不执行探测命令或读控制台。消息框委托
 * 当前游戏窗口；未实现的选择器明确返回NULL，query报告no_solution。
 */
#include "tinyfiledialogs.h"
#include "game_dialog.h"
#include <stdio.h>
#include <string.h>

/* 与上游公开全局ABI保持同名和大小；版本是所适配的接口版本，needs明确标记后端。
 * 这些兼容全局同上游一样需要调用方串行修改，不能作为跨线程身份或权限来源。 */
char tinyfd_version[8] = "3.19.3";
char tinyfd_needs[] = "AMCL OHOS backend: active game window; message/notification dialogs only";
char tinyfd_response[1024] = "no_solution";
int tinyfd_verbose = 0, tinyfd_silent = 1, tinyfd_allowCursesDialogs = 0, tinyfd_forceConsole = 0;

/** 全局查询不触发能力探测，更不把字符串拼成命令；未知名字沿上游返回NULL/-1。 */
char const* tinyfd_getGlobalChar(char const* name) {
    if (!name) return NULL;
    if (!strcmp(name, "tinyfd_version")) return tinyfd_version;
    if (!strcmp(name, "tinyfd_needs")) return tinyfd_needs;
    if (!strcmp(name, "tinyfd_response")) return tinyfd_response;
    return NULL;
}
static int* global_int(char const* name) {
    if (!name) return NULL;
    if (!strcmp(name, "tinyfd_verbose")) return &tinyfd_verbose;
    if (!strcmp(name, "tinyfd_silent")) return &tinyfd_silent;
    if (!strcmp(name, "tinyfd_allowCursesDialogs")) return &tinyfd_allowCursesDialogs;
    if (!strcmp(name, "tinyfd_forceConsole")) return &tinyfd_forceConsole;
    return NULL;
}
int tinyfd_getGlobalInt(char const* name) { int* value = global_int(name); return value ? *value : -1; }
int tinyfd_setGlobalInt(char const* name, int value) {
    int* target = global_int(name);
    if (!target) return -1;
    *target = value;
    return value;
}
static int is_query(const char* title) { return title && !strcmp(title, "tinyfd_query"); }
/** 查询和实际调用共用能力判断；forceConsole在此平台不获得伪造的控制台后端。 */
static int available(void) { return !tinyfd_forceConsole && AmclGameDialogAvailableV1(); }
static int query(int supported) {
    const int ready = supported && available();
    strcpy(tinyfd_response, ready ? "amcl-ohos" : "no_solution");
    return ready;
}
static void unsupported(const char* function) {
    fprintf(stderr, "AMCL_TINYFD unsupported=%s backend=ohos\n", function);
}

/** 四种按钮的返回值原样透传；default只交给UI设焦点，绝不自动决定结果。 */
int tinyfd_messageBox(const char* title, const char* message, const char* type, const char* icon, int button) {
    (void)icon; /* ArkUI沿系统提示样式显示；图标字符串不改变按钮或结果语义。 */
    if (is_query(title)) return query(1);
    int kind = AMCL_DIALOG_OK;
    if (type && !strcmp(type, "okcancel")) kind = AMCL_DIALOG_OK_CANCEL;
    else if (type && !strcmp(type, "yesno")) kind = AMCL_DIALOG_YES_NO;
    else if (type && !strcmp(type, "yesnocancel")) kind = AMCL_DIALOG_YES_NO_CANCEL;
    else if (type && strcmp(type, "ok")) { unsupported("messageBox-type"); return 0; }
    if (!available()) { unsupported("messageBox-no-window"); return 0; }
    return AmclGameDialogMessageV1(title, message, kind, button);
}
int tinyfd_notifyPopup(const char* title, const char* message, const char* icon) {
    (void)icon;
    if (is_query(title)) return query(1);
    if (!available()) { unsupported("notifyPopup-no-window"); return 0; }
    return AmclGameDialogNotifyV1(title, message);
}

/* 下列能力尚无OHOS实现；保持标准取消值且不改输出buffer，不读取stdin、不启动shell。
 * 查询也返回无方案，调用方能够选择自己的游戏内UI；不能将默认值当用户已选结果。 */
void tinyfd_beep(void) { unsupported("beep"); }
char* tinyfd_inputBox(const char* title, const char* message, const char* value) {
    (void)message; (void)value;
    if (is_query(title)) query(0); else unsupported("inputBox");
    return NULL;
}
char* tinyfd_saveFileDialog(const char* title, const char* path, int count, const char* const* filters, const char* description) {
    (void)path; (void)count; (void)filters; (void)description;
    if (is_query(title)) query(0); else unsupported("saveFileDialog");
    return NULL;
}
char* tinyfd_openFileDialog(const char* title, const char* path, int count, const char* const* filters, const char* description, int multiple) {
    (void)path; (void)count; (void)filters; (void)description; (void)multiple;
    if (is_query(title)) query(0); else unsupported("openFileDialog");
    return NULL;
}
char* tinyfd_selectFolderDialog(const char* title, const char* path) {
    (void)path;
    if (is_query(title)) query(0); else unsupported("selectFolderDialog");
    return NULL;
}
char* tinyfd_colorChooser(const char* title, const char* hex, const unsigned char rgb[3], unsigned char output[3]) {
    (void)hex; (void)rgb; (void)output;
    if (is_query(title)) query(0); else unsupported("colorChooser");
    return NULL;
}
