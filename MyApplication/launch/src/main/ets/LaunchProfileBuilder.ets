import { DiagnosticPolicy } from 'commons'
/**
 * LaunchProfileBuilder.ets — 构建 MC 启动配置
 *
 * 从 VersionParser 的解析结果 + 用户设置，构建完整的 LaunchProfile。
 * LaunchProfile 通过 NAPI 传给 C 层执行，C 层不做任何解析和决策。
 *
 * 扩展点：
 *   - Forge/Fabric: 覆盖 mainClass, 追加 classpath 和 mcArgs
 *   - LWJGL 2: 不同的 jar 替换策略
 *   - 多账户: username/uuid/accessToken 从账户系统获取
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { VersionParser, ParsedVersion, ensureMinecraftLoggingConfig, minecraftLoggingArgument } from 'feature_core';
import { ProfileFieldSink } from 'account';
import { parseLibraryPathGav, compareMavenVersions, LibraryGav } from 'feature_core';
import { isMcVersionAtLeast } from 'commons';
import { resolveInstalledMcVersion, resolveInstalledLoader } from 'mods';
import { launchNative } from './LaunchNativeBridge';
import { normalizeManifestJnaTmpdir, jvmArgumentOverrideKey, retainLastJvmArgumentValues } from './RuntimeJvmArgumentPolicy';
import { applyGameCompatibility } from './GameCompatibility';
import { ActivityLogger } from 'commons';
import { updateSessionEnvironment, sessionEnvironmentFact } from 'commons';
import { prepareSessionLoggingArgument } from './SessionLoggingConfig';
import { LOG_DOMAIN_LAUNCH } from 'commons';
// Profile selection and metadata are owned by GraphicsProfileResolver / GraphicsProfileRegistry.
// This builder serializes their admitted plan without repeating route decisions.
import { RendererDecision, GraphicsHistoryHint } from './GraphicsSelectionTypes';
import { GraphicsGameApi, GRAPHICS_DEFAULT_PROFILE_ID } from './GraphicsProfileRegistry';
import { resolveGraphicsPlan, serializeGraphicsPlan, ResolvedGraphicsPlan, VulkanPolicy, CapabilityResult, GraphicsPlanInput } from './GraphicsBackendPlan';
import { DeviceGraphicsFacts } from './DeviceGraphicsFacts';
import { GraphicsGameFacts, graphicsGameFacts } from './GraphicsGameFacts';
import { GraphicsProfileInput } from './GraphicsProfileResolver';
import { minecraftGraphicsBackendForApi, withMinecraftGraphicsBackend } from './MinecraftGraphicsPreference';
import { lwjglSlotClasspath } from './RuntimeSlotClasspath';
import { lwjglGenerationDirectory } from './RuntimeSlotGenerations';
// 加载器世代路由（启动世代契约规范 §1.1 / 施工记录 §S02）：契约表在 LoaderGenerationRegistry，
// 判定在 LoaderGenerationResolver，校验在 LaunchContractPreflight。
// ⚠️ 改启动契约行为**只改契约表**，不要在本文件加 `if (某个世代)` 特例。
import { resolveLoaderGeneration, LoaderGenerationDecision } from './LoaderGenerationResolver';
import {
  reportLaunchContract, describeLaunchContractViolations,
  LaunchContractReport, LaunchContractVerdict, LaunchContractSeverity,
  CLASSPATH_DELIVERY_ARG_KEY, LOADER_GENERATION_ARG_KEY,
} from './LaunchContractPreflight';
// C0 探针（批次 C Phase 0）。默认关；判定与 marker 键都在那个文件里，本文件只接线。
import {
  resolveAgentProbe, AgentProbeDecision, AGENT_PROBE_JAR_NAME,
} from './LaunchAgentProbe';

const TAG = 'LaunchProfileBuilder';

// ============================================================
//  LaunchProfile — 启动一个 MC 实例所需的全部信息
// ============================================================

export interface LaunchProfile {
  version: string
  versionType: string
  filesDir: string
  gameDir: string
  assetsDir: string
  assetIndex: string
  jdkVersion: string
  xmxMb: number
  mainClass: string
  classpath: string
  mcArgs: string[]
  extraJvmArgs: string[]
  lwjglVersion: number
  lwjglJarDir: string
  username: string
  uuid: string
  accessToken: string
  userType: string
  /**
   * 判定出的加载器世代。契约见 `docs/refactor/启动世代契约规范.md`。
   *
   * ⭐ **它必须作为数据下传，不能让下游重算。** 此前 C 层用 mainClass 子串重算
   * `isForge`/`isFabric`，而那套判定对四个 Forge 家族世代同时为真 ——
   * "BSL 有 legacyClassPath 旁路、新 bootstrap 没有"因此无法表达（`1000576` 与
   * 2026-09-04 Forge 故障的共同成因）。
   */
  generation: string
  /**
   * `java.class.path` 的交付方式，由世代契约决定。**C 层照此执行，不再推断。**
   *
   * 取值见 `ClasspathDelivery`。`amcl-loader-only` 仅原版使用。
   */
  classpathDelivery: string
  graphicsPlanWire?: string
  graphicsPlan?: ResolvedGraphicsPlan
  /** 诊断事实来自已解析版本，实例显示名不能代替基础版本和加载器版本。 */
  baseGameVersion?: string
  loaderType?: string
  loaderVersion?: string
}

interface ClasspathBuildResult {
  classpath: string
  jars: string[]
  missingJars: string[]
}

interface JarDedupeResult {
  jars: string[]
  duplicates: number
}

// ============================================================
//  IPv6 偏好护栏（方案 docs/adaptation/JDK_IPV6_ADAPTATION_PLAN.md §四·五 R2）
// ============================================================
//
// 抽成**导出的纯函数**而不是留在 builder 私有方法里，理由是它必须能离线断言：
// 这条护栏的失效形态是"多数人的主机名连接变慢/偶发失败"，既不抛异常也不进日志告警，
// 只能靠断言钉住。真机那一侧（R5.3）要启动一次游戏才能看到最终参数，
// 而这里的判定可以在 `hvigorw test` 里每次构建都跑一遍。
// 断言在 entry/src/test/Ipv6PreferenceGuard.test.ets。

/** 护栏关心的键前缀。导出是为了让测试与调用方共用同一个字面量，不各写一份。 */
export const IPV6_PREFER_ADDRESSES_KEY: string = '-Djava.net.preferIPv6Addresses='

export interface Ipv6PreferenceGuardResult {
  /** 处理后的完整参数列表（同键项已剔除，护栏项追加在**末尾**）。 */
  args: string[]
  /** 被剔除的原有同键项，按原顺序。仅用于日志与断言。 */
  replaced: string[]
}

/**
 * 把 `java.net.preferIPv6Addresses` 钉成 `false`：剔除已有同键项，再把护栏项**追加到末尾**。
 *
 * 为什么要先剔除再追加、而不是直接追加：JVM 对重复 `-D` 取最后一个，光追加也能生效，
 * 但命令行里会同时出现 `=system` 与 `=false` 两条 —— R5.3 的验收是"从启动日志读出实际
 * 最终值"，留两条就得靠人推理"谁在后面"。剔除之后这条判据变成肉眼可判。
 *
 * ⚠️ 匹配用的是**带等号**的前缀。所以裸写的 `-Djava.net.preferIPv6Addresses`（无等号，
 * JVM 视为空值）不会被剔除 —— 这是刻意的：它与我们追加的那条不同键面，
 * 而我们的项在它之后，JVM 取最后一个，结论仍是 false。
 *
 * 调用点必须排在 mergeUserJvmArgs **之前**，这样用户在「自定义 JVM 参数」里显式写
 * `-Djava.net.preferIPv6Addresses=system` 仍然赢（那就是 R2 说的用户开关）。
 */
export function applyIpv6PreferenceGuard(jvmArgs: string[]): Ipv6PreferenceGuardResult {
  let kept: string[] = []
  let replaced: string[] = []
  for (let a of jvmArgs) {
    if (a.indexOf(IPV6_PREFER_ADDRESSES_KEY) === 0) {
      replaced.push(a)
    } else {
      kept.push(a)
    }
  }
  kept.push(IPV6_PREFER_ADDRESSES_KEY + 'false')
  let out: Ipv6PreferenceGuardResult = { args: kept, replaced: replaced }
  return out
}

// ============================================================
//  Builder
// ============================================================

export class LaunchProfileBuilder implements ProfileFieldSink {
  private filesDir: string = ''
  private mcDir: string = ''     // .minecraft 根目录（jar/libraries/assets 查找）
  private alog: ActivityLogger = new ActivityLogger(0);
  setActivityId(id: number): LaunchProfileBuilder { this.alog = new ActivityLogger(id); return this; }

  private gameDir: string = ''    // 运行时目录（版本隔离时为 versions/<ver>/）
  private version: string = ''
  private jdkVersion: string = '17'
  private xmxMb: number = 0
  private username: string = 'MCPlayer'
  private uuid: string = '00000000-0000-0000-0000-000000000000'
  private accessToken: string = '00000000000000000000000000000000'
  private userType: string = 'legacy'
  private lastBuildError: string = ''
  // 最近一次 build() 的契约校验留痕。null = 那一步**没有执行到**（在它之前就失败了），
  // 与"校验通过"是两个事实，调用方必须分开处理。
  private lastContractReport: LaunchContractReport | null = null
  private customJvmArgs: string = ''   // 用户自定义 JVM 参数（原始字符串，全局），优先级最高
  // Canonical peer graphics profile preference (legacy PreferenceManager.glRenderer
  // storage key). Resolver applies platform, manifest and capability gates.
  private glRendererPref: string = 'mobileglues'
  private nativeGlAvailable: boolean = false
  private vulkanPolicy: VulkanPolicy = VulkanPolicy.ALLOW
  private capabilityResult: CapabilityResult | undefined = undefined
  private capabilityResults: CapabilityResult[] = []
  private deviceGraphicsFacts: DeviceGraphicsFacts | undefined = undefined
  private availableGraphicsProfileIds: string[] | undefined = undefined
  private graphicsProfileExplicit: boolean | undefined = undefined
  private graphicsRecoveryProfile: string = ''
  // 历史只调整同作用域下的自动候选顺序，不代替能力证据。保存独立快照，避免页面
  // 在准备日志或等待启动期间改动原数组，导致本次输入与已经计算的制品身份不一致。
  private graphicsHistoryScope: string = ''
  private graphicsHistory: GraphicsHistoryHint[] = []
  /** 接收本次图形准备结果；复制历史记录的每个字段，空输入也清除上一次记录。 */
  setGraphicsEnvironment(value: GraphicsProfileInput): LaunchProfileBuilder {
    this.deviceGraphicsFacts = value.deviceFacts;
    this.capabilityResults = value.capabilityResults ?? [];
    this.availableGraphicsProfileIds = value.availableProfileIds;
    this.graphicsGameApi = value.gameApi ?? GraphicsGameApi.UNKNOWN;
    this.graphicsRequirementId = value.requirementId ?? '';
    // API 禁用策略与准入证据一起进入最终 resolver，不能在页面判断后被 builder 丢失。
    // 兼容未提供该字段的旧调用者及其独立 setVulkanPolicy 设置。
    if (value.vulkanPolicy !== undefined) this.vulkanPolicy = value.vulkanPolicy;
    this.graphicsProfileExplicit = value.graphicsProfileExplicit;
    this.graphicsRecoveryProfile = value.graphicsRecoveryProfile ?? '';
    this.graphicsHistoryScope = value.graphicsHistoryScope ?? '';
    this.graphicsHistory = (value.graphicsHistory ?? []).map((hint: GraphicsHistoryHint): GraphicsHistoryHint => {
      return { profile: hint.profile, scopeHash: hint.scopeHash, priority: hint.priority, reason: hint.reason };
    });
    return this;
  }
  private graphicsGameApi: GraphicsGameApi = GraphicsGameApi.UNKNOWN
  private graphicsRequirementId: string = ''
  setNativeGlAvailable(available: boolean): LaunchProfileBuilder { this.nativeGlAvailable = available; return this }
  // DevTools 专用的 candidate/experimental 后端覆盖（PreferenceManager.devRendererOverride）。
  // 空串 = 无覆盖。判定归解析器（只对 lifecycle∈{Candidate, Experimental} 放行）。
  private devRendererOverride: string = ''
  // 渲染面（XComponent surface / 屏幕）尺寸 px。>0 时作为 MC 初始分辨率（--width/--height）。
  // 用途：LWJGL2（≤1.12）的早期加载页（Mojang logo）用 MC 初始 displayWidth/Height 直接渲染，
  // 此时还没进主循环、没轮询过 wasResized，若初始值是默认 854×480 则加载页只占左下角。把初始
  // 分辨率设为真实 surface 尺寸，加载页一开始即全屏（高版本 LWJGL3 靠 GLFW framebuffer 回调，无此问题）。
  private windowWidth: number = 0
  private windowHeight: number = 0

  // 第三方皮肤站（authlib-injector）注入参数。仅当选中账户为 AUTHLIB_INJECTOR 时由
  // 启动流程（McGamePage）设置：需要在启动前联网 prefetch 元数据、提取 jar，故不能在
  // build() 里同步完成，由上游异步准备好后经 setter 注入。三者要么全空、要么全有。
  private authlibJarPath: string = ''      // 已提取到 filesDir 的 authlib-injector.jar 绝对路径
  private authlibApiRoot: string = ''      // API 根（-javaagent 参数值）
  private authlibPrefetched: string = ''   // base64(GET apiRoot 响应体)

