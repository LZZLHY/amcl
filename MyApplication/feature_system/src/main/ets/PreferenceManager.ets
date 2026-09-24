/**
 * PreferenceManager.ets — 统一偏好设置管理
 *
 * 封装 HarmonyOS preferences API，提供类型安全的读写接口。
 * 所有设置项集中管理，避免 get/put key 字符串分散在各处。
 */

import { ProcessPreferences, LaunchPreferenceStore } from 'commons';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemeMode } from 'commons';
import { SUPPORTED_JDK_VERSION, SUPPORTED_JDK_VERSIONS, JDK_AUTO } from 'commons';
import { DEFAULT_GAME_LANGUAGE, normalizeGlobalGameLanguage } from 'commons';
import { formatError } from 'commons';

const TAG = 'PreferenceManager'
const PREF_NAME = 'amcl_settings'
const OHOS_FRAME_RATE_CAP_MIN: number = 30
const OHOS_FRAME_RATE_CAP_MAX: number = 240

export class PreferenceManager {
  get desktopNativeGamepad(): boolean { return this.getBool('desktopNativeGamepad', false); }
  set desktopNativeGamepad(value: boolean) { this.put('desktopNativeGamepad', value); }

  private pref: LaunchPreferenceStore;

  constructor(context: Context) {
    this.pref = ProcessPreferences.open(context, PREF_NAME);
  }

  // ===== 基础读写 =====

  getString(key: string, def: string): string {
    try { return this.pref.getSync(key, def) as string; }
    catch (e) { return def; }
  }

  getNumber(key: string, def: number): number {
    try { return this.pref.getSync(key, def) as number; }
    catch (e) { return def; }
  }

  getBool(key: string, def: boolean): boolean {
    try { return this.pref.getSync(key, def) as boolean; }
    catch (e) { return def; }
  }

  put(key: string, value: string | number | boolean): void {
    try {
      this.pref.putSync(key, value);
      this.pref.flush();
    } catch (e) {
      hilog.warn(0x0000, TAG, 'Failed to save %{public}s: %{public}s', key, formatError(e));
    }
  }

  /** 批量写入后统一 flush（性能优化） */
  putBatch(entries: Record<string, string | number | boolean>): void {
    try {
      let keys = Object.keys(entries);
      for (let key of keys) {
        this.pref.putSync(key, entries[key]);
      }
      this.pref.flush();
    } catch (e) {
      hilog.warn(0x0000, TAG, 'Failed to save batch: %{public}s', formatError(e));
    }
  }

  // ===== 业务属性 =====

  get desktopInteraction(): string { return this.getString('desktopInteraction', 'auto'); }
  set desktopInteraction(v: string) { this.put('desktopInteraction', v); }

