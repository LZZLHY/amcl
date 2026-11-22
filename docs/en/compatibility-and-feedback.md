# Compatibility and troubleshooting

[简体中文](../compatibility-and-feedback.md)

To find out whether a modpack will run on your device, start with your **device model and system version, Minecraft version, Java version, mod loader, and mods**. For display problems, include the graphics backend. These details help you find reports from players with similar setups and give others a way to reproduce your issue. [First launch](../../README.en.md#first-launch)

## Choose a configuration

| Component | What to check |
| --- | --- |
| App and device | The universal sideload package targets HarmonyOS phones, tablets, and computers (`2in1`). Its declared minimum is HarmonyOS 6.0.0 (API 20). When a separate desktop package is available on the download page, it targets `2in1` devices only, requires at least 6.0.2 (API 22), and uses the desktop controls. [Official downloads](https://amcl.lovedhy.cn/download) · [Product definitions](../../MyApplication/config/products.json) |
| Java runtime | Leave Java selection on automatic. AMCL uses the game manifest and loader requirements to choose a JDK and prompts you to download it if needed. If you pinned a Java version for an instance and the game stopped launching after a version change, check that instance’s Java settings first. HarmonyOS runtimes for Java 8, 17, 21, and 25 are available to install individually. [Runtime guide](https://amcl.lovedhy.cn/docs/jdk) |
| Loaders and mods | Match the Minecraft version, loader, and required dependencies listed for each mod file. You can install Fabric, Forge, and NeoForge directly from the game version page. When troubleshooting an existing modpack, record its version and any mods you added or removed. |
| Graphics and input | For your first launch, leave the graphics backend on automatic under Settings → Display and controls → Graphics backend (设置 → 显示与操控 → 图形后端 → 自动选择). If you selected a backend manually, record its name. For input issues, specify whether you used a touchscreen, a physical keyboard and mouse, or a controller, and whether the problem occurred in a menu or in the world. |

### Which setups have been tested in a world?

Both examples below were tested on the same MRDI-W10 tablet (API 26), with an AMCL `1.0.7-pre1` development build, the listed HarmonyOS JDK, and an offline account. In both cases, the tester created a world, saved it, exited the game, and relaunched it to load the same save. A different device, mod version, or public sideload build needs its own test. [Tablet test report](https://github.com/LZZLHY/mc-ohos-resources/blob/main/docs/tablet-jdk-games-2026-11-11.md)

| Minecraft | Java and loader | Mods tested |
| --- | --- | --- |
| 1.12.2 | JDK 8 · Forge 14.23.5.2864 | JEI 4.24.0.1042 |
| 26.1.1 | JDK 25 · Fabric Loader 0.19.3 | Sodium 0.8.9 + Fabric API 0.145.4+26.1.1 |

The second setup initially failed because the Fabric API version conflicted with Sodium. With the same device and JDK, the tester could enter the world after switching to the Fabric API version shown above. If a loader reports a similar error, include the mod and dependency names and versions it mentions. An exit code alone leaves out those details.

## Start where the failure occurred

| Symptom | First check | What to include in a report |
| --- | --- | --- |
| The HAP downloaded but will not install | Check that the package is intended for your device. If the filename contains `unsigned`, follow the sideload guide to sign the package yourself and install it. [Illustrated sideload guide](https://amcl.lovedhy.cn/docs/install-hokit-en) | HAP filename, device and system version, and the exact error from the installation tool. |
| A game, mod, or runtime download failed | Open the failed download in the activity log (活动账本) and check which file or stage it reached. | Resource name, target version, time of failure, and the matching download record. |
| Launch stopped at the pre-launch checks (启动前检查) | Look for the check that failed. If a JDK is missing, download the recommended version. If just-in-time compilation (JIT) is unavailable, note the system version and the check result. | Text or screenshot of the failed check and the Java version selected. |
| Vanilla works, but the game exits with mods | Create a test instance with a separate game directory and a new world, keeping the Minecraft version the same. Try the required loader first, then add mods and their dependencies in groups. | The smallest combination that reproduces the failure, each mod’s version, and logs from that attempt. |
| The screen is black or corrupted, or mouse or touch input behaves unexpectedly | Note whether the issue starts at the title screen, while loading a world, or after entering it. If you chose the graphics backend manually, try automatic selection (自动选择) and compare the result. | Device model, graphics backend, input method, steps to reproduce, and screenshots or logs that show the difference. |

## Find the log for the failed attempt

1. **If the game has just exited**, tap Analyze logs (分析日志) in the unexpected-exit dialog (游戏异常退出). This opens the activity details (活动详情) for that session. Tap View related logs (查看相关日志).
2. **If you closed the dialog or retried**, open Settings → Activity log (设置 → 活动账本) and locate the failed attempt by time and Minecraft version. Open its **⋯** menu on the right and select View activity details (查看活动详情) or View raw logs (查看原始日志). Retrying creates a new record, so check the timestamp before sharing.
3. **If a few lines show the problem**, find the event in the related log. Open Actions (操作), choose Copy redacted event (复制事件（脱敏）), and paste the error along with its immediate context into your report.
4. **If you need to share several files**, open the activity’s **⋯** menu and choose Custom sharing and preview (自定义分享与预览). Select the relevant files and tap Preview and continue (预览并继续). Check for tokens, account details, server addresses, and personal file paths. When you are ready to make the selected content public, tap Confirm public sharing (确认公开分享), then Copy link (复制链接). Anyone with the link can read the shared content.

## Report a problem

Search GitHub Issues for an existing report first. If the same steps reproduce the issue, add your findings there. For a new issue, use the GitHub problem and build failure form (问题与构建失败), or use the feedback form on the AMCL website. On the website, paste the log link in the description and attach screenshots using the image upload field. [Search issues](https://github.com/LZZLHY/amcl/issues) · [Open a GitHub issue](https://github.com/LZZLHY/amcl/issues/new/choose) · [Website feedback](https://amcl.lovedhy.cn/feedback)

Copy the fields below into your report. If the game never opened, describe the last step you reached.

```text
AMCL version and product (e.g. stable universal sideload build):
Device model and system version:
Minecraft, JDK, loader, and relevant mod versions:
Graphics backend or input method (for graphics or controls issues):
Steps to reproduce:
Expected and actual results, including the exact error:
Time of failure, redacted log excerpt, or log share link:
```

For a failure **while building AMCL from source**, include the public repository commit, host operating system, SDK and tool versions, the command that failed, and the first relevant error. [Public build guide and common errors](build.md)
