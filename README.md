# AMCL — Axe Minecraft Launcher for HarmonyOS NEXT

[简体中文](./README.zh-CN.md) · **English**

> A third-party Minecraft Java Edition launcher targeting HarmonyOS NEXT (Huawei mobile / tablet devices).

## 1. Project Introduction

AMCL (**A**xe **M**inecraft **C**lient **L**auncher) is an individual-developer project that runs the unmodified Minecraft Java Edition client on HarmonyOS NEXT. It is built directly on the HarmonyOS NEXT C/C++ SDK and the ArkTS UI framework, embedding:

- A patched OpenJDK HotSpot runtime cross-compiled for HarmonyOS NEXT (musl, aarch64)
- A GLFW → XComponent compatibility shim
- A MobileGlues GL → GLES 3.2 translation layer running on Maleoon GPUs
- An OpenAL Soft audio stack backed by OHAudio
- A custom ELF loader that bypasses HarmonyOS' `MAP_XPM` (no-write-execute) signing constraint

The project is in **pre-1.0 active development**. This `amcl-public` repository hosts the **public documentation and technical specifications** only — the full application source code remains in a private repository and will be open-sourced **only after the project reaches a mature stable release**.

## 2. Scope of Applicability

| Aspect | Supported scope |
|---|---|
| Operating system | HarmonyOS NEXT, API level 20 (SDK 6.0.0) or later |
| Devices | Huawei phones and tablets with a Maleoon-family GPU (verified on HUAWEI Mate 70) |
| Game | Minecraft Java Edition only (no Bedrock support and none planned) |
| Account | Microsoft genuine login (OAuth 2.0 Auth Code + PKCE; Xbox Live → XSTS → Mojang); offline accounts for development testing |
| Network | Direct Mojang servers; BMCLAPI mirror with user consent |

AMCL is intended for end-users who own a legal Minecraft Java Edition account. It does **not** redistribute the Minecraft client `.jar`; all game files are downloaded at runtime from official servers.

## 3. Adaptation Progress

### 3.1 Mod loaders

| Loader | Status |
|---|---|
| Vanilla | ✅ Supported |
| Fabric | ✅ Supported |
| Forge | ✅ Supported |
| NeoForge | ❌ Not yet — data layer only (mod browsing works, install service pending) |
| Quilt | ❌ Not yet |
| OptiFine | ❌ Not yet |

### 3.2 JDK runtimes

AMCL ships two patched OpenJDK builds, cross-compiled in Docker for HarmonyOS NEXT (musl, aarch64). Runtime artifacts are downloaded on first launch from a dedicated GitHub Releases:

**JDK repository**: <https://github.com/LZZLHY/mc-ohos-resources/releases>

| Runtime | Release tag | Asset | Status |
|---|---|---|---|
| OpenJDK 17 | `v17.0.13-ohos-4` | `jdk17-ohos-full-v4.zip` (≈109 MB) | ✅ Stable |
| OpenJDK 21 | `v21.0.5-ohos-6` | `jdk21-ohos-full.zip` (≈113 MB) | ⚠️ Experimental |

### 3.3 Minecraft version coverage

The MC version → required JDK mapping follows Mojang's official `java-runtime` selection (see the [Minecraft Wiki](https://minecraft.wiki/w/Tutorial:Update_Java)):

| MC version range | Required JDK | AMCL adaptation status |
|---|---|---|
| ≤ 1.12.2 | Java 8 + LWJGL 2.x | ❌ Not yet adapted |
| 1.13 – 1.16.5 | Java 8 + LWJGL 3 | ❌ Not yet adapted |
| 1.17 | Java 16 | ❌ Not yet adapted |
| 1.18 – 1.20.4 | Java 17 | ✅ Adapted (verified on 1.20.4) |
| 1.20.5 – 1.21.x | Java 21 | ✅ Adapted (experimental) |
| 26.1 and newer | Java 25 | ❌ Not yet adapted |

Notes:

- Beginning with Minecraft Java Edition **26.1**, the Mojang launcher bundles Java SE 25.
- AMCL routes a chosen MC version to the appropriate JDK automatically (`autoSelectVersion`); manual override is available in Settings.

## 4. Future Outlook

Short-term (toward the first stable v1.0):

- Cross-compile and integrate OpenJDK 8 to unlock the entire 1.0 – 1.16.5 catalogue (the largest body of legacy mods)
- Cross-compile OpenJDK 16 for the 1.17 slot
- Port LWJGL 2.x to HarmonyOS NEXT so pre-1.13 clients (still using LWJGL 2) can run
- Implement the NeoForge install service (the data layer is already wired)
- Add Quilt and OptiFine adapters
- Cross-compile OpenJDK 25 for the 26.1+ slot once Mojang's snapshot cadence stabilises

Long-term (parity with mature desktop launchers HMCL / PCL2):

- Multi-account vault with HUKS AES-GCM-256 at-rest encryption
- Skin & cape management (preview, upload, change)
- Modrinth + CurseForge integrated mod browsing and one-click install
- Resource pack / shader pack / world / data pack one-click install
- Full version isolation (per-version `.minecraft` directory and per-version JVM args)
- Custom virtual key layouts with cloud sync
- Crash reporter with automatic JVM thread dump and log harvesting
- Background download manager with multi-mirror, multi-thread, resumable downloads

## 5. Known Issues

The first public preview (`v1.0.0-alpha.1`, this release) carries the following limitations:

- **HAP is unsigned.** The published HAP is produced by DevEco Studio's default unsigned profile. Real-device installation requires either (a) joining the Huawei Developer programme and self-signing, or (b) waiting for a signed redistribution we will publish once an organisational signing certificate is approved.
- **HarmonyOS NEXT API 20 only.** Earlier ROMs (API ≤ 19) will reject the bundle.
- **The `ALLOW_WRITABLE_CODE_MEMORY` ACL is required** for the JIT path of the patched HotSpot to work. Without it, the JDK falls back to the interpreter and the game runs at a fraction of expected FPS.
- **Microsoft genuine login & HUKS credential encryption are in milestone M2 and only partially complete.** The current build allows offline accounts only.
- **The OpenJDK 21 path is flagged experimental.** Real-headless AWT (our workaround for HarmonyOS NEXT's missing X11/Wayland) is stable on the tested code paths but has not received full coverage; mods that touch `java.awt` may still throw.
- **GPU support is currently limited to the Maleoon 910 family.** Other Huawei chipsets are likely to work but have not been verified.
- **MC version coverage is 1.18 – 1.21.x today.** Older and 26.1+ versions report a missing-runtime error at launch.

## 6. Releases & Downloads

Latest release: **v1.0.0-alpha.1** (pre-release).

The HAP file is published as a GitHub release asset of this repository — see the [Releases page](https://github.com/LZZLHY/amcl/releases) for the download.

## 7. Source Code Policy

Only this `amcl-public` repository (documentation and specifications) is open source. The application source code is kept in a private repository while the project is in pre-1.0 active development and **will be open-sourced after the first stable release**. Until then, this repository is the canonical public touchpoint for reviewers, future contributors, and developers building similar HarmonyOS-based JVM runtimes.

## License

Documentation in this repository is released under the [MIT License](./LICENSE).

"Minecraft" is a trademark of Mojang Studios. AMCL has **no affiliation, sponsorship, or endorsement** from Mojang Studios, Microsoft Corporation, or Xbox.
