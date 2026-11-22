# Build AMCL from the public source snapshot

[简体中文](../../MyApplication/docs/BUILD_SNAPSHOT.md) · [English README](../../README.en.md) · [Engineering docs](README.md) · [Architecture](architecture.md) · [Contributing](../../CONTRIBUTING.en.md)

Clone the complete public repository, open the `MyApplication/` directory, prepare the dependencies, and build a HarmonyOS app package (HAP) with DevEco Studio or Hvigor. To identify your checkout, open the snapshot manifest at the same Git commit. Its `release.versionName` and `release.versionCode` fields identify the app version and installation version code. The `sourceCommit` field identifies the corresponding commit in the main development repository. [Source snapshot manifest](../../MyApplication/SOURCE_SNAPSHOT.json)

To find out what was actually built for a release, look up its version and public commit in the rebuild report. It records the sideload builds of 1.0.7 and 1.0.4, including the tools, output hashes, and checks performed for each. [Public rebuild report (Chinese)](../../MyApplication/docs/public-reproduction-audit.md)

A normal HAP build compiles the app’s ArkTS code, the Java launcher, and native sources including MobileGlues and OpenAL. It also uses third-party binaries from the snapshot, including MobileGL, SDL3, LWJGL native libraries, and curl. Both MobileGL libraries and their build provenance are included. Rebuilding all of those third-party inputs from source is a separate undertaking. Reproducing an official signed release byte for byte also depends on the toolchain, paths, build metadata, and signing. A successful HAP build establishes only the result for the inputs you used.

## 1. Tools and network access

The documented build environment is Windows x64. The optional MobileGL source build explicitly uses `cmake.exe`, `ninja.exe`, and LLVM tools from the HarmonyOS SDK for Windows. Full Linux and macOS HAP builds have not been verified for this guide.

| Tool | Requirements |
|---|---|
| Git for Windows | Install Git and Git Bash. Bash must be able to run `setup_deps.sh` and access the same Git, Node.js, and JDK installations as the rest of the build. |
| DevEco Studio or official command-line tools | Install the HarmonyOS SDK, ArkTS and native toolchains, Hvigor, and ohpm. The project uses the HarmonyOS build system. |
| Compile SDK | The pinned SDK is `26.0.0.105`. [Toolchain lock](../../MyApplication/toolchain.lock) |
| Hvigor | The lock records version `6.26.4`. Older plugins can fail when reading the 26.0.0 SDK configuration. |
| Native tools | BiSheng clang 15.0.4 and CMake 3.28.2. The toolchain lock also records SHA-256 hashes for the tools. |
| Node.js | Use the Node.js version supplied for your Hvigor installation. Make `node` available on `PATH`. |
| Build JDK | The general Java tools require a full JDK 21 or later. The game compatibility compiler requires JDK 25 or later to read Java 25 input classes. Set `AMCL_COMPAT_JAVA_HOME` or the local `compatJavaHome` setting to select a separate JDK for that step. [Example configuration](../../MyApplication/build-dependencies.local.json.example) |
| Rust | For products other than `store`, the on-device HDC component requires Cargo and the `aarch64-unknown-linux-ohos` target. It builds with `--locked` against `Cargo.lock`. The build fails if the toolchain is missing. |
| Python | Make Python 3 available as `python` on `PATH`. Both the Java build and the LWJGL post-processing step invoke Python. Some Node.js entry points accept `AMCL_PYTHON` to select the interpreter. |
| PowerShell | The examples use PowerShell. The optional standalone native rebuild uses PowerShell 7 through `pwsh`. |

The compile SDK describes the build environment. The target and minimum compatible SDKs are defined per product. [Product definitions](../../MyApplication/config/products.json)

| Product | targetSdkVersion | compatibleSdkVersion | Default build mode |
|---|---|---|---|
| default | 6.1.0(23) | 6.0.0(20) | debug, for development |
| sideload | 6.1.0(23) | 6.0.0(20) | release |
| store | 6.1.0(23) | 6.0.0(20) | release |
| desktop | 26.0.0 | 6.0.2(22) | release, 2in1 devices only |

Initial setup needs network access to the GitHub dependency repositories, Maven download sources, and the ohpm registry. Maven JARs and ArkTS HAR packages are retrieved separately from the source repositories. When a download fails, check the connection to the relevant source and keep TLS verification and the locked dependency identities intact.

## 2. Clone and verify the snapshot

Run these commands in PowerShell.

```powershell
git -c core.longpaths=true clone https://github.com/LZZLHY/amcl.git amcl
Set-Location amcl/MyApplication
git config core.longpaths true
node scripts/check-public-snapshot.mjs
```

