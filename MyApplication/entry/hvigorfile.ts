import { hapTasks, OhosPluginId } from '@ohos/hvigor-ohos-plugin';
import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';

/**
 * 当前激活的构建目标名（= hvigor task 前缀）。
 *
 * hvigor 内置 task 命名为 `<target>@<TaskName>`（如 default@PreBuild）。本项目
 * 自定义 task（syncPrebuiltJars / buildAmclLauncher）需挂在这些内置 task 前后，
 * 故依赖名必须带正确的 target 前缀。
 *
 * 多 product（store / sideload / default）下，每个 product 映射到同名 target
 * （见 build-profile.json5 modules.entry.targets 的 applyToProducts），所以从命令行
 * `-p product=xxx` 解析出的值即 target 名。命令行不带 product 时回退 'default'。
 */
function activeTargetName(): string {
  for (const arg of process.argv) {
    const m = /^product=(.+)$/.exec(arg);
    if (m) return m[1];
  }
  return 'default';
}
const TARGET = activeTargetName();
let BUILD_MODE = process.argv.find(arg => arg.startsWith('buildMode='))?.slice('buildMode='.length) ?? 'debug';

/** Full native argument replacement: product identity is never inferred from Debug. */
function diagnosticProfilePlugin() {
  return {
    pluginId: 'diagnosticProfile',
    apply(node: any) {
      node.afterNodeEvaluate((evaluated: any) => {
        const context = evaluated.getContext(OhosPluginId.OHOS_HAP_PLUGIN);
        if (!context) throw new Error('Diagnostic build context unavailable');
        BUILD_MODE = context.getBuildMode();
        const projectRoot = resolve(__dirname, '..');
        const args = execFileSync(process.execPath, [resolve(projectRoot, 'scripts/diagnostic-profile.mjs'),
          '--product', TARGET, '--mode', BUILD_MODE, '--arguments'], { cwd: projectRoot, encoding: 'utf8' }).trim();
        const profile = context.getBuildProfileOpt();
        const target = profile.targets.find((item: any) => item.name === TARGET);
        if (!target) throw new Error(`Missing diagnostic target ${TARGET}`);
        const native = target.config.buildOption.externalNativeOptions;
        native.arguments = native.arguments.replace(/(?:^|\s)-DMC_OHOS_BUILD_TESTS=\S+/g, '') + ' ' + args;
        const nativeGl = process.env.AMCL_DESKTOP_NATIVE_GL_VALIDATE === '1';
        if (nativeGl && TARGET !== 'desktop') throw new Error('Native GL validation requires desktop product');
        native.arguments += ' -DAMCL_DESKTOP_NATIVE_GL_VALIDATE=' + (nativeGl ? 'ON' : 'OFF');
        // Every product carries the same graphics providers. Only retired
        // in-app Mesa/Zink assets are excluded from the complete artifact set.
        {
          const options = target.config.buildOption;
          options.nativeLib = options.nativeLib ?? {};
          options.nativeLib.filter = options.nativeLib.filter ?? {};
          const excluded = options.nativeLib.filter.excludes ?? [];
          options.nativeLib.filter.excludes = [...new Set([...excluded,
            '**/libEGL_mesa.so', '**/libgallium.so', '**/libglapi.so'])];
        }
        context.setBuildProfileOpt(profile);
      });
    },
  };
}

/**
 * syncPrebuiltJarsPlugin — hvigor 自定义 task，把 prebuilt/lwjgl3/jars/*.jar 同步到 rawfile/lwjgl/。
 *
 * 历史：项目长期靠人工 `bash scripts/sync_prebuilt.sh` 手动同步，一旦改了 prebuilt 而忘
 * 跑此脚本，HAP 内的 jar 就还是旧版本（rawfile mtime 早于 prebuilt）。
 * 2026-05-19 LWJGL 3.3.3 升级时撞上这个坑：手动替换 `prebuilt/lwjgl3/jars/*.jar` 为 3.3.3 后
 * 直接 hvigorw assembleHap，HAP 内还是 3.3.2，sodium 检查失败。
 *
 * 现在挂在 hvigor 构建图里：`PreBuild → syncPrebuiltJars → CompileResource → PackageHap`
 * 改 prebuilt 后跑 hvigorw 自动同步，无需再手动。
 *
 * 实现纯 Node：拷贝 prebuilt/lwjgl3/jars/*.jar + prebuilt/stubs/*.jar 到 rawfile，
 * 增量比较 mtime 跳过已同步文件。
 */
