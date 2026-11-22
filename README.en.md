<div align="center">
  <img src="./assets/agc-icon-216.png" width="112" height="112" alt="AMCL icon">
  <h1>AMCL · Axe Minecraft Launcher</h1>
  <p>Run Minecraft: Java Edition on HarmonyOS NEXT</p>
  <p><a href="README.md" lang="zh-CN">简体中文</a> · <strong>English</strong></p>
  <p><a href="https://amcl.lovedhy.cn/download">Download AMCL</a> · <a href="https://github.com/LZZLHY/amcl/releases/latest">Stable release on GitHub</a> · <a href="https://amcl.lovedhy.cn/docs/getting-started-en">Quick start</a> · <a href="docs/en/compatibility-and-feedback.md">Compatibility and troubleshooting</a></p>
</div>

AMCL runs Minecraft: Java Edition locally on HarmonyOS NEXT phones, tablets and computers using a port of OpenJDK. You can download the game, install mods, manage saves and settings for different versions, and play with touch controls or a keyboard and mouse.

## First launch

1. **Install the launcher.** Choose the stable universal sideload package on the download page, or open the latest stable GitHub release and download the asset with `sideload` and `unsigned.hap` in its name. Sign the HAP for your device before installing it. To try a preview, look for the **Pre-release** label in the release list. [Illustrated sideloading guide](https://amcl.lovedhy.cn/docs/install-hokit-en) · [All releases](https://github.com/LZZLHY/amcl/releases)
2. **Choose a game account.** Tap the avatar or username on the home screen. Choose a Microsoft account, a supported third-party skin server account, or a local offline account for offline play.
3. **Download Minecraft.** Open Downloads → Versions (下载 → 版本), choose a Minecraft release and leave the loader set to Vanilla (原版) for your first run. Tap Start download (开始下载). When adding mods later, choose the game version and loader that the mods require.
4. **Start the game.** Select the installed version on the home screen and tap Launch game (启动游戏). If the pre-launch check asks for Java, use the download button it offers, such as 一同下载 JDK 21. You can also install a runtime in advance under Downloads → JDK (下载 → JDK). AMCL offers HarmonyOS builds of OpenJDK 8, 17, 21 and 25. Download the one your instance needs. Runtimes update independently of the launcher. [Java runtime catalog](https://amcl.lovedhy.cn/runtimes)

## Mods, modpacks and controls

- **Build a modded instance.** Install Fabric, Forge or NeoForge and browse Modrinth or CurseForge for compatible mods, shaders and resource packs. You can also import an existing modpack as a game instance and manage its mods and configuration.
- **Set up touch controls.** On phones and tablets, edit virtual buttons, the joystick, camera controls and button groups, or import another player's layout. The universal package also supports keyboard and mouse controls on HarmonyOS computers. [Control layouts and import instructions (Chinese)](https://amcl.lovedhy.cn/docs/controls-market)
- **Check a particular combination.** Compatibility depends on the device, Java version, mod loader, mods and graphics backend. The guide lists combinations tested through saving and reopening a world, and shows how to find the right log for a failed launch, a black screen or a crash. [Compatibility and troubleshooting](docs/en/compatibility-and-feedback.md)

## Source and contributions

The launcher interface uses ArkTS and ArkUI. AMCL prepares the game and its dependencies, starts the JVM and loads Minecraft through its Java launch layer. GLFW and SDL adapters connect windowing and input to HarmonyOS. The graphics backend depends on the device and the game, and OpenAL Soft routes game audio to OHAudio. [Application architecture](docs/en/architecture.md)

The public application project lives in `MyApplication/`. Maintainers publish a source snapshot and its build inputs with each release. The snapshot manifest identifies the application version and the original source commit. Reproduction steps, documentation improvements and code fixes are welcome. [Snapshot manifest](MyApplication/SOURCE_SNAPSHOT.json) · [Build from source](docs/en/build.md) · [Contributing](CONTRIBUTING.en.md) · [GitHub Issues](https://github.com/LZZLHY/amcl/issues)

AMCL's own code is licensed under GPL-3.0-only. Third-party components retain their respective licenses and copyrights. AMCL is an independent project with no affiliation with or endorsement by Mojang, Microsoft, NetEase or Huawei. [License](LICENSE) · [Third-party sources and licenses](docs/en/credits.md) · [Notices](MyApplication/NOTICE)

This README was written with AI.
