# Khronos EGL declarations for host tests

These unchanged EGL/KHR headers come from the configured HarmonyOS native SDK (`default/openharmony/native/sysroot/usr/include`). They let the production desktop EGL core compile under the normal host CTest entry without a GPU, a platform SDK installation or a MobileGlues include dependency.

Only host tests include this directory. Product builds continue to use their configured SDK headers. Upstream notices are retained; Apache-2.0 text is in `LICENSE.txt`, and `KHR/khrplatform.h` also contains its permission notice. Upstream: <https://github.com/KhronosGroup/EGL-Registry>.