  /**
   * 平板独立游戏进程的持久选择；不复用历史 useNewWindow（窗口样式并不等于进程边界）。
   * 缺省开启，只有真实布尔值参与决策；损坏或不可读取的值安全关闭，不以字符串真值猜测。
   * 本属性只是下次启动器进程的选择，实际会话路线由 RuntimeProductProfile 首次初始化锁存。
   */
  get tabletIndependentGameProcess(): boolean {
    try {
      const value = this.pref.getSync('tabletIndependentGameProcess', true);
      return typeof value === 'boolean' ? value : false;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'Cannot read tablet process preference: %{public}s', formatError(e));
      return false;
    }
  }

  /**
   * 此开关保存后通常会紧接着重启，不能使用普通 put 的异步即忘语义。
   * 仅启动器可写，等待 flush 成功才让 UI 显示已保存；失败恢复本进程缓存并尝试落盘回滚，
   * 原错误继续交给 UI。回滚也失败时不冒充磁盘一致，用户仍会看到保存失败并可重试。
   */
  async saveTabletIndependentGameProcess(value: boolean): Promise<void> {
    if (ProcessPreferences.isGameProcess()) throw new Error('请在启动器设置中修改独立游戏进程');
    const previous: boolean = this.tabletIndependentGameProcess;
    try {
      await this.pref.put('tabletIndependentGameProcess', value);
      await this.pref.flush();
    } catch (e) {
      try {
        this.pref.putSync('tabletIndependentGameProcess', previous);
        await this.pref.flush();
      } catch (rollbackError) {
        hilog.warn(0x0000, TAG, 'Tablet process preference rollback failed: %{public}s', formatError(rollbackError));
      }
      throw e as Error;
    }
  }

  get themeMode(): ThemeMode { return this.getNumber('themeMode', ThemeMode.SYSTEM) as ThemeMode; }
  set themeMode(v: ThemeMode) { this.put('themeMode', v); }

  get mcVersion(): string { return this.getString('mcVersion', '1.20.4'); }
  set mcVersion(v: string) { this.put('mcVersion', v); }

  get useNewWindow(): boolean { return this.getBool('useNewWindow', false); }
  set useNewWindow(v: boolean) { this.put('useNewWindow', v); }

  /**
   * 是否已同意隐私政策（开屏隐私弹窗用）。默认 false → 首次启动弹政策同意框。
   * 上架（平板）合规要求：用户须先同意隐私政策方可使用。同意后落盘，后续不再弹。
   */
  get privacyAgreed(): boolean { return this.getBool('privacyAgreed', false); }
  set privacyAgreed(v: boolean) { this.put('privacyAgreed', v); }

  get versionIsolation(): boolean { return this.getBool('versionIsolation', true); }
  set versionIsolation(v: boolean) { this.put('versionIsolation', v); }

  get mcXmx(): number { return this.getNumber('mcXmx', 0); }
  set mcXmx(v: number) { this.put('mcXmx', v); }

  /**
   * 虚拟内存（堆文件）模式。默认 false。
   *
   * 开启后启动时向 JVM 注入 marker `-Damcl.heapfile=1`，C 层据此用
   * `-XX:AllocateHeapAt=<沙箱目录>`（JEP 316）把 Java 堆分配到存储文件上，
   * 使堆内存「文件背书、可被系统回收」，避免低内存设备跑重型整合包时
   * 世界生成峰值被系统 lowmemkiller 强杀（SIGKILL）。
   *
   * 代价：堆落在 UFS 存储上，GC/世界生成会明显变慢、增加存储写入。
   * 仅建议在「可用内存不足以支撑整合包」时开启。
   */
  get virtualMemoryMode(): boolean { return this.getBool('virtualMemoryMode', false); }
  set virtualMemoryMode(v: boolean) { this.put('virtualMemoryMode', v); }

  /**
   * GL 渲染器偏好。默认 `'mobileglues'`。
   *
   * 可选值由 `launch` 的渲染后端注册表（`RENDERER_BACKENDS` 里 `userSelectable=true` 的那些）
   * 决定，**刻意不在本文件里枚举** —— 那会变成第二份可漂移的清单。
   * 契约见 `docs/guides/renderer-backend-governance.md` §2/§4。
   *
   * 📌 历史：这里曾列出 `'zink'`（Mesa Zink / OSMesa GL4.6 on Vulkan）。
   * 它已于 2026-08-27 完全退役（施工记录 §S6），偏好里的旧值由解析器落默认。
   */
  // ⚠️⚠️ **本 getter 刻意不做归一化。** 归一化归解析器
  // （`resolveRendererBackend` 对未知 / 不可选的 id 一律落默认，见施工记录 §S2.2 ③）。
  //
  // 为什么不在这里做：本类是**偏好存储**，它不知道也不该知道"哪些后端当前可选" ——
  // 那需要 import `launch`，而 `feature_system` 在依赖图里比 `launch` 更底层。
  // 在这里塞一份"合法值列表"就是治理规范 §1 缺陷 1 那个形状（同一事实两处各说一套）。
  //
  // ⇒ **已退役后端的偏好会原样读出来**（例如 2026-08-27 退役的 `'zink'`：
  // 老用户的持久化偏好里仍然存着它）。解析器把它当"不可选"落默认，**不抛错、不清空存储**。
  // 刻意不清空：清空不可逆，而保留能让"这个用户曾选过 zink"在诊断日志里可见
  // （解析器会打 `preference 'zink' is not user-selectable (lifecycle=retired) -> default`）。
  get glRenderer(): string { return this.getString('glRenderer', 'mobileglues'); }
  set glRenderer(v: string) { this.put('glRenderer', v); }

  /** Canonical peer graphics profile preference. The legacy glRenderer key is
   * retained as the on-disk compatibility format; selection and availability
   * are owned by launch's profile registry. */
  get graphicsProfile(): string { return this.glRenderer; }
  set graphicsProfile(v: string) {
    this.glRenderer = v;
    // Distinguish an explicit launcher choice from the historical default
    // value. A user choice can intentionally override Minecraft's in-game API
    // preference; old installs without this marker keep game preference flow.
    this.put('graphicsProfileExplicit', true);
  }
  get graphicsProfileExplicit(): boolean { return this.getBool('graphicsProfileExplicit', false); }

  /**
   * 开发验证产品的渲染后端覆盖（candidate/experimental 验证通道）。空串 = 无覆盖。
   * 旧 DevTools 验证入口继续读取此键；设置页平级选择使用 graphicsProfile，
   * 选择任一 profile 时清除旧覆盖，避免两份偏好竞争。
   * （McGamePage → LaunchProfileBuilder.setDevRendererOverride → 解析器）。
   * 与 `glRenderer` 同一条"不在存储层归一化"的纪律：坏值/退役值由解析器判定并
   * 打可 grep 的日志（`dev override '<id>' is not a candidate/experimental backend`），
   * 不在这里静默清洗。
   */
  get devRendererOverride(): string { return this.getString('devRendererOverride', ''); }
  set devRendererOverride(v: string) { this.put('devRendererOverride', v); }

  /**
   * HarmonyOS 给游戏 XComponent 的调度帧率上限。0 = 自动跟随当前显示刷新率；
   * 30..240 = 用户明确设置的硬上限。它不读写 Minecraft options.txt，也不冒充
   * 游戏自身的 FPS limiter。非法/旧脏值在读取和写入时都归一化为 Auto。
   */
  get ohosFrameRateCap(): number {
    return this.normalizeOhosFrameRateCap(this.getNumber('ohosFrameRateCap', 0));
  }
  set ohosFrameRateCap(v: number) {
    this.put('ohosFrameRateCap', this.normalizeOhosFrameRateCap(v));
  }

  private normalizeOhosFrameRateCap(v: number): number {
    if (v === 0) return 0;
    if (v < OHOS_FRAME_RATE_CAP_MIN || v > OHOS_FRAME_RATE_CAP_MAX || Math.floor(v) !== v) {
      return 0;
    }
    return v;
  }

  /**
   * 游戏数据(.minecraft)存储位置：'sandbox'(默认) | 'external'。
   * external = 公共 Download/com.amcl.launcher/.minecraft（文件管理器显示为 AMCL），卸载应用后数据仍保留
   * （需 Phase 0 探针确认设备支持）。
   * 切换是带权限申请 + 可选迁移的独立动作，故不进 loadAll/saveAll 批量快照，避免被批量覆盖。
   */
  get mcStorageLocation(): string { return this.getString('mcStorageLocation', 'sandbox'); }
  set mcStorageLocation(v: string) { this.put('mcStorageLocation', v); }

  /**
   * 手机端「外部存储」学到的公共应用目录（…/Download/com.amcl.launcher）。'' = 尚未学到。
   *
   * 手机上 Environment.getUserDownloadDir() 报 801，无法凭空构造 Download 路径；首次启用外部
   * 时用 DocumentViewPicker DOWNLOAD 模式（无弹窗）「学」一次该路径并落盘，之后冷启动直接读回
   * 按原始路径用（所有权式访问，无需 picker/persist/activate）。平板不用此字段（走 Environment）。
   * 详见 docs/adaptation/手机端沙箱外存储适配方案.md。
   * 与 mcStorageLocation 一样不进 loadAll/saveAll 批量快照，避免被覆盖。
   */
  get phoneExternalDir(): string { return this.getString('phoneExternalDir', ''); }
  set phoneExternalDir(v: string) { this.put('phoneExternalDir', v); }

  /**
   * 用户自定义 JVM 参数（全局，空格分隔；支持引号包裹含空格的值）。
   *
   * 语义对齐 FoldCraftLauncher / HMCL 的 javaArguments：**用户参数优先级最高**——
   * LaunchProfileBuilder.mergeUserJvmArgs 会让同 `-Dkey` / `-Xmx` 等的用户值覆盖
   * version.json 与 SSOT 默认参数（见该方法注释）。
   *
   * 典型用途：临时调试（-Dsodium.checks.issue2561=true 恢复 Sodium 检查）、
   * 加 -XX 调参、覆盖 file.encoding 等。空串 = 不加任何额外参数。
   *
   * 与 mcStorageLocation 一样在专门的设置页编辑，不进 loadAll/saveAll 批量快照，
   * 避免被批量覆盖。
   */
  get customJvmArgs(): string { return this.getString('customJvmArgs', ''); }
  set customJvmArgs(v: string) { this.put('customJvmArgs', v); }

  /**
   * 全局游戏语言（Minecraft `options.txt` 的 `lang` 键）。默认简体中文 `zh_cn`。
   *
   * 语义（对齐 PCL2 的 options.txt lang 写入 + AMCL 字段级继承模型）：
   *   - 这是"启动器权威"的全局默认语言：每个版本若未单独指定语言，则跟随此值。
   *   - 启动时由 resolveLaunch 注入 `-Damcl.gamelang=<code>` marker，C 层
   *     applyGameLanguage 据此写进该版本 gameDir/options.txt 的 `lang`。
   * 非法 / 未知值读盘时归一化回默认（避免脏数据写坏 options.txt）。
   */
  get gameLanguage(): string { return normalizeGlobalGameLanguage(this.getString('gameLanguage', DEFAULT_GAME_LANGUAGE)); }
  set gameLanguage(v: string) { this.put('gameLanguage', v); }

  // ===== 单版本启动配置覆盖（字段级继承模型：每个字段独立"留空=沿用全局"） =====
  //
  // 设计变更（2026-06：UI 重构）：
  //   旧模型是 HMCL 式 useGlobal 整体开关（要么全沿用全局、要么全覆盖），
  //   导致"只想给某版本加一条自定义 JVM 参数"时会连带丢掉全局内存设置。
  //   新模型改为【字段级继承】——override 里每个字段都用"空值"表示沿用全局：
  //     - xmx <= 0        → 沿用全局 mcXmx
  //     - jdkVersion ''   → 不指定（调用方按纪元自动路由）
  //     - customJvmArgs   → 与全局 customJvmArgs 拼接（全局在前、单版本在后，
  //                          单版本优先级更高，最终由 LaunchProfileBuilder.mergeUserJvmArgs 去重）
  //   当前 UI 只暴露"单版本自定义 JVM 参数"（版本详情 sheet 内联编辑），
  //   xmx / jdkVersion 字段保留供未来扩展，模型本身已支持。

  private defaultVersionOverride(): VersionLaunchOverride {
    return { xmx: 0, jdkVersion: '', customJvmArgs: '', gameLanguage: '' };
  }

  /**
   * 读取某版本的启动配置覆盖。无记录 / 解析失败 → 全字段默认（即全沿用全局）。
   * key = `verLaunch.<versionId>`，值为 JSON 编码的 VersionLaunchOverride。
   */
  getVersionOverride(versionId: string): VersionLaunchOverride {
    if (!versionId || versionId.length === 0) return this.defaultVersionOverride();
    let raw = this.getString('verLaunch.' + versionId, '');
    if (raw.length === 0) return this.defaultVersionOverride();
    try {
      let o = JSON.parse(raw) as Record<string, Object>;
      return {
        xmx: typeof o['xmx'] === 'number' ? (o['xmx'] as number) : 0,
        jdkVersion: typeof o['jdkVersion'] === 'string' ? (o['jdkVersion'] as string) : '',
        customJvmArgs: typeof o['customJvmArgs'] === 'string' ? (o['customJvmArgs'] as string) : '',
        gameLanguage: typeof o['gameLanguage'] === 'string' ? (o['gameLanguage'] as string) : '',
      };
    } catch (e) {
      hilog.warn(0x0000, TAG, 'getVersionOverride parse failed: %{public}s', formatError(e));
      return this.defaultVersionOverride();
    }
  }

  /**
   * 写入某版本的启动配置覆盖。全字段都为空（=全沿用全局）时删除 key，
   * 避免存储里堆空记录。
   */
  setVersionOverride(versionId: string, o: VersionLaunchOverride): void {
    if (!versionId || versionId.length === 0) return;
    let key = 'verLaunch.' + versionId;
    if (o.xmx <= 0 && o.jdkVersion.length === 0 && o.customJvmArgs.length === 0
        && o.gameLanguage.length === 0) {
      try { this.pref.deleteSync(key); this.pref.flush(); } catch (e) { /* 不存在也无妨 */ }
      return;
    }
    this.put(key, JSON.stringify(o));
  }

  /**
   * 解析某版本【实际生效】的启动配置——统一控制点，逐字段在"单版本覆盖"与"全局"间继承：
   *   - xmx           : 单版本 > 0 时用单版本，否则用全局 mcXmx
   *   - jdkVersion    : 单版本非空时用单版本（调用方校验已安装），否则 '' = 按纪元自动路由
   *   - customJvmArgs : 全局参数 + 单版本参数 拼接（单版本在后，优先级更高）
   * fromGlobal = 该版本无任何覆盖（纯沿用全局）。
   */
  resolveLaunch(versionId: string): EffectiveLaunchConfig {
    let o = this.getVersionOverride(versionId);
    let merged: string[] = [];
    let g = this.customJvmArgs.trim();
    if (g.length > 0) merged.push(g);
    let v = o.customJvmArgs.trim();
    if (v.length > 0) merged.push(v);
    // 虚拟内存（堆文件）模式：注入 marker，由 C 层 launchWithProfileImpl 识别并
    // 转成 -XX:AllocateHeapAt。放在末尾即可（marker 无覆盖语义、不参与去重）。
    if (this.virtualMemoryMode) merged.push('-Damcl.heapfile=1');
    // 游戏语言（启动器权威）：单版本非空则用单版本，否则跟随全局；作为 marker 注入，
    // 由 C 层 applyGameLanguage 写进该版本 options.txt 的 lang。lang 恒非空（全局默认
    // zh_cn），故每次启动都会按选择校正语言。marker 本身不下传 JVM（native 消费）。
    let lang = o.gameLanguage.length > 0 ? o.gameLanguage : this.gameLanguage;
    if (lang.length > 0) merged.push('-Damcl.gamelang=' + lang);
    return {
      xmx: o.xmx > 0 ? o.xmx : this.mcXmx,
      jdkVersion: o.jdkVersion,
      customJvmArgs: merged.join(' '),
      gameLanguage: lang,
      fromGlobal: o.xmx <= 0 && o.jdkVersion.length === 0 && o.customJvmArgs.length === 0
        && o.gameLanguage.length === 0,
    };
  }

  /**
   * JDK 版本（全局默认 Java 运行时选择）。
   *
   * 取值：'auto'（按 MC 版本纪元自动路由，**新默认**）或具体版本（SUPPORTED_JDK_VERSIONS 之一）。
   * 历史：旧默认是 '17'。已显式存过具体版本的用户保留其值（仍当作"偏好 hint"，
   *      由 LaunchCoordinator/resolveLaunchJdk 在兼容时采用、不兼容回退纪元路由——行为同旧版）；
   *      新用户拿到 'auto'。未知脏数据（如 '19'）才回退到 'auto'。
   *
   * 性能：getter 在 Index.onPageShow / updateJdkReadyState 等热路径里高频调用；
   * `migratedOnce_` 标志保证 disk write 每个 Preferences 实例最多一次。
   */
  private migratedJdkVersionOnce_: boolean = false;
  get jdkVersion(): string {
    let saved = this.getString('jdkVersion', JDK_AUTO);
    // 合法值 = 'auto' ∪ SUPPORTED_JDK_VERSIONS；其余（历史脏数据）迁移到 auto。
    if (saved !== JDK_AUTO && SUPPORTED_JDK_VERSIONS.indexOf(saved) < 0) {
      if (!this.migratedJdkVersionOnce_) {
        hilog.warn(0x0000, TAG,
          'Migrate unknown jdkVersion %{public}s -> %{public}s',
          saved, JDK_AUTO);
        this.put('jdkVersion', JDK_AUTO);
        this.migratedJdkVersionOnce_ = true;
      }
      return JDK_AUTO;
    }
    return saved;
  }
  set jdkVersion(v: string) { this.put('jdkVersion', v); }

  // ===== P1-MODS §6.4: 模组下载相关偏好 =====

  /** 模组源偏好：'auto' 走 SourceProber，'mcim' 强制镜像，'official' 强制官方 */
  get modSource(): string { return this.getString('modSource', 'auto'); }
  set modSource(v: string) { this.put('modSource', v); }

  /**
   * MC 版本下载源偏好（client.jar / libraries / assets / 版本清单）：
   *   - 'auto'     自动：按 RTT 探测选更快的源（默认）
   *   - 'mirror'   强制镜像优先（BMCLAPI）
   *   - 'official' 强制官方优先（Mojang / piston-data）
   *
   * 2026-08-04 新增。在此之前**根本不存在**这个偏好：设置页里的 auto/mcim/official
   * 只作用于模组（modSource → ModrinthSourceMode），版本下载的源顺序完全由
   * SourceProber 的 RTT 探测决定，用户怎么切都不可能生效。
   *
   * 语义与 PCL2 的 ToolDownloadSource 对齐：**只重排，不删源**。选了"官方"时官方排前面，
   * 但镜像仍在候选列表里兜底，官方挂了引擎会自动回退。
   *
   * 未知脏数据回退 'auto'。
   */
  get mcSource(): string {
    let v = this.getString('mcSource', 'auto');
    if (v !== 'auto' && v !== 'mirror' && v !== 'official') return 'auto';
    return v;
  }
  set mcSource(v: string) { this.put('mcSource', v); }

  /**
   * JDK 下载源偏好：
   *   - 'auto'   自动（Gitee 国内直连优先 → 失败回退 GitHub 镜像/直连，推荐）
   *   - 'github' GitHub 源站优先（适合开代理/VPN 的用户，直连 GitHub 常满速，比任何镜像都快）
   *   - 'gitee'  强制 Gitee 国内镜像（失败仍回退 GitHub 保证可用）
   *   - 'mirror' 强制 GitHub 代理镜像（不走 Gitee，交给下载引擎按 RTT 选最快镜像）
   * 未知脏数据回退到 'auto'。
   */
  get jdkSource(): string {
    let v = this.getString('jdkSource', 'auto');
    if (v !== 'auto' && v !== 'github' && v !== 'gitee' && v !== 'mirror') return 'auto';
    return v;
  }
  set jdkSource(v: string) { this.put('jdkSource', v); }

  /** 是否缓存远程元数据（项目详情 / 版本列表 TTL 缓存） */
  get cacheRemoteMeta(): boolean { return this.getBool('cacheRemoteMeta', true); }
  set cacheRemoteMeta(v: boolean) { this.put('cacheRemoteMeta', v); }

  /**
   * 加速下载（经 AMCL 加速网关）。
   *
   * 打开后：把**官方源** URL（Mojang / cdn.modrinth.com / GitHub / 官方 Maven）改写成
   * 经由加速网关。镜像源 URL 不改写也不移除。
   *
   * ⚠️ 2026-08-04 修正描述：原注释写「用户原有的镜像/源偏好一律不生效」，与实现不符。
   * native 侧 `relayCanAccelerate` 只对官方主机放行，候选 URL 列表既不重排也不删项；
   * 唯一真的会覆盖用户选择的地方是 JDK 源（getJdkDownloadSource），且已改为**只覆盖
   * 'auto'**，显式选择照办。原则统一为：**用户选了就用用户的**。
   *
   * 为什么这样设计：网关部署在美国，到各官方源实测 3~5MB/s 且不会被地域重定向甩到
   * 慢节点（真机对比：国内直连 cdn-alt.modrinth.com 3~5KB/s，经网关 1343KB/s）。
   * 此时再走国内镜像只会多一层转发、还可能命中镜像自身的缓存未命中回源，纯亏。
   *
   * 默认关闭：网关是可选增强，关掉就是完全原来的行为（不依赖我们的服务器）。
   */
  get accelDownload(): boolean { return this.getBool('accelDownload', false); }
  set accelDownload(v: boolean) { this.put('accelDownload', v); }

  /**
   * 加速网关的设备标识（首次生成后固定）。
   * 作用：让加速面板能按设备聚合流量/配额/封禁，出问题可溯源到具体一台设备。
   * 不含任何个人信息，就是一串随机 hex。
   */
  get relayDeviceId(): string { return this.getString('relayDeviceId', ''); }
  set relayDeviceId(v: string) { this.put('relayDeviceId', v); }

  /** 模组并发下载数（同时下载几个 mod 文件） */
  get modConcurrentDownloads(): number { return this.getNumber('modConcurrentDownloads', 3); }
  set modConcurrentDownloads(v: number) { this.put('modConcurrentDownloads', v); }

  // ===== 上次启动时间（用于首页 Quick Stats "上次游戏" 卡片） =====

  /**
   * 上次启动 MC 的 wall-clock 时间戳（ms），0 = 从未启动过。
   *
   * 与 SessionMarker 的差异：
   *   - SessionMarker 标记"上次会话**未正常关闭**"（用于冷启动 toast 提示）；
   *   - lastPlayedAt 是"最近一次成功执行 launch 流程"的时间，正常退出 / 进程被杀
   *     都不影响其值。HomeTab 只关心"最近一次玩"。
   *
   * 由 Index.launchMC 在拉起 MC 之前写入；HomeTab 通过 prop 读取。
   */
  get lastPlayedAt(): number { return this.getNumber('lastPlayedAt', 0); }
  set lastPlayedAt(v: number) { this.put('lastPlayedAt', v); }

  /** 上次启动的版本 id（与 lastPlayedAt 配对，未来 HomeTab 可显示"上次：1.20.4"） */
  get lastPlayedVersion(): string { return this.getString('lastPlayedVersion', ''); }
  set lastPlayedVersion(v: string) { this.put('lastPlayedVersion', v); }

  // ===== 检查更新（节流 + 红点持久化） =====

  /** 上次成功检查更新（自动或手动）的 wall-clock 时间戳（ms），0 = 从未。用于自动节流。 */
  get lastUpdateCheckAt(): number { return this.getNumber('lastUpdateCheckAt', 0); }
  set lastUpdateCheckAt(v: number) { this.put('lastUpdateCheckAt', v); }

  /**
   * 用户上次在更新弹窗点击「稍后再说」的 wall-clock 时间戳（ms），0 = 未延后。
   * 红点不受它影响；只在 24 小时内压制启动自动检查/弹窗。
   */
  get updatePromptDeferredAt(): number { return this.getNumber('updatePromptDeferredAt', 0); }
  set updatePromptDeferredAt(v: number) { this.put('updatePromptDeferredAt', v); }

  /**
   * 见过的线上最新 versionCode（来自 update.json）。冷启动时若 > 已装 versionCode →
   * 立即显示红点（无需联网）；用户真正升级后已装 versionCode 追上，红点自然消失。
   */
  get latestSeenVersionCode(): number { return this.getNumber('latestSeenVersionCode', 0); }
  set latestSeenVersionCode(v: number) { this.put('latestSeenVersionCode', v); }

  // ===== 已装资源 sheet 的行排序（按 versionId + kind 维度持久化） =====

  /**
   * 已装模组 / 资源包 / 光影 / 数据包 sheet 的行顺序。
   *
   * 设计：
   *   - key  = `resOrder.<versionId>.<kind>`，例如 `resOrder.fabric-loader-0.18.6-1.20.4.mod`
   *   - val  = JSON 编码的 `string[]`，每项是"逻辑文件名"
   *            （`.jar.disabled` 会被剥成 `.jar`，下面用 enableFilename 归一化），
   *            这样切换启用/禁用导致 filename 变化时仍能命中同一项，行不会跳。
   *   - 行为 = 真相源是磁盘文件目录；本数组只用作"已知项的顺序提示"。
   *            refresh 时：磁盘里有但数组里没有的项 → 按字母序追加到末尾；
   *                        数组里有但磁盘里没的 → 从持久化清掉；
   *                        两边都有 → 用数组里的相对顺序排。
   *
   * 为什么不直接 sort by filename？
   *   - 用户可能手动安装"我的整合包推荐顺序"或者按依赖顺序排版，简单字母序会破坏这个意图。
   *   - 用户切 toggle 时，原版 `enabled !== a.enabled ? -1 : 1` 排序键会让行跳到顶部 / 底部，
   *     体感像 sheet 重新洗牌了一次，非常糟糕。
   *
   * 失败语义：JSON 损坏 / 不存在 → 当作空数组（→ 全按字母序）。
   */
  getResOrder(versionId: string, kindKey: string): string[] {
    if (versionId.length === 0 || kindKey.length === 0) return [];
    let key = 'resOrder.' + versionId + '.' + kindKey;
    let raw = this.getString(key, '');
    if (raw.length === 0) return [];
    try {
      let arr = JSON.parse(raw) as Object;
      if (!Array.isArray(arr)) return [];
      let result: string[] = [];
      for (let item of arr as Object[]) {
        if (typeof item === 'string') result.push(item as string);
      }
      return result;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'getResOrder parse failed: %{public}s', formatError(e));
      return [];
    }
  }

  setResOrder(versionId: string, kindKey: string, names: string[]): void {
    if (versionId.length === 0 || kindKey.length === 0) return;
    let key = 'resOrder.' + versionId + '.' + kindKey;
    if (names.length === 0) {
      // 空列表 → 删 key（避免存储里堆一堆空 entry）
      try { this.pref.deleteSync(key); this.pref.flush(); }
      catch (e) { /* 不存在也无所谓 */ }
      return;
    }
    this.put(key, JSON.stringify(names));
  }

  // ===== 版本列表的用户自定义拖拽顺序 =====

  /**
   * 版本管理列表的行顺序（用户拖拽决定）。
   *   - key = `versionOrder`，val = JSON 编码的 `string[]`（版本目录名，自上而下）。
   *   - 真相源是磁盘 versions/ 目录；本数组只是"已知项的顺序提示"。
   *   - 合并规则（见 Index.applyVersionOrder）：磁盘有但数组没有的【新下载】版本按
   *     mtime 倒序排在最上面；数组里有且磁盘仍在的按数组顺序；数组里有但磁盘没的忽略。
   *   - 失败语义：JSON 损坏 / 不存在 → 空数组（→ 全按"最新下载在上"）。
   */
  get versionOrder(): string[] {
    let raw = this.getString('versionOrder', '');
    if (raw.length === 0) return [];
    try {
      let arr = JSON.parse(raw) as Object;
      if (!Array.isArray(arr)) return [];
      let result: string[] = [];
      for (let item of arr as Object[]) {
        if (typeof item === 'string') result.push(item as string);
      }
      return result;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'get versionOrder parse failed: %{public}s', formatError(e));
      return [];
    }
  }
  set versionOrder(names: string[]) {
    if (names.length === 0) {
      try { this.pref.deleteSync('versionOrder'); this.pref.flush(); } catch (e) { /* */ }
      return;
    }
    this.put('versionOrder', JSON.stringify(names));
  }

  /**
   * 一次性加载所有设置到目标对象（用于 ViewModel 初始化）
   */
  loadAll(): PreferenceSnapshot {
    return {
      themeMode: this.themeMode,
      mcVersion: this.mcVersion,
      useNewWindow: this.useNewWindow,
      versionIsolation: this.versionIsolation,
      mcXmx: this.mcXmx,
      jdkVersion: this.jdkVersion,
    };
  }

  /**
   * 一次性保存所有设置（用于 ViewModel 批量同步）
   */
  saveAll(snapshot: PreferenceSnapshot): void {
    this.putBatch({
      'themeMode': snapshot.themeMode,
      'mcVersion': snapshot.mcVersion,
      'useNewWindow': snapshot.useNewWindow,
      'versionIsolation': snapshot.versionIsolation,
      'mcXmx': snapshot.mcXmx,
      'jdkVersion': snapshot.jdkVersion,
    });
  }
}