function syncPrebuiltJarsPlugin() {
  return {
    pluginId: 'syncPrebuiltJars',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    apply(pluginContext: any) {
      pluginContext.registerTask({
        name: 'syncPrebuiltJars',
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        run: (_taskContext: any) => {
          const fs = require('node:fs');
          const path = require('node:path');
          const projectRoot = resolve(__dirname, '..');
          const lwjglSrc = resolve(projectRoot, 'prebuilt', 'lwjgl3', 'jars');
          const lwjgl322Src = resolve(projectRoot, 'prebuilt', 'lwjgl3', '3.2.3', 'jars');
          const stubsSrc = resolve(projectRoot, 'prebuilt', 'stubs');
          const rawfileLwjgl = resolve(projectRoot, 'entry', 'src', 'main', 'resources', 'rawfile', 'lwjgl');
          const rawfileLwjgl322 = resolve(projectRoot, 'entry', 'src', 'main', 'resources', 'rawfile', 'lwjgl-3.2.3');
          const rawfileRoot = resolve(projectRoot, 'entry', 'src', 'main', 'resources', 'rawfile');

          let copied = 0;
          let skipped = 0;
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          const sync = (srcDir: string, dstDir: string, label: string) => {
            if (!fs.existsSync(srcDir)) return;
            if (!fs.existsSync(dstDir)) fs.mkdirSync(dstDir, { recursive: true });
            for (const name of fs.readdirSync(srcDir)) {
              if (!name.endsWith('.jar')) continue;
              const src = path.join(srcDir, name);
              const dst = path.join(dstDir, name);
              const srcMtime = fs.statSync(src).mtimeMs;
              const dstMtime = fs.existsSync(dst) ? fs.statSync(dst).mtimeMs : 0;
              if (srcMtime > dstMtime) {
                fs.copyFileSync(src, dst);
                console.log(`[hvigor syncPrebuiltJars] ${label}: ${name}`);
                copied++;
              } else {
                skipped++;
              }
            }
          };
          sync(lwjglSrc, rawfileLwjgl, 'LWJGL3');
          sync(lwjgl322Src, rawfileLwjgl322, 'LWJGL322');
          sync(stubsSrc, rawfileRoot, 'STUBS');
          console.log(`[hvigor syncPrebuiltJars] copied=${copied} skipped=${skipped}`);
        },
        dependencies: ['checkSdl3LaunchContract'],
        postDependencies: [`${TARGET}@CompileResource`],
      });
    },
  };
}

/** 在资源同步前完成 bridge 注入与 3.4.2 现代槽位整体验证。 */
function prepareLwjglModernSlotPlugin() {
  return {
    pluginId: 'prepareLwjglModernSlot',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    apply(pluginContext: any) {
      pluginContext.registerTask({
        name: 'prepareLwjglModernSlot',
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        run: (_taskContext: any) => {
          const projectRoot = resolve(__dirname, '..');
          const script = resolve(projectRoot, 'scripts', 'prepare-lwjgl-modern-slot.mjs');
          console.log('[hvigor prepareLwjglModernSlot] running:', script);
          execFileSync(process.execPath, [script, '--require-source'], {
            stdio: 'inherit',
            cwd: projectRoot,
          });
        },
        dependencies: ['prepareProductArtifact'],
      });
    },
  };
}

/** 在资源编译前锁住 MC 26.3 所需的 SDL3 启动线程与库路由契约。 */
function checkSdl3LaunchContractPlugin() {
  return {
    pluginId: 'checkSdl3LaunchContract',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    apply(pluginContext: any) {
      pluginContext.registerTask({
        name: 'checkSdl3LaunchContract',
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        run: (_taskContext: any) => {
          const projectRoot = resolve(__dirname, '..');
          const script = resolve(projectRoot, 'scripts', 'check-sdl3-artifact.mjs');
          console.log('[hvigor checkSdl3LaunchContract] running:', script);
          execFileSync(process.execPath, [script], {
            stdio: 'inherit',
            cwd: projectRoot,
          });
        },
        dependencies: ['prepareLwjglModernSlot'],
      });
    },
  };
}

