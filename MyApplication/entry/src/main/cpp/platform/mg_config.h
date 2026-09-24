// mg_config.h — MobileGlues 最小运行时接线
#ifndef MC_OHOS_MG_CONFIG_H
#define MC_OHOS_MG_CONFIG_H

#ifdef __cplusplus
extern "C" {
#endif

// Sets the writable MG_DIR_PATH and materializes or schema-migrates the
// versioned Android-parity OHOS preset. Legacy/malformed input is backed up
// before an atomic replacement. Must run before glfwInit/MG init.
void prepareMobileGluesRuntime();

#ifdef __cplusplus
}
#endif

#endif // MC_OHOS_MG_CONFIG_H
