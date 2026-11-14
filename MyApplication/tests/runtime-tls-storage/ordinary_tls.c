/* 系统 glibc loader 对照：只有普通 TLS，没有 CXX dtor、NODELETE 或额外 dlopen 引用。 */
static __thread unsigned char ordinary_tls_bytes[16384];

/* 调用仅发生在真实 dlopen handle 仍有效时；close 后不访问已卸载函数或旧 TLS 指针。 */
__attribute__((visibility("default"))) unsigned char* ordinary_tls_touch(unsigned char value) {
    ordinary_tls_bytes[0] = value;
    ordinary_tls_bytes[16383] = value;
    return ordinary_tls_bytes;
}