/**
 * buildAmclLauncherPlugin — hvigor 自定义 task，在 HAP 打包前自动编 JavaApp/*.java
 *
 * JavaApp/ 下是 AMCL Java 中间启动层（AmclLauncher / AmclClassLoader / LaunchConfig / ForgeHelper）。
 * 这些 .java 不是 HAP 代码，而是通过 C 层 JNI_CreateJavaVM 由 HotSpot 加载的 classpath。
 * 原来靠 build-hap.ps1 手跑 javac + jar，改代码后忘记跑就会跑旧版。
 *
 * 现在挂在 hvigor 构建图里：
 * `syncPrebuiltJars → buildAmclLauncher → CompileResource → PackageHap`。
 * rawfile 会在 CompileResource 阶段被快照，因此 jar 必须在该阶段之前生成；只挂到
 * PackageHap 前会让第一次 clean build 打入上一次的 jar。
 * DevEco Run / hvigorw 命令行 / CI 都会自动触发，不再依赖外部脚本。
 *
 * 实际的 javac + jar 逻辑在 scripts/build-amcl-launcher.mjs（跨平台 Node，
 * 带增量检查：jar 比源文件新就跳过）。
 *
 * 已解决 ROADMAP.md P0-1（JavaApp 游离于 hvigor 之外）。
 */
function buildAmclLauncherPlugin() {
  return {
    pluginId: 'buildAmclLauncher',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    apply(pluginContext: any) {
      pluginContext.registerTask({
        name: 'buildAmclLauncher',
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        run: (_taskContext: any) => {
          // entry/ 下 hvigorfile.ts，__dirname 定位到 entry/；向上一层到项目根
          const projectRoot = resolve(__dirname, '..');
          const script = resolve(projectRoot, 'scripts', 'build-amcl-launcher.mjs');
          console.log('[hvigor buildAmclLauncher] running:', script);
          execFileSync(process.execPath, [script, '--product', TARGET], {
            stdio: 'inherit',
            cwd: projectRoot,
          });
        },
        dependencies: ['syncPrebuiltJars'],
        postDependencies: [`${TARGET}@CompileResource`],
      });
    },
  };
}

function prepareProductArtifactPlugin() {
  return {
    pluginId: 'prepareProductArtifact',
    apply(pluginContext: any) {
      pluginContext.registerTask({
        name: 'prepareProductArtifact',
        run: () => {
          const projectRoot = resolve(__dirname, '..');
          execFileSync(process.execPath, [resolve(projectRoot, 'scripts/check-product-contract.mjs'), '--product', TARGET], { cwd: projectRoot, stdio: 'inherit' });
          execFileSync(process.execPath, [resolve(projectRoot, 'scripts/check-desktop-runtime.mjs')], { cwd: projectRoot, stdio: 'inherit' });
          execFileSync(process.execPath, [resolve(projectRoot, 'scripts/prepare-product-artifact.mjs'), '--product', TARGET, '--mode', BUILD_MODE], { cwd: projectRoot, stdio: 'inherit' });
          execFileSync(process.execPath, [resolve(projectRoot, 'scripts/check-mobilegl-build-contract.mjs'), '--prepare', '--product', TARGET], { cwd: projectRoot, stdio: 'inherit' });
        },
        dependencies: [`${TARGET}@PreBuild`],
      });
    },
  };
}

/** Customize the evaluated manifest; never rewrite the shared source file. */
function desktopManifestPlugin() {
  return {
    pluginId: 'desktopManifest',
    apply(node: any) {
      if (TARGET !== 'desktop') return;
      node.afterNodeEvaluate((evaluated: any) => {
        const context = evaluated.getContext(OhosPluginId.OHOS_HAP_PLUGIN);
        if (!context) throw new Error('Desktop manifest context unavailable');
        const manifest = context.getModuleJsonOpt();
        if (!(manifest.module.requestPermissions ?? []).some((item: any) => item.name === 'ohos.permission.READ_PASTEBOARD')) {
          manifest.module.requestPermissions.push({ name: 'ohos.permission.READ_PASTEBOARD',
            reason: '$string:perm_reason_pasteboard', usedScene: { abilities: ['GameAbility'], when: 'inuse' } });
        }
        const ability = manifest.module.abilities.find((item: any) => item.name === 'EntryAbility');
        if (!ability || !Array.isArray(ability.skills)) throw new Error('EntryAbility skills unavailable');
        if (TARGET === 'desktop') ability.skills = ability.skills.filter((skill: any) =>
          !(skill.uris ?? []).some((uri: any) => uri.type === 'general.json' && uri.linkFeature === 'FileOpen'));
        context.setModuleJsonOpt(manifest);
      });
    },
  };
}

export default {
  system: hapTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: [
    diagnosticProfilePlugin(),
    desktopManifestPlugin(),
    prepareProductArtifactPlugin(),
    prepareLwjglModernSlotPlugin(),
    checkSdl3LaunchContractPlugin(),
    syncPrebuiltJarsPlugin(),
    buildAmclLauncherPlugin(),
  ],
};