  setFilesDir(dir: string): LaunchProfileBuilder { this.filesDir = dir; return this }
  setMcDir(dir: string): LaunchProfileBuilder { this.mcDir = dir; return this }
  setGameDir(dir: string): LaunchProfileBuilder { this.gameDir = dir; return this }
  setVersion(ver: string): LaunchProfileBuilder { this.version = ver; return this }
  setJdkVersion(ver: string): LaunchProfileBuilder { this.jdkVersion = ver; return this }
  setXmxMb(mb: number): LaunchProfileBuilder { this.xmxMb = mb; return this }
  setUsername(name: string): LaunchProfileBuilder { this.username = name; return this }
  setUuid(uuid: string): LaunchProfileBuilder { this.uuid = uuid; return this }
  setAccessToken(token: string): LaunchProfileBuilder { this.accessToken = token; return this }
  setUserType(type: string): LaunchProfileBuilder { this.userType = type; return this }
  /** 设置渲染面尺寸 px（MC 初始分辨率 --width/--height）。<=0 不注入。 */
  setWindowSize(w: number, h: number): LaunchProfileBuilder { this.windowWidth = w; this.windowHeight = h; return this }
  /** 设置用户自定义 JVM 参数（原始字符串）。空串 = 不加。优先级最高，见 mergeUserJvmArgs。 */
  setCustomJvmArgs(raw: string): LaunchProfileBuilder { this.customJvmArgs = raw || ''; return this }
  /** Legacy setter retained for callers while the resolver owns peer semantics. */
  setGlRenderer(v: string): LaunchProfileBuilder { this.glRendererPref = v || 'mobileglues'; return this }
  /** Canonical peer profile setter; keeps the old method as source compatibility. */
  setGraphicsProfile(v: string): LaunchProfileBuilder { this.glRendererPref = v || 'mobileglues'; return this }
  setVulkanPolicy(value: VulkanPolicy): LaunchProfileBuilder { this.vulkanPolicy = value; return this }
  setCapabilityResult(value: CapabilityResult): LaunchProfileBuilder { this.capabilityResult = value; return this }
  setCapabilityResults(values: CapabilityResult[]): LaunchProfileBuilder {
    this.capabilityResults = values.slice();
    return this;
  }
  setDeviceGraphicsFacts(value: DeviceGraphicsFacts): LaunchProfileBuilder {
    this.deviceGraphicsFacts = value;
    return this;
  }
  setAvailableGraphicsProfileIds(values: string[]): LaunchProfileBuilder {
    this.availableGraphicsProfileIds = values.slice();
    return this;
  }
  /** Game API evidence from the concrete version manifest/audit; UNKNOWN never enables Vulkan. */
  setGraphicsGameApi(value: GraphicsGameApi): LaunchProfileBuilder { this.graphicsGameApi = value; return this }
  setGraphicsRequirementId(value: string): LaunchProfileBuilder { this.graphicsRequirementId = value || ''; return this }
  /** 设置 DevTools 后端覆盖（candidate/experimental 验证通道）。空串 = 无覆盖。 */
  setDevRendererOverride(v: string): LaunchProfileBuilder { this.devRendererOverride = v || ''; return this }
  /**
   * 设置第三方皮肤站（authlib-injector）注入参数。三者需同时提供：
   *   - jarPath：已提取到本地的 authlib-injector.jar 绝对路径
   *   - apiRoot：皮肤站 API 根（ALI 解析后的最终地址）
   *   - prefetched：base64(GET apiRoot 响应体)，避免 agent 启动再联网
   * 任一为空则整体跳过注入（非 authlib 账户即为空）。
   */
  setAuthlibInjector(jarPath: string, apiRoot: string, prefetched: string): LaunchProfileBuilder {
    this.authlibJarPath = jarPath || ''
    this.authlibApiRoot = apiRoot || ''
    this.authlibPrefetched = prefetched || ''
    return this
  }
  getLastBuildError(): string { return this.lastBuildError }
  /** 异步准备阶段验证官方配置；build 保持同步，加载器/用户指定配置优先。 */
  async prepareLogging(): Promise<void> {
    const parsed = VersionParser.parse(this.mcDir + '/versions/' + this.version + '/' + this.version + '.json');
    if (parsed === null || this.hasLoggingOverride_(parsed)) return;
    await ensureMinecraftLoggingConfig(this.mcDir, parsed.loggingClient);
  }
  private hasLoggingOverride_(parsed: ParsedVersion): boolean {
    return parsed.jvmArgs.some((arg: string): boolean => new RegExp('^-Dlog4j(?:2)?\\.configurationFile=').test(arg))
      || new RegExp('(?:^|\\s)-Dlog4j(?:2)?\\.configurationFile=').test(this.customJvmArgs);
  }
  /**
   * 最近一次 `build()` 走到契约校验时的留痕；`null` = 没走到。
   *
   * ⚠️ **`null` 不等于"契约没问题"。** 文件校验先失败时 `build()` 在契约校验之前
   * 就返回了，此时这里是 null；而契约失败时它**非 null 且 `verdict.ok === false`** ——
   * 那种情况下文件其实全过了。`PreLaunchValidator.contractCheck` 靠这个区别把
   * "契约类失败"与"版本文件缺失"分开显示（后者的建议是删版本重下，用在前者身上是有害的）。
   */
  getLastContractReport(): LaunchContractReport | null { return this.lastContractReport }

