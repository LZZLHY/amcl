/* LWJGL 2 的 JInput consumer 与 GLFW/SDL 共读游戏进程的同一快照。 */
#include <jni.h>
#include <string.h>
#include "gamepad_reader.h"
#include "gamepad_topology.h"

static AmclGamepadReadFn current_reader(void) {
    /* 每线程成对缓存发布进程与常驻导出。fork 继承的指针可能持有父进程的锁；
     * 必须先撤掉旧指针并按子进程重新解析。首次未发布仍允许下次查询重试。 */
    static _Thread_local int32_t owner;
    static _Thread_local AmclGamepadReadFn reader;
    const int32_t pid = (int32_t)getpid();
    if (owner != pid) {
        reader = NULL;
        owner = pid;
    }
    if (!reader) reader = amclResolveGamepadReader();
    return reader;
}

/* 变化的拓扑一次投递所有槽的连接代次，避免每次 poll 扫描 16 个设备。 */
JNIEXPORT jlong JNICALL Java_net_java_games_input_DefaultControllerEnvironment_nTopology(
    JNIEnv* env, jclass cls, jlong previous, jlongArray generations) {
    (void)cls;
    AmclGamepadReadFn read = current_reader();
    AmclDesktopGamepad topology = {0};
    topology.generation = (uint64_t)previous;
    if (read) {
        int result = read(AMCL_PAD_TOPOLOGY_QUERY, &topology);
        if (result == AMCL_PAD_TOPOLOGY_UNCHANGED) return previous;
        if (result == AMCL_PAD_TOPOLOGY_CHANGED) {
            jlong latest[AMCL_PAD_SLOT_COUNT];
            memcpy(latest, topology.id, sizeof(latest));
            (*env)->SetLongArrayRegion(env, generations, 0, AMCL_PAD_SLOT_COUNT, latest);
            return (jlong)topology.generation;
        }
    }
    if (previous != 0) {
        const jlong empty[AMCL_PAD_SLOT_COUNT] = {0};
        (*env)->SetLongArrayRegion(env, generations, 0, AMCL_PAD_SLOT_COUNT, empty);
    }
    return 0;
}

static int read_connection(jint slot, jlong generation, AmclDesktopGamepad* snapshot) {
    AmclGamepadReadFn read = current_reader();
    return read && read(slot, snapshot) == 1 && snapshot->generation == (uint64_t)generation;
}

/* 名字是 UTF-8 原字节。代次变化时稍后重枚举，不给旧对象套上新设备的身份。 */
JNIEXPORT jbyteArray JNICALL Java_net_java_games_input_DefaultControllerEnvironment_nName(
    JNIEnv* env, jclass cls, jint slot, jlong generation) {
    (void)cls;
    AmclDesktopGamepad snapshot;
    if (!read_connection(slot, generation, &snapshot)) return NULL;
    size_t length = strnlen(snapshot.name, sizeof(snapshot.name));
    jbyteArray name = (*env)->NewByteArray(env, (jsize)length);
    if (name) (*env)->SetByteArrayRegion(env, name, 0, (jsize)length, (const jbyte*)snapshot.name);
    return name;
}

/* JInput 轴顺序为左 XY、右 RX/RY、LT/RT，然后是独立按键与八向 POV。 */
JNIEXPORT jboolean JNICALL Java_net_java_games_input_DefaultControllerEnvironment_nState(
    JNIEnv* env, jclass cls, jint slot, jlong generation, jfloatArray state) {
    (void)cls;
    AmclDesktopGamepad snapshot;
    if (!read_connection(slot, generation, &snapshot)) return JNI_FALSE;
    jfloat values[25];
    for (int i = 0; i < 4; ++i) values[i] = snapshot.axes[i];
    for (int i = 4; i < 6; ++i) values[i] = (snapshot.axes[i] + 1.0f) * 0.5f;
    for (int i = 0; i < 18; ++i) values[6+i] = snapshot.buttons[i] ? 1.0f : 0.0f;
    /* GLFW 帽位是上右下左四位，JInput POV 为顺时针八分之一圈，左为 1。 */
    static const float pov[16] = {0, .25f, .5f, .375f, .75f, 0, .625f, 0, 1, .125f, 0, 0, .875f};
    values[24] = pov[snapshot.hats[0] & 15];
    (*env)->SetFloatArrayRegion(env, state, 0, 25, values);
    return JNI_TRUE;
}
