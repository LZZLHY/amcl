/** 另一个TU保留SDK默认emutls，证明门禁只保护权威槽，不误禁全产品已有thread_local。 */
static thread_local unsigned unrelated_tls_value = 19;
extern "C" __attribute__((visibility("default"))) unsigned* application_tls_other_fixture() {
    return &unrelated_tls_value;
}