Use a short checkout path such as `C:/src/amcl` to reduce the chance of hitting Windows path length limits during native builds.

The snapshot manifest records the source commit, whether the working tree had uncommitted changes at export time, and the SHA-256 hashes of the files. If `sourceDirty` is `true`, the snapshot includes working-tree changes and `sourceCommit` identifies only its base. Use the file manifest to verify the exported contents. Text hashes are normalized to LF so that Windows line-ending conversions do not produce false mismatches. [Source snapshot manifest](../../MyApplication/SOURCE_SNAPSHOT.json)

The Git repository root is one directory above `MyApplication/`. Its submodule declarations and the four gitlinks in the Git index identify LWJGL, MobileGlues, MobileGL, and muka-rust-hdc. The snapshot records the exact source gitlink for HDC. The other three dependencies are also checked against `deps.lock`. Use a Git clone and keep its outer repository. GitHub’s source ZIP lacks the submodule working trees and the Git metadata needed for these checks. [Submodule declarations](../../.gitmodules)

The default native configuration enables input capabilities governed by the project’s Gate 0 approval. During configuration, CMake checks the approval entry, the presence of the referenced document, and its recorded hash. Both files must be present and intact. [Gate 0 lock](../../MyApplication/gate0-evidence.lock) · [Redacted input-capability record (Chinese)](../../MyApplication/docs/testing/gate0-raw-relative-evidence.md)

The public record omits raw device logs. During export, tooling verifies the original evidence hash, replaces device serial numbers, and records the public copy’s SHA-256. The `sourceEvidenceSha256` field preserves the identity of the original. The approval status, date, open gaps G1–G7, and the product owner’s risk acceptance carry over from the original record. The `approved=true` entry applies to that decision. The gaps remain open, and exporting the record provides no additional device validation.

## 3. Configure local tool paths

Replace the example paths below with the tools installed on your machine.

```powershell
$env:JAVA_HOME = 'C:\Tools\jdk-21'
$env:DEVECO_SDK_HOME = 'C:\Tools\command-line-tools\sdk'
$env:AMCL_HVIGORW = 'C:\Tools\command-line-tools\bin\hvigorw.bat'
$env:AMCL_OHPM = 'C:\Tools\command-line-tools\bin\ohpm.bat'
$env:OHOS_LLVM_READELF = Join-Path $env:DEVECO_SDK_HOME 'default\openharmony\native\llvm\bin\llvm-readelf.exe'
$env:Path = "$env:JAVA_HOME\bin;$env:Path"

Test-Path -LiteralPath $env:OHOS_LLVM_READELF
git --version
bash --version
node --version
python --version
javac -version
& $env:AMCL_HVIGORW --version --no-daemon
& $env:AMCL_OHPM --version
```

Set `DEVECO_SDK_HOME` to the SDK root containing `default/openharmony/`. The MobileGL recipe looks for `default/openharmony/native/build-tools/cmake/bin/cmake.exe` below this root. Pointing it directly at `native/` gives the wrong path. If you use the tools bundled with DevEco Studio, point the Hvigor and ohpm variables to the corresponding launchers in its `tools/` directory.

`Test-Path` should return `True`. Set `OHOS_LLVM_READELF` explicitly. The LWJGL native symbol check does not discover `llvm-readelf` from `DEVECO_SDK_HOME` alone.

Make sure `bash.exe` on `PATH` comes from Git for Windows. Git Bash can use the Windows JDK and SDK paths shown here. WSL Bash uses a separate path and tool environment.

## 4. Prepare third-party sources and Java build inputs

```powershell
node scripts/prepare-public-deps.mjs
node scripts/prepare-public-deps.mjs --check
```

The first command prepares the dependencies. The `--check` invocation verifies what has already been prepared. The initial run downloads several large source trees and can take time. If it appears to stall, use the repository, path, and command printed by the script to identify the active download.

The game compatibility layer requires pinned compile-time dependencies. Choose a download directory outside the repository and point `AMCL_COMPAT_JAVA_HOME` to a full JDK 25 installation. The downloader verifies the size and digest of each file. The compatibility JAR contains only the adaptation code. [Compile-time input manifest](../../MyApplication/prebuilt/runtime-compat/threading-inputs.json)

```powershell
$env:AMCL_GAME_COMPAT_INPUTS = 'C:/AMCL-cache/game-compat-inputs'
$env:AMCL_COMPAT_JAVA_HOME = 'C:/Java/jdk-25'
python scripts/prepare-game-compat-inputs.py --download --output $env:AMCL_GAME_COMPAT_INPUTS
```

