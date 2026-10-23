/**
 * RuntimeDeployer.ets — LWJGL jar + stub-objc-bridge 部署逻辑
 *
 * 从 Index.ets 中提取的 extractLwjglJars() 和 deployStubObjcBridge() 逻辑。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { resolveFontconfigSource, FONTCONFIG_MIN_SIZE_BYTES, SUPPORTED_JDK_VERSIONS, isJdkSlotVersion } from 'commons';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_LAUNCH } from 'commons';
import { lwjglRuntimeSlot } from './LwjglRuntimeSlots';
import { LwjglViewJar } from './LwjglJdkViews';
import { LwjglSlotIntegrityResult, lwjglBytesSha256, verifyLwjglRuntimeSlotSync } from './LwjglSlotIntegrity';
import { stringToUtf8 } from 'commons';
import { VersionFileVerifier, VersionParser } from 'feature_core';
import { graphicsGameFacts } from './GraphicsGameFacts';
import { GAME_COMPAT_JAR, GAME_COMPAT_SIZE, GAME_COMPAT_SHA256 } from './GameCompatibilityArtifact';
import { gameCompatibilityPath } from './GameCompatibility';
import { lwjglGenerationDirectory, runtimeSlotNativeOps, collectUnusedLwjglGenerations } from './RuntimeSlotGenerations';
import { validateRuntimeTree } from './JdkTreeValidation';

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
   * 部署现代槽的指定 JDK 派生视图。首页预备 17；真实启动须明确调用所选视图入口。
   * 单槽失败会抛出；deployAll 在明确记录后继续部署其他独立槽，所选槽仍须过预检。
   */
  extractLwjglJars(mcDir: string, javaFeature: number = 17): void {
    this.extractLwjglSlot(mcDir, 'lwjgl-ohos', javaFeature);
  }

  /**
   * 预检与真实游戏入口共同使用的部署边界。先复核 JDK 包内 release/架构/布局与
   * 所选 feature 相符，再部署对应的不可变内容；不以安装目录名称代替真实运行时身份。
   * 上层先确定槽，旧槽保持独立字节；任何失败都回传，不创建 JVM 或静默换 JDK。
   */
  deployLwjglSlotForLaunch(mcDir: string, slotName: string, javaFeature: number): void {
    lwjglRuntimeSlot(slotName, javaFeature);
    const runtimeError: string = validateRuntimeTree(this.context.filesDir + '/jdk/' + javaFeature.toString(),
      javaFeature.toString());
    if (runtimeError.length > 0) throw new Error('所选 JDK 身份校验失败：' + runtimeError);
    this.extractLwjglSlot(mcDir, slotName, javaFeature);
  }

  /**
   * 独立游戏进程在构建 profile 前准备同一运行视图，覆盖自动化或直接导航未经过
   * 启动前 Sheet 的入口。只消费有效合并清单，失败不按实例显示名猜测现代槽。
   */
  deployLwjglForVersion(mcDir: string, version: string, javaFeature: number): void {
    const parsed = VersionParser.parse(mcDir + '/versions/' + version + '/' + version + '.json');
    if (parsed === null || parsed.inheritsFrom.length > 0) throw new Error('无法从完整版本清单选择 LWJGL 视图');
    const facts = graphicsGameFacts(parsed.libraries, version);
    const slotName: string = facts.lwjglVersion === 2 ? 'lwjgl-ohos-2'
      : (facts.needsLwjgl322Slot ? 'lwjgl-ohos-322' : 'lwjgl-ohos');
    this.deployLwjglSlotForLaunch(mcDir, slotName, javaFeature);
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
  private extractLwjglSlot(mcDir: string, slotName: string, javaFeature: number = 0): void {
    const slot = lwjglRuntimeSlot(slotName, javaFeature);
    const directory: string = lwjglGenerationDirectory(mcDir, slotName, javaFeature);
    const reusable = verifyLwjglRuntimeSlotSync(directory, true, javaFeature);
    if (reusable.ok) {
      runtimeSlotNativeOps().publish('', directory);
      // 前一次升级时旧游戏可能仍持租约；即使本代直接复用，也要给已退出的旧代一次回收机会。
      try { collectUnusedLwjglGenerations(mcDir, slotName, javaFeature); }
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
        const bytes: Uint8Array = this.context.resourceManager.getRawFileContentSync(jar.resourcePath);
        if (bytes.byteLength !== jar.size || lwjglBytesSha256(bytes) !== jar.sha256) {
          throw new Error('包内 LWJGL 内容身份不匹配：' + slot.id + '/' + jar.name);
        }
        this.writeFileAtomic(stage + '/' + jar.name, bytes);
      }
      const verified = verifyLwjglRuntimeSlotSync(stage, false, javaFeature);
      if (!verified.ok) throw new Error(verified.detail);
      this.writeFileAtomic(stage + '/.installed', stringToUtf8(slot.marker));
      const staged = verifyLwjglRuntimeSlotSync(stage, true, javaFeature);
      if (!staged.ok) throw new Error(staged.detail);
      runtimeSlotNativeOps().publish(stage, directory);
      // marker 写入/关闭/重命名异常不能被静默当作可用槽；提交后再验证一次完整身份。
      const committed = verifyLwjglRuntimeSlotSync(directory, true, javaFeature);
      if (!committed.ok) throw new Error(committed.detail);
      AppLogger.info('LWJGL', committed.detail, LOG_DOMAIN_LAUNCH);
      // 回收失败或旧游戏占用均不损坏刚发布的代；下次部署再尝试。
      try { collectUnusedLwjglGenerations(mcDir, slotName, javaFeature); }
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
        // 首页尚未解析具体游戏，仅预备常用的 17 视图；其他 feature 在所选槽预检前
        // 按需部署。GC 沿用原协议，不为首页批量发布所有视图而反复切换活动指针。
        this.extractLwjglSlot(mcDir, slot, slot === 'lwjgl-ohos' ? 17 : 0);
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
   * 开屏专用的分阶段准备入口，不替代游戏预检使用的同步 deployAll / 所选槽准入。
   * 三个槽顺序部署，沿用同一内容清单、唯一 staging、marker、原子发布与 native GC；
   * 单槽错误仍明确记录后继续，不能把未选槽失败转成改换运行路线。
   *
   * yieldFrame 由页面提供与当前窗口绑定的绘制让步；HAR 不获取或持有 UIContext。
   * 未提供时使用 16 ms 定时让出事件循环，这只提供渲染机会，不保证真实呈现了一帧。
   * 资源读取、分块文件读写、fsync 和摘要使用 SDK 异步接口；native 的 stage/publish/
   * discard/collect 保持同步原子边界，stub/fontconfig/JDK8 小阶段暂沿用已有实现。
   * 调用方必须把本 Promise 纳入启动就绪条件，不能发起后立即开放游戏操作。
   * @throws {Error} 页面让步失败或非槽阶段出现未被原实现处理的异常时向宿主传播。
   */
  async deployAllForStartup(mcDir: string,
    yieldFrame: () => Promise<void> = (): Promise<void> => new Promise<void>(
      (resolve: () => void): void => { setTimeout(resolve, 16); })): Promise<void> {
    const slots: string[] = ['lwjgl-ohos', 'lwjgl-ohos-322', 'lwjgl-ohos-2'];
    for (const slot of slots) {
      await yieldFrame();
      try {
        await this.extractLwjglSlotForStartup_(mcDir, slot, slot === 'lwjgl-ohos' ? 17 : 0);
      } catch (error) {
        AppLogger.error('LWJGL', 'Runtime slot deployment failed; selected-slot preflight will block: ' + slot,
          error, LOG_DOMAIN_LAUNCH);
      }
    }
    await yieldFrame();
    this.deployStubObjcBridge(mcDir);
    await yieldFrame();
    this.deployFontconfigRuntime();
    await yieldFrame();
    this.deployJdk8FontConfig();
  }

  /**
   * 启动异步槽部署，与 extractLwjglSlot 的提交协议逐项一致。
   * 所有 await 都位于本调用独占的 staging 或只读核验中；native publish 的锁定、
   * 代目录重命名及活动指针更新不拆开、不跨 await，也不把 Context 或 native 端口送入线程池。
   * finally 仍交给原 native 端口清理唯一 staging，失败不留下“已提交”的 marker 假象。
   * @throws {Error} 槽身份、文件 I/O、摘要或 native 发布失败时由逐槽入口记录。
   */
  private async extractLwjglSlotForStartup_(mcDir: string, slotName: string, javaFeature: number): Promise<void> {
    const slot = lwjglRuntimeSlot(slotName, javaFeature);
    const directory: string = lwjglGenerationDirectory(mcDir, slotName, javaFeature);
    const reusable: LwjglSlotIntegrityResult = await this.verifyStartupSlot_(directory, true, javaFeature);
    if (reusable.ok) {
      runtimeSlotNativeOps().publish('', directory);
      this.collectStartupSlot_(mcDir, slotName, javaFeature);
      AppLogger.info('LWJGL', 'Reusing verified runtime slot: ' + slot.id, LOG_DOMAIN_LAUNCH);
      return;
    }
    AppLogger.info('LWJGL', 'Installing LWJGL ' + slot.version + ' slot ' + slot.id, LOG_DOMAIN_LAUNCH);
    const managed: string = mcDir + '/.amcl-runtime';
    try { await fs.mkdir(managed, true); }
    catch (error) { if (!(await fs.stat(managed)).isDirectory()) throw error as Error; }
    const stage: string = runtimeSlotNativeOps().createStage(directory);
    try {
      for (const jar of slot.jars) {
        const bytes: Uint8Array = await this.context.resourceManager.getRawFileContent(jar.resourcePath);
        if (bytes.byteLength !== jar.size || await this.startupBytesSha256_(bytes) !== jar.sha256) {
          throw new Error('包内 LWJGL 内容身份不匹配：' + slot.id + '/' + jar.name);
        }
        await this.writeStartupFileAtomic_(stage + '/' + jar.name, bytes);
      }
      const verified: LwjglSlotIntegrityResult = await this.verifyStartupSlot_(stage, false, javaFeature);
      if (!verified.ok) throw new Error(verified.detail);
      await this.writeStartupFileAtomic_(stage + '/.installed', stringToUtf8(slot.marker));
      const staged: LwjglSlotIntegrityResult = await this.verifyStartupSlot_(stage, true, javaFeature);
      if (!staged.ok) throw new Error(staged.detail);
      runtimeSlotNativeOps().publish(stage, directory);
      const committed: LwjglSlotIntegrityResult = await this.verifyStartupSlot_(directory, true, javaFeature);
      if (!committed.ok) throw new Error(committed.detail);
      AppLogger.info('LWJGL', committed.detail, LOG_DOMAIN_LAUNCH);
      this.collectStartupSlot_(mcDir, slotName, javaFeature);
    } catch (error) {
      throw new Error('LWJGL ' + slot.id + ' 部署失败：' + (error as Error).message);
    } finally {
      try { runtimeSlotNativeOps().discardStage(stage); }
      catch (cleanupError) { AppLogger.warn('LWJGL', 'Staging cleanup deferred', cleanupError, LOG_DOMAIN_LAUNCH); }
    }
  }

  /** native 有界 GC 仍核验当前指针、stage owner 与读租约；失败不撤销已发布代。 */
  private collectStartupSlot_(mcDir: string, slotName: string, javaFeature: number): void {
    try { collectUnusedLwjglGenerations(mcDir, slotName, javaFeature); }
    catch (cleanupError) { AppLogger.warn('LWJGL', 'Deferred old generation collection', cleanupError, LOG_DOMAIN_LAUNCH); }
  }

  /**
   * 启动读取同一份完整性协议：限长 marker → 精确 JAR 集合 → 普通文件/大小/SHA256 →
   * 再次核对 marker。只把 I/O 和摘要调成真实异步，不能只用 async 包装同步整槽校验。
   * 此处与 LwjglSlotIntegrity 的同步入口共用清单选择器，判据必须随该入口一致维护。
   */
  private async verifyStartupSlot_(directory: string, requireMarker: boolean,
    javaFeature: number): Promise<LwjglSlotIntegrityResult> {
    try {
      const slot = lwjglRuntimeSlot(directory, javaFeature);
      const markerPath: string = directory + '/.installed';
      if (requireMarker && await this.readStartupMarker_(markerPath) !== slot.marker) {
        throw new Error('部署标记缺失或内容身份不匹配，请完全退出并重新打开应用');
      }
      const actualNames: string[] = (await fs.listFile(directory))
        .filter((name: string): boolean => name.endsWith('.jar'));
      const expectedNames: string[] = slot.jars.map((jar: LwjglViewJar): string => jar.name);
      actualNames.sort();
      expectedNames.sort();
      if (actualNames.join('|') !== expectedNames.join('|')) {
        throw new Error('JAR 集合不匹配：期望 ' + expectedNames.join(', ') + '，实际 ' + actualNames.join(', '));
      }
      for (const jar of slot.jars) {
        const path: string = directory + '/' + jar.name;
        const stat: fs.Stat = await fs.stat(path);
        if (!stat.isFile() || stat.size !== jar.size) throw new Error(jar.name + ' 大小不匹配或不是普通文件');
        if (await this.startupFileSha256_(path) !== jar.sha256) {
          throw new Error(jar.name + ' SHA-256 不匹配，已阻止加载混合版本 LWJGL');
        }
      }
      if (requireMarker && await this.readStartupMarker_(markerPath) !== slot.marker) {
        throw new Error('校验期间部署标记发生变化');
      }
      return { ok: true, detail: 'LWJGL ' + slot.version + ' 槽 ' + slot.deploymentDirectory
        + ' 完整（' + slot.jars.length + ' 个 jar，SHA-256 已核验）' };
    } catch (error) {
      return { ok: false, detail: directory + '：' + (error as Error).message };
    }
  }

  /**
   * marker 只允许最多 4096 字节的普通文件，保持同步校验入口的边界。
   * @throws {Error} 非法 marker 或读取错误由完整性入口转换为明确的失败结果。
   */
  private async readStartupMarker_(path: string): Promise<string> {
    const stat: fs.Stat = await fs.stat(path);
    if (!stat.isFile() || stat.size > 4096) throw new Error('LWJGL 部署标记不是有效的小型文件');
    return fs.readText(path);
  }

  /** 摘要输出始终为小写十六进制，与锁定清单及同步校验比较方式一致。 */
  private startupDigestHex_(bytes: Uint8Array): string {
    let hex: string = '';
    for (const byte of bytes) hex += byte.toString(16).padStart(2, '0');
    return hex;
  }

  /**
   * 包内 rawfile 的有效 Uint8Array 视图分块进入异步摘要，不散列 backing buffer 的额外字节。
   * @throws {Error} 算法对象创建、更新或最终摘要失败时使本槽保持未提交。
   */
  private async startupBytesSha256_(bytes: Uint8Array): Promise<string> {
    const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    for (let offset: number = 0; offset < bytes.byteLength; offset += 256 * 1024) {
      await digest.update({ data: bytes.subarray(offset, Math.min(offset + 256 * 1024, bytes.byteLength)) });
    }
    return this.startupDigestHex_((await digest.digest()).data);
  }

  /**
   * 异步分块读取后再更新摘要；缓冲区只在 update 完成后复用，任何读错都向完整性边界传播。
   * @throws {Error} 打开、读取、摘要或关闭错误由完整性入口转换为明确的失败结果。
   */
  private async startupFileSha256_(path: string): Promise<string> {
    const opened: fs.File = await fs.open(path, fs.OpenMode.READ_ONLY);
    try {
      const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
      const buffer: ArrayBuffer = new ArrayBuffer(256 * 1024);
      while (true) {
        const count: number = await fs.read(opened.fd, buffer);
        if (count === 0) break;
        if (count < 0) throw new Error('LWJGL 文件读取失败：' + path);
        await digest.update({ data: new Uint8Array(buffer, 0, count) });
      }
      return this.startupDigestHex_((await digest.digest()).data);
    } finally { await fs.close(opened); }
  }

  /**
   * 仅写本调用独占的 staging：256 KiB 分块写入并处理短写，await fsync/close 后才 rename。
   * 最终代仍由 native 整目录发布；单文件失败或取消式异常保留未提交状态并清理临时文件。
   * @throws {Error} 打开、短写、同步落盘、关闭或改名失败时交给槽入口保留失败证据。
   */
  private async writeStartupFileAtomic_(dest: string, bytes: Uint8Array): Promise<void> {
    const temporary: string = dest + '.tmp.' + Date.now() + '-' + Math.floor(Math.random() * 1000000000);
    let opened: fs.File | undefined = undefined;
    try {
      opened = await fs.open(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      let offset: number = 0;
      while (offset < bytes.byteLength) {
        const chunk: Uint8Array = bytes.slice(offset, Math.min(offset + 256 * 1024, bytes.byteLength));
        const written: number = await fs.write(opened.fd, chunk.buffer as ArrayBuffer);
        if (written <= 0 || written > chunk.byteLength) throw new Error('LWJGL 文件短写：' + dest);
        offset += written;
      }
      await fs.fsync(opened.fd);
      await fs.close(opened);
      opened = undefined;
      try { await fs.rename(temporary, dest); }
      catch (renameError) {
        if (await fs.access(dest)) await fs.unlink(dest);
        await fs.rename(temporary, dest);
      }
    } finally {
      if (opened !== undefined) {
        try { await fs.close(opened); }
        catch (closeError) { AppLogger.warn('LWJGL', 'Failed to close staging file', closeError, LOG_DOMAIN_LAUNCH); }
      }
      try { if (await fs.access(temporary)) await fs.unlink(temporary); }
      catch (cleanupError) { AppLogger.warn('LWJGL', 'Failed to clean temporary file: ' + temporary, cleanupError, LOG_DOMAIN_LAUNCH); }
    }
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
    // 独立游戏进程有自己的模块内存，未必初始化主页面目录注册表。合并磁盘数字槽位，
    // 让新增主版本、离线安装和下架保留项同样获得字体配置，不依赖另一进程的数组状态。
    const runtimeVersions: string[] = SUPPORTED_JDK_VERSIONS.slice();
    try {
      for (const version of fs.listFileSync(this.context.filesDir + '/jdk')) {
        if (isJdkSlotVersion(version) && runtimeVersions.indexOf(version) < 0) runtimeVersions.push(version);
      }
    } catch (e) { /* 首次启动还没有安装目录，可信注册表项目仍可预部署。 */ }
    for (let ver of runtimeVersions) {
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
