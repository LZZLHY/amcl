/** 真实独立外库出口，仅用地址owner核验反控，从不用于创建被测音频设备。 */
__attribute__((visibility("default"))) void* alcOpenDevice(const char* unused) {
    (void)unused;return 0;
}
