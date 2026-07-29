<div align="center">
  <img src="./assets/agc-icon-216.png" width="128" height="128" alt="AMCL icon">
  <h1>AMCL</h1>
  <p><strong>Axe Minecraft Launcher</strong></p>
  <p>A third-party Minecraft Java Edition game manager and launcher for HarmonyOS NEXT</p>
  <p>
    <img src="https://img.shields.io/badge/HarmonyOS-NEXT-008577?style=flat-square" alt="HarmonyOS NEXT">
    <img src="https://img.shields.io/badge/Language-ArkTS-32b8aa?style=flat-square" alt="Language ArkTS">
    <img src="https://img.shields.io/badge/UI-ArkUI-32b8aa?style=flat-square" alt="UI ArkUI">
  </p>
  <p>
    <img src="https://img.shields.io/badge/License-MIT-4c78d0?style=flat-square" alt="License MIT">
    <img src="https://img.shields.io/badge/Version-1.0.1-f29d38?style=flat-square" alt="Version 1.0.1">
    <img src="https://img.shields.io/github/stars/LZZLHY/amcl?style=flat-square&label=stars" alt="GitHub stars">
    <img src="https://img.shields.io/github/last-commit/LZZLHY/amcl?style=flat-square&label=last%20commit" alt="Last commit">
  </p>
  <p><a href="./README.md">简体中文</a> · <strong>English</strong></p>
  <p>
    <a href="https://github.com/LZZLHY/amcl/releases/latest">Latest release</a> ·
    <a href="https://amcl.lovedhy.cn/docs/install-hokit">HoKit installation guide</a> ·
    <a href="https://lzzlhy.github.io/amcl/">Project website</a> ·
    <a href="https://lzzlhy.github.io/amcl/privacy-policy/">Privacy policy</a> ·
    <a href="https://github.com/LZZLHY/amcl/issues">Issues</a>
  </p>
</div>

## Current status

| Item | Status |
|---|---|
| Latest stable release | **1.0.1** (versionCode `1000450`, 2026-07-29) |
| Current development line | **1.0.2** (in development) |
| Distribution | Unsigned HAP through GitHub Releases |
| Target platform | HarmonyOS NEXT phones, tablets, and 2-in-1 devices |
| Game | Minecraft Java Edition |
| Bundled runtime families | OpenJDK 8 / 17 / 21 / 25 for HarmonyOS aarch64 |

AMCL (**Axe Minecraft Launcher**) is independently maintained. It combines ArkTS, the HarmonyOS C/C++ SDK, and native compatibility layers to run the unmodified Minecraft Java Edition client on HarmonyOS NEXT.

This `amcl-public` repository is the public release endpoint for AMCL. It hosts release assets, the update manifest, project information, and the privacy policy. The application source is not hosted in this repository; any future publication plan will be announced separately.

## Highlights

### Versions and mod loaders

- Install and launch Vanilla, Fabric, Forge, and NeoForge instances.
- LWJGL 2 and LWJGL 3 compatibility paths for legacy and current Minecraft versions.
- Automatic OpenJDK 8 / 17 / 21 / 25 selection with an optional manual override.
- Per-version isolation, JVM arguments, game language, and storage settings.

### Accounts and security

- Microsoft authentication through OAuth 2.0 + PKCE and the Xbox Live / XSTS / Mojang chain.
- Offline accounts and authlib-injector-compatible third-party skin services.
- Sensitive credentials encrypted locally with HarmonyOS HUKS AES-GCM-256.
- SHA-256 verification for critical runtime downloads.

### Content and downloads

- Modrinth and CurseForge browsing, search, dependency resolution, and installation.
- Resource and modpack installation with compatibility warnings.
- A unified download manager with mirrors, segmented transfers, resume, cancellation, and retry.
- Activity logs, network diagnostics, and local game logs for troubleshooting.

### Touch controls

- Touch-oriented joysticks, buttons, direct hotbar selection, and menu text input.
- A visual layout editor with snapping, multi-selection, phone/tablet presets, and true-aspect previews.
- Layout import, export, HarmonyOS sharing, and JSON import through the system “Open with” flow.

## Compatibility overview

| Item | Status |
|---|---|
| Vanilla | Supported |
| Fabric | Supported |
| Forge | Supported |
| NeoForge | Supported |
| Quilt | No built-in one-click installer yet |
| OptiFine | No built-in one-click installer yet |
| Minecraft Bedrock Edition | Not supported |

“Supported” means that AMCL provides the corresponding installation and launch path. It does not imply that every combination of game version, mod, and device driver has been tested.

## Download and install

1. Open the [latest release](https://github.com/LZZLHY/amcl/releases/latest).
2. Download the asset ending in `-unsigned.hap`; for 1.0.1 this is `amcl-v1.0.1-unsigned.hap`.
3. Follow the [HoKit installation guide](https://amcl.lovedhy.cn/docs/install-hokit) to sign and sideload the package.
4. On first launch, download the JDK and game resources requested by AMCL.

> GitHub Releases provide an unsigned HAP. Some JIT capabilities depend on restricted HarmonyOS permissions, so behavior may vary between distribution channels and devices.

## Version 1.0.1 hotfix

- Fixed JDK downloads failing, stalling, or becoming unresponsive after cancellation.
- Fixed repeated downloads near completion and long NeoForge installation stalls.
- Improved resumable downloads, dynamic segmentation, mirror health tracking, and slow-tail takeover.
- Kept the previous `v1.0.0` release intact for verification and rollback.

See [AMCL v1.0.1](https://github.com/LZZLHY/amcl/releases/tag/v1.0.1) for the release and asset.

## Technology

- ArkTS / ArkUI for the application UI and HarmonyOS integration.
- HarmonyOS C/C++ SDK for the game window, input, audio, networking, and JVM launch path.
- Patched OpenJDK HotSpot builds for HarmonyOS NEXT (musl, aarch64).
- A GLFW-to-XComponent compatibility layer and MobileGlues OpenGL-to-OpenGL ES translation.
- OpenAL Soft backed by OHAudio.
- A custom ELF loader for integrity-verified JDK native libraries.

## Repository contents

| File | Purpose |
|---|---|
| [`update.json`](./update.json) | In-app update manifest |
| [`privacy-policy.html`](./privacy-policy.html) | Privacy policy and GitHub Pages document |
| [`index.html`](./index.html) | Chinese-first bilingual project website |
| [`README.md`](./README.md) | Primary Chinese project documentation |
| [`LICENSE`](./LICENSE) | Public documentation license |

## Notice and license

- AMCL does not redistribute the Minecraft client JAR. Game files are downloaded on the user's device from Mojang or a mirror selected by the user.
- “Minecraft” is a trademark of Mojang Studios. AMCL is not affiliated with, sponsored by, or endorsed by Mojang Studios, Microsoft Corporation, Xbox, NetEase, or Huawei Device Co., Ltd.
- Public documentation in this repository is licensed under the [MIT License](./LICENSE). Third-party components remain under their respective licenses.
