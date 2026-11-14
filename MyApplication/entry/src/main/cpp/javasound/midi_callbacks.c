/* 由HAP正常签名装载，仅导出固定版本的强类型数据回调表。系统所有间接调用目标
 * 都在此映像内，不把匿名JDK映像函数再作为回调进行转发。 */
#include "midi_callbacks.h"
const AmclMidiCallbackAbiV1* amcl_javasound_midi_callbacks_v1(void) {
    return amcl_midi_local_callbacks_v1();
}
