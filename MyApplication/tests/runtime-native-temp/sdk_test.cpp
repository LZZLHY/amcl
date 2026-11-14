/** 只用于实际SDK编译/链接实例化完整桥；不会在目标设备调用。 */
#include "../../entry/src/main/cpp/napi/jdk_native_temp_qualification.h"
#ifdef MC_OHOS_BUILD_TESTS
std::string InstantiateNativeTempBridge(int root, int run, const std::string& path) {
    return amcl::jdkqualification::RunNativeTempQualification(root, run, path);
}
#endif