  /**
   * 构建 LaunchProfile
   * 解析 version.json → 构建 classpath → 组装参数
   */
  build(): LaunchProfile | null {
    this.lastBuildError = ''
    this.lastContractReport = null
    if (!this.filesDir || !this.version) {
      this.alog.error(TAG, 'Missing required fields: filesDir/version', null, LOG_DOMAIN_LAUNCH)
      this.lastBuildError = '启动参数不完整（filesDir/version 缺失）'
      return null
    }
    // mcDir 缺失时按 gameDir 兜底（向后兼容，且 mcDir 本质是 .minecraft 根，
    //   一定能由 gameDir 反推；这条保留）
    if (!this.mcDir) this.mcDir = this.gameDir
    // ⚠️ gameDir 缺失不再静默退化为 mcDir。
    //   历史上这条曾掩盖 GameAbility.onCreate 漏写 'mcGameDir' 导致的版本隔离失效，
    //   存档落到 .minecraft/saves 而非 .minecraft/versions/<ver>/saves。
    //   现在改为硬失败，让上游 bug 在第一时间暴露。
    if (!this.gameDir) {
      this.alog.error(TAG, 'gameDir not set; refusing silent fallback to mcDir to avoid version-isolation regression', null, LOG_DOMAIN_LAUNCH)
      this.lastBuildError = '启动参数不完整（gameDir 未设置，疑似版本隔离配置错误）'
      return null
    }

    // 解析 version.json（合并后的 JSON 是完全自包含的，无需继承链解析）
    let jsonPath = this.mcDir + '/versions/' + this.version + '/' + this.version + '.json'
    let parsed = VersionParser.parse(jsonPath)
    if (!parsed) {
      this.alog.error(TAG, `Failed to parse version.json: ${jsonPath}`, null, LOG_DOMAIN_LAUNCH)
      this.lastBuildError = '解析版本配置失败：' + jsonPath
      return null
    }

    // 版本清单完整性硬门槛（2026-06-07）：AMCL 采用"安装时合并"——正确安装的版本是
    // **完全自包含**的（无 inheritsFrom）。若 version.json 仍带 inheritsFrom，说明它是
    // 【未合并的加载器清单】（只有加载器库、缺原版库 log4j/jopt 等），直接放行会让
    // ModLauncher 在启动时报 "Module ... not found" 闪退。这类必须先"修复"（重做合并），
    // 故在此即失败拦截，避免"完整性校验通过却闪退"。
    if (parsed.inheritsFrom && parsed.inheritsFrom.length > 0) {
      this.alog.error(TAG, `version.json not merged (inheritsFrom=${parsed.inheritsFrom}): ${jsonPath}`, null, LOG_DOMAIN_LAUNCH)
      this.lastBuildError = '版本清单不完整：未合并原版库（inheritsFrom=' + parsed.inheritsFrom + '）。\n'
        + '该版本的启动清单缺少原版依赖库，直接启动会闪退。请点"修复"重建完整版本。'
      return null
    }

    // 确定 LWJGL 版本（通过检查 libraries 是否包含 org.lwjgl 的 2.x 坐标）
    //
    // ⚠️ 2026-06-11 修复（1.12.2 误报"缺 jinput jar"根因）：
    //   LWJGL 2 的 maven 坐标是 org.lwjgl.lwjgl:lwjgl:2.9.x，落到磁盘是
    //     libraries/org/lwjgl/lwjgl/lwjgl/2.9.4-nightly-20150209/lwjgl-2.9.4-...jar
    //   （注意 groupId=org.lwjgl.lwjgl、artifactId=lwjgl → 路径里有【两层】lwjgl）。
    //   旧检测串 'org/lwjgl/lwjgl/2.' 少了一层 'lwjgl/'，对 1.12.2 永不命中 → LWJGL 2
    //   早失败分支被绕过 → 一路走到 classpath 校验，崩在"缺 jinput-platform natives jar"
    //   的误导信息上（用户报"完整性校验不通过，疑似检测 bug"——正是这里）。
    //   改为匹配 jar 文件名 'lwjgl-2.'（最稳，不依赖 group 路径层数）+ 兼容旧串。
    const gameFacts: GraphicsGameFacts = graphicsGameFacts(parsed.libraries,
      resolveInstalledMcVersion(this.mcDir, this.version))
    const lwjglVersion: number = gameFacts.lwjglVersion

    // ============================================================
    // LWJGL 2 (MC ≤ 1.12.2) —— 真·LWJGL2 单独适配（2026-06-13，§11）。
    // 不再硬失败：lwjglVersion===2 时走 lwjgl-ohos-2 套（真 LWJGL 2.9.4 + liblwjgl_v2.so，
    // 后端桥接 libglfw+gl4es）。路由在下方 lwjglJarDir 选择处处理。
    // ============================================================
    if (lwjglVersion === 2) {
      this.alog.info(TAG, `LWJGL 2 detected (MC ${this.version}) -> real LWJGL2 (lwjgl-ohos-2)`, LOG_DOMAIN_LAUNCH)
    }

    // Forge 判定采用多信号：versionId/mainClass/libraries/gameArgs
    let isForge = this.isForgeProfile(parsed)
    // 所有加载器统一从所选 OHOS 槽位白名单交付 LWJGL；buildClasspath 已过滤
    // libraries/org/lwjgl，所以不再按 Fabric 身份覆盖共享 Maven 缓存。旧 .orig
    // 没有可靠内容身份，不能在切换加载器时自动恢复，更不能覆盖用户后续修改。
    let lwjglJarDir = this.mcDir + '/lwjgl-ohos'
    // LWJGL 多版本路由（方案 C，2026-06-11）：MC 1.13–1.18.2 声明 LWJGL 3.0–3.2（调 mallocStack
    // 等 3.3.0 已删 API），用 322 套（lwjgl-ohos-322 + entry/libs 的 _v322 native）；1.19+ 声明
    // 3.3+，沿用 341 套（lwjgl-ohos）。判定依据 = MC version.json libraries 里声明的 lwjgl core 版本。
    const needs322: boolean = gameFacts.needsLwjgl322Slot

    // SDL3 时代判定（MC 26.3 Snapshot 4 起窗口/输入/平台集成从 GLFW 换成 SDL3）。
    //
    // 判据必须是【版本清单声明了 org.lwjgl:lwjgl-sdl】，不能是"classpath 里有没有
    // lwjgl-sdl.jar"——后者对 1.19+ 全部版本恒真（该 jar 无条件部署进 modern 槽位，
    // 而 buildClasspath 按该槽位白名单纳入）。2026-08-04 真机实证：26.2-neoforge 那次启动
    // 照样执行了 SDL 准备流程并真的加载了 libSDL3.so（白跑一遍 SDL 静态初始化）。
    //
    // 该 marker 以系统属性形式下传 JVM（与 -Damcl.gl.backend 同款），native 侧：
    //   · launchWithProfileImpl 扫 extraJvmArgs → 决定是否设 SDL_OPENGL/EGL_LIBRARY env
    //     （必须在 JVM 创建前，所以只能读参数向量、不能读系统属性）
    //   · phase_prepareSdl 经 getSystemProperty("amcl.sdl3") → 决定是否做 SDL 准备
    const usesSdl3: boolean = gameFacts.usesSdl3
    if (usesSdl3) {
      parsed.jvmArgs.push('-Damcl.sdl3=1')
      // AMCL 的 host-injected SDL 路线支持一个 presented XComponent window +
      // auxiliary pbuffer windows。默认只在确证为 SDL3 的 profile 上打开；现有
      // mergeUserJvmArgs 在末尾按 -D key 去重，因此用户显式传
      // -Damcl.sdl.auxiliaryWindows=off 会移除本项并作为最终值下传。
      parsed.jvmArgs.push('-Damcl.sdl.auxiliaryWindows=pbuffer')
      this.alog.info(TAG,
        `SDL3 route: version manifest declares org.lwjgl:lwjgl-sdl (MC ${this.version}) `
        + '-> SDL3 window/input path; auxiliary window default=pbuffer (custom JVM arg may override)',
        LOG_DOMAIN_LAUNCH)
    }
    if (needs322) {
      lwjglJarDir = this.mcDir + '/lwjgl-ohos-322'
      // core native 名经 JVM 参数重定向到 liblwjgl_v322.so（模块名 lwjgl_opengl/_stb/_tinyfd
      // 已在 322 jar 内字节码 patch 成 *_v322；glfw 经 org.lwjgl.glfw.libname=libglfw.so 共用）。
      parsed.jvmArgs.push('-Dorg.lwjgl.libname=lwjgl_v322')
      this.alog.info(TAG, `LWJGL route: 322 set (MC declares LWJGL 3.0-3.2) dir=${lwjglJarDir}`, LOG_DOMAIN_LAUNCH)
    }
    // LWJGL 2 路由（MC ≤1.12，2026-06-13 §11）：真·LWJGL 2.9.4 套（lwjgl-ohos-2），native =
    // liblwjgl_v2.so（经 Sys.JNI_LIBRARY_NAME=lwjgl_v2 → System.loadLibrary 走 java.library.path，
    // 无需 org.lwjgl.libname/librarypath）。后端桥接 libglfw+gl4es（渲染器由下方统一决策）。
    if (lwjglVersion === 2) {
      lwjglJarDir = this.mcDir + '/lwjgl-ohos-2'
      this.alog.info(TAG, `LWJGL route: v2 set (real LWJGL2, MC <=1.12) dir=${lwjglJarDir}`, LOG_DOMAIN_LAUNCH)
    }

    // 路由仍由版本/LWJGL 契约决定；确定槽后锁定本 HAP 清单对应的不可变内容目录。
    lwjglJarDir = lwjglGenerationDirectory(this.mcDir, lwjglJarDir)

    // ============================================================
    // 渲染后端路由（治理规范 §4.1；施工记录 §S3）
    // ============================================================
    // ⚠️ **本段之前是三个带顺序依赖的 if 块**（gl4es 嵌在 needs322 里、gl4es 在 LWJGL2 块里、
    // zink 块靠 `jvmArgs.indexOf('-Damcl.gl.backend=gl4es') >= 0` **反查前两块的产物**）。
    // 现在收敛成一次纯函数调用；优先级与每项排除原因由 GraphicsProfileResolver 表达。
    //
    // ⛔ **不要在这里加 `if (某个后端)` 特例。** 改选择行为只改 GraphicsProfileResolver 或注册表 ——
    // 这与 `platform/input_channel_policy.h` 的优先级表是同一条纪律
    // （「优先级表就是全部策略，改行为只应改那两张表，不要在调用点加特例」）。
    //
    // `resolveInstalledMcVersion` 带缓存（`InstalledLoaderResolver` 里按 `mcDir|versionId` 记忆），
    // 所以从"两处懒调用"改成"一处无条件调用"不引入额外的文件系统开销。
    const graphicsInput: GraphicsPlanInput = {
      realMcVersion: gameFacts.realMcVersion,
      lwjglVersion: lwjglVersion,
      needsLwjgl322Slot: needs322,
      userPreferredBackendId: this.glRendererPref,
      graphicsProfilePreference: this.glRendererPref,
      graphicsProfileExplicit: this.graphicsProfileExplicit,
      graphicsRecoveryProfile: this.graphicsRecoveryProfile,
      graphicsHistoryScope: this.graphicsHistoryScope,
      graphicsHistory: this.graphicsHistory,
      devOverrideBackendId: this.devRendererOverride,
      usesSdl3: usesSdl3,
      manifestProviderVerified: !gameFacts.providerConflict,
      nativeGlAvailable: this.nativeGlAvailable,
      capabilityResult: this.capabilityResult,
      capabilityResults: this.capabilityResults,
      deviceFacts: this.deviceGraphicsFacts,
      availableProfileIds: this.availableGraphicsProfileIds,
      gameApi: this.graphicsGameApi === GraphicsGameApi.UNKNOWN ? gameFacts.gameApi : this.graphicsGameApi,
      nativePreflightPending: this.deviceGraphicsFacts !== undefined,
      requirementId: this.graphicsRequirementId,
      vulkanPolicy: this.vulkanPolicy,
    }
    const graphicsPlan: ResolvedGraphicsPlan = resolveGraphicsPlan(graphicsInput)
    const rendererDecision: RendererDecision = graphicsPlan.decision
    const graphicsPlanWire: string = serializeGraphicsPlan(graphicsPlan)
    this.alog.info(TAG, rendererDecision.logLine, LOG_DOMAIN_LAUNCH)
    // Preserve the optional GL-only compatibility marker. Native Vulkan has no GL backend id.
    if (graphicsPlan.legacyGlBackendMarker.length > 0 && graphicsPlan.legacyGlBackendMarker !== GRAPHICS_DEFAULT_PROFILE_ID) {
      parsed.jvmArgs.push(`-Damcl.gl.backend=${graphicsPlan.legacyGlBackendMarker}`)
    }

    // MC 26.3+ 的 RenderPearl 使用两槽 submit fence。present pacing 机制保留（MG 第十一提交，
    // 经 -Damcl.mg.framePacingFps 表达），但**默认不注入**：2026-08-27 真机数据显示中位帧率
    // 低于 60（cap 很少真正起作用），而封顶会把"真实上限"从所有性能测量里抹掉——用户看到的
    // "帧数上不去"有一半是这个默认值造成的观测假象。要平滑度的用户自行加
    // -Damcl.mg.framePacingFps=60（或 30..240）。
    //
    // ⚠️ 判据从 `parsed.jvmArgs.indexOf('-Damcl.gl.backend=gl4es') < 0` 改成读**决策对象** ——
    // 这是本文件里**第四个**曾经反查 jvmArgs 产物的地方（施工记录 §S3.0 记了全部五个消费点）。
    // 反查产物的写法有两个问题：① 它要求本段必须排在注入之后，是隐式的顺序依赖；
    // ② 加第四个后端时要重新推演"哪些后端算 gl4es 那一类"。读决策没有这两个问题。
    if (usesSdl3 && rendererDecision.backendId !== 'gl4es') {
      this.alog.info(TAG, 'MobileGlues frame pacing: off by default (opt in with -Damcl.mg.framePacingFps=30..240)', LOG_DOMAIN_LAUNCH)

      // GC 选择（2026-08-27 真机归因，gc-amcl.log + MG 慢帧因果捕获对齐）：SSOT 默认
      // ParallelGC 在跨区块分配风暴下 young 停顿 56–127ms、Metaspace/CodeCache 阈值
      // Full GC 189–448ms，渲染线程整段冻结 —— 与"跨区块边界帧数跳变"逐一吻合
      // （jvm_common_args.cpp 的实测注释早已记录同一形状：中位 110.6ms、每 2.5s 一次）。
      // G1 增量回收 + 停顿目标把单次停顿压到几十毫秒内；Metaspace 起始 192m 消掉
      // 启动期的 Metadata 阈值 Full GC。
      //
      // ⚠️ 2026-08-30 更正这条注释的**因果表述**（行为未改，只改说法）。原文写的是
      // 「仅注入 26.3+/SDL3 路线：重型整合包走 GLFW 路线保持 ParallelGC（1000253 的
      // ATM8 G1 OOM 教训只对那类堆成立）」—— 它把「重型整合包保持 ParallelGC」当成了
      // 本门的**理由**，而这站不住：
      //   · 本门的判据是外层的 usesSdl3（清单里有 org/lwjgl/lwjgl-sdl），**与堆大小、
      //     整合包重量、模组数量全都无关**；
      //   · 全仓没有任何按堆大小/整合包重量路由收集器的代码 —— jvm_common_args.cpp
      //     §39-48 已就此更正过一次（「重型整合包按堆大小路由 G1GC 在代码里不存在」）。
      //     所以「重型整合包保持 ParallelGC」是本门判据的**副作用**，不是它实现的保护。
      //   · 后果是两头都不准：重型整合包若跑在 26.3+ 上照样会拿到 G1（本门拦不住它），
      //     而轻量的旧版本（如 1.18.2 原版）明明适合 G1 却拿不到。
      // ⇒ 1000253 的 ATM8 教训依然有效，但它约束的是「大堆重型整合包」，本门表达不了
      //   这个条件。要真正按「轻量 vs 重型」路由，得用注入点当场可得的信号（this.xmxMb、
      //   已解析的 MC 版本，或把 ModpackSnapshot.recommendedMaxMemMb 接进来），
      //   并且单独一批改动 + 自己的真机验证 —— 不要顺手挂在 usesSdl3 上。
      // 📌 已有的反向证据：2026-08-30 在 1.18.2 + Fabric 上采到 ParallelGC 的
      //   Pause Young 185 次 / 3109.5 ms、Full 4 次 / 905.7 ms（最长 461.5 ms），
      //   即这道门当前正把一个确实需要评估 G1 的场景挡在外面。
      //
      // 用户自选收集器时不注入 —— jvm_launcher 的 isGcSelector 取 extras 里第一个
      // 选择器替换 SSOT 默认，两个显式选择器并存会让 JVM 拒启。
      let userPicksGc = false
      for (let ua of this.parseUserJvmArgs(this.customJvmArgs)) {
        if (ua.indexOf('-XX:+Use') === 0 && ua.length > 10 && ua.lastIndexOf('GC') === ua.length - 2) {
          userPicksGc = true
          break
        }
      }
      if (!userPicksGc) {
        parsed.jvmArgs.push('-XX:+UseG1GC')
        parsed.jvmArgs.push('-XX:MaxGCPauseMillis=40')
        parsed.jvmArgs.push('-XX:MetaspaceSize=192m')
        this.alog.info(TAG, 'GC: G1 + 40ms pause target (chunk-boundary stutter fix; pick any -XX:+Use*GC to override)', LOG_DOMAIN_LAUNCH)
      }

      // awaitSubmit 等待归因（诊断期默认开）：把 RenderPearl 两槽提交等待按语义调用方
      // （global_submit / source_ring / gpu_fence_poll）与 owner 帧内容（uploader/retired/idle）
      // 聚合成每秒一行 [AMCL-GPU-WAIT]（TerrainWaitDiagnostics）。开销 = 每次等待两个
      // nanoTime + 每秒一行 stdout。跨区块归因闭环后撤这个默认。用户显式给值时不覆盖。
      let hasUserWaitDiag = false
      for (let arg of parsed.jvmArgs) {
        if (arg.indexOf('-Damcl.gpuWaitDiagnostics=') === 0) { hasUserWaitDiag = true; break }
      }
      if (!hasUserWaitDiag) {
        parsed.jvmArgs.push('-Damcl.gpuWaitDiagnostics=true')
        this.alog.info(TAG, 'GPU wait diagnostics: on (owner-correlated awaitSubmit attribution)', LOG_DOMAIN_LAUNCH)
      }

    }

    // ⚠️ 以下**刻意在 usesSdl3 门之外** —— 版本无关的观测面，而上面那个门是按
    // "26.3+/SDL3 路线"划的。放在门内曾让旧版本连诊断都采不到。
    // 门内保留的三项各有独立理由，**不要**跟着外提：
    //   · G1 三项 —— 1000253 的 ATM8 G1 OOM 教训只对重型整合包/GLFW 路线成立；
    //   · gpuWaitDiagnostics —— 它靠 RenderPearl 两个类的 exact-SHA256 字节码补丁挂钩
    //     （AmclClassLoader all-or-none），pre-1.20 客户端没有那些类，开了也恒为零数据。
    //
    // ⚠️ 这里原本外提了**两段**（渲染停顿采样 + GC 日志），现在只剩 GC 日志一段，
    // 采样器已于 2026-08-30 撤回默认关（理由见下）。外提时引用的那条论据 ——
    // 「1.18.2 有 93% 墙钟落在 GL 之外、单个非 GL 空洞达 4415ms，所以要问空洞里在干什么」
    // —— **其前提已被同日的审计推翻**：那个 93% 是在常驻观测（causal 窗口 + always-on
    // BufferAllocation + upload probe）与 10ms 栈采样同时开着的会话里测的，而
    // outside_gl_ns 按定义还含"causal 窗口之外的未观测 GL"。⇒ 它既不能证明时间在 GL 之外，
    // 也不能用来给"必须默认开采样器"背书。引用它之前先看 AGENTS §二.7。

    // 渲染线程停顿采样：hiperf tracepoint 对 shell 无权限（sched 采样 0 样本），改在 JVM
    // 内以 10ms 周期取渲染线程栈，同栈持续 ≥150ms 打印一条 [AMCL-RENDER-STALL] 全栈 ——
    // 空洞期间渲染线程停在哪，由栈自己开口。RenderStallSampler.install() 由 AmclLauncher
    // 无条件调用、只由本属性自门控，且归因帧回退到 stack[0]，因此不依赖任何 MC 版本。
    //
    // ⚠️ 2026-08-30：**撤掉默认注入**，改成只有用户显式传 `-Damcl.renderStallSampler=true`
    // 才开。上面那段"版本无关的观测面所以放在门外"的理由本身没错，错的是把它默认打开 ——
    // 它是 100 次/秒的渲染线程 stack walk，而它服务的那个问题（"空洞里在干什么"）恰恰是
    // 帧率问题。1000551 早就给观测者效应定过价（平板 exhaustive 逐调用计时 59.53 → 27.59 FPS）。
    //
    // ⭐ 同轮 A/B 结果（2026-08-30 16:50，同设备同存档同 options.txt，三样观测一起关）：
    // **假设被否证**。1.18.2 纯原版 active_world 的 present 率 —— 插桩几乎为零的那场
    // （08-29 22:22，observed_calls 峰值 2）p50 只有 **23.39**，三样全开那场（11:19，峰值
    // 81903）p50 **43.89**，全关这场（16:50，峰值 0）p50 **39.54**。观测量与帧率无负相关。
    // ⇒ 关掉它不是修复，**别把这次改动当成性能修复引用**。它仍然该默认关，理由只是
    // 「未经量化的常驻开销不该出货」，不是「关了会变快」。
    //
    // ⚠️ 重开的话要带自己的 A/B（固定镜头路线、样本远大于本轮的 46 个一秒窗）。本轮样本不足以
    // 支撑"关掉反而慢了几帧"这个具体差值，只够支撑"没有出现预期的大幅改善"。

    // 轻量 GC 日志（JDK9+ 统一日志），写进游戏目录 logs/，2 个文件 × 2MB 轮转，开销可忽略；
    // 用户已自带 -Xlog:gc（version.json 或自定义参数）时不重复注入。
    // 证据纪律（AGENTS §二 1）：先让停顿变成可以数的数，再决定怎么修。
    //
    // ⚠️ 2026-08-27 真机教训（JNI_CreateJavaVM 返回 -6，游戏完全起不来）：
    //   `file=` 必须是**绝对路径**且目录必须**此刻已存在** —— HotSpot 在
    //   JNI_CreateJavaVM 期间就打开该文件，而 chdir(gameDir) 在 Phase 4
    //   redirectIO 才发生，相对路径 `logs/` 解析到进程根 CWD → ENOENT →
    //   -Xlog 初始化失败对 JVM 创建是**致命**的（不是降级）。Phase 4 的
    //   mkdir(logs) 对它来说也太晚，必须在这里先建。建不了就跳过注入 ——
    //   诊断日志永远不能挡启动。
    let hasUserGcLog = false
    for (let arg of parsed.jvmArgs) {
      if (arg.indexOf('-Xlog:gc') === 0) { hasUserGcLog = true; break }
    }
    if (!hasUserGcLog) {
      for (let ua of this.parseUserJvmArgs(this.customJvmArgs)) {
        if (ua.indexOf('-Xlog:gc') === 0) { hasUserGcLog = true; break }
      }
    }
    if (!hasUserGcLog) {
      let gcLogDir = this.alog.id() > 0 ? this.filesDir + '/logs/ledger/' + this.alog.id() + '/jvm' : this.gameDir + '/logs'
      let gcLogDirReady = true
      try {
        fs.mkdirSync(gcLogDir, true)
      } catch (e) {
        try { fs.statSync(gcLogDir) } catch (e2) { gcLogDirReady = false }
      }
      if (gcLogDirReady) {
        parsed.jvmArgs.push('-Xlog:gc*:file=' + gcLogDir + '/gc-amcl.log:time,uptime:'
          + (this.alog.id() > 0 ? 'filecount=0' : 'filecount=2,filesize=2m'))
        this.alog.info(TAG, `GC diagnostics: -Xlog:gc* -> ${gcLogDir}/gc-amcl.log`, LOG_DOMAIN_LAUNCH)
      } else {
        this.alog.warn(TAG, `GC diagnostics skipped: cannot create ${gcLogDir}`, null, LOG_DOMAIN_LAUNCH)
      }
    }

    // 统一使用 OHOS LWJGL jar（参考 Amethyst-iOS：所有 org.lwjgl 库统一跳过替换）
    // 不再区分 Forge/非 Forge，避免原版 LWJGL jar 与 OHOS native .so 不匹配
    let useOhosLwjgl = true
    let cpResult = this.buildClasspath(parsed, lwjglJarDir, useOhosLwjgl)
    if (cpResult.missingJars.length > 0) {
      let forgeGeneratedMissing = this.filterForgeGeneratedArtifacts(cpResult.missingJars)
      if (isForge && forgeGeneratedMissing.length > 0) {
        this.lastBuildError = this.buildForgeMissingError(forgeGeneratedMissing)
      } else {
        this.lastBuildError = this.buildClasspathMissingError(cpResult.missingJars)
      }
      this.alog.error(TAG, `Launch precheck failed: ${this.lastBuildError}`, null, LOG_DOMAIN_LAUNCH)
      return null
    }
    // 全局 JAR 完整性校验：检查所有 classpath jar 的 ZIP 头，拦截 CDN 错误页伪装的 jar
    let corruptedJars = this.validateAllJarsZipHeader(cpResult.jars)
    if (corruptedJars.length > 0) {
      this.alog.error(TAG, `Corrupted JAR files detected: ${corruptedJars.length}`, null, LOG_DOMAIN_LAUNCH)
      for (let cj of corruptedJars.slice(0, 5)) {
        this.alog.error(TAG, `Corrupted: ${cj}`, null, LOG_DOMAIN_LAUNCH)
      }
      // 自动删除损坏文件，让用户重新下载
      for (let cj of corruptedJars) {
        try { fs.unlinkSync(cj); this.alog.info(TAG, `Deleted corrupted jar: ${cj}`, LOG_DOMAIN_LAUNCH) } catch (e) { /* */ }
      }
      this.lastBuildError = corruptedJars.length + ' 个库文件损坏（可能是下载时 CDN 返回了错误页面），已自动清理。\n请重新下载该版本。\n'
        + '损坏文件: ' + corruptedJars.slice(0, 3).map((p: string) => p.substring(p.lastIndexOf('/') + 1)).join(', ')
      return null
    }
    // Forge 增强校验：检查 processor 产物是否被截断/损坏（zlib SHA1 差异可能导致）
    if (isForge) {
      let corruptedArtifacts = this.validateForgeGeneratedArtifacts(cpResult.jars)
      if (corruptedArtifacts.length > 0) {
        this.lastBuildError = 'Forge 安装产物疑似损坏（文件过小），请重新安装 Forge。\n'
          + '损坏文件: ' + corruptedArtifacts.slice(0, 3).join('\n')
        this.alog.error(TAG, `Forge artifact corruption detected: ${corruptedArtifacts.length} files`, null, LOG_DOMAIN_LAUNCH)
        return null
      }
    }
    let classpath = cpResult.classpath

    // Forge: 禁用 EarlyDisplay 窗口（OHOS 上无法在 XComponent 之前创建 GLFW 窗口）
    if (isForge) {
      parsed.jvmArgs.push('-Dfml.earlyprogresswindow=false')
      parsed.jvmArgs.push('-Dforge.enableGameTest=false')
      // --add-exports=cpw.mods.bootstraplauncher 由 C 层 SSOT 统一添加（见 jvm/jvm_common_args.cpp）
      // 新版 Forge 通过 config/fml.toml 控制 EarlyDisplay
      this.disableForgeEarlyDisplay()
      // 旧版 Forge（FML legacy ≤1.12）：禁用 SplashProgress 独立线程（共享 GL 上下文在 OHOS 崩溃）
      this.disableLegacyForgeSplash()
    }

    // 过滤不适用于 OHOS 的 JVM 参数
    if (parsed.loggingClient !== undefined && !this.hasLoggingOverride_(parsed)) {
      try { parsed.jvmArgs.push(prepareSessionLoggingArgument(this.filesDir, this.alog.id(), minecraftLoggingArgument(this.mcDir, parsed.loggingClient))); }
      catch (e) { this.lastBuildError = (e as Error).message; return null; }
    } else if (this.alog.id() > 0) {
      updateSessionEnvironment(this.filesDir, this.alog.id(), [
        sessionEnvironmentFact('logging.configurationStatus', 'external', 'LaunchProfileBuilder'),
        sessionEnvironmentFact('logging.configurationReason', '加载器/用户配置拥有输出位置，未覆盖其配置；完整性按实际来源标记', 'LaunchProfileBuilder'),
      ]);
    }
    // 注：filterJvmArgs 在 NAPI getCommonJvmArgs 不可用时会抛错（不再退化为静默继续，
    // 见 filterJvmArgs 注释）。把它转回 lastBuildError + null 的返回风格，
    // 让上层 UI 走统一的失败路径。
    try {
      parsed.jvmArgs = this.filterJvmArgs(parsed.jvmArgs, classpath)
    } catch (e) {
      let msg = (e as Error)?.message ?? String(e)
      this.alog.error(TAG, `filterJvmArgs failed: ${msg}`, null, LOG_DOMAIN_LAUNCH)
      if (this.lastBuildError.length === 0) {
        this.lastBuildError = '解析 JVM 参数失败：' + msg
      }
      return null
    }

    // 注入 mcDir 内部属性（C 层读取用于 LaunchConfig.mcDir，避免与 gameDir 混淆）
    // 用于 Forge 版本隔离场景下 ForgeHelper 正确写入 .minecraft/config 与 instance/config
    if (this.mcDir && this.mcDir.length > 0) {
      parsed.jvmArgs.push('-Damcl.mc.dir=' + this.mcDir)
    }

    // 第三方皮肤站（authlib-injector）javaagent 注入。在 filterJvmArgs 之后追加，
    // 避免被 unresolved-variable / 内存参数过滤误伤（这三条是 AMCL 生成的绝对路径 + base64，
    // 不含 ${} 模板）。对齐 PCL2 ModLaunch 的 Auth 分支。
    this.injectAuthlibArgs(parsed.jvmArgs)

    // IPv6 偏好护栏（方案 docs/adaptation/JDK_IPV6_ADAPTATION_PLAN.md §四·五 R2）。
    // ⚠️ 必须与能力层（elf_loader 的 /proc/net/if_inet6 垫片）同批上，不能滞后。
    this.injectIpv6PreferenceGuard(parsed.jvmArgs)

    // 用户自定义 JVM 参数：最高优先级，最后合入（同 -Dkey / -Xmx 覆盖 version.json 与 SSOT 默认）
    parsed.jvmArgs = this.mergeUserJvmArgs(parsed.jvmArgs)
    for (let arg of parsed.jvmArgs) {
      if (arg.indexOf('-Damcl.graphics.plan=') === 0 || arg.indexOf('-Damcl.graphics.profile=') === 0
        || arg.indexOf('-Dorg.lwjgl.vulkan.libname=') === 0) {
        this.lastBuildError = '图形后端计划及运行库由启动器生成，不允许自定义 JVM 参数覆盖'
        this.alog.error(TAG, 'Rejected custom graphics plan/profile/Vulkan library override', null, LOG_DOMAIN_LAUNCH)
        return null
      }
    }
    // The selected plan is an AMCL launch invariant. Inject it after custom args
    // merge so an arbitrary JVM marker cannot silently replace the resolved route.
    parsed.jvmArgs.push('-Damcl.graphics.plan=' + graphicsPlanWire)

    // 构建 MC 启动参数。
    //
    // Minecraft 26.2+ has its own API selector.  The AMCL graphics plan is
    // deliberately kept separate from that selector: the plan chooses the
    // provider/loader/window contract, while this argument tells Minecraft
    // which RenderPearl backend it must instantiate.  Before this bridge was
    // added, a valid native Vulkan plan still entered PreferredGraphicsApi's
    // default OpenGL-first path and failed in GlBackend.loadLibrary() before
    // any Vulkan WSI call was made (the remote black-screen log showed exactly
    // that shape).
    let mcArgs = this.buildMcArgs(parsed)
    const realGraphicsVersion: string = graphicsInput.realMcVersion
    // API 已由 canonical profile 生成到计划；新增平级后端不需要在 builder 再枚举名称。
    // 真实基础版本与页面 options 偏好使用相同来源，可重命名的实例 ID 不参与 API 判定。
    const forcedMinecraftBackend: string = minecraftGraphicsBackendForApi(realGraphicsVersion, graphicsPlan.apiFamily)
    if (forcedMinecraftBackend.length > 0) {
      mcArgs = withMinecraftGraphicsBackend(mcArgs, forcedMinecraftBackend)
      this.alog.info(TAG,
        'Minecraft graphics API argument: --graphicsBackend ' + forcedMinecraftBackend
          + ' (profile=' + graphicsPlan.profile + ', version=' + realGraphicsVersion + ')',
        LOG_DOMAIN_LAUNCH)
    }

    // assets 目录
    let assetsDir = this.mcDir + '/assets'

    // ============================================================
    // 加载器世代判定 + 启动契约校验（规范 §1.1、§3.3）
    // ============================================================
    // ⚠️ **必须排在 mergeUserJvmArgs 之后** —— 契约校验要读**最终**的 jvmArgs
    // （BSL 的 -DlegacyClassPath 那条判据依赖它）。排在合并之前会让用户参数覆盖
    // 后的实际值逃过校验，那正是"判据看的不是生效值"这一族缺陷。
    const genDecision: LoaderGenerationDecision = resolveLoaderGeneration({
      mainClass: parsed.mainClass,
    })
    this.alog.info(TAG, genDecision.logLine, LOG_DOMAIN_LAUNCH)
    parsed.jvmArgs = applyGameCompatibility(parsed.jvmArgs,
      resolveInstalledMcVersion(this.mcDir, this.version), genDecision.generation, this.filesDir)

    // 留痕（不只是 verdict）：Phase 0 的检查列表要把这条结论单独显示成一项，
    // 而它**不允许**为此再 build 一次。见 LaunchContractReport 的注释。
    this.lastContractReport = reportLaunchContract({
      contract: genDecision.contract,
      effectiveDelivery: genDecision.contract.classpathDelivery,
      gameClasspathEntries: classpath.length > 0 ? classpath.split(':').length : 0,
      jvmArgs: parsed.jvmArgs,
      jdkMajor: this.jdkVersion,
    })
    const verdict: LaunchContractVerdict = this.lastContractReport.verdict
    this.alog.info(TAG, verdict.logLine, LOG_DOMAIN_LAUNCH)
    for (let k = 0; k < verdict.violations.length; k++) {
      if (verdict.violations[k].severity === LaunchContractSeverity.Warn) {
        this.alog.warn(TAG, `launch contract warn [${verdict.violations[k].code}]: `
          + verdict.violations[k].message, null, LOG_DOMAIN_LAUNCH)
      }
    }
    if (!verdict.ok) {
      // 阻断启动并给出指名道姓的原因。**这正是本次 Forge 故障缺的东西** ——
      // 当时用户看到的是几百毫秒后的 NoSuchElementException + 零信息量兜底诊断。
      this.lastBuildError = '启动契约校验失败（' + genDecision.contract.displayName + '）：\n'
        + describeLaunchContractViolations(verdict)
      this.alog.error(TAG, `Launch contract failed: ${verdict.logLine}`, null, LOG_DOMAIN_LAUNCH)
      return null
    }

    // delivery marker 下传。⚠️ **刻意排在 mergeUserJvmArgs 之后**，理由见
    // CLASSPATH_DELIVERY_ARG_KEY 的注释：用户的同 -Dkey 覆盖会把自己的启动弄坏。
    parsed.jvmArgs.push(CLASSPATH_DELIVERY_ARG_KEY + genDecision.contract.classpathDelivery)
    parsed.jvmArgs.push(LOADER_GENERATION_ARG_KEY + genDecision.generation)

    // 应用内 agent 探针只由 default 开发产品按需注入。
    if (DiagnosticPolicy.isDeveloperBuild()) {
      const probe: AgentProbeDecision = resolveAgentProbe(
        parsed.jvmArgs, this.filesDir + '/' + AGENT_PROBE_JAR_NAME, this.filesDir + '/logs')
      this.alog.debug(TAG, probe.logLine, LOG_DOMAIN_LAUNCH)
      for (let k = 0; k < probe.args.length; k++) parsed.jvmArgs.push(probe.args[k])
    }

    let profile: LaunchProfile = {
      version: this.version,
      versionType: parsed.type,
      filesDir: this.filesDir,
      gameDir: this.gameDir,
      assetsDir: assetsDir,
      assetIndex: parsed.assetIndex,
      jdkVersion: this.jdkVersion,
      xmxMb: this.xmxMb,
      mainClass: parsed.mainClass,
      classpath: classpath,
      mcArgs: mcArgs,
      extraJvmArgs: parsed.jvmArgs,
      lwjglVersion: lwjglVersion,
      lwjglJarDir: lwjglJarDir,
      username: this.username,
      uuid: this.uuid,
      accessToken: this.accessToken,
      userType: this.userType,
      generation: genDecision.generation,
      classpathDelivery: genDecision.contract.classpathDelivery,
      graphicsPlanWire: graphicsPlanWire,
      graphicsPlan: graphicsPlan,
      baseGameVersion: resolveInstalledMcVersion(this.mcDir, this.version),
      loaderType: resolveInstalledLoader(this.mcDir, this.version) || 'vanilla',
      loaderVersion: this.loaderVersion_(parsed.libraries),
    }

    this.alog.info(TAG, `LaunchProfile built: ver=${profile.version} main=${profile.mainClass} lwjgl=${profile.lwjglVersion} libs=${parsed.libraries.length} args=${mcArgs.length} cp=${classpath.length} chars gen=${profile.generation} delivery=${profile.classpathDelivery}`, LOG_DOMAIN_LAUNCH)

    return profile
  }