The preparation script sets `GIT_LFS_SKIP_SMUDGE=1`. This preserves the pointer files for the large LFS replay fixtures used by the optional MobileGL `trace_replay` tool. A regular HAP build needs no additional `git lfs pull`. Retrieve those fixtures separately if you run the replay tool itself.

Since 1.0.8-pre1, Hvigor’s resource preparation has checked the sideload signing compatibility inputs and generated the packaged templates from a pinned public commit of Xiaobai Debug Assistant (小白调试助手) and the public HoKit 1.2.2 Android package. During the build, AMCL runs its own template parsing and cryptographic checks. The generated files stay outside Git, and the build does not read a maintainer’s or device owner’s personal signing material. If HoKit’s default download URL serves a different version, set `AMCL_HOKIT_TEMPLATE_INPUT` to a copy of the pinned public package. The script verifies its size and SHA-256. [Template preparation script](../../MyApplication/scripts/prepare-signing-templates.mjs) · [Component credits and sources](credits.md)

| Input | How it is obtained |
|---|---|
| MobileGlues | The script initializes the fork at the revision recorded by `deps.lock` and the submodule gitlink, including the nested submodules required for a normal build. |
| LWJGL 3 | The script initializes the source submodule, downloads the pinned modern Maven JARs, verifies them, and runs AMCL’s post-processing steps. |
| OpenAL Soft | `setup_deps.sh` retrieves the upstream tag and commit recorded in `deps.lock`, verifies the SHA, then uses `docker/apply_patches.sh` to apply the OHAudio registration patch. The patch step can be run again safely. |
| SDL3 sources | The script prepares `prebuilt/sdl3/sdl3_src` from the `[sdl3-native]` entry in `deps.lock`. An ordinary HAP build uses the SDL3 library included in the snapshot. |
| MobileGL | The script initializes the fork and required nested dependencies, including `asio` for the production thread pool. It restores the external inputs listed in glslang’s `known_good` manifest, verifies the bundled `dist` files, and prepares the HAP inputs. |
| On-device HDC | The script initializes the pinned muka-rust-hdc submodule. The source tree contains the AMCL adaptations, `Cargo.lock`, and the build entry point. A regular non-store build generates the static library. |
| ArkTS HAR packages | Install these with ohpm in the next step. They are separate from the Git submodules. |
| Game JDK | The app downloads the configured game runtime on the device. The build host uses its own `JAVA_HOME`. |

The root submodule file registers Git submodules for the public repository. The dependency lock records their sources and fingerprints. glslang’s `External/spirv-tools` is acquired separately from normal Git submodules. A recursive submodule update alone misses this input, and running `setup_deps.sh` alone also leaves the MobileGL preparation incomplete. [Submodule declarations](../../.gitmodules) · [Dependency lock](../../MyApplication/deps.lock)

Use the default preparation mode on a fresh checkout. `setup_deps.sh --force` recreates some existing dependencies. If you have edited their sources, save your changes before deciding whether to restore the locked versions.

## 5. Configure the project and signing

```powershell
Copy-Item build-profile.json5.template build-profile.json5
& $env:AMCL_OHPM install --all
```

Copy the template only when setting up a new environment, to preserve any existing local settings. Open `MyApplication/` in DevEco Studio, select the installed SDK, and let the IDE generate `local.properties` and synchronize the project.

The template’s `signingConfigs` array is empty, and its products refer to a configuration named `default`. To build a signed package for installation, open **Project Structure → Signing Configs** in DevEco Studio and configure your own certificate, profile, and keystore. The configuration name must match the selected product’s `signingConfig`. For an unsigned build check, remove the selected product’s `signingConfig` property from your local `build-profile.json5` and leave `signingConfigs` empty. Use real signing credentials only when configuring a signed build.

`build-profile.json5`, `local.properties`, and signing credentials are local inputs. A signed HAP must meet the device and signing profile requirements before it can be installed. An unsigned build verifies compilation and packaging only.

## 6. Build a HAP with the locked inputs

All four products require the complete set of graphics artifacts. The public snapshot ships three locked MobileGL inputs, `libmobilegl.so`, `libmobilegl.unstripped.so`, and `build-provenance.json`. As part of normal dependency preparation, `prepare-public-deps.mjs` runs the project’s MobileGL verifier. It checks the source revision, the SHA-256 of both libraries, and the runtime contents before copying the required library into the HAP input directory. This path uses the supplied binaries directly. [Locked MobileGL artifacts](../../MyApplication/prebuilt/mobilegl/dist/)

```powershell
node scripts/check-mobilegl-build-contract.mjs --prepare --product default
```

