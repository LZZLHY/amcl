/* 假设备只在 reader 边缘提供快照。JNI 编码、JInput/Controllers 代码来自候选。 */
#include <jni.h>
#include <string.h>
#include "gamepad_reader.h"
static AmclDesktopGamepad slots[16];
static long revision = 1;
static int simulatedPid = 1, published = 1;
int amclTestPid(void) { return simulatedPid; }
static int read_pad(int slot, AmclDesktopGamepad* out) {
    if (slot == -2) {
        uint64_t generations[16] = {0};
        if (out->generation == (uint64_t)revision) return 2;
        out->generation = revision;
        for (int i=0; i<16; ++i) if (slots[i].connected) generations[i] = slots[i].generation;
        memcpy(out->id, generations, sizeof(generations));
        return 1;
    }
    if (slot < 0 || slot >= 16 || !slots[slot].connected) return 0;
    *out = slots[slot];
    return 1;
}
AmclGamepadReadFn amclResolveGamepadReader(void) { return published ? read_pad : NULL; }
/* Sys 的启动 ABI 仍用真实交付 Java 核对；宿主没有 OHOS 的窗口与 JVM 原生模块。 */
JNIEXPORT jint JNICALL Java_org_lwjgl_DefaultSysImplementation_getJNIVersion(JNIEnv* e, jobject o) { return 19; }
JNIEXPORT jint JNICALL Java_org_lwjgl_DefaultSysImplementation_getPointerSize(JNIEnv* e, jobject o) { return sizeof(void*); }
JNIEXPORT void JNICALL Java_org_lwjgl_DefaultSysImplementation_setDebug(JNIEnv* e, jobject o, jboolean value) {}
JNIEXPORT void JNICALL Java_L2GamepadProbe_input(JNIEnv* e, jclass c, jint mode, jint slot, jfloat axis) {
    /* 子进程仍继承旧地址能读到的旧快照，但它的 PID 此刻没有合法 reader。 */
    if (mode == 3) { ++simulatedPid; published = 0; return; }
    if (mode == 4) { published = 1; ++slots[slot].generation; ++revision; return; }
    AmclDesktopGamepad* pad = &slots[slot];
    if (mode < 2) {
        uint64_t generation = pad->generation + 1;
        memset(pad, 0, sizeof(*pad));
        pad->generation = generation;
        pad->connected = mode;
        strcpy(pad->name, "Wireless Controller");
        pad->axes[4] = pad->axes[5] = -1;
        ++revision;
    } else {
        pad->axes[0] = axis;
        pad->axes[4] = axis ? axis : -1;
        pad->buttons[0] = axis != 0;
        pad->hats[0] = axis ? 3 : 0;
    }
}