  /** 从实际库坐标读取加载器版本；仅补诊断字段，不参与既有世代/启动决策。 */
  private loaderVersion_(libraries: string[]): string {
    for (const library of libraries) {
      const gav = parseLibraryPathGav(library.indexOf('/libraries/') >= 0 ? library : this.mcDir + '/libraries/' + library);
      if (gav === null) continue;
      const key: string = gav.key.split(':').slice(0, 2).join(':');
      if (['net.fabricmc:fabric-loader', 'org.quiltmc:quilt-loader', 'net.neoforged:neoforge', 'net.minecraftforge:forge'].includes(key)) {
        const base: string = resolveInstalledMcVersion(this.mcDir, this.version) + '-';
        return key === 'net.minecraftforge:forge' && gav.version.startsWith(base) ? gav.version.substring(base.length) : gav.version;
      }
    }
    return 'unknown (library version not recorded)';
  }

  /**
   * 构建 classpath
   * - useOhosLwjgl=true: 过滤 org/lwjgl/*，改用 lwjgl-ohos
   * - useOhosLwjgl=false: 保留原版 org/lwjgl/*
   */
  private buildClasspath(parsed: ParsedVersion, lwjglJarDir: string, useOhosLwjgl: boolean): ClasspathBuildResult {
    let jars: string[] = []
    let libDir = this.mcDir + '/libraries'

    // MC 主 jar。
    //
    // ⚠️ 2026-06-06 修复（26.1-forge 运行时 FieldToMethodTransformer "fluid is not
    //   private" 闪退根因）：
    //   VersionJsonMerger 会把【原版 MC client jar】复制成 versions/<id>/<id>.jar
    //   （如 26.1-forge-62.0.9.jar）。但新版 Forge（≥1.13）的 patched MC 已完整收录在
    //   libraries 的 forge-<ver>-client.jar 里（binarypatcher --clean 产物=完整 patched
    //   客户端）。1.21+/26.1 起 Forge 运行时改用【官方映射】，原版与 patched 的
    //   net.minecraft.* 类【同名】：原版 LiquidBlock.fluid 是 protected，Forge patched 版
    //   被改成 private；若原版 jar 排在 classpath 前面抢先加载，Forge 的
    //   FieldToMethodTransformer 检测到本应 private 的 fluid 不是 private → 抛
    //   IllegalStateException → System.exit → 闪退。PC 官方启动器对新版 Forge 根本
    //   不把原版 MC jar 放进 classpath（MC 全部来自 forge-client.jar），AMCL 多放了。
    //   修法：当 libraries 里存在 Forge patched client jar 时，不再加入原版 MC jar，
    //   让 patched MC 成为唯一来源（与 PC 一致）。非 Forge（原版/Fabric）和无 patched
    //   client 的旧链路不受影响。
    let hasForgePatchedClient = false
    for (let libPath of parsed.libraries) {
      let p = libPath.replace(/\\/g, '/')
      // parsed.libraries 是相对路径（无前导斜杠），如
      //   net/minecraftforge/forge/26.1-62.0.9/forge-26.1-62.0.9-client.jar
      //   net/neoforged/neoforge/20.4.196/neoforge-20.4.196-client.jar
      // 故匹配串不能带前导 '/'（之前带了 '/net/...' 导致永不命中、skip 形同虚设）。
      // NeoForge 同理：patched client 是 classpath 唯一 MC 来源，原版 jar 抢加载会触发
      // FieldToMethodTransformer 类遮蔽闪退（与 Forge 1.21+ 同根问题）。
      if (((p.indexOf('net/minecraftforge/forge/') >= 0) || (p.indexOf('net/neoforged/neoforge/') >= 0))
          && p.indexOf('-client.jar') >= 0) {
        hasForgePatchedClient = true
        break
      }
    }
    let mcJar = this.mcDir + '/versions/' + this.version + '/' + this.version + '.jar'
    if (hasForgePatchedClient) {
      this.alog.info(TAG,
        `Skip vanilla MC jar (Forge patched client present, avoid class shadow): ${mcJar}`, LOG_DOMAIN_LAUNCH)
    } else {
      jars.push(mcJar)
    }

    // libraries
    let lwjglSkipped = 0
    let objcSkipped = 0
    for (let libPath of parsed.libraries) {
      // 过滤原版 LWJGL jar，用 lwjgl-ohos/ 替换
      if (useOhosLwjgl && libPath.indexOf('org/lwjgl/') >= 0) {
        lwjglSkipped++
        continue
      }
      // LWJGL 2 时代的 jinput 手柄输入库（net.java.jinput / net.java.jutils）：OHOS 上输入由
      // AMCL 后端（XComponent）提供，不用 jinput；其 jinput-platform 是 X11/Win/Mac natives jar，
      // 设备上不存在 → 会被 classpath 完整性校验误判缺失。vanilla MC 不依赖手柄，安全跳过。
      if (libPath.indexOf('net/java/jinput/') >= 0 || libPath.indexOf('net/java/jutils/') >= 0) {
        lwjglSkipped++
        continue
      }
      if (libPath.indexOf('java-objc-bridge') >= 0) {
        objcSkipped++
        continue
      }
      jars.push(libDir + '/' + libPath)
    }

    // 只交付所选槽位的精确名单，不让升级残留/诊断 JAR 重新定义同名类或模块。
    // 必需文件即使缺失也保留在列表中，由下方 findMissingJars 给出准确诊断；
    // 不能因为扫描目录只看见部分文件，就把不完整部署误判成完整 classpath。
    if (useOhosLwjgl && lwjglJarDir) {
      let lwjglJars = lwjglSlotClasspath(lwjglJarDir)
      for (let jar of lwjglJars) {
        jars.push(jar)
      }
    }

    // stub-objc-bridge.jar
    //
    // 仅 LWJGL3（macOS 路径引用 ca.weblite java-objc-bridge）需要这个兜底 stub。
    // LWJGL2（≤1.12）不依赖 java-objc-bridge → 不注入。
    // ⚠️ 2026-06-13 修复（1.8.9 等老 Forge 崩溃根因）：该 stub jar 的类是 Java 11/17 字节码
    //   （major 55/61）。老 Forge（FML legacy ≤1.12）的 mod 扫描器 JarDiscoverer 会用
    //   asm-all-5.0.3 解析 classpath 上每个 jar 的每个类找 @Mod；ASM 5.0.3 只支持到 Java 8
    //   （major≤52），遇到 stub 里 major 61 的 NativeUtils.class 抛 IllegalArgumentException
    //   → FML 包成 LoaderException 致命崩溃（真机实证 ASMModParser → ClassReader IAE）。
    //   1.13+ 用 modlauncher + 现代 ASM 不受影响，故只需对 LWJGL2 路径排除即可。
    let isLwjgl2Dir = lwjglJarDir.indexOf('lwjgl-ohos-2') >= 0
    if (!isLwjgl2Dir) {
      let stubJar = this.mcDir + '/stub-objc-bridge.jar'
      try {
        let stat = fs.statSync(stubJar)
        if (stat.size > 0) {
          jars.unshift(stubJar) // prepend
        }
      } catch (e) { /* not exists */ }
    } else {
      this.alog.info(TAG, 'LWJGL2: skip stub-objc-bridge.jar (FML asm-all-5.0.3 rejects its Java11/17 bytecode)', LOG_DOMAIN_LAUNCH)
    }

    // 双重保险：若仍有 libraries/org/lwjgl/* 漏进来，直接剔除
    if (useOhosLwjgl) {
      let cleaned: string[] = []
      for (let jar of jars) {
        if (this.isOfficialLwjglLibraryJar(jar)) {
          lwjglSkipped++
          continue
        }
        cleaned.push(jar)
      }
      jars = cleaned
    }

    // 去重（保序），避免父子版本重复库触发模块重复解析
    let dedupe = this.dedupeJarsPreserveOrder(jars)
    jars = dedupe.jars
    if (dedupe.duplicates > 0) {
      this.alog.warn(TAG, `Classpath dedupe removed ${dedupe.duplicates} duplicate jars`, null, LOG_DOMAIN_LAUNCH)
    }

    // 按 groupId:artifactId 去重并保留最高版本（兜底层）。
    //
    // 上面的 dedupeJarsPreserveOrder 只按完整路径去重，无法处理"同一库不同版本"
    // （asm/9.6/asm-9.6.jar 与 asm/9.9/asm-9.9.jar 路径不同）。当原版与加载器各自
    // 声明同一库的不同版本时，两者都会进 classpath，Fabric loader 的
    // LoaderUtil.verifyClasspath 检测到重复 ASM 类直接抛 IllegalStateException 拒绝启动。
    //
    // 治本在 VersionJsonMerger.uniqueLibraries（新装版本生成的 JSON 即干净），这里是
    // 兜底层：对**已经存在 dup 的旧版本**（合并 JSON 已写盘）在启动时即时修复，无需重装。
    // 标准做法对齐 HMCL MaintainTask.unique —— 保留最高版本。
    jars = this.dedupeLibrariesByGav(jars)

    this.alog.info(TAG, `Classpath: ${jars.length} jars (mode=${useOhosLwjgl ? 'ohos-lwjgl' : 'vanilla-lwjgl'}, skipped ${lwjglSkipped} lwjgl + ${objcSkipped} objc)`, LOG_DOMAIN_LAUNCH)

    let missingJars = this.findMissingJars(jars)
    if (missingJars.length > 0) {
      this.alog.error(TAG, `Classpath precheck: missing ${missingJars.length} jars`, null, LOG_DOMAIN_LAUNCH)
      let preview = missingJars.slice(0, 8)
      for (let p of preview) {
        this.alog.error(TAG, `Missing jar: ${p}`, null, LOG_DOMAIN_LAUNCH)
      }
      if (missingJars.length > preview.length) {
        this.alog.error(TAG, `... and ${missingJars.length - preview.length} more missing jars`, null, LOG_DOMAIN_LAUNCH)
      }
    }

    let result: ClasspathBuildResult = {
      classpath: jars.join(':'),
      jars: jars,
      missingJars: missingJars
    }
    return result
  }