You can run that command on its own to recheck or prepare the locked inputs. It verifies the identity of the libraries and copies the required input without compiling MobileGL. The optional source rebuild in section 9 overwrites the supplied `dist` files. The standalone rebuild produced different bytes from the locked binaries, so keep it separate from normal HAP preparation.

To check the Java build and resource preparation before compiling the entire HAP, run the following commands.

```powershell
node scripts/prepare-lwjgl-modern-slot.mjs --require-source
node scripts/build-amcl-launcher.mjs --product default
```

Then run the Hvigor supplied for your SDK from the project directory, `MyApplication/`.

```powershell
& $env:AMCL_HVIGORW assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

In DevEco Studio, you can instead select the matching product, target, and build mode and build the HAP there. Before resource compilation, `entry/hvigorfile.ts` prepares product resources, checks MobileGL and SDL3, processes LWJGL, and generates the Java artifacts. Running the individual commands above can surface dependency or JDK errors earlier.

When switching products, set both `product` and `buildMode`. For the sideload release build, run the following command.

```powershell
& $env:AMCL_HVIGORW assembleHap --mode module -p product=sideload -p buildMode=release --no-daemon
```

For `store` and `desktop`, use the matching product and `entry` target from the template. Check both `config/products.json` and the final merged HAP configuration to establish the product’s capabilities.

The development repository’s `build-hap.ps1`, `build-app.ps1`, and release scripts also check source-repository identity, internal evidence, and release or acceptance requirements. These scripts intentionally reject the public distribution repository as a release source. Use the DevEco/Hvigor procedure above to build the public snapshot. Formal release acceptance is a separate process in the development repository.

## 7. Check the build output

Confirm that Hvigor completed with exit code 0. Then inspect the output directory for your target.

```powershell
Get-ChildItem entry/build/default/outputs -Recurse -Filter *.hap
```

For another product, replace `default` with the target name. Check that the output’s `signed` or `unsigned` suffix matches your local signing configuration. Record the Git commit, `SOURCE_SNAPSHOT.json`, `deps.lock`, `toolchain.lock`, the actual tool versions, and the build command.

- Verify that the HAP is for the selected product and contains the required `arm64-v8a` native libraries and Java resources.
- Confirm that the MobileGL artifact checks passed. Review the Java and LWJGL build output for skipped failures.
- If you install the app on a device, use your own valid signing configuration. Verify app startup, downloads, JDK extraction, and the target game separately.

Verify the snapshot before building. Build scripts can update JARs in `rawfile`, product metadata, and generated ArkTS constants. Use `git diff` after building to distinguish generated changes from hand edits. A generated difference alone does not show that a file was missing from the export. Record any local edits when reporting the provenance of a build.

## 8. Troubleshoot common failures

| Symptom | What to check |
|---|---|
| A submodule path or gitlink is missing | Check that you kept the outer `amcl` Git repository and ran the public dependency preparation script. Start from a complete clone. A source ZIP or a copy of `MyApplication/` alone lacks the required Git metadata. |
| A Git download takes a long time | Check which dependency Git is retrieving and verify connectivity to its upstream. The initial LWJGL and MobileGL source downloads can be large. |
| Windows reports `Filename too long` | The preparation script enables long-path support for Git writes, including glslang’s `External` inputs. Use a short checkout path because SDK and native tools can have their own limits. Older preparation scripts may have left incomplete directories. Preserve your edits before restoring the locked files. |
| A download stalls on Git LFS or large `trace_replay` data | Run `prepare-public-deps.mjs`. It skips optional LFS replay fixtures for regular HAP builds. There is no need to run `git lfs pull` for this build. |
| glslang is missing `External/spirv-tools` | Rerun `prepare-public-deps.mjs`. A normal recursive submodule update does not retrieve these external dependencies. |
| `javac` does not support `release 21` or reports `Compatibility input requires JDK 25+` | Run `javac -version` in the current terminal. The compatibility build first checks `AMCL_COMPAT_JAVA_HOME`, then the local `compatJavaHome` setting, then `JAVA_HOME` or `PATH`. Verify that the selected `bin/javac` is version 25 or later. |
| Python is missing or the compatibility JAR fails to build | Check `python`, `AMCL_PYTHON`, the prepared LWJGL JARs, and the source-manifest verification output. |
| An SDK version string is invalid or an API is missing | Confirm that Hvigor and its plugins match the SDK. Changing `compatibleSdkVersion` alone leaves a compile-SDK mismatch unresolved. |
| `check-lwjgl-native-surface` cannot find `llvm-readelf` | Set `OHOS_LLVM_READELF` as shown in section 3 and confirm that `Test-Path` returns `True`. |
| CMake rejects the configuration during the Gate 0 input check | Verify that `gate0-evidence.lock` and the redacted document it references are present in the clone and match their recorded contents. Restore any missing or changed input from the same public commit, preserving the approvals and hashes. |
| MobileGL `dist` is missing | Check that the clone includes all three bundled `dist` files. An ordinary HAP build uses those artifacts directly. |
| A MobileGL hash differs | Check whether the optional source rebuild overwrote `dist`. Save the new artifacts and logs, then restore the locked inputs as described in section 9. Keep the hashes in the dependency lock intact. |
| The `default` signing configuration is missing | Import your own signing material, or remove the selected product’s `signingConfig` from your local configuration for an unsigned build as described in section 5. |
| `build-hap.ps1` rejects the Git origin or reports missing internal documentation | That script handles acceptance and release builds in the main development repository. Use the DevEco/Hvigor procedure in this guide for the public project. |

## 9. Rebuilding third-party libraries

A standard HAP build uses the third-party native inputs included in the snapshot. To rebuild one independently, locate its source, version, patches, and build recipe in the component credits. [Third-party component credits](credits.md)

- **SDL3.** See `scripts/build-sdl3-ohos.ps1` and `prebuilt/sdl3/patches/series`.
- **LWJGL, curl, gl4es, Mesa/Zink, and the JDK.** See the relevant recipe in `docker/` and the matching notes under `prebuilt/`.
- **MobileGL.** Use the optional Windows native build below for independent work. A normal HAP build uses the bundled `dist` from section 6.
- **MobileGlues and OpenAL.** These are compiled as part of the native HAP build. The dependency preparation step retrieves their source code.

Prepare the required Docker images, a usable OHOS sysroot, upstream archives, and the tools for each component separately. The public repository does not bundle every external toolchain or all third-party sources. A download field marked `PENDING` in `deps.lock` does not identify an available prebuilt release. End-to-end source rebuilds and byte-for-byte reproduction have not been verified across all historical recipes and binary inputs. Verify each component you rebuild.

### Optional MobileGL source build

Once you have prepared the dependencies and configured the SDK, use the following command to compile MobileGL independently for study or verification.

```powershell
pwsh -File prebuilt/mobilegl/build-mobilegl.ps1
```

This command regenerates and overwrites all three files in `prebuilt/mobilegl/dist/`. On 2026-09-24, MobileGL compiled successfully in a separate working directory using the public source. The stripped and unstripped libraries had different SHA-256 hashes from the artifacts in `deps.lock`, so they cannot pass the HAP input check as replacements. The causes of all byte differences have yet to be established. Keep the locked hashes when building the HAP.

If you want to keep your rebuild, first save the new libraries, provenance, and logs to a separate directory. **Run the following commands only when you are ready to discard any rebuilt MobileGL files in this checkout.** From `MyApplication/`, restore the locked files from the current public commit and prepare the HAP input again.

```powershell
git restore -- prebuilt/mobilegl/dist
node scripts/check-mobilegl-build-contract.mjs --prepare --product default
```

Dependency preparation and Java launcher compilation have been verified in a separate public checkout. Full HAP compilation, installation, and device acceptance each require their own results.

The snapshot also includes a patch covering two VMA C++ changes from the main working tree that had not landed upstream. It is based on the locked LWJGL commit and has SHA-256 `4af5f2259e3490eda3d4ba0c61cbbd68490fa6a8949080bc56110527c203bbb3`. The preparation script leaves the pinned upstream source tree used for Java resources untouched by this patch. Ordinary HAP builds use the retained `liblwjgl_vma.so`. To rebuild the library independently, verify the patch, native build arguments, and resulting artifact. A complete clean-clone rebuild of that library has yet to be verified. [VMA patch](../../MyApplication/prebuilt/lwjgl3/local-worktree.patch)

The current JDK 8, 17, 21, and 25 recipes pin exact source commits in the build-input manifest and prepare them with `docker/scripts/prepare_jdk_source.py`. The `PENDING` value in the older `deps.lock [openjdk].commit` entry describes a historical record. The newer pins identify the source for their respective recipes. They do not establish the complete provenance or byte-for-byte reproducibility of earlier runtimes assembled from mixed inputs. The component index records these identities separately. [JDK build inputs](../../MyApplication/prebuilt/jdk/build-inputs.json)

The snapshot provides identifiable project inputs and a documented build procedure. Claims about full device compatibility, source rebuilds of every third-party component, and byte-for-byte reproduction of an official release each require verification at that level.