export interface PreferenceSnapshot {
  themeMode: ThemeMode;
  mcVersion: string;
  useNewWindow: boolean;
  versionIsolation: boolean;
  mcXmx: number;
  jdkVersion: string;
}

/** 单版本启动配置覆盖（字段级继承模型）。每个字段的"空值"表示沿用全局：
 *  xmx<=0 → 全局内存；customJvmArgs '' → 仅用全局参数。
 *  jdkVersion 取值：'' = 跟随全局设置；'auto' = 该版本按纪元自动路由；
 *               具体版本（'8'/'17'/'21'/'25'）= 硬覆盖（即便与纪元不匹配也照用，供调试）。 */
export interface VersionLaunchOverride {
  xmx: number;          // MB，<=0 = 沿用全局
  jdkVersion: string;   // '' = 跟随全局 | 'auto' = 自动路由 | 具体版本 = 硬覆盖
  customJvmArgs: string;
  gameLanguage: string; // '' = 跟随全局设置 | 具体 code（'zh_cn'/'en_us'…）= 单版本硬覆盖
}

/** 某版本实际生效的启动配置（resolveLaunch 的返回）。 */
export interface EffectiveLaunchConfig {
  xmx: number;
  jdkVersion: string;   // '' = 调用方按纪元自动路由
  customJvmArgs: string;
  gameLanguage: string; // 实际生效的游戏语言 code（单版本覆盖 or 全局默认；恒非空）
  fromGlobal: boolean;
}