  private isOfficialLwjglLibraryJar(path: string): boolean {
    let normalized = path.replace(/\\/g, '/')
    return normalized.indexOf('/libraries/org/lwjgl/') >= 0
  }

  private dedupeJarsPreserveOrder(jars: string[]): JarDedupeResult {
    let out: string[] = []
    let seen = new Set<string>()
    let duplicates = 0
    for (let jar of jars) {
      if (!jar) continue
      let key = jar.replace(/\\/g, '/')
      if (seen.has(key)) {
        duplicates++
        continue
      }
      seen.add(key)
      out.push(jar)
    }
    let result: JarDedupeResult = { jars: out, duplicates: duplicates }
    return result
  }

  /**
   * 按 groupId:artifactId(:classifier) 去重 classpath 中的 Maven 库 jar，保留最高版本。
   *
   * 移植自 HMCL MaintainTask.unique 的"保留高版本"策略，但作用于已组装的 jar 路径列表
   * （而非 version.json 的 library 条目），因此能修复**已写盘的旧合并 JSON**带来的
   * 重复库问题（无需重新合并/重装）。
   *
   * 仅对 .minecraft/libraries 下的标准 Maven 布局 jar 生效（parseLibraryPathGav 返回非 null）；
   * MC 主 jar / lwjgl-ohos / stub-objc-bridge 等非 Maven 布局路径原样保留。
   */
  private dedupeLibrariesByGav(jars: string[]): string[] {
    // 第一遍：找出每个 GA(:classifier) 的最高版本
    let bestVersion = new Map<string, string>()
    for (let jar of jars) {
      let gav: LibraryGav | null = parseLibraryPathGav(jar)
      if (!gav) continue
      let cur = bestVersion.get(gav.key)
      if (cur === undefined || compareMavenVersions(gav.version, cur) > 0) {
        bestVersion.set(gav.key, gav.version)
      }
    }
    // 第二遍：保序保留最高版本，丢弃低版本与同版本重复项
    let out: string[] = []
    let usedKey = new Set<string>()
    let dropped = 0
    for (let jar of jars) {
      let gav: LibraryGav | null = parseLibraryPathGav(jar)
      if (!gav) {
        out.push(jar)
        continue
      }
      let best = bestVersion.get(gav.key) as string
      if (compareMavenVersions(gav.version, best) < 0) {
        this.alog.warn(TAG, `GAV dedupe: drop ${jar.substring(jar.lastIndexOf('/') + 1)} (lower than kept ${gav.key}:${best})`, null, LOG_DOMAIN_LAUNCH)
        dropped++
        continue
      }
      if (usedKey.has(gav.key)) {
        // 同 GA 同最高版本的重复（不同路径）—— 只留第一个
        dropped++
        continue
      }
      usedKey.add(gav.key)
      out.push(jar)
    }
    if (dropped > 0) {
      this.alog.info(TAG, `GAV dedupe removed ${dropped} conflicting/duplicate library jars`, LOG_DOMAIN_LAUNCH)
    }
    return out
  }

  private findMissingJars(jars: string[]): string[] {
    let missing: string[] = []
    let seen = new Set<string>()
    for (let jar of jars) {
      if (!jar || seen.has(jar)) continue
      seen.add(jar)
      try {
        let st = fs.statSync(jar)
        if (st.size <= 0) {
          missing.push(jar)
        }
      } catch (e) {
        missing.push(jar)
      }
    }
    return missing
  }

  private filterForgeGeneratedArtifacts(paths: string[]): string[] {
    let result: string[] = []
    for (let p of paths) {
      if (!p) continue
      let isMcExtra = p.indexOf('/net/minecraft/client/') >= 0 && p.indexOf('-extra.jar') >= 0
      let isMcSrg = p.indexOf('/net/minecraft/client/') >= 0 && p.indexOf('-srg.jar') >= 0
      // Forge 与 NeoForge 的 patched client / universal 产物（generated，缺失走重装提示而非普通报错）
      let isLoaderDir = p.indexOf('/net/minecraftforge/forge/') >= 0 || p.indexOf('/net/neoforged/neoforge/') >= 0
      let isForgeClient = isLoaderDir && p.indexOf('-client.jar') >= 0
      let isForgeUniversal = isLoaderDir && p.indexOf('-universal.jar') >= 0
      if (isMcExtra || isMcSrg || isForgeClient || isForgeUniversal) {
        result.push(p)
      }
    }
    return result
  }

