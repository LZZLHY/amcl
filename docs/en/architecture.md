# AMCL application architecture

[简体中文](../../MyApplication/docs/architecture.md) · **English**

AMCL manages and runs Minecraft: Java Edition on HarmonyOS NEXT. A working HAP brings together the ArkTS/ArkUI launcher, native C/C++ libraries, Java launch code and third-party runtime components.

## Launcher and game processes

`EntryAbility` hosts the launcher interface. Phones run the game inside the game page. Computers use a separate game process, and supported tablets let the user choose the process mode in Settings. In separate-process mode, the launcher passes a snapshot of the launch configuration to a single-instance `GameAbility` in the private `:game` process. [Pages and runtime services](../../MyApplication/entry/src/main/ets/) · [Ability declarations](../../MyApplication/entry/src/main/module.json5)

| Module | Responsibility |
| --- | --- |
| `account` | Account data, sign-in and account selection |
| `commons` | Shared types, logging, file utilities and process configuration |
| `feature_core` | Minecraft versions, downloads and game assets |
| `feature_system` | System settings, preferences and device capabilities |
| `gamecontrol` | Input, control layouts and product-specific behavior |
| `launch` | Launch planning, Java runtime selection and game compatibility |
| `mods` | Mod management and installation |
| `update` | Application updates and version information |

These modules are Harmony Archives (HARs). Each module declares its dependencies in `oh-package.json5`. The entry build profile selects the pages and source directories used by each product. [Entry build profile](../../MyApplication/entry/build-profile.json5)

## Native code and the JVM

Native code is organized under [entry/src/main/cpp/](../../MyApplication/entry/src/main/cpp/).

| Directory | Responsibility |
| --- | --- |
| `napi/` | Calls between ArkTS and C/C++ |
| `jvm/` | Load the JDK, create the JVM, finalize launch properties, pass the classpath and start Minecraft |
| `glfw/` | Window, input, callback and EGL compatibility for LWJGL |
| `input/`, `platform/` | Input state, system windows, graphics providers, device capabilities and lifecycle |
| `download/` | Native downloads using the project's libcurl build |
| `openal/` | OpenAL Soft build integration. Dependency preparation supplies the upstream source in its `openal-soft/` subdirectory |
| `stubs/`, `third_party/`, `utils/` | Compatibility implementations, third-party headers and shared utilities |
| `tests/` | Native tests and fixtures for the build host or a device, depending on the test |

CMake selects the native source files, compile options and link targets. It compiles MobileGlues from `prebuilt/mobileglues/mg_src/MobileGlues-cpp/`. MobileGL is a separate shared library. Normal HAP builds use the verified binaries from `prebuilt/mobilegl/dist/`. An independent recipe is available to rebuild MobileGL. [Native build definition](../../MyApplication/entry/src/main/cpp/CMakeLists.txt) · [Build guide](build.md)

Inside the JVM, `AmclLauncher`, `AmclClassLoader`, `LaunchConfig` and `ForgeHelper` handle configuration, class loading and compatibility. The launcher targets Java 8 bytecode. The separate Fabric compatibility JAR targets Java 21, but its compiler needs to read Java 25 class files, so that step requires JDK 25 or newer. [Java sources](../../MyApplication/JavaApp/src/) · [Launcher build script](../../MyApplication/scripts/build-amcl-launcher.mjs) · [Compatibility JAR build script](../../MyApplication/scripts/build-game-compat.py)

## Graphics, audio and runtime inputs

Backend selection takes into account the product, device capabilities, the game's request, packaged libraries and active window provider. The runtime selects among MobileGlues, MobileGL, system OpenGL and the game's Vulkan path when eligible. SDL3 and GLFW share the host's window and input contracts. OpenAL Soft supplies game audio through its HarmonyOS OHAudio backend.

The `default` development product builds in debug mode by default. The `sideload`, `store` and `desktop` products default to release builds. The desktop product declares only `2in1`. The other products declare `phone`, `tablet` and `2in1`, with store distribution restricted to tablets and computers. All current products use `graphicsArtifactSet=complete`. The build checks MobileGL's source identity, the hashes of its distribution files and the copy packaged in the HAP. [Product definitions](../../MyApplication/config/products.json)

The snapshot includes native libraries, JARs, certificate bundles and other required inputs. Before compiling resources, Hvigor prepares the product resources, LWJGL slots and Java launcher. The application downloads game JDK archives, Minecraft and mod content separately. [Native binaries](../../MyApplication/entry/libs/arm64-v8a/) · [Packaged resources](../../MyApplication/entry/src/main/resources/rawfile/) · [Hvigor build hooks](../../MyApplication/entry/hvigorfile.ts)

## What the public snapshot records

The default native input configuration refers to a lock file and a sanitized record of input capabilities. They preserve the original approval, its scope and accepted risks. The snapshot omits raw device logs and signing credentials. Device tests and signing require their own evidence in the environment where they were performed. [Input capability lock](../../MyApplication/gate0-evidence.lock) · [Sanitized record](../../MyApplication/docs/testing/gate0-raw-relative-evidence.md) · [Third-party sources](credits.md) · [Public build guide](build.md)
