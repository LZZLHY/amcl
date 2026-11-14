/**
 * SDK真实CRT/TLS夹具的C边界。事件回调必须不抛异常，并在全部工作线程结束前保持有效。
 * A通过DT_NEEDED持有B；只有B声明非平凡thread_local，B的真实静态对象由CRT登记/终结。
 * 不定义__dso_handle、不替代__cxa_finalize、不禁异常或EH；这些都来自真实SDK CRT/provider。
 */
#pragma once

using AmclSdkTlsEventSink = void (*)(int event, int detail);
enum AmclSdkTlsEvent {
    AMCL_SDK_A_FINI_BEGIN = 10,
    AMCL_SDK_A_FINI_END = 11,
    AMCL_SDK_B_TLS_CREATED = 20,
    AMCL_SDK_B_TLS_DESTROYED = 21,
    AMCL_SDK_B_STATIC_DESTROYED = 30,
    AMCL_SDK_B_STATIC_DEAD_DURING_TLS = 31,
    AMCL_SDK_EH_B_CLEANUP = 40,
    AMCL_SDK_EH_CAUGHT_IN_A = 41,
    AMCL_SDK_EH_A_CLEANUP = 42,
};

// 同一公开类型跨两个真实C++ DSO抛出/捕获，用正常SDK RTTI及异常展开验证夹具未退化为C stub。
struct __attribute__((visibility("default"))) AmclSdkTlsException { int code; };

extern "C" {
// 由A转发到B；须在任何TLS触碰/关闭前调用一次。此函数不触发TLS构造。
__attribute__((visibility("default"))) void amcl_sdk_tls_configure(AmclSdkTlsEventSink sink);
// which=1/2分别构造两个独立TLS对象，返回37+which；用于与系统DSO/HAP TLS队列交错。
__attribute__((visibility("default"))) int amcl_sdk_tls_touch(int which);
// 非零时，A的真实静态析构会在B尚应存活的DT_NEEDED边上首次触碰B TLS1。
__attribute__((visibility("default"))) void amcl_sdk_tls_enable_late(int enabled);
// B抛出、A捕获，返回原token；事件顺序为B清理→A捕获→A清理。
__attribute__((visibility("default"))) int amcl_sdk_tls_exception_roundtrip(int token);
// 只在仍拥有A公开handle时查询：B静态资源活着返回1，且A/B各已由真实CRT构造。
__attribute__((visibility("default"))) int amcl_sdk_tls_resource_live();
// 只读普通TLS指针初值：必须与B的全局值同址且读得73，地址不符返回-1。
// 指针位于.tdata并由真实动态重定位填充；不登记C++析构，用于检查模板复制时点。
__attribute__((visibility("default"))) int amcl_sdk_tls_initial_value();

// B的依赖边导出；一般驱动使用上面A入口即可，无需借B的裸handle绕过拥有关系。
__attribute__((visibility("default"))) void amcl_sdk_tls_b_configure(AmclSdkTlsEventSink sink);
__attribute__((visibility("default"))) int amcl_sdk_tls_b_touch(int which);
__attribute__((visibility("default"))) void amcl_sdk_tls_b_throw(int token);
__attribute__((visibility("default"))) int amcl_sdk_tls_b_resource_live();
__attribute__((visibility("default"))) int amcl_sdk_tls_b_initial_value();
}