  /**
   * 全局 JAR 完整性校验：检查所有 classpath jar 的 ZIP 头部签名 (PK magic)。
   * 拦截 CDN 返回的错误页面伪装成 jar 的场景（HTTP 200 + HTML/XML body）。
   * 开销极小：每个 jar 只读 4 字节，88 个 jar ~1ms。
   */
  private validateAllJarsZipHeader(jars: string[]): string[] {
    let corrupted: string[] = []
    for (let jar of jars) {
      if (!jar) continue
      try {
        let st = fs.statSync(jar)
        if (st.size < 4) {
          corrupted.push(jar)
          continue
        }
        let file = fs.openSync(jar, fs.OpenMode.READ_ONLY)
        let buf = new ArrayBuffer(4)
        let bytesRead = fs.readSync(file.fd, buf, { offset: 0, length: 4 })
        fs.closeSync(file)
        if (bytesRead < 4) {
          corrupted.push(jar)
          continue
        }
        let h = new Uint8Array(buf)
        let isPK = h[0] === 0x50 && h[1] === 0x4B
          && ((h[2] === 0x03 && h[3] === 0x04)
            || (h[2] === 0x05 && h[3] === 0x06))
        if (!isPK) {
          this.alog.error(TAG, `JAR not valid ZIP (bad magic ${h[0]} ${h[1]} ${h[2]} ${h[3]}, size=${st.size}): ${jar.substring(jar.lastIndexOf('/') + 1)}`, null, LOG_DOMAIN_LAUNCH)
          corrupted.push(jar)
        }
      } catch (e) {
        // 文件不存在已被 findMissingJars 捕获
      }
    }
    return corrupted
  }

  /**
   * 对 Forge 关键 processor 产物做增强校验：
   * 1) 检查文件存在与最小合理大小（避免 zlib 损坏导致的截断文件）
   * 2) 校验 ZIP 文件头（jar 必须是合法 ZIP：以 "PK\x03\x04" 或 "PK\x05\x06" 开头）
   * 3) 校验 ZIP 尾部 End-of-Central-Directory 签名（避免截断/写入中断）
   */
  private validateForgeGeneratedArtifacts(jars: string[]): string[] {
    let suspicious: string[] = []
    const MIN_FORGE_ARTIFACT_SIZE = 4096
    for (let jar of jars) {
      if (!jar) continue
      let isGenerated = false
      if (jar.indexOf('/net/minecraft/client/') >= 0 &&
          (jar.indexOf('-extra.jar') >= 0 || jar.indexOf('-srg.jar') >= 0)) {
        isGenerated = true
      }
      if (((jar.indexOf('/net/minecraftforge/forge/') >= 0) || (jar.indexOf('/net/neoforged/neoforge/') >= 0))
          && jar.indexOf('-client.jar') >= 0) {
        isGenerated = true
      }
      if (!isGenerated) continue
      try {
        let st = fs.statSync(jar)
        if (st.size < MIN_FORGE_ARTIFACT_SIZE) {
          this.alog.error(TAG, `Forge artifact too small (likely corrupted): ${jar} (${st.size} bytes)`, null, LOG_DOMAIN_LAUNCH)
          suspicious.push(jar)
          continue
        }
        if (!this.validateZipIntegrity(jar, st.size)) {
          this.alog.error(TAG, `Forge artifact ZIP integrity failed: ${jar}`, null, LOG_DOMAIN_LAUNCH)
          suspicious.push(jar)
        }
      } catch (e) {
        // 文件不存在已被 findMissingJars 捕获，这里不重复
      }
    }
    return suspicious
  }

  /**
   * 检查文件是否为合法 ZIP（jar 本质是 ZIP 格式）。
   * 通过读取开头 4 字节和结尾 22 字节做签名校验，开销极小（< 1ms/jar）。
   *
   * - 头部签名：PK\x03\x04（local file header）或 PK\x05\x06（空 archive）
   * - 尾部签名：PK\x05\x06（End of Central Directory Record, EOCD）
   *   EOCD 至少 22 字节，通常在文件末尾但可能因 comment 字段前移 65KB 以内。
   *
   * 不解析中央目录，只验证文件"不是半截/空文件/截断文件"，已足够拦截
   * OHOS JDK zlib 导致的截断产物。
   */
  private validateZipIntegrity(path: string, totalSize: number): boolean {
    if (totalSize < 22) return false
    let file: fs.File | null = null
    try {
      file = fs.openSync(path, fs.OpenMode.READ_ONLY)
      // 读开头 4 字节检查 PK signature
      let headerBuf = new ArrayBuffer(4)
      let headerRead = fs.readSync(file.fd, headerBuf, { offset: 0, length: 4 })
      if (headerRead < 4) return false
      let header = new Uint8Array(headerBuf)
      let headerOk = header[0] === 0x50 && header[1] === 0x4B
        && ((header[2] === 0x03 && header[3] === 0x04)
         || (header[2] === 0x05 && header[3] === 0x06))
      if (!headerOk) {
        this.alog.error(TAG, `Invalid ZIP header: ${path} (bytes: ${header[0]} ${header[1]} ${header[2]} ${header[3]})`, null, LOG_DOMAIN_LAUNCH)
        return false
      }

      // 读末尾 min(totalSize, 65557) 字节搜索 EOCD 签名
      // EOCD 最大可能位置：22 + 65535（comment 最大）
      const EOCD_SEARCH_SIZE = 65557
      let searchSize = Math.min(totalSize, EOCD_SEARCH_SIZE)
      let tailBuf = new ArrayBuffer(searchSize)
      let tailStart = totalSize - searchSize
      let tailRead = fs.readSync(file.fd, tailBuf, { offset: tailStart, length: searchSize })
      if (tailRead < 22) return false
      let tail = new Uint8Array(tailBuf)
      // 从末尾往前找 PK\x05\x06
      let found = false
      for (let i = tail.length - 22; i >= 0; i--) {
        if (tail[i] === 0x50 && tail[i + 1] === 0x4B
          && tail[i + 2] === 0x05 && tail[i + 3] === 0x06) {
          found = true
          break
        }
      }
      if (!found) {
        this.alog.error(TAG, `ZIP EOCD signature not found (file truncated?): ${path}`, null, LOG_DOMAIN_LAUNCH)
        return false
      }
      return true
    } catch (e) {
      this.alog.error(TAG, `ZIP integrity check failed: ${path}`, e as Object, LOG_DOMAIN_LAUNCH)
      return false
    } finally {
      if (file) { try { fs.closeSync(file) } catch (e) { /* ignore */ } }
    }
  }

  private buildForgeMissingError(missingForgeArtifacts: string[]): string {
    let lines: string[] = []
    lines.push('Forge 安装不完整：缺少关键运行产物。')
    lines.push('请在下载页重新安装当前 Forge 版本后再启动。')
    let preview = missingForgeArtifacts.slice(0, 3)
    for (let p of preview) {
      lines.push('缺失: ' + p)
    }
    if (missingForgeArtifacts.length > preview.length) {
      lines.push('另外缺失 ' + (missingForgeArtifacts.length - preview.length) + ' 个文件。')
    }
    return lines.join('\n')
  }

  private buildClasspathMissingError(missingJars: string[]): string {
    let lines: string[] = []
    lines.push('启动文件不完整：classpath 存在缺失 jar。')
    lines.push('请先补齐游戏/模组依赖后再启动。')
    let preview = missingJars.slice(0, 5)
    for (let p of preview) {
      lines.push('缺失: ' + p)
    }
    if (missingJars.length > preview.length) {
      lines.push('另外缺失 ' + (missingJars.length - preview.length) + ' 个文件。')
    }
    return lines.join('\n')
  }

