/** 用真实生产头生成最小目标ELF，仅取权威槽地址，不执行Coordinator或伪造系统生命周期。
 * 同一份输入分别用SDK默认emutls和-fno-emulated-tls编译，使负控来自真实编译器产物。
 */
#include "../../entry/src/main/cpp/jvm/tls_thread_storage.h"
extern "C" __attribute__((visibility("default"))) void* application_tls_slot_fixture() {
    return &amcl::tlsstorage::detail::slot;
}
