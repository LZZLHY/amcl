# AMCL documentation

[简体中文](../../MyApplication/docs/README.md) · **English**

To install the launcher and start your first game, begin with the README. If a game fails, the troubleshooting guide shows how to find the log for that specific session. [First launch](../../README.en.md#first-launch) · [Compatibility and troubleshooting](compatibility-and-feedback.md)

| What you need | Document |
| --- | --- |
| Set up the toolchain, prepare dependencies and build a HarmonyOS HAP | [Build from the public snapshot](build.md) |
| See which public commits were rebuilt and what was verified for each HAP | [Public rebuild records (Chinese)](../../MyApplication/docs/public-reproduction-audit.md) |
| Understand the app modules, game process and native/JVM launch path | [Application architecture](architecture.md) |
| Find upstream projects, patches, build recipes and licenses | [Third-party components and licenses](credits.md) |
| Report an issue or submit a change | [Contributing to AMCL](../../CONTRIBUTING.en.md) |
| Identify a release snapshot, its source commit and file hashes | [Source snapshot manifest](../../MyApplication/SOURCE_SNAPSHOT.json) |
| Inspect the input capability evidence required by the default native build | [Gate 0 lock](../../MyApplication/gate0-evidence.lock) · [Sanitized evidence (Chinese)](../../MyApplication/docs/testing/gate0-raw-relative-evidence.md) |
| Read the license for AMCL code and the terms for third-party files | [License](../../MyApplication/LICENSE) · [Notices](../../MyApplication/NOTICE) · [Third-party license texts](../../MyApplication/third-party-notices/README.md) |

The dependency lock, submodule pointers and component manifests identify the inputs. Product definitions record the device and channel configuration. Hvigor, CMake and the build scripts determine which inputs each product uses. [Dependency lock](../../MyApplication/deps.lock) · [Product definitions](../../MyApplication/config/products.json)

The public snapshot includes sanitized input capability evidence with the original approval scope and outstanding gaps. Raw device logs, private diagnostics, internal work logs and release signing procedures stay outside the snapshot. Source comments may refer to those historical documents. The public build instructions describe the steps available to contributors.