  // 旧版 Forge（FML legacy，≤1.12）禁用启动画面（SplashProgress）。
  //
  // ⚠️ 2026-06-13 修复（1.8.9-forge 进游戏前 gl4es FPE 着色器编译失败 → realize_glenv SIGSEGV）：
  //   FML 1.8.9 的 SplashProgress 在【独立线程】用 SharedDrawable（共享 GL 上下文）渲染转圈 logo。
  //   AMCL 的 libglfw+EGL 是单窗口单上下文、不支持在另一线程创建共享上下文 → splash 线程拿不到
  //   有效 GL 上下文 → gl4es FPE 着色器编译失败（空错误日志）→ realize_glenv 解引用空程序 SIGSEGV
  //   （真机 hs_err 实证：`# C [libgl4es.so+0xc676c] realize_glenv`）。主线程渲染本身正常（1.12.2
  //   vanilla 同 FPE 已验证可出图），故只需关掉这个独立线程的 splash。
  //   FML 读 config/splash.properties 的 enabled；置 false 即 start() 早退、不创建 splash 线程。
  //   新版 Forge（1.13+）忽略该文件，故对其无副作用。
  private disableLegacyForgeSplash(): void {
    let configDirs: string[] = [this.gameDir + '/config']
    if (this.mcDir !== this.gameDir) configDirs.push(this.mcDir + '/config')
    if (this.filesDir && this.filesDir !== this.gameDir && this.filesDir !== this.mcDir) {
      configDirs.push(this.filesDir + '/config')
    }
    for (let configDir of configDirs) {
      let propsPath = configDir + '/splash.properties'
      try { fs.mkdirSync(configDir, true) } catch (e) { /* exists */ }
      let original = ''
      try { original = fs.readTextSync(propsPath) } catch (e) { original = '' }
      let updated: string
      if (original.length === 0) {
        updated = '# Auto-generated by AMCL for HarmonyOS (disable FML splash thread)\nenabled=false\n'
      } else if (/^[ \t]*enabled[ \t]*=.*$/m.test(original)) {
        updated = original.replace(/^[ \t]*enabled[ \t]*=.*$/m, 'enabled=false')
      } else {
        updated = (original.endsWith('\n') ? original : original + '\n') + 'enabled=false\n'
      }
      if (updated === original) continue
      let f: fs.File | null = null
      try {
        f = fs.openSync(propsPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
        fs.writeSync(f.fd, updated)
        this.alog.info(TAG, `Legacy Forge: disabled FML splash in ${propsPath}`, LOG_DOMAIN_LAUNCH)
      } catch (e) {
        this.alog.warn(TAG, `disable FML splash ${propsPath} failed`, e as Object, LOG_DOMAIN_LAUNCH)
      } finally {
        if (f) { try { fs.closeSync(f) } catch (_) { /* ignore */ } }
      }
    }
  }

  private disableForgeEarlyDisplay(): void {
    // 写入所有可能的 config 位置，确保 Forge 无论从哪个路径读取都能找到配置
    // Forge 可能从 user.dir（gameDir）、.minecraft 根目录、或 user.home（filesDir）读取
    let configDirs: string[] = [this.gameDir + '/config']
    if (this.mcDir !== this.gameDir) {
      configDirs.push(this.mcDir + '/config')
    }
    if (this.filesDir && this.filesDir !== this.gameDir && this.filesDir !== this.mcDir) {
      configDirs.push(this.filesDir + '/config')
    }
    for (let configDir of configDirs) {
      let tomlPath = configDir + '/fml.toml'
      try { fs.mkdirSync(configDir, true) } catch (e) { /* exists */ }
      let original = ''
      try {
        original = fs.readTextSync(tomlPath)
      } catch (e) {
        original = ''
      }
      let updated = original
      if (updated.length === 0) {
        updated = '# Auto-generated by AMCL for HarmonyOS\n'
      }
      // ⚠️ 2026-06-06 修复：Forge 1.17+ 的 fml.toml 是【扁平】的——earlyWindow* 是顶层
      //   key，不存在 [fmlClient] 段。历史代码把 key 写进 [fmlClient] 段 → Forge 顶层
      //   读不到 earlyWindowControl → 用默认 true → 加载 EarlyDisplay → OHOS 上卡在
      //   Forge 加载界面（1.21.5）/ 首启失败（1.21.6）。删除历史误加的段头，改为顶层 upsert。
      updated = updated.replace(/^[ \t]*\[fmlClient\][ \t]*\r?\n?/gm, '')
      updated = this.upsertTomlBoolean(updated, 'earlyWindowControl', false)
      updated = this.upsertTomlBoolean(updated, 'earlyWindowShowCPU', false)
      updated = this.upsertTomlBoolean(updated, 'earlyWindowSquir', false)
      updated = this.upsertTomlBoolean(updated, 'earlyWindowLogHelpMessage', false)

      if (updated !== original) {
        // 2026-05-23 ArkTS 严格模式：fs.openSync / writeSync / closeSync 报
        // 'Function may throw'。包 try-catch + hilog + rethrow，finally 关 fd。
        // 详见 docs/guides/api-migration-2026-05.md。
        let f: fs.File | null = null
        try {
          f = fs.openSync(tomlPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
          fs.writeSync(f.fd, updated)
        } catch (e) {
          this.alog.warn(TAG, `patch EarlyDisplay ${tomlPath} failed`, e as Object, LOG_DOMAIN_LAUNCH)
          throw e as Error
        } finally {
          if (f) {
            try { fs.closeSync(f) } catch (_) { /* ignore */ }
          }
        }
        this.alog.info(TAG, `Forge: patched EarlyDisplay flags in ${tomlPath}`, LOG_DOMAIN_LAUNCH)
      }
    }
  }

  private upsertTomlBoolean(content: string, key: string, value: boolean): string {
    let line = key + ' = ' + (value ? 'true' : 'false')
    let escaped = this.escapeRegExp(key)
    // ⚠️ 2026-06-15：改为"删除该 key 的全部顶层出现 + 末尾追加唯一一行"，保证幂等且**无重复键**。
    //   旧实现 replace(首个匹配) 在整合包自带 fml.toml（已含 earlyWindow* 键）+ 多次/多路径
    //   写入下会残留/追加出重复键 → FML 的 TOML 解析器报 "entry defined twice" → 启动崩溃。
    //   用 [ \t] 而非 \s 限定行内空白（\s 含换行会跨行误吞）。
    let stripAll = new RegExp('^[ \\t]*' + escaped + '[ \\t]*=.*(?:\\r?\\n|$)', 'gm')
    let out = content.replace(stripAll, '')
    if (out.length > 0 && !out.endsWith('\n')) out += '\n'
    out += line + '\n'
    return out
  }

  private escapeRegExp(raw: string): string {
    return raw.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  }

  /**
   * 旧 Forge（cpw.mods.bootstraplauncher.BootstrapLauncher，1.20.x 及更早）专属修复。
   *
   * 背景：旧 Forge 用 BootstrapLauncher + securejarhandler 2.1.x 把 -cp 里非 ignoreList 的
   * jar 提升为【命名模块】，再 --add-modules ALL-MODULE-PATH 强制解析全部。我们用的
   * lwjgl-ohos 是 LWJGL 3.4.1，module-info 只在 META-INF/versions/11|25/（旧 securejarhandler
   * 读不到根 module-info → org.lwjgl 模块解析失败 → 闪退）。
   *
   * 修法（最终方案）：不再用 ignoreList（会让 LWJGL 落到 classpath，MC 的 TransformingClassLoader
   * 够不到 → NoClassDefFoundError: org/lwjgl/system/MemoryUtil）。改为给 lwjgl-ohos 的 jar
   * 补【根 module-info.class】，让 securejarhandler 正确命名 org.lwjgl 等模块（见
   * scripts/patch-lwjgl-module-info.py + docs/reports/forge-lwjgl-root-module-info-202606.md）。
   * 此 ArkTS 侧不再需要特殊处理。
   */
  private isForgeProfile(parsed: ParsedVersion): boolean {
    let versionLower = this.version.toLowerCase()
    if (versionLower.indexOf('forge') >= 0) return true

    let mainLower = parsed.mainClass.toLowerCase()
    if (mainLower.indexOf('forge') >= 0 || mainLower.indexOf('bootstraplauncher') >= 0) return true

    for (let lib of parsed.libraries) {
      let lower = lib.toLowerCase()
      if (lower.indexOf('net/minecraftforge/') >= 0 || lower.indexOf('net/neoforged/') >= 0) return true
    }

    for (let arg of parsed.gameArgs) {
      let lower = arg.toLowerCase()
      if (lower.indexOf('--fml.') === 0 || lower.indexOf('net.minecraftforge') >= 0
          || lower.indexOf('net.neoforged') >= 0) {
        return true
      }
    }
    return false
  }

  // ============================================================
  //  用户自定义 JVM 参数（优先级最高，对齐 FCL/HMCL 的 javaArguments 语义）
  // ============================================================

  /**
   * 解析用户自定义 JVM 参数字符串 → 参数数组。
   * 以空格/制表/换行分隔；支持单/双引号包裹含空格的值（引号本身被去除）。
   */
  private parseUserJvmArgs(raw: string): string[] {
    let out: string[] = []
    if (!raw) return out
    let cur = ''
    let inToken = false
    let quote = ''
    for (let i = 0; i < raw.length; i++) {
      let c = raw.charAt(i)
      if (quote.length > 0) {
        if (c === quote) { quote = '' } else { cur += c }
      } else if (c === '"' || c === '\'') {
        quote = c
        inToken = true
      } else if (c === ' ' || c === '\t' || c === '\n' || c === '\r') {
        if (inToken) { out.push(cur); cur = ''; inToken = false }
      } else {
        cur += c
        inToken = true
      }
    }
    if (inToken) out.push(cur)
    return out
  }

  /**
   * 计算一个 JVM 参数的"去重键"：仅对受"覆盖语义"影响的参数返回非空键。
   *   -Dfoo=bar / -Dfoo → '-Dfoo'
   *   -Xmx512m          → '-Xmx'（-Xms/-Xss/-Xmn 同理）
   *   其它（--add-opens / --add-exports 等可重复参数）→ ''（不参与去重，原样保留）
   */
  private jvmArgKey(arg: string): string {
    return jvmArgumentOverrideKey(arg)
  }

  /**
   * 合入用户自定义 JVM 参数，语义对齐 FoldCraftLauncher / HMCL 的"用户优先"：
   *   - 用户参数先按键保留末项，再追加在末尾。上游按全局、单版本的顺序拼接，
   *     所以单版本参数覆盖全局同键；清除失效旧值后，native 冻结检查的是最终生效值。
   *     SSOT 在 extraJvmArgs 之前注入，用户最终值仍覆盖它和 version.json 的普通默认。
   *   - 同时把 version.json 里与用户【同键】(-Dkey / -Xmx 系列) 的参数剔除，避免命令行
   *     出现两条互相矛盾的 -Dkey（保留也会被覆盖，剔除让命令更干净）。
   *   - --add-opens / --add-exports 等可重复参数 jvmArgKey 返回 ''，不参与去重，原样保留。
   *
   * 例：用户写 "-Dsodium.checks.issue2561=true" 即可覆盖 SSOT 的 =false 默认（恢复检查）。
   */
  private mergeUserJvmArgs(versionArgs: string[]): string[] {
    // 此处只整理用户覆盖次序，不对显式路径、模板或图形身份做默认值替换。
    // 最终异值仍会被后续 builder/native 拒绝；不能让已被覆盖的全局旧值误伤有效设置。
    let userArgs = retainLastJvmArgumentValues(
      this.parseUserJvmArgs(this.customJvmArgs).filter((a: string): boolean => a.length > 0))
    if (userArgs.length === 0) return versionArgs

    let userKeys = new Set<string>()
    for (let ua of userArgs) {
      let k = this.jvmArgKey(ua)
      if (k.length > 0) userKeys.add(k)
    }
    let kept: string[] = []
    for (let va of versionArgs) {
      let k = this.jvmArgKey(va)
      if (k.length > 0 && userKeys.has(k)) {
        this.alog.info(TAG, `User JVM arg overrides version.json key: ${k}`, LOG_DOMAIN_LAUNCH)
        continue
      }
      kept.push(va)
    }
    this.alog.info(TAG, `Merged ${userArgs.length} custom JVM arg(s)`, LOG_DOMAIN_LAUNCH)
    return kept.concat(userArgs)
  }

  /**
   * 注入 authlib-injector 的 javaagent 参数（若已设置）。
   *
   * 三条参数（对齐 PCL2 / authlib-injector 官方部署说明）：
   *   -javaagent:<jar>=<apiRoot>              加载 agent 并指定验证服务器
   *   -Dauthlibinjector.side=client           声明客户端侧
   *   -Dauthlibinjector.yggdrasil.prefetched  base64 预取元数据（省一次联网 + 抗抖动）
   *
   * 三者需齐全；任一缺失则整体跳过（避免加载了 agent 却没元数据导致游戏内验证失败）。
   *
   * ┌── TODO（待做）：统一通行证 Nide8 支持 ──────────────────────────────────────┐
   * │ PCL2 除 authlib-injector 外还支持「统一通行证」(Nide8)。Nide8 本质也是一个    │
   * │ Yggdrasil 服务器（BaseUrl = https://auth.mc-user.com:233/<serverId>/authserver），│
   * │ 故认证网络层可【直接复用现有 account/authlib/YggdrasilApi.ets】（validate/refresh/│
   * │ authenticate/纹理 全部通用），账户模型可复用 AuthlibInjectorAccount（加一个       │
   * │ flavor:'authlib'|'nide8' + serverId 字段，避免新开 AccountType）。               │
   * │ 与本方法唯一的差异在【启动注入】：Nide8 用                                        │
   * │     -javaagent:<nide8auth.jar>=<serverId>   （值是 serverId，不是完整 URL）       │
   * │ 且【不带】-Dauthlibinjector.side / .prefetched（nide8auth.jar 内建 host 逻辑）。  │
   * │ JVM 信任库沿用 injectJvmTrustStore()（同样需要 JVM 内 HTTPS 可信）。              │
   * │ **硬阻塞**：需要统一通行证官方 nide8auth.jar 二进制放进 entry/.../rawfile/，       │
   * │ 拿到 jar 后再实现（本项目无法自带该第三方 jar）。详见 CHANGELOG 1000349 备注。    │
   * └────────────────────────────────────────────────────────────────────────────┘
   */
  /**
   * IPv6 偏好护栏（方案 §四·五 R2）：把 `java.net.preferIPv6Addresses` 钉成 `false`。
   *
   * ┌─ 为什么需要它 ────────────────────────────────────────────────────────────┐
   * │ Mojang 的官方 version manifest（实测 1.20.4 自带）里有                    │
   * │     -Djava.net.preferIPv6Addresses=system                                │
   * │ 这条参数**今天什么也不做** —— HarmonyOS 沙箱拒读 /proc/net/if_inet6，     │
   * │ libnet 的 IPv6_supported() 判 false，整条 IPv6 通路是关的。              │
   * │                                                                          │
   * │ 而能力层（elf_loader 的 if_inet6 垫片）一落地，它就**开始生效**：所有主机名 │
   * │ 解析都会按系统策略优先选 IPv6。本仓已有真机记录：本平台存在「有 IPv6 路由  │
   * │ 但该主机 IPv6 不通」（CHANGELOG 1000467，下载器为此加了每主机地址族选择）， │
   * │ 而 MC / Netty **没有**这种回退。                                          │
   * │ ⇒ 不加护栏就等于：为修好少数人的 IPv6 直连，让多数人的主机名连接可能变慢/ │
   * │   偶发失败。加了护栏就是：**只补能力，不改偏好**。                        │
   * └──────────────────────────────────────────────────────────────────────────┘
   *
   * 落点与优先级（依赖本文件既有语义，不是新发明）：
   *   - 在 filterJvmArgs 之后追加（同 `-Damcl.mc.dir` / authlib 那几条），不会被过滤误伤；
   *   - 先剔除 manifest 里的同键项再 push，让最终命令行只有一条，
   *     R5.3 的验收（"实际最终值为 false"）因此可以直接从启动日志读出来，不必推理；
   *   - 排在 `mergeUserJvmArgs` **之前** ⇒ 用户在「自定义 JVM 参数」里显式写
   *     `-Djava.net.preferIPv6Addresses=system`（或 true）仍然赢 —— 那就是 R2 说的
   *     "用户开关"，走已有通道，不需要新的设置项。
   */
  private injectIpv6PreferenceGuard(jvmArgs: string[]): void {
    let r: Ipv6PreferenceGuardResult = applyIpv6PreferenceGuard(jvmArgs)
    // 原地替换，保持既有调用点"传数组进去、被就地改写"的语义
    jvmArgs.length = 0
    for (let a of r.args) jvmArgs.push(a)

    if (r.replaced.length > 0) {
      this.alog.info(TAG,
        `IPv6 preference guard: replaced ${r.replaced.length} manifest arg(s) ${JSON.stringify(r.replaced)} `
        + `with ${IPV6_PREFER_ADDRESSES_KEY}false `
        + '(capability is fixed by the if_inet6 shim; preference intentionally left IPv4-first. '
        + 'Users can opt in via custom JVM args.)',
        LOG_DOMAIN_LAUNCH)
    } else {
      this.alog.info(TAG,
        `IPv6 preference guard: pinned ${IPV6_PREFER_ADDRESSES_KEY}false (no manifest arg to replace)`,
        LOG_DOMAIN_LAUNCH)
    }
  }

  private injectAuthlibArgs(jvmArgs: string[]): void {
    if (this.authlibJarPath.length === 0 || this.authlibApiRoot.length === 0 || this.authlibPrefetched.length === 0) {
      return
    }
    jvmArgs.push('-javaagent:' + this.authlibJarPath + '=' + this.authlibApiRoot)
    jvmArgs.push('-Dauthlibinjector.side=client')
    jvmArgs.push('-Dauthlibinjector.yggdrasil.prefetched=' + this.authlibPrefetched)
    this.alog.info(TAG, `authlib-injector args injected (apiRoot=${this.authlibApiRoot}, prefetched=${this.authlibPrefetched.length}B)`, LOG_DOMAIN_LAUNCH)
    // 第三方登录必须保证【JVM 内】HTTPS 可信：authlib-injector 在运行时要连皮肤站
    // （单人渲染自己皮肤下 CDN 贴图、多人 /join 走 sessionserver）。PCL2 为此在 Auth 分支加
    // -Djavax.net.ssl.trustStoreType=WINDOWS-ROOT 信任系统根证书；OHOS 无此机制，改为显式
    // 指向 JDK 自带 cacerts（标准 OpenJDK 产物，含 Mozilla CA，密码 changeit）。见下方方法。
    this.injectJvmTrustStore(jvmArgs)
  }

  /**
   * 显式指定 JVM 的 TLS 信任库（JSSE 的 -Djavax.net.ssl.trustStore*）。
   *
   * 背景 / 为什么需要：
   *   AMCL 给 libcurl（原生下载）配的 cacert.pem 只对 native 下载引擎生效，
   *   **对 JVM 内部的 HttpsURLConnection 无效**。第三方皮肤站登录（authlib-injector）
   *   是本项目首个真正依赖【JVM 自身 HTTPS 栈】的场景：agent 运行时要连皮肤站的
   *   yggdrasil/sessionserver/纹理 CDN，用的是 JVM 默认 SSLContext → JVM 信任库。
   *   若信任库缺失/未被发现，会报「PKIX path building failed」→ 皮肤不显示 / 无法进
   *   使用该皮肤站验证的服务器。
   *
   * 策略（belt-and-suspenders，零新增打包产物）：
   *   标准 OpenJDK 会把 cacerts 放在 <java.home>/lib/security/cacerts（JDK8 经典布局在
   *   jre/lib/security/cacerts），并在 java.home 正确时自动发现。这里**在文件确实存在时**
   *   显式再指一遍（+ 默认口令 changeit），消除 OHOS 上 java.home/发现路径可能的怪异；
   *   文件不存在则不注入（避免指向空路径反而让 HTTPS 更差），并告警——真机日志即可暴露
   *   「该 JDK 包没带 cacerts」这一需要在交叉编译侧补的问题。
   *
   * 仅在第三方登录（authlib / 后续 Nide8）路径调用，保持原版/微软 battle-tested 启动路径不变。
   */
  private injectJvmTrustStore(jvmArgs: string[]): void {
    // 已由用户自定义参数显式指定 trustStore 时，尊重用户，不覆盖。
    for (const a of jvmArgs) {
      if (a.indexOf('-Djavax.net.ssl.trustStore=') === 0) {
        this.alog.info(TAG, 'trustStore already specified, skip auto-inject', LOG_DOMAIN_LAUNCH)
        return
      }
    }
    const jdkRoot = this.filesDir + '/jdk/' + this.jdkVersion
    // 模块化布局（17/21/25）优先；JDK8 经典布局兜底。
    const candidates: string[] = [
      jdkRoot + '/lib/security/cacerts',
      jdkRoot + '/jre/lib/security/cacerts',
    ]
    let found = ''
    for (const p of candidates) {
      try {
        if (fs.statSync(p).size > 0) { found = p; break }
      } catch (e) { /* 不存在，试下一个 */ }
    }
    if (found.length === 0) {
      this.alog.warn(TAG,
        `JVM cacerts not found under ${jdkRoot}/lib/security — third-party skin-site HTTPS ` +
        `may fail (PKIX). JDK data zip should ship lib/security/cacerts.`,
        null, LOG_DOMAIN_LAUNCH)
      return
    }
    jvmArgs.push('-Djavax.net.ssl.trustStore=' + found)
    jvmArgs.push('-Djavax.net.ssl.trustStorePassword=changeit')
    this.alog.info(TAG, `JVM trustStore pinned: ${found}`, LOG_DOMAIN_LAUNCH)
  }

  /**
   * 过滤不适用于 OHOS 的 JVM 参数
   * 保留：--add-modules, --add-opens, --add-exports, --add-reads, -p, -D*, --module-path
   * 过滤：-Xms*, -Xmx*（由 jvm_launcher 控制）、含 ${} 未替换变量的
   *
   * 特殊处理：将“参数 + 值”二元选项合并为 --key=value 形式，
   * 避免在 JavaVMOption 中出现孤立参数值。
   */
  private filterJvmArgs(args: string[], classpath: string): string[] {
    let result: string[] = []
    const pairOptions: string[] = [
      '-p', '--module-path',
      '--add-modules',
      '--add-opens',
      '--add-exports',
      '--add-reads',
      '--patch-module',
    ]

    // SSOT: 共享 JVM 参数清单来自 C 层 amcl::getCommonJvmArgs()
    //   （实现见 entry/src/main/cpp/jvm/jvm_common_args.cpp）
    // 本函数过滤 version.json 中的 jvmArgs 时跳过任何与清单重复的项，
    // 避免 `--add-opens x/y=z x/y=z` 被 JVM 当成重复声明而告警（部分版本直接拒绝启动）。
    //
    // 失败策略：硬错。历史上曾退化为"不去重"，但 ROADMAP §二·5 已记录"部分 JVM 版本
    // 遇到重复 --add-opens 会直接拒绝启动" — 退化无声继续等于把这种崩溃藏到了 JVM 阶段。
    // 这里宁可让上层 build() 收到清晰错误，也不在启动期掩盖 SSOT 缺失。
    let cLayerArgs: Set<string> = new Set<string>()
    try {
      const shared: string[] = launchNative().getCommonJvmArgs() as string[]
      if (!shared || shared.length === 0) {
        throw new Error('getCommonJvmArgs() returned empty; SSOT lookup must not be silent')
      }
      for (let k = 0; k < shared.length; k++) cLayerArgs.add(shared[k])
    } catch (e) {
      let msg = (e as Error)?.message ?? String(e)
      this.alog.error(TAG, `getCommonJvmArgs() FAILED: ${msg}`, null, LOG_DOMAIN_LAUNCH)
      this.lastBuildError = '内部错误：JVM 参数 SSOT 不可用（' + msg + '）。请重装或检查 libentry.so'
      throw new Error('getCommonJvmArgs unavailable: ' + msg)
    }

    for (let i = 0; i < args.length; i++) {
      let rawArg = args[i]
      let arg = this.resolveJvmArgTemplate(rawArg, classpath)
      if (arg === null) {
        this.alog.warn(TAG, `Skip JVM arg with unresolved variable: ${rawArg}`, null, LOG_DOMAIN_LAUNCH)
        continue
      }
      // 跳过内存参数（由 jvm_launcher 控制）
      if (arg.indexOf('-Xms') === 0 || arg.indexOf('-Xmx') === 0) continue
      // 剔除 OHOS HotSpot 不兼容的紧凑对象头（JEP 519）。
      //
      // MC 26.1+（YY.D.H 新纪元）的 version.json 带 `-XX:+UseCompactObjectHeaders`
      // （JDK 25 起为正式特性，Mojang 为省内存开启）。但 AMCL 的 SSOT 公共参数
      // （jvm_common_args.cpp）强制 `-XX:-UseCompressedOops`：
      //   · CompactObjectHeaders 需要窄 klass 编码 → HotSpot 把压缩类空间基址放到
      //     高位 0x5f00000000 / shift 9；compressed oops 关闭时该基址无法编码类指针
      //     → fatal error (compressedKlass.cpp:287) → JNI_CreateJavaVM 阶段直接 abort
      //     （真机 26.1-forge 实测 0.03 秒崩溃，MC 根本没加载）。
      // CompactObjectHeaders 纯属内存占用优化，关闭后 MC 行为完全一致；而翻动
      // `-UseCompressedOops` 会动到 safepoint/signal 机制（见 docs/adaptation/JDK_ADAPTATION_GUIDE.md
      // §5.4 警示），风险高且难验证。故在此剥离该 flag（含显式 +/-，两种写法都剥）。
      // 旧 JDK 17/21 不识别该 flag（vm_args.ignoreUnrecognized=JNI_TRUE 会忽略），
      // 故无条件剥离对老版本无害。
      if (arg === '-XX:+UseCompactObjectHeaders' || arg === '-XX:-UseCompactObjectHeaders') {
        this.alog.info(TAG,
          `Strip incompatible JVM arg ${arg} (conflicts with forced -UseCompressedOops on OHOS HotSpot)`,
          LOG_DOMAIN_LAUNCH)
        continue
      }
      // 跳过 -cp（classpath 由 jvm_launcher 设置）
      if (arg === '-cp' || arg === '-classpath') {
        i++ // 跳过下一个参数（classpath 值）
        continue
      }
      // 跳过会覆盖主链路 native 搜索路径的参数
      // 但保留 Forge 指定的 natives_directory 路径，追加到 extraJvmArgs 中合并传递
      if (arg.indexOf('-Djava.library.path=') === 0) {
        // 提取 Forge 指定的路径值，后续由 C 层合并到 java.library.path
        let forgePath = arg.substring('-Djava.library.path='.length)
        if (forgePath.length > 0 && forgePath.indexOf('${') < 0) {
          result.push('-Damcl.forge.native.path=' + forgePath)
          this.alog.info(TAG, `Captured Forge native path: ${forgePath}`, LOG_DOMAIN_LAUNCH)
        }
        continue
      }
      if (arg.indexOf('-Dorg.lwjgl.librarypath=') === 0) continue
      // 合并需要下一个参数的选项：--add-opens x/y=z -> --add-opens=x/y=z
      if (pairOptions.indexOf(arg) >= 0 && i + 1 < args.length) {
        let rawNext = args[i + 1]
        let nextArg = this.resolveJvmArgTemplate(rawNext, classpath)
        if (nextArg === null) {
          this.alog.warn(TAG, `Skip JVM arg pair with unresolved value: ${arg} -> ${rawNext}`, null, LOG_DOMAIN_LAUNCH)
          i++
          continue
        }
        if (arg === '-p') {
          // JVM 不接受 "-p=<path>"，统一规范为长参数写法
          let merged = '--module-path=' + nextArg
          if (!cLayerArgs.has(merged)) result.push(merged)
        } else {
          let merged = arg + '=' + nextArg
          if (!cLayerArgs.has(merged)) result.push(merged)
        }
        i++ // 跳过下一个参数
        continue
      }
      if (pairOptions.indexOf(arg) >= 0 && i + 1 >= args.length) {
        this.alog.warn(TAG, `Skip incomplete JVM arg pair: ${arg}`, null, LOG_DOMAIN_LAUNCH)
        continue
      }
      // 跳过 C 层已硬编码的参数，避免重复
      if (cLayerArgs.has(arg)) {
        this.alog.info(TAG, `Skip C-layer duplicate JVM arg: ${arg}`, LOG_DOMAIN_LAUNCH)
        continue
      }
      result.push(arg)
    }
    return result
  }

  /**
   * 字面量全量替换（split/join）。
   * 2026-08-27（加载链审查修复批次）：替换一律走本方法，不再用
   * String.replace(regex, string) —— 后者会解释替换串里的 $ 模式（$& $' $` $$）。
   * 用户名/路径是用户可控输入（离线名可含 "$&"），会被展开成占位符本身或前后文。
   */
  private static substAll(text: string, needle: string, value: string): string {
    if (text.indexOf(needle) < 0) return text
    return text.split(needle).join(value)
  }

  private resolveJvmArgTemplate(arg: string, classpath: string): string | null {
    // 此入口只消费清单参数，必须在通用占位符替换前识别官方 JNA 默认模板。
    // 只改 jna.tmpdir 的已知默认值，java.library.path/LWJGL/Netty 仍沿用各自目录语义；
    // 用户参数在 filterJvmArgs 之后合入，不经过该适配，显式异值会保留到严格冻结。
    let resolved = normalizeManifestJnaTmpdir(arg, this.gameDir)
    if (resolved.indexOf('${') < 0) return resolved
    resolved = LaunchProfileBuilder.substAll(resolved, '${library_directory}', this.mcDir + '/libraries')
    resolved = LaunchProfileBuilder.substAll(resolved, '${classpath_separator}', ':')
    resolved = LaunchProfileBuilder.substAll(resolved, '${version_name}', this.version)
    resolved = LaunchProfileBuilder.substAll(resolved, '${classpath}', classpath)
    // `${natives_directory}` follows the active game directory. In version
    // isolation this is different from the .minecraft root; the native
    // launcher creates exactly this gameDir/natives directory before JVM
    // startup, so both sides must resolve to the same path.
    resolved = LaunchProfileBuilder.substAll(resolved, '${natives_directory}', this.gameDir + '/natives')
    resolved = LaunchProfileBuilder.substAll(resolved, '${launcher_name}', 'amcl')
    resolved = LaunchProfileBuilder.substAll(resolved, '${launcher_version}', '1.0')
    if (resolved.indexOf('${') >= 0) {
      // 自定义 JNA 模板也属于受冻结保护的明确输入；无法解析时保留异值，
      // 让 native 报出 jna.tmpdir 冲突，不能当作普通未知参数跳过后悄悄恢复默认目录。
      if (this.jvmArgKey(arg) === '-Djna.tmpdir') return resolved
      return null
    }
    return resolved
  }

  /**
   * 构建 MC 启动参数（替换变量占位符）
   */
  private buildMcArgs(parsed: ParsedVersion): string[] {
    let args: string[] = []

    if (parsed.gameArgs.length > 0) {
      // MC 1.13+ 格式
      for (let arg of parsed.gameArgs) {
        let replaced = this.replaceVariables(arg, parsed.assetIndex)
        // 过滤掉含未替换变量的参数（如 ${quickPlayMultiplayer}）
        if (replaced.indexOf('${') >= 0) continue
        args.push(replaced)
      }
    } else {
      // 回退到硬编码参数（MC 1.12 或 json 无 arguments）
      args = [
        '--version', this.version,
        '--gameDir', this.gameDir,
        '--assetsDir', this.mcDir + '/assets',
        '--assetIndex', parsed.assetIndex,
        '--accessToken', this.accessToken,
        '--uuid', this.uuid,
        '--username', this.username,
        '--userType', this.userType,
        '--versionType', parsed.type,
      ]
    }

    // 注入 MC 初始分辨率（=渲染面尺寸），解决 LWJGL2 早期加载页（Mojang logo）只占左下角的问题。
    // 仅在未显式声明 --width/--height 时追加；尺寸无效（<=0）则不加。
    if (this.windowWidth > 0 && this.windowHeight > 0
      && args.indexOf('--width') < 0 && args.indexOf('--height') < 0) {
      args.push('--width', String(this.windowWidth))
      args.push('--height', String(this.windowHeight))
    }

    return args
  }

  /**
   * 替换参数中的变量占位符
   * ${auth_player_name} → username, ${version_name} → version, etc.
   *
   * 替换 **所有** 出现位置（substAll = split/join）。早期实现用 `.replace(literal, value)`
   * 只能替换首次，遇到 Forge / NeoForge 中"一个 arg 含多个相同占位符"的场景
   * （如 `${library_directory}/foo.jar:${library_directory}/bar.jar`）会导致残留
   * `${...}` 在 buildMcArgs 里被整条丢弃。改 substAll 的动机见其注释（$ 模式注入）。
   */
  private replaceVariables(arg: string, assetIndex: string = ''): string {
    let result = arg
    result = LaunchProfileBuilder.substAll(result, '${auth_player_name}', this.username)
    result = LaunchProfileBuilder.substAll(result, '${version_name}', this.version)
    result = LaunchProfileBuilder.substAll(result, '${game_directory}', this.gameDir)
    result = LaunchProfileBuilder.substAll(result, '${assets_root}', this.mcDir + '/assets')
    result = LaunchProfileBuilder.substAll(result, '${assets_index_name}', assetIndex ? assetIndex : this.version)
    // ⚠️ 2026-08-04 补齐：`${game_assets}` 以前没有替换规则，1.6.x 及更早的
    //   `minecraftArguments`（`--assetsDir ${game_assets}`）会把占位符原样传给游戏。
    //   对齐 PCL2 `ModLaunch.vb:1661`：指向 assets/virtual/legacy
    //   （PCL2 原注释：「1.5.2 的 pre-1.6 资源索引应与 legacy 合并」）。
    //   McDownloader 现在会把 virtual/map_to_resources 索引按资源名落到该目录，
    //   两边配套后老版本才真正能读到声音与语言文件。
    result = LaunchProfileBuilder.substAll(result, '${game_assets}', this.mcDir + '/assets/virtual/legacy')
    result = LaunchProfileBuilder.substAll(result, '${auth_uuid}', this.uuid)
    result = LaunchProfileBuilder.substAll(result, '${auth_access_token}', this.accessToken)
    result = LaunchProfileBuilder.substAll(result, '${user_type}', this.userType)
    result = LaunchProfileBuilder.substAll(result, '${version_type}', 'release')
    result = LaunchProfileBuilder.substAll(result, '${user_properties}', '{}')
    result = LaunchProfileBuilder.substAll(result, '${clientid}', '')
    result = LaunchProfileBuilder.substAll(result, '${auth_xuid}', '')
    return result
  }
}
