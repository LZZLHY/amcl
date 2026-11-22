# Third-party components and licenses

[简体中文](../../MyApplication/docs/CREDITS.md) · **English**

Use the table to find a component's upstream source, HarmonyOS changes and build recipe. To identify the exact inputs in a snapshot, consult the dependency lock, the Git submodule pointers, each component's `sources.json` and its artifact manifest. [Dependency lock](../../MyApplication/deps.lock)

| Component | Where to look | Source and build details |
| --- | --- | --- |
| LWJGL 3 and legacy compatibility slots | [LWJGL 3](../../MyApplication/prebuilt/lwjgl3/) | Upstream submodule, modern and legacy slot manifests, OHOS GLFW bridge and STB compatibility sources. The download script fetches the modern Maven JARs and verifies their post-processing. |
| LWJGL 2 | [LWJGL 2](../../MyApplication/prebuilt/lwjgl2/) · [Build recipe](../../MyApplication/docker/build_lwjgl2_ohos.sh) | Native libraries and adaptations for older Minecraft versions. |
| MobileGlues | [MobileGlues](../../MyApplication/prebuilt/mobileglues/) | The `[mobileglues]` lock entry and the pinned LZZLHY/MobileGlues fork identify the source and AMCL changes. |
| MobileGL | [MobileGL](../../MyApplication/prebuilt/mobilegl/) | The LZZLHY/MobileGL submodule and `[mobilegl]` lock entry identify the source. Normal HAP builds use the two pinned libraries and `build-provenance.json` in `dist/`. The build guide covers independent recompilation. |
| OpenAL Soft and OHAudio | [Component](../../MyApplication/prebuilt/openal-soft/) · [Native integration](../../MyApplication/entry/src/main/cpp/openal/) | Upstream OpenAL Soft source, the OHAudio backend, patches and CMake integration. |
| SDL3 | [SDL3](../../MyApplication/prebuilt/sdl3/) · [Build script](../../MyApplication/scripts/build-sdl3-ohos.ps1) | The `[sdl3-native]` lock entry and `patches/series` identify the source and patch order. |
| curl and OpenSSL | [curl](../../MyApplication/prebuilt/curl/) · [Build recipe](../../MyApplication/docker/build_curl_ohos.sh) | Native download and TLS dependencies. The recipe records versions and compiler options. |
| OpenJDK 8, 17, 21 and 25 | [JDK adaptations](../../MyApplication/prebuilt/jdk/) · [Build recipes](../../MyApplication/docker/) | Per-version patches, shims and build scripts. The launcher downloads complete runtime archives through its configured distribution sources. |
| gl4es and Mesa/Zink | [gl4es](../../MyApplication/prebuilt/gl4es/) · [Mesa/Zink](../../MyApplication/prebuilt/mesa-zink/) | Patches and Docker recipes. Which artifacts ship in a product depends on its active build configuration. |
| JNA and compatibility stubs | [JNA](../../MyApplication/prebuilt/jna/) · [Stubs](../../MyApplication/prebuilt/stubs/) | Source notes, retained sources and build inputs. |
| Native dependencies used by mods | [Mod native libraries](../../MyApplication/prebuilt/mod-natives/) | `manifest.json` and source/build information for components including imgui-java. |
| Fabric compatibility inputs | [Runtime compatibility layer](../../MyApplication/prebuilt/runtime-compat/) | AMCL's compatibility code and the Mixin and ASM build dependencies pinned in `lib/sources.json`. Fabric Loader supplies Mixin at runtime. |
| Khronos EGL headers | [Headers and license](../../MyApplication/prebuilt/khronos-egl-headers/) | See the component README and `LICENSE.txt`. |
| Compatibility with sideload signing tools | [Template preparation script](../../MyApplication/scripts/prepare-signing-templates.mjs) | Inputs come from a pinned public commit of [小白调试助手](https://github.com/likuai2010/auto-installer) and the public [HoKit](https://www.sydxky.cn/) Android 1.2.2 package. The build verifies input hashes before preparing templates. Signing for a device still requires account authorization and a valid device profile. |

Submodule URLs are recorded in the repository's `.gitmodules`. The Git index pins each submodule through a mode-160000 gitlink. Use those commits together with the lock files when preparing dependencies. [Submodule list](../../.gitmodules) · [Build guide](build.md)

A separate patch preserves two local VMA C++ changes that had not reached the upstream commit. It helps trace differences in the retained native library. The normal dependency preparation leaves the upstream checkout at its pinned commit. The build guide records the patch base, hash and outstanding rebuild checks. [VMA patch](../../MyApplication/prebuilt/lwjgl3/local-worktree.patch) · [Build guide](build.md)

## Licenses and redistribution

AMCL's own source code is licensed under GNU GPL-3.0-only. Third-party source files, headers, patches, JARs, native libraries, runtime archives and other resources retain their respective copyrights and license terms. [AMCL license](../../MyApplication/LICENSE) · [Notices](../../MyApplication/NOTICE)

The snapshot includes 23 license texts copied from 18 pinned source locations. The manifest records the repository, commit, original path and SHA-256 of each text. For components and historical binaries beyond that collection, check the upstream LICENSE, COPYING, NOTICE and source headers to determine the applicable terms. [Third-party notices](../../MyApplication/third-party-notices/README.md) · [License manifest](../../MyApplication/third-party-notices/manifest.json)

Minecraft, Fabric, Forge, NeoForge, LWJGL, OpenAL Soft, SDL3, MobileGlues, MobileGL, HarmonyOS and their trademarks belong to their respective owners. AMCL is independent of Mojang Studios, Microsoft, Xbox, NetEase, Huawei and the third-party projects listed here.
