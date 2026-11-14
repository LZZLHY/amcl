/** A的真实CRT析构通过合法DT_NEEDED边触碰B，覆盖“前一成员fini新建后一成员TLS”。 */
#include "fixture_api.h"

namespace {
AmclSdkTlsEventSink events = nullptr;
bool touchDuringFini = false;
void emit(int event, int detail) { if (events) events(event, detail); }
struct Owner {
    ~Owner() {
        emit(AMCL_SDK_A_FINI_BEGIN, 0);
        if (touchDuringFini) amcl_sdk_tls_b_touch(1);
        emit(AMCL_SDK_A_FINI_END, 0);
    }
} owner;
struct ExceptionScope { ~ExceptionScope() { emit(AMCL_SDK_EH_A_CLEANUP, 0); } };
}

extern "C" void amcl_sdk_tls_configure(AmclSdkTlsEventSink sink) {
    events = sink; amcl_sdk_tls_b_configure(sink);
}
extern "C" int amcl_sdk_tls_touch(int which) { return amcl_sdk_tls_b_touch(which); }
extern "C" void amcl_sdk_tls_enable_late(int enabled) { touchDuringFini = enabled != 0; }
extern "C" __attribute__((noinline)) int amcl_sdk_tls_exception_roundtrip(int token) {
    ExceptionScope scope;
    try { amcl_sdk_tls_b_throw(token); }
    catch (const AmclSdkTlsException& error) { emit(AMCL_SDK_EH_CAUGHT_IN_A, error.code); return error.code; }
    catch (...) { return -999; }
    return -998;
}
extern "C" int amcl_sdk_tls_resource_live() { return amcl_sdk_tls_b_resource_live(); }
extern "C" int amcl_sdk_tls_initial_value() { return amcl_sdk_tls_b_initial_value(); }
