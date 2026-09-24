/**
 * RuntimeDeployer.ets — LWJGL jar + stub-objc-bridge 部署逻辑
 *
 * 从 Index.ets 中提取的 extractLwjglJars() 和 deployStubObjcBridge() 逻辑。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { resolveFontconfigSource, FONTCONFIG_MIN_SIZE_BYTES, SUPPORTED_JDK_VERSIONS } from 'commons';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_LAUNCH } from 'commons';
import { lwjglRuntimeSlot } from './LwjglRuntimeSlots';
import { lwjglBytesSha256, verifyLwjglRuntimeSlotSync } from './LwjglSlotIntegrity';
import { stringToUtf8 } from 'commons';
import { VersionFileVerifier } from 'feature_core';
import { GAME_COMPAT_JAR, GAME_COMPAT_SIZE, GAME_COMPAT_SHA256 } from './GameCompatibilityArtifact';
import { gameCompatibilityPath } from './GameCompatibility';
import { lwjglGenerationDirectory, runtimeSlotNativeOps, collectUnusedLwjglGenerations } from './RuntimeSlotGenerations';

export class RuntimeDeployer {
  private context: Context;

  constructor(context: Context) {
    this.context = context;
  }

  /** Immutable content-addressed artifact; never modifies the instance's mods directory. */
  async deployGameCompatibility(filesDir: string): Promise<void> {
    const dest = gameCompatibilityPath(filesDir);
    try {
      if (fs.statSync(dest).size === GAME_COMPAT_SIZE &&
        (await VersionFileVerifier.sha256File(dest)).toLowerCase() === GAME_COMPAT_SHA256) return;
    } catch (e) { /* absent or incomplete artifact is replaced below */ }
    try { fs.mkdirSync(filesDir + '/runtime-compat', true); } catch (e) { /* exists */ }
    const data: Uint8Array = this.context.resourceManager.getRawFileContentSync(GAME_COMPAT_JAR);
    if (data.byteLength !== GAME_COMPAT_SIZE) throw new Error('Game compatibility resource size mismatch');
    const temp = dest + '.tmp.' + Date.now() + '-' + Math.floor(Math.random() * 1000000000);
    try {
      const file = fs.openSync(temp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try { fs.writeSync(file.fd, data.buffer); fs.fsyncSync(file.fd); } finally { fs.closeSync(file); }
      if ((await VersionFileVerifier.sha256File(temp)).toLowerCase() !== GAME_COMPAT_SHA256) {
        throw new Error('Game compatibility resource hash mismatch');
      }
      try { fs.renameSync(temp, dest); } catch (e) {
        // A concurrent launcher may already have published these exact immutable bytes.
        if ((await VersionFileVerifier.sha256File(dest)).toLowerCase() !== GAME_COMPAT_SHA256) {
          throw new Error('Cannot publish game compatibility artifact: ' + (e as Error).message);
        }
      }
    } finally {
      try { fs.unlinkSync(temp); } catch (e) { /* renamed or never created */ }
    }
  }

  /**
   * 部署现代槽；版本与字节清单继续由 LwjglModernSlot 的既有生成契约决定。
   * 单槽失败会抛出；deployAll 在明确记录后继续部署其他独立槽，所选槽仍须过预检。
   */
  extractLwjglJars(mcDir: string): void {
    this.extractLwjglSlot(mcDir, 'lwjgl-ohos');
  }

  /**
   * 部署 3.2.3 兼容槽。保留 _v322 native 与现役七模块路线，不升级 JAR 字节。
   * 与现代槽使用同一完整性协议，历史 installed 字符串不再代表有效内容身份。
   */
  extractLwjgl322Jars(mcDir: string): void {
    this.extractLwjglSlot(mcDir, 'lwjgl-ohos-322');
  }

  /**
   * 每份交付清单对应不可变目录。先在唯一 staging 验证全部字节与 marker，再由 native
   * 在发布锁下原子改名、更新活动指针。损坏同名代仅在没有读者时修复；旧平铺槽不改写。
   */
  private extractLwjglSlot(mcDir: string, slotName: string): void {
    const slot = lwjglRuntimeSlot(slotName);
    const directory: string = lwjglGenerationDirectory(mcDir, slotName);
    const reusable = verifyLwjglRuntimeSlotSync(directory);
    if (reusable.ok) {
      runtimeSlotNativeOps().publish('', directory);
      // 前一次升级时旧游戏可能仍持租约；即使本代直接复用，也要给已退出的旧代一次回收机会。
      try { collectUnusedLwjglGenerations(mcDir, slotName); }
      catch (cleanupError) { AppLogger.warn('LWJGL', 'Deferred old generation collection', cleanupError, LOG_DOMAIN_LAUNCH); }
      AppLogger.info('LWJGL', 'Reusing verified runtime slot: ' + slot.id, LOG_DOMAIN_LAUNCH);
      return;
    }
    AppLogger.info('LWJGL', 'Installing LWJGL ' + slot.version + ' slot ' + slot.id, LOG_DOMAIN_LAUNCH);
    const managed: string = mcDir + '/.amcl-runtime';
    try { fs.mkdirSync(managed, true); } catch (error) { if (!fs.statSync(managed).isDirectory()) throw error as Error; }
    const stage: string = runtimeSlotNativeOps().createStage(directory);
    try {
      for (const jar of slot.jars) {
        const bytes: Uint8Array = this.context.resourceManager.getRawFileContentSync(slot.resourceDirectory + '/' + jar.name);
        if (bytes.byteLength !== jar.size || lwjglBytesSha256(bytes) !== jar.sha256) {
          throw new Error('包内 LWJGL 内容身份不匹配：' + slot.id + '/' + jar.name);
        }
        this.writeFileAtomic(stage + '/' + jar.name, bytes);
      }
      const verified = verifyLwjglRuntimeSlotSync(stage, false);
      if (!verified.ok) throw new Error(verified.detail);
      this.writeFileAtomic(stage + '/.installed', stringToUtf8(slot.marker));
      const staged = verifyLwjglRuntimeSlotSync(stage);
      if (!staged.ok) throw new Error(staged.detail);
      runtimeSlotNativeOps().publish(stage, directory);
      // marker 写入/关闭/重命名异常不能被静默当作可用槽；提交后再验证一次完整身份。
      const committed = verifyLwjglRuntimeSlotSync(directory);
      if (!committed.ok) throw new Error(committed.detail);
      AppLogger.info('LWJGL', committed.detail, LOG_DOMAIN_LAUNCH);
      // 回收失败或旧游戏占用均不损坏刚发布的代；下次部署再尝试。
      try { collectUnusedLwjglGenerations(mcDir, slotName); }
      catch (cleanupError) { AppLogger.warn('LWJGL', 'Deferred old generation collection', cleanupError, LOG_DOMAIN_LAUNCH); }
    } catch (error) {
      throw new Error('LWJGL ' + slot.id + ' 部署失败：' + (error as Error).message);
    } finally {
      try { runtimeSlotNativeOps().discardStage(stage); }
      catch (cleanupError) { AppLogger.warn('LWJGL', 'Staging cleanup deferred', cleanupError, LOG_DOMAIN_LAUNCH); }
    }
  }

  /**
   * 有界写入唯一临时文件，检查短写，fsync 后 rename；finally 始终关闭句柄与清残件。
   * 此方法只写当前调用独占的 staging 目录。整槽提交由 native 的目录 fsync/rename
   * 完成；这里的单文件重试不能改写已发布代。失败必须回传给所选槽预检。
   */
  private writeFileAtomic(dest: string, data: Uint8Array): void {
    const temporary: string = dest + '.tmp.' + Date.now() + '-' + Math.floor(Math.random() * 1000000000);
    let opened: fs.File | undefined = undefined;
    try {
      opened = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      let offset: number = 0;
      while (offset < data.byteLength) {
        const chunk: Uint8Array = data.slice(offset, Math.min(offset + 256 * 1024, data.byteLength));
        const written: number = fs.writeSync(opened.fd, chunk.buffer as ArrayBuffer);
        if (written <= 0 || written > chunk.byteLength) throw new Error('LWJGL 文件短写：' + dest);
        offset += written;
      }
      fs.fsyncSync(opened.fd);
      fs.closeSync(opened);
      opened = undefined;
      try {
        fs.renameSync(temporary, dest);
      } catch (renameError) {
        if (fs.accessSync(dest)) fs.unlinkSync(dest);
        fs.renameSync(temporary, dest);
      }
    } finally {
      if (opened !== undefined) fs.closeSync(opened);
      try {
        if (fs.accessSync(temporary)) fs.unlinkSync(temporary);
      } catch (cleanupError) {
        AppLogger.warn('LWJGL', 'Failed to clean temporary file: ' + temporary, cleanupError, LOG_DOMAIN_LAUNCH);
      }
    }
  }

  /**
   * 部署 stub-objc-bridge.jar 到 <mcDir>/
   */
  deployStubObjcBridge(mcDir: string): void {
    let dest = mcDir + '/stub-objc-bridge.jar'
    try {
      let data: Uint8Array = this.context.resourceManager.getRawFileContentSync('stub-objc-bridge.jar')
      let f = fs.openSync(dest, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
      fs.writeSync(f.fd, data.buffer)
      fs.closeSync(f)
      AppLogger.info('OBJC', `Deployed stub-objc-bridge.jar (${data.byteLength} bytes)`, LOG_DOMAIN_LAUNCH)
    } catch (e) {
      AppLogger.error('OBJC', 'Failed to deploy stub-objc-bridge.jar', e, LOG_DOMAIN_LAUNCH)
    }
  }

  /**
   * 部署真 LWJGL 2.9.4 槽；保留现役 lwjgl.jar 与 liblwjgl_v2.so 后端，不变更路由。
   * 单 JAR 同样要求内容摘要和提交 marker，不能用“文件存在”代替可用判断。
   */
  extractLwjgl2Jars(mcDir: string): void {
    this.extractLwjglSlot(mcDir, 'lwjgl-ohos-2');
  }

  /**
   * 初始化当前 Minecraft 根的三个独立槽及其余运行时资产。
   * 一个未被选择的槽损坏不应阻止其他槽部署或启动器首页初始化；因此逐槽明确记错，
   * 保留该槽未提交状态，由按所选槽执行的预检阻断游戏。这里没有更换路线或静默降级。
   * fonts.conf 与 JDK 的 fontconfig 仍落在沙箱 filesDir，不随 Minecraft 根迁移。
   */
  deployAll(mcDir: string): void {
    const slots: string[] = ['lwjgl-ohos', 'lwjgl-ohos-322', 'lwjgl-ohos-2'];
    for (const slot of slots) {
      try {
        this.extractLwjglSlot(mcDir, slot);
      } catch (error) {
        AppLogger.error('LWJGL', 'Runtime slot deployment failed; selected-slot preflight will block: ' + slot,
          error, LOG_DOMAIN_LAUNCH);
      }
    }
    this.deployStubObjcBridge(mcDir);
    this.deployFontconfigRuntime();
    this.deployJdk8FontConfig();
  }

  /**
   * 部署 JDK 8 的 fontconfig.properties 到 <sandbox>/jdk/8/jre/lib/。
   *
   * 为什么需要：AMCL 自带的 OpenJDK 8 未携带 jre/lib/fontconfig.properties（也无 jre/lib/fonts/）。
   * 任何调用 AWT 字体子系统的 mod（如 RLCraft 的 Varied Commodities 在 TrueTypeFont.<clinit>
   * 里调 getAllFonts()）会触发 sun.awt.FontConfiguration.getVersion() 因内部表为空抛 NPE → mod
   * 初始化失败 → 整个游戏崩。补上符合 OpenJDK 规范的 fontconfig.properties（映射逻辑字体到
   * /system/fonts 的 HarmonyOS Sans）即可让字体子系统正常初始化。
   *
   * 仅针对 JDK 8（经典布局，走 sun.awt.FontConfiguration）；模块化 JDK 17/21/25 的字体机制不同、
   * 不受此问题影响，故不处理。jdk/8 不存在（用户未装 JDK8）时静默跳过。
   */
  private deployJdk8FontConfig(): void {
    let jreLibDir = this.context.filesDir + '/jdk/8/jre/lib'
    // 仅当 JDK8 已安装（jre/lib 存在）时才部署，避免无谓建目录。
    try {
      fs.statSync(jreLibDir)
    } catch (e) {
      return // JDK8 未安装
    }
    let dest = jreLibDir + '/fontconfig.properties'
    try {
      let data: Uint8Array = this.context.resourceManager.getRawFileContentSync('jdk8/fontconfig.properties')
      let f = fs.openSync(dest, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
      fs.writeSync(f.fd, data.buffer)
      fs.closeSync(f)
      AppLogger.info('FORGE', `Deployed JDK8 fontconfig.properties (${data.byteLength} bytes) to ${dest}`, LOG_DOMAIN_LAUNCH)
    } catch (e) {
      AppLogger.warn('FORGE', 'Failed to deploy JDK8 fontconfig.properties', e, LOG_DOMAIN_LAUNCH)
    }
  }

  /**
   * 部署 JVM 字体子系统所需的 fontconfig 运行时（fonts.conf + libfontconfig.so.1）。
   *
   * 历史：原 deployForgeBootstrapper 还顺带部署 forge-install-bootstrapper.jar；该 jar 自
   * Forge 安装迁到 ForgelikeInstaller（自实现 processors）后已废弃，故本方法只保留 fontconfig
   * 部署（Forge/NeoForge 安装器子进程 + 游戏 JVM 的字体子系统都依赖 libfontconfig.so.1）。
   *
   * 2026-08-27（加载链审查修复批次）：目标目录从硬编码 jdk/17/lib 扩为
   * SUPPORTED_JDK_VERSIONS 全部版本。此前注释声称覆盖"安装器子进程 + 游戏 JVM"，
   * 但 fork_run_java 按所选 JDK 预加载 <jdk>/lib/libfontconfig.so.1 —— MC ≥1.20.5
   * 纪元路由到 21/25 时该文件从未被部署过，dlopen 必败。与 17 一致地"预埋"目录：
   * JDK 后装时 unzip 落进同一 lib/，预埋文件不受影响。
   */
  private deployFontconfigRuntime(): void {
    // Fontconfig stub (JVM 字体子系统需要 libfontconfig.so.1)
    let fontsConf = this.context.filesDir + '/fonts.conf'
    try {
      let data: Uint8Array = this.context.resourceManager.getRawFileContentSync('fonts.conf')
      let f = fs.openSync(fontsConf, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
      fs.writeSync(f.fd, data.buffer)
      fs.closeSync(f)
    } catch (e) { /* */ }
    // 复制 libfontconfig.so 到各 JDK lib 目录（命名为 libfontconfig.so.1）。
    // fork_run_java / jvmInit 对所有版本统一读 <jdk>/<ver>/lib/（JDK8 也是），口径一致。
    let fcSrc: string | null = null
    let fcSrcResolved = false
    for (let ver of SUPPORTED_JDK_VERSIONS) {
      let jdkLibDir = this.context.filesDir + '/jdk/' + ver + '/lib'
      try { fs.mkdirSync(jdkLibDir, true) } catch (e) { /* exists */ }
      let fcDest = jdkLibDir + '/libfontconfig.so.1'
      try {
        fs.statSync(fcDest)
        continue // 已部署
      } catch (e) { /* absent -> deploy */ }
      if (!fcSrcResolved) {
        fcSrc = resolveFontconfigSource(this.context.filesDir)
        fcSrcResolved = true
        if (!fcSrc) {
          AppLogger.warn('FORGE', 'No valid fontconfig source found for deploy', null, LOG_DOMAIN_LAUNCH)
          return
        }
      }
      if (!fcSrc) { return }
      try {
        fs.copyFileSync(fcSrc, fcDest)
        let st = fs.statSync(fcDest)
        if (st.size <= FONTCONFIG_MIN_SIZE_BYTES) {
          AppLogger.warn('FORGE', `fontconfig copied but too small: ${st.size} bytes (jdk ${ver})`, null, LOG_DOMAIN_LAUNCH)
          continue
        }
        AppLogger.info('FORGE', `Deployed libfontconfig.so.1 to jdk/${ver}/lib from ${fcSrc}`, LOG_DOMAIN_LAUNCH)
      } catch (e2) {
        AppLogger.warn('FORGE', `Failed to deploy fontconfig for jdk ${ver}`, e2, LOG_DOMAIN_LAUNCH)
      }
    }
  }
}
