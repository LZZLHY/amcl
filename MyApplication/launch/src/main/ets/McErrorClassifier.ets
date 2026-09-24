/**
 * McErrorClassifier.ets — MC 启动失败错误分类器（v6.5.1，2026-05-22）
 *
 * 把 mc_output.log 尾部 + summary 翻译成"人话 + 原因 + 解决办法步骤"。
 * McErrorSheet 渲染时根据 McDiagnosis 的 category 字段选取不同的图标/颜色/建议。
 *
 * 不同于 SessionMarker.extractErrorSummary（只抽 Java 异常顶行）：
 * 本分类器额外做模式匹配 + 解析关键参数（如 class file version），
 * 给出用户能看懂的"为什么会出错"和"怎么办"。
 *
 * 新增错误类型只需：
 *   1. 在 McErrorCategory 加成员
 *   2. 在 classify() 加一段 if 分支
 *   3. 在 build*Diagnosis 里返回该类别的 McDiagnosis（含 suggestions）
 */

// 复用版本识别 / 纪元判定的单一事实源，给"该版本应该用哪个 JDK"算出推荐值。
import { detectMcEra, McEra, isMcVersionAtLeast } from 'commons';
import { extractGameVersionFromId } from 'mods';
import { JDK21_MIN_MC_VERSION } from 'commons';
import { stripLogNoiseText } from 'commons';
import { hasErrorSignal } from 'commons';
import { McLogEvidence } from './SessionMarker';
import { LWJGL_MODERN_VERSION } from './LwjglModernSlot';

export type McErrorCategory =
  | 'jdk_version'      // UnsupportedClassVersionError —— class file version 不匹配
  | 'jdk_runtime'      // JDK 运行时不兼容（移除的 API / 模块不匹配，常因选错 JDK 版本）
  | 'lwjgl_module_missing' // 游戏需要的 LWJGL 类/模块未随 AMCL 的 OHOS 运行时交付
  | 'lwjgl_version'    // LWJGL 版本不匹配（jar 与游戏期望的 API 面不一致，如现代槽缺旧版 mallocStack）
  | 'oom'              // OutOfMemoryError —— 内存不足
  | 'mod_conflict'     // Fabric / Forge mod 冲突
  | 'missing_file'     // NoSuchFileException / FileNotFoundException
  | 'mixin_apply'      // MIXIN apply failed
  | 'native_crash'     // SIGSEGV / fatal error from JVM
  | 'launch_arg'       // 启动参数缺失（access denied / module not found）
  | 'fabric_game_missing' // Fabric 的 Knot 定位不到游戏本体（启动器没把游戏 classpath 交给它，详见 matchFabricGameProvider）
  | 'forge_boot_classpath' // Forge 新 bootstrap（1.20.2+）建不出模块层（同一根因的另一条路线，详见 matchForgeBootClasspath）
  | 'ipv6_unsupported' // 运行时把 IPv6 判成不可用 ⇒ 填 IPv6 服务器地址连不上（详见 matchIpv6Unsupported）
  | 'not_diagnosable'  // 日志里没有可归因的错误（会话被系统/用户结束等），不要编造原因
  | 'unknown';

/** 一条解决办法（编号 1/2/3 显示） */
export interface McSuggestion {
  title: string;
  desc: string;
  /** true → 显示 "推荐" badge */
  recommended: boolean;
  /**
   * 关联的应用内操作。McErrorSheet 主按钮根据第一个 recommended 的 actionKey 决定 label + 跳转。
   *   - 'open_versions'    → 关闭 sheet + 跳到 DownloadTab 版本列表
   *   - 'open_jdk_manager' → 关闭 sheet + 跳到设置 → JDK 管理
   *   - 'open_mod_list'    → 关闭 sheet + 跳到模组管理
   *   - 'redownload'       → 关闭 sheet + 触发重新下载
   *   - null               → 无主操作，仅文字建议
   */
  actionKey: string | null;
}

export interface McDiagnosis {
  category: McErrorCategory;
  /** 人话标题（顶部红色小标签下方大标题用，sheet 主标题用 session.version） */
  title: string;
  /** 1-2 行用户能看懂的解释（"为什么会出错？"卡片里展开的正文） */
  description: string;
  /** 技术原因小 chip 文字，例如 "UnsupportedClassVersionError (class v69 vs runtime v65)" */
  techDetail: string;
  /** 异常类短名（开发者看的 chip） */
  errorKind: string;
  /** 解决办法步骤 */
  suggestions: McSuggestion[];
  /** 主按钮 label，未提供时由第一个 recommended suggestion 推导 */
  primaryActionLabel: string;
  primaryActionKey: string | null;
}

// ============================================================
//  入口
// ============================================================

/**
 * 门控：这次会话到底该不该做错误诊断（日志系统 v3 · S0）。
 *
 * 这是本次改造的**第一道也是最重要的一道防线**。旧实现把分类器无条件套到任何
 * 残留 marker 的会话上，而分类器的规则又会命中每局必现的无害噪声，于是「用户自己
 * 从后台划掉游戏」也会被诊断成 LWJGL 不兼容 / 文件缺失，并给出破坏性建议。
 *
 * 判据（保守但不再编造）：
 *   - 没拿到日志            → 不诊断（无从归因）
 *   - 有崩溃强信号          → 诊断（Crash Report / fatal error / SIGSEGV）
 *   - 有正常关闭标记且无真实错误 → 不诊断（用户正常退游戏）
 *   - 其余看剥离噪声后是否还有真实错误
 *
 * 调用方拿到 false 时应展示中性文案（如「上次游戏已结束」），**不要**展示任何
 * 「错误原因」或修复建议。
 */
export function shouldDiagnose(evidence: McLogEvidence): boolean {
  if (!evidence.hasLog) return false;
  if (evidence.hasCrashMarker) return true;
  if (evidence.hasStopMarker && !evidence.hasRealError) return false;
  return evidence.hasRealError;
}

/**
 * 解析 mc_output.log 尾部 + SessionMarker 摘要，给出诊断。
 *
 * 2026-07-30（日志系统 v3 · S0）：
 *   1. 入口先对 logTail 过一遍无害噪声白名单（纵深防御 —— 即使调用方忘了门控，
 *      也不会再被 Realms 401 / libflite / LWJGL 自检这些噪声带偏）。
 *   2. 剥离后既没有 summary 也没有任何错误特征时，返回 `not_diagnosable`，
 *      让 UI 老实说「没找到可归因的错误」，而不是兜底到 unknown 再劝用户上传日志。
 *
 * @param summary  SessionMarker.extractErrorSummary 抽出的异常顶行（可能为空串）
 * @param logTail  mc_output.log 尾部全文（~32 KB，可为原始未剥离文本）
 * @param mcVersion 启动的 MC 版本（如 'fabric-loader-0.19.2-26.1'），用于建议文案
 */
export function classifyMcError(summary: string, logTail: string, mcVersion: string): McDiagnosis {
  // 纵深防御：无论调用方传的是原文还是已剥离文本，这里都再过一遍（幂等）。
  let cleanTail = stripLogNoiseText(logTail);
  let cleanSummary = stripLogNoiseText(summary);
  if (cleanSummary.trim().length === 0 && !hasAnyErrorSignal(cleanTail)) {
    return buildNotDiagnosableDiagnosis();
  }
  let cleanText = cleanSummary + '\n' + cleanTail;
  let combined = cleanText.toLowerCase();

  // 顺序敏感：先匹配更具体的，避免被宽泛规则吃掉
  if (matchJdkVersion(summary, logTail)) {
    return buildJdkVersionDiagnosis(logTail, mcVersion);
  }
  // IPv6 地址族不可用要早判，理由不是"和别的规则抢"，而是**它自己太容易被吞**：
  //   三种形态里有两种的异常 message 是 null（见 matchIpv6Unsupported），
  //   规则链后段任何一条命中都会把它变成"游戏意外退出 / 复制日志反馈"——
  //   即分类器的失效形态是静默退化，不是报错。放前面 + 有专门的测试套件钉住。
  //   与 matchJdkVersion 不可能同时成立（class version 不匹配时游戏根本起不来，
  //   也就不会走到"连服务器"这一步），所以两者的先后无实际影响。
  if (matchIpv6Unsupported(combined)) {
    return buildIpv6UnsupportedDiagnosis(combined);
  }
  // Fabric 把 "需要更高 Java 版本" 报成 mod resolution 失败（FormattedException: Some of your
  //   mods are incompatible）。必须在 matchModConflict 之前判，否则会被误归"模组冲突"。
  if (matchFabricJavaReq(combined)) {
    return buildFabricJavaReqDiagnosis(logTail, mcVersion);
  }
  // Fabric 定位不到游戏本体。排在 lwjgl_module_missing / missing_file / mod_conflict 之前是
  //   **防御性**的，不是因为实测被抢过：2026-08-29 的真机样本（mc_output.log 全文 2317 字节）
  //   里既没有 org.lwjgl 符号也没有 "no such file or directory"，那次是一路落到兜底
  //   buildUnknownDiagnosis 的（「游戏意外退出」，零信息量）。
  //   之所以仍要前置，是这三条的判据形状决定了它们**能**吃掉本类，而一旦吃掉给的都是
  //   反向建议：
  //     · lwjgl_module_missing：尾部若还捎带一条精确的 SPNG NoClassDefFoundError 就能命中
  //       （logTail 是 ~32KB 尾部，可能捎带上一段更长会话的内容），错报成运行时交付缺口；
  //     · missing_file：任一行含 "no such file or directory" 且带 .jar 即命中，
  //       结论是"删除版本重新下载" —— 而本类的版本 jar 完好，重下不会有任何变化；
  //     · mod_conflict：定位游戏发生在模组发现**之前**，归成模组冲突会让用户去删模组。
  //   顺序由 McErrorFabricGameProvider.test.ets 的"抢占"用例钉住。
  if (matchFabricGameProvider(combined)) {
    return buildFabricGameProviderDiagnosis(summary);
  }
  // Forge 新 bootstrap 拿不到游戏 classpath —— 与上一条**同一根因、不同加载器**，
  //   所以紧挨着放。它必须排在 matchMissingFile 与 matchModConflict 之前，理由与上一条逐字相同，
  //   而且在这条路线上更硬：Forge 的启动日志本来就有 `no such file or directory` 指向
  //   `.jar` / `libraries/` 的行（native 库探测、可选资源），missing_file 一旦抢到就会
  //   建议用户删版本重下几百 MB —— 而版本 jar 完好。归成模组冲突同理有害：
  //   这条崩溃发生在模组发现**之前**，模组一个都还没被读取。
  if (matchForgeBootClasspath(combined)) {
    return buildForgeBootClasspathDiagnosis(summary);
  }
  // 必须在 lwjgl_version 之前：缺少一个整模块/类与“类存在但方法或字段版本不匹配”是
  // 两种相反的交付故障，给用户的处置也相反。Fabric 的专用原文仍拥有更高优先级。
  let missingLwjglClass = extractKnownLwjglMissingClass(cleanText);
  if (missingLwjglClass.length > 0) {
    return buildLwjglModuleMissingDiagnosis(missingLwjglClass, mcVersion);
  }
  // LWJGL 版本不匹配要在 jdk_runtime / native_crash 之前判：
  //   - 它的 NoSuchMethodError 信号会被 jdk_runtime 的"nosuchmethoderror+unsafe"放过（无 unsafe），
  //     但若不前置，Sodium 硬校验 System.exit→SIGABRT 会被 native_crash 抢走，给错建议。
  if (matchLwjglVersion(combined)) {
    return buildLwjglVersionDiagnosis(logTail, mcVersion);
  }
  if (matchOom(combined)) {
    return buildOomDiagnosis();
  }
  if (matchModConflict(combined)) {
    return buildModConflictDiagnosis(summary);
  }
  if (matchMixinFail(combined)) {
    return buildMixinDiagnosis(summary);
  }
  if (matchJdkRuntime(combined)) {
    return buildJdkRuntimeDiagnosis(mcVersion);
  }
  if (matchMissingFile(combined)) {
    return buildMissingFileDiagnosis(summary);
  }
  if (matchNativeCrash(combined)) {
    return buildNativeCrashDiagnosis();
  }
  if (matchLaunchArg(combined)) {
    return buildLaunchArgDiagnosis(summary);
  }
  return buildUnknownDiagnosis(summary);
}

// ============================================================
//  规则匹配
// ============================================================

/**
 * 剥离噪声后的日志里是否还存在**任何**错误信号。
 * 用于 classifyMcError 的早退判断：没有任何信号就不要进规则链（规则链的兜底
 * 分支会给出「游戏意外退出」这种无信息量且暗示出了故障的结论）。
 *
 * ⚠️ 2026-08-29 补齐一处**对称缺口**（由 McErrorFabricGameProvider.test.ets 抓出）：
 * 原判据只有带斜杠的 `/error]` / `/fatal]`，那是 **Minecraft** 的行格式
 * （`[13:14:15] [Render thread/ERROR]: ...`，级别跟在线程名后面）。而 **Fabric loader**
 * 自己打的是 `[12:39:44] [ERROR] [FabricLoader/GameProvider]: ...` —— 级别单独成段、
 * 不带斜杠，于是一整类「Fabric 在游戏起来之前就报错并终止」的会话被判成"没有错误信号"，
 * 早退成 not_diagnosable。表现是用户看到「上次游戏已结束」，而实际上启动失败了。
 * 两种排版现在都由 `LogErrorSignal` 认领。
 *
 * ⭐ 2026-09-06（日志系统重构 · 批次 A）：**删掉了本函数原有的全文 `indexOf` 判据**，
 * 整体委托给 `LogErrorSignal.hasErrorSignal`（按行 + 带级别语义）。
 *
 * 被删掉的是这一句注释所依赖的前提：
 *   > 本函数的输入已经过 stripLogNoiseText …… ⇒ 剥离后仍剩的错误级别标记是真信号。
 * 它成立的条件是「噪声集合已知且封闭」，而噪声集合是**用户模组列表的函数**。
 * 2026-09-05 在一份 133 模组的用户日志上实测：剥完白名单仍有 7 行被判成真实错误，
 * 一行都不是错误 —— 其中 4 行是 `[WARN]`，还有一行只是散文里出现了 "exceptions" 这个词
 * （旧判据 `low.indexOf('exception')` 命中普通英文单词）。
 * 因果与推演见 docs/refactor/日志系统重构施工记录.md §S01.2 / §S02。
 */
function hasAnyErrorSignal(cleanTail: string): boolean {
  return hasErrorSignal(cleanTail);
}

function matchJdkVersion(summary: string, logTail: string): boolean {
  let s = summary.toLowerCase();
  if (s.indexOf('unsupportedclassversionerror') >= 0) return true;
  if (s.indexOf('class file version') >= 0) return true;
  // 兜底：logTail 也扫一下（summary 可能被截掉关键字）
  let t = logTail.toLowerCase();
  return t.indexOf('unsupportedclassversionerror') >= 0
      || t.indexOf('has been compiled by a more recent version of the java runtime') >= 0;
}

/**
 * Fabric（含 Quilt）在加载阶段对 Java 版本做依赖校验，版本过低时报成 mod resolution 失败，
 * 典型日志（MC 26.1 用 JDK 17 时）：
 *   Some of your mods are incompatible with the game or each other!
 *    - Mod 'Fabric API' (fabric-api) ... requires version 25 or later of 'OpenJDK 64-Bit Server VM' (java),
 *      but only the wrong version is present: 17!
 *    - Replace 'OpenJDK 64-Bit Server VM' (java) 17 with version 25 or later.
 * 这是【JDK 版本过低】，不是真正的模组冲突——必须在 matchModConflict 之前命中并归到 JDK 类别。
 * 判据：日志同时含 "(java)" 的 VM 标识 + 版本要求关键词（requires version / or later / wrong version is present）。
 */
function matchFabricJavaReq(combined: string): boolean {
  // Fabric 的 Java 运行时依赖项标识固定为 "...Server VM' (java)"（区别于普通 mod 依赖
  //   "requires version X or later of 'ModName'"）。必须命中该 VM 描述才判为 JDK 版本问题。
  if (combined.indexOf("vm' (java)") < 0) return false;
  return (combined.indexOf('requires version') >= 0 && combined.indexOf('or later') >= 0)
      || combined.indexOf('wrong version is present') >= 0
      || combined.indexOf('with version') >= 0;
}

/**
 * Fabric 的 Knot 定位不到 Minecraft 本体。
 *
 * 这**不是**用户侧问题：Knot 只从 `java.class.path` 推导游戏查找路径，而启动器把该属性
 * 收窄成只有自己的 jar（游戏 classpath 改由自定义 ClassLoader 持有）。两者相撞时 Fabric
 * 在启动最早期就抛 RuntimeException，此时模组一个都还没被读取。
 * 版本文件、模组、JDK 全都是好的 —— 所以本类的建议里**不许**出现"重新下载版本"。
 *
 * 判据取自 Fabric 的原文（它自己先打一条 [FabricLoader/GameProvider] ERROR 行，
 * 随后 Knot 抛的异常 message 措辞相同）：
 *   Minecraft game provider couldn't locate the game! The game may be absent from the
 *   class path, lacks some expected files, suffers from jar corruption or is of an
 *   unsupported variety/version.
 */
function matchFabricGameProvider(combined: string): boolean {
  if (combined.indexOf("couldn't locate the game") >= 0) return true;
  // 兜底：撇号在不同日志编码/转写下可能变形（' / ’ / `）。两个 needle 都要求命中，
  //   否则单独一个 "game provider" 会把 Fabric 其它阶段的报错也吃进来。
  return combined.indexOf('game provider') >= 0 && combined.indexOf('locate the game') >= 0;
}

/**
 * 三个信号必须落在**同一段堆栈**里才算命中，窗口取这么多行。
 *
 * 12 行的依据是真机原文的形状：`Caused by:` 与它下面那两帧是相邻的三行，
 * 中间最多再插几帧 `at java.base/...`。放大到"整份 32 KB 尾部都算"就会变成
 * 交叉命中 —— 那正是 extractKnownLwjglMissingClass 头注释里记下的同一个坑。
 */
const FORGE_BOOT_STACK_WINDOW: number = 12;

/**
 * Forge 新 bootstrap（MC 1.20.2+）建不出模块层。
 *
 * 这**不是**用户侧问题，也**不是** Fabric 那条的重复：两者根因同源（启动器交付
 * 游戏 classpath 的方式错了），但报错形态完全不同，所以必须各有一条规则。
 * `bootstrap 2.x` 唯一的 classpath 来源是 `java.class.path`（反汇编实测，无
 * `legacyClassPath` 旁路）；拿不到游戏 jar ⇒ 新建的模块层是空的 ⇒
 * `layer.findModule("net.minecraftforge.bootstrap").get()` 必抛。用户看到的是
 * "点开就闪退"，且 `.minecraft` 里**没有** MC 的 crash-report ——
 * 异常发生在 FML 起来之前，MC 的崩溃处理还不存在。
 *
 * 判据取三个信号（2026-09-04 真机原文，见 McErrorForgeBootstrap.test.ets）：
 *   1. `nosuchelementexception` / `no value present`
 *   2. `optional.get` / `findmodule`   ← 抛出点
 *   3. `bootstrapmain` / `net.minecraftforge.bootstrap`  ← 谁在问
 *
 * ⚠️ **少一个都不行，而且第 1 条最不能单用。** `NoSuchElementException` 在 MC 与模组里
 * 到处都是（任何 `Optional.get()`），而第 3 条在这一代 Forge 上**几乎恒真** ——
 * 启动器自己每局都打一行 `Loading net.minecraftforge.bootstrap.ForgeBootstrap...`。
 * ⇒ 1+3 两条合起来仍然过宽（等于"这一代 Forge 上的任何 NoSuchElementException"），
 * 真正把范围收住的是"三条同窗口"。
 */
function matchForgeBootClasspath(combined: string): boolean {
  let lines = combined.split('\n');
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].indexOf('nosuchelementexception') < 0
      && lines[i].indexOf('no value present') < 0) continue;
    let hasThrowSite = false;
    let hasForgeBoot = false;
    let end = Math.min(lines.length, i + FORGE_BOOT_STACK_WINDOW + 1);
    for (let k = i; k < end; k++) {
      let line = lines[k];
      if (line.indexOf('optional.get') >= 0 || line.indexOf('findmodule') >= 0) {
        hasThrowSite = true;
      }
      if (line.indexOf('bootstrapmain') >= 0
        || line.indexOf('net.minecraftforge.bootstrap') >= 0) {
        hasForgeBoot = true;
      }
    }
    if (hasThrowSite && hasForgeBoot) return true;
  }
  return false;
}

function matchOom(combined: string): boolean {
  return combined.indexOf('outofmemoryerror') >= 0
      || combined.indexOf('java heap space') >= 0
      || combined.indexOf('gc overhead limit exceeded') >= 0;
}

/**
 * 从异常行本身提取已确认代表 AMCL 交付缺口的 LWJGL 类。
 *
 * 不能用“全文同时含 NoClassDefFoundError + org.lwjgl”这种交叉命中：32 KB 尾部可能同时
 * 带着两个互不相关的异常。更不能把任意 org.lwjgl 缺类都归到 AMCL：模组可能引用当前
 * 游戏不需要的可选 binding，LWJGL 也存在刻意缺省后安全回退的模块。这里只认冒号后的
 * 直接异常目标，并且只返回已有真机与 manifest 证据确认的精确类。
 */
function extractKnownLwjglMissingClass(text: string): string {
  let lines = text.split('\n');
  let markers: string[] = ['noclassdeffounderror:', 'classnotfoundexception:'];
  for (let i = 0; i < lines.length; i++) {
    let line = lines[i].trim();
    let low = line.toLowerCase();
    for (let j = 0; j < markers.length; j++) {
      let marker = markers[j];
      let markerAt = low.indexOf(marker);
      if (markerAt < 0) continue;
      let target = line.substring(markerAt + marker.length).trim();
      let spaceAt = target.indexOf(' ');
      if (spaceAt >= 0) target = target.substring(0, spaceAt);
      let tabAt = target.indexOf('\t');
      if (tabAt >= 0) target = target.substring(0, tabAt);
      let normalized = target.split('/').join('.');
      if (normalized === 'org.lwjgl.util.spng.SPNG') return normalized;
    }
  }
  return '';
}

/**
 * LWJGL 版本不匹配。AMCL 在 HAP 内统一打包【单套现代 LWJGL】，并在 classpath 里
 * 用它替换 MC version.json 声明的官方 LWJGL jar。当游戏（或 mod）期望的 LWJGL API 面与打包
 * 的这套不一致时，会以两种形态崩：
 *   1) 原版字节码调到已被删除的方法/字段 —— 典型 MC 1.13–1.18（绑 LWJGL 3.1–3.2）调
 *      `GLFWImage.mallocStack` 等（3.3.0 起移除）→ NoSuchMethodError，类名在 org.lwjgl.*；
 *   2) Sodium/Iris 的精确版本硬校验 —— "currently active LWJGL version is not compatible"
 *      （连更高版本也拒）→ System.exit → 单进程 SIGABRT。
 *
 * LWJGL 自带的 jar↔native 配对自检是 AMCL 每局固有噪声，不再作为判据；已确认的 SPNG
 * NoClassDefFoundError 则由 extractKnownLwjglMissingClass 归到模块缺失。顺序上仍须早于
 * native_crash，避免形态 2 被抢走。
 */
function matchLwjglVersion(combined: string): boolean {
  // 形态 2：Sodium/Iris 硬校验（最明确）
  if (combined.indexOf('lwjgl version is not compatible') >= 0) return true;
  if (combined.indexOf('currently active lwjgl version') >= 0) return true;
  // 固有噪声（2026-07-30 移除）：曾把 LWJGL 自带的 jar↔native 配对自检
  //   "Incompatible Java and native library versions detected." 当作判据。
  //   真机复核证明这条在 AMCL 上是**每局必现的固有告警**（我们用定制 LWJGL 替换官方 jar，
  //   自检必然报不匹配），游戏照常运行。一局跑到主菜单、被用户从后台划掉的会话就因为它
  //   被误诊成「LWJGL 版本不兼容」并建议用户改用 1.19+ 版本 —— 破坏性误导。
  //   该字符串已进 commons/LogNoiseFilter 白名单，这里同步不再作为判据。
  //   形态 1（下面的 org.lwjgl + NoSuchMethodError）才是真实的版本面不匹配信号。
  // 形态 1：原版/库调到被删的 LWJGL 方法或字段。NoClassDefFoundError 由
  // extractKnownLwjglMissingClass 只认已确认的交付缺口，不能再混成“版本不兼容”。
  let hasLwjglSymbol = combined.indexOf('org.lwjgl') >= 0 || combined.indexOf('org/lwjgl') >= 0;
  if (hasLwjglSymbol &&
      (combined.indexOf('nosuchmethoderror') >= 0
        || combined.indexOf('nosuchfielderror') >= 0)) {
    return true;
  }
  return false;
}

function matchModConflict(combined: string): boolean {
  return combined.indexOf('some of your mods are incompatible') >= 0
      || combined.indexOf('mod resolution failed') >= 0
      || combined.indexOf('incompatible mods found') >= 0
      || combined.indexOf('modresolutionexception') >= 0;
}

function matchMixinFail(combined: string): boolean {
  return combined.indexOf('mixin apply') >= 0
      || combined.indexOf('mixinapplyerror') >= 0
      || combined.indexOf('mixin transformation') >= 0
      || combined.indexOf('mixin injection') >= 0;
}

/**
 * JDK 运行时不兼容（区别于 jdk_version 的"class 太新、JDK 太旧"）。
 *
 * 这里专门抓"JDK 与该版本不匹配"的另一类信号——典型是【JDK 过新】跑旧版 MC：
 *   - 新 JDK 移除的 Java EE 模块（javax.xml.bind / javax.activation / java.se.ee）
 *   - 旧版 MC / 库用的 sun.misc.Unsafe 方法在新 JDK 改了签名/被移除（NoSuchMethodError）
 *   - JDK 模块系统解析失败（FindException / ResolutionException）
 *
 * 背景（这正是用户担心的点）：我们虽然有纪元路由，但 UNKNOWN（周快照 / 纯中文目录名等）
 * 会兜底到最新 JDK，旧版 MC 在过新 JDK 上就可能崩在这些移除的 API 上。
 *
 * 顺序敏感：放在 mod_conflict / mixin 之后（模组导致的崩溃优先归到模组类别），
 * 放在 launch_arg 之前（FindException 里的 "module ... not found" 不被 launch_arg 抢走）。
 */
function matchJdkRuntime(combined: string): boolean {
  if (combined.indexOf('javax/xml/bind') >= 0) return true;
  if (combined.indexOf('javax/activation') >= 0) return true;
  if (combined.indexOf('java.se.ee') >= 0) return true;
  if (combined.indexOf('nosuchmethoderror') >= 0 && combined.indexOf('unsafe') >= 0) return true;
  if (combined.indexOf('java.lang.module.findexception') >= 0) return true;
  if (combined.indexOf('java.lang.module.resolutionexception') >= 0) return true;
  return false;
}

/**
 * 游戏文件缺失 / 损坏。
 *
 * 2026-07-30 收紧：原实现把裸字符串 `no such file or directory` 也当判据，太泛。
 *   真机上 OHOS 没有旁白语音库，每局都会出现
 *   `libflite.so: No such file or directory`（4 处），于是健康会话被诊断成
 *   「游戏文件缺失或损坏」并建议用户**删除版本重新下载** —— 破坏性误导。
 *
 * 现在的判据：
 *   - Java 的 NoSuchFileException / FileNotFoundException 保留（强信号，且这两个
 *     异常在 native 库加载失败时不会抛）；
 *   - 裸 `no such file or directory` 必须**同时**指向游戏资产（.jar / assets/ /
 *     libraries/ / versions/），且该行不是 native 库（.so）加载失败。
 */
function matchMissingFile(combined: string): boolean {
  if (combined.indexOf('nosuchfileexception') >= 0) return true;
  if (combined.indexOf('filenotfoundexception') >= 0) return true;
  return matchRawMissingFile(combined);
}

/** 逐行判断裸 "no such file or directory" 是否真的指向游戏资产。 */
function matchRawMissingFile(combined: string): boolean {
  let lines = combined.split('\n');
  for (let i = 0; i < lines.length; i++) {
    let line = lines[i];
    if (line.indexOf('no such file or directory') < 0) continue;
    // native 库加载失败不算「游戏文件缺失」（OHOS 缺 libflite 等属常态）
    if (line.indexOf('.so') >= 0) continue;
    // 必须指向游戏资产路径，否则可能是任意第三方库的探测失败
    let isGameAsset = line.indexOf('.jar') >= 0
      || line.indexOf('assets/') >= 0
      || line.indexOf('libraries/') >= 0
      || line.indexOf('versions/') >= 0;
    if (isGameAsset) return true;
  }
  return false;
}

function matchNativeCrash(combined: string): boolean {
  return combined.indexOf('sigsegv') >= 0
      || combined.indexOf('# a fatal error has been detected') >= 0
      || combined.indexOf('jvm crashed') >= 0;
}

/**
 * 运行时把 IPv6 判成"不可用"，导致填 IPv6 服务器地址连不上（表现常常像崩溃）。
 *
 * 成因（真机取证，见 `docs/refactor/JDK-IPv6施工记录.md`）：应用沙箱对
 * `/proc/net/if_inet6` 返回 EACCES，而 OpenJDK 的 `IPv6_supported()` 用"能不能读到
 * 这个文件的第一行"回答"本机有没有 IPv6" ⇒ `Net.isIPv6Available()` 恒 false ⇒
 * NIO 只建 IPv4-only channel ⇒ 遇到 `Inet6Address` 直接拒收。
 * AMCL 已在启动 JVM 时合成该文件修掉根因（CHANGELOG `1000571`），所以**现在还能命中
 * 这条规则的用户，绝大多数是在跑旧版启动器**——这决定了下面第一条建议是"更新"。
 *
 * 三种形态，前两种取决于 MC 走 NIO 还是传统 Socket，第三种是 MC 自己的二次异常：
 *   1. `java.nio.channels.UnsupportedAddressTypeException`，抛在 `sun.nio.ch.Net.checkAddress`。
 *      **message 为 null**，只有类名可匹配。MC / Netty 走的是这条。
 *   2. `java.net.SocketException: IPv6 protocol family unavailable`，抛在 `Net.connect0`。
 *      message 非空且自带结论。
 *   3. Minecraft `ConnectScreen` 拿形态 1 的异常去调 `getMessage().replaceAll(...)`，
 *      而 message 是 null ⇒ 二次 NPE。用户看到的往往**只有这一条**（形态 1 被
 *      `CompletableFuture` 吞掉，不一定进日志尾部）。
 *      单凭"getMessage() 为 null"不足以归因（别的 NPE 也长这样），所以要求叠加连接上下文。
 */
function matchIpv6Unsupported(combined: string): boolean {
  if (combined.indexOf('unsupportedaddresstypeexception') >= 0) return true;
  if (combined.indexOf('ipv6 protocol family unavailable') >= 0) return true;
  let nullMessageNpe = combined.indexOf('string.replaceall') >= 0
      && combined.indexOf('getmessage()') >= 0
      && combined.indexOf('is null') >= 0;
  if (!nullMessageNpe) return false;
  return combined.indexOf('connectscreen') >= 0
      || combined.indexOf('screens.connect') >= 0
      || combined.indexOf('connecting to') >= 0;
}

function matchLaunchArg(combined: string): boolean {
  // module not found / access denied 经常是启动参数 / classloader 配置问题
  return combined.indexOf('module not found') >= 0
      || combined.indexOf('add-opens') >= 0 && combined.indexOf('inaccessibleobjectexception') >= 0;
}

// ============================================================
//  分类构造（每个 category 一个 build 函数）
// ============================================================

// ----------- JDK 版本不匹配 -----------

function buildJdkVersionDiagnosis(logTail: string, mcVersion: string): McDiagnosis {
  // 提取 class file version X 和 runtime version Y
  let classVer = extractClassVersion(logTail);
  let runtimeVer = extractRuntimeVersion(logTail);
  let neededJava = classVerToJava(classVer);
  let currentJava = classVerToJava(runtimeVer);

  let techDetail = 'UnsupportedClassVersionError';
  if (classVer > 0 && runtimeVer > 0) {
    techDetail += ' (class v' + classVer + ' vs runtime v' + runtimeVer + ')';
  }

  let description = '此版本的 Minecraft（' + extractShortVersion(mcVersion) + '）'
    + '是用 Java ' + (neededJava > 0 ? neededJava.toString() : '更新版本')
    + ' 编译的，但本次启动用的是 Java ' + (currentJava > 0 ? currentJava.toString() : '较旧版本')
    + '。旧版 Java 无法读取新版 Java 编译的程序文件，因此游戏启动时崩溃。'
    + '请在"设置 / JDK 管理"里切换到匹配的 Java 版本后重试。';

  // 按 MC 实际需要的 Java 版本推荐对应 JDK（AMCL 已上线 17 / 21 / 25）。
  let neededJdkLabel = neededJava >= 25 ? '25'
    : neededJava >= 21 ? '21'
    : neededJava >= 17 ? '17'
    : '17';
  let recTitle = '切换到 JDK ' + neededJdkLabel + '（推荐）';
  let recDesc = 'Minecraft ' + extractShortVersion(mcVersion) + ' 需要 Java '
    + (neededJava > 0 ? neededJava.toString() : neededJdkLabel)
    + '。到"设置 → JDK 管理"选择并安装 JDK ' + neededJdkLabel
    + '（MC 26.1+ 用 25，1.20.5–1.21.x 用 21，1.20.4 及以下用 17），再启动。';

  return {
    category: 'jdk_version',
    title: '需要匹配的 Java 版本',
    description,
    techDetail,
    errorKind: 'UnsupportedClassVersionError',
    primaryActionLabel: '打开 JDK 管理',
    primaryActionKey: 'open_jdk_manager',
    suggestions: [
      {
        title: recTitle,
        desc: recDesc,
        recommended: true,
        actionKey: 'open_jdk_manager',
      },
      {
        title: '确认版本路由',
        desc: 'AMCL 默认按 MC 版本自动选 JDK（26.1+ → 25，1.20.5+ → 21，更早 → 17）。'
          + '如果你在「设置」或「版本管理 → 版本详情 → Java 运行时」里为该版本手动指定了 JDK，请改回"自动"或选对版本。',
        recommended: false,
        actionKey: 'open_jdk_manager',
      },
      {
        title: '检查版本元数据',
        desc: '如果你认为这个版本不该需要更新的 Java，请重新下载版本元数据（版本列表右上角 ↻ 刷新）后再试。',
        recommended: false,
        actionKey: 'open_versions',
      },
    ],
  };
}

// ----------- Fabric/Quilt 报告的 Java 版本过低 -----------

/**
 * Fabric 的 "requires version N or later of 'OpenJDK ... (java)'" → JDK 版本过低。
 * 从日志抽出需要的 Java 版本与当前 Java 版本，给"切到更高 JDK / 改回自动"建议。
 * 复用 jdk_version 类别（McErrorSheet 已映射为 Java 图标）。
 */
function buildFabricJavaReqDiagnosis(logTail: string, mcVersion: string): McDiagnosis {
  let need = 0;
  let have = 0;
  let mNeed = logTail.match(/version (\d+) or later of/i);
  if (mNeed) need = parseInt(mNeed[1], 10);
  let mHave = logTail.match(/wrong version is present:?\s*(\d+)/i);
  if (mHave) have = parseInt(mHave[1], 10);
  if (have === 0) {
    let mHave2 = logTail.match(/\(java\)\s*(\d+)\s*with version/i);
    if (mHave2) have = parseInt(mHave2[1], 10);
  }

  let recVer = need > 0 ? need.toString() : (recommendJdkForMc(mcVersion) || '25');
  let shortVer = extractShortVersion(mcVersion);
  let needLabel = need > 0 ? ('Java ' + need) : ('Java ' + recVer);
  let haveLabel = have > 0 ? ('Java ' + have) : '更低版本的 Java';

  let description = '此版本（' + shortVer + '，含 Fabric / 模组）要求 ' + needLabel
    + ' 或更高，但本次启动用的是 ' + haveLabel
    + '。Fabric 在加载阶段检测到 Java 版本过低而中止（它会把这报成"模组不兼容"，实际是 JDK 版本问题）。'
    + '改用匹配的 Java 版本后即可启动。';

  return {
    category: 'jdk_version',
    title: 'Java 版本过低',
    description,
    techDetail: 'Fabric 要求 Java ≥ ' + (need > 0 ? need.toString() : recVer)
      + (have > 0 ? ('，当前 Java ' + have) : ''),
    errorKind: 'Java Version Too Low',
    primaryActionLabel: '打开 JDK 管理',
    primaryActionKey: 'open_jdk_manager',
    suggestions: [
      {
        title: '切换到 JDK ' + recVer + '（推荐）',
        desc: '到"设置 → JDK 管理"安装并切换到 JDK ' + recVer + '；'
          + '若是在「版本详情 → Java 运行时」为该版本强制指定了更低的 JDK，请改回"自动"。',
        recommended: true,
        actionKey: 'open_jdk_manager',
      },
      {
        title: '改回自动选择',
        desc: 'AMCL 默认按版本自动选 JDK（26.1+ → 25）。把该版本的单版本 JDK 选择改回"自动"，'
          + '即可让它用上匹配的 Java 版本。',
        recommended: false,
        actionKey: 'open_jdk_manager',
      },
      {
        title: '仍失败则反馈日志',
        desc: '切换 JDK 后若仍报错，点下方"上传日志"反馈给开发者。',
        recommended: false,
        actionKey: 'copy_log',
      },
    ],
  };
}

// ----------- LWJGL 模块缺失 -----------

/**
 * Java 类已经明确缺失，说明 AMCL 的 OHOS LWJGL 交付没有覆盖游戏所需模块。
 * `lwjgl-spng` 是 26.3-pre-1 首次启动时 eager-load 的已知实例；它不能靠重下 Minecraft、
 * 删除模组或换一个游戏版本修好，也不能只放一个 Java 空壳绕过。
 */
function buildLwjglModuleMissingDiagnosis(missingClass: string, mcVersion: string): McDiagnosis {
  let shortVer = extractShortVersion(mcVersion);
  let isSpng = missingClass.indexOf('org.lwjgl.util.spng.') === 0;
  let moduleName = isSpng ? 'lwjgl-spng' : '对应的 LWJGL Java 模块';
  let deliveryDetail = isSpng
    ? 'AMCL 需要同时交付 lwjgl-spng.jar 与 OHOS aarch64 的 liblwjgl_spng.so。'
    : 'AMCL 需要随 OHOS LWJGL 运行时交付包含该类的 Java 模块及其配套 native。';

  return {
    category: 'lwjgl_module_missing',
    title: '缺少 LWJGL 运行时模块',
    description: '该版本（' + shortVer + '）启动时需要 ' + moduleName + '，但当前 AMCL 随应用交付的'
      + '鸿蒙 LWJGL 运行时里没有 ' + missingClass + '，所以游戏在创建窗口和渲染器之前就停止了。'
      + '这是 AMCL 的运行时交付缺口，不是游戏文件损坏、模组冲突或你的操作导致。'
      + '请更新 AMCL 到包含完整 SPNG 运行时的版本后重试；如果已经是最新版，请上传完整日志。',
    techDetail: 'NoClassDefFoundError: ' + missingClass + '（缺少 ' + moduleName + '）',
    errorKind: isSpng ? 'LWJGLSpngMissing' : 'LWJGLClassMissing',
    primaryActionLabel: '知道了',
    primaryActionKey: null,
    suggestions: [
      {
        title: '更新 AMCL 到包含该模块的版本（推荐）',
        desc: deliveryDetail + ' 安装包含完整运行时的 AMCL 版本后再启动。',
        recommended: true,
        actionKey: null,
      },
      {
        title: '不用重下游戏或删除模组',
        desc: '缺的是 AMCL 自带的鸿蒙运行时，不在 Minecraft 版本目录或模组目录里。'
          + '重新下载游戏、删除模组或来回切换游戏版本都不会补上这个模块。',
        recommended: false,
        actionKey: null,
      },
      {
        title: '更新后仍失败则上传日志',
        desc: '如果已经安装了包含该模块的 AMCL 版本仍出现同类错误，请上传完整日志给开发者核对交付产物。',
        recommended: false,
        actionKey: 'copy_log',
      },
    ],
  };
}

// ----------- LWJGL 版本不匹配 -----------
/**
 * 区分两种 LWJGL 不匹配形态，给不同建议：
 *   - Sodium/Iris 硬校验 → 引导核对触发精确校验的模组版本；
 *   - 缺方法/字段 → 只能确定调用方与本次选中的兼容槽 API 面不一致。AMCL 已有现代、3.2.3
 *     与 LWJGL2 三槽，不能再把这类错误一律解释为“旧 MC 等待多版本能力”。
 */
function buildLwjglVersionDiagnosis(logTail: string, mcVersion: string): McDiagnosis {
  let low = logTail.toLowerCase();
  let isModCheck = low.indexOf('lwjgl version is not compatible') >= 0
    || low.indexOf('currently active lwjgl version') >= 0;
  let isFieldError = low.indexOf('nosuchfielderror') >= 0;
  let shortVer = extractShortVersion(mcVersion);

  // 尝试抓出被调用的缺失方法名（如 GLFWImage.mallocStack），放进技术详情。
  let missingSym = '';
  let m = logTail.match(/NoSuchMethodError:\s*'?([^\n']+)'?/);
  if (m && m[1]) missingSym = m[1].trim();

  if (isModCheck) {
    return {
      category: 'lwjgl_version',
      title: 'LWJGL 版本被模组拒绝',
      description: 'Sodium / Iris 等模组会精确校验 LWJGL 版本，与游戏自带版本不一致时（即使更高也）'
        + '拒绝启动。AMCL 在鸿蒙上使用为 GPU 适配定制的 LWJGL（org.lwjgl '
        + LWJGL_MODERN_VERSION + '），'
        + '与该模组编译时锁定的版本不同，于是被拦下。',
      techDetail: 'LWJGL version check failed (Sodium/Iris issue2561)',
      errorKind: 'LWJGL Version Incompatible',
      primaryActionLabel: '打开模组管理',
      primaryActionKey: 'open_mod_list',
      suggestions: [
        {
          title: '移除或更换该模组（推荐）',
          desc: '在模组管理里禁用触发校验的 Sodium / Iris，或换用与当前游戏版本匹配的对应版本后再启动。',
          recommended: true,
          actionKey: 'open_mod_list',
        },
        {
          title: '改用更新的游戏版本',
          desc: '较新的 MC（1.19+）与 AMCL 打包的 LWJGL 同代，配套的 Sodium/Iris 校验更易通过。',
          recommended: false,
          actionKey: 'open_versions',
        },
        {
          title: '仍失败则反馈日志',
          desc: 'AMCL 后续将提供按版本匹配 LWJGL 的能力。若以上都不行，点下方"上传日志"反馈给开发者。',
          recommended: false,
          actionKey: 'copy_log',
        },
      ],
    };
  }

  // API 成员缺失。NoSuchFieldError 没有方法签名可提取，必须保留它自己的真实异常类型；
  // jar↔native 自检已从匹配规则移除，不能再拿它当兜底技术详情。
  let techDetail = missingSym.length > 0
    ? 'NoSuchMethodError: ' + missingSym + '（org.lwjgl，版本面不匹配）'
    : isFieldError
      ? 'NoSuchFieldError（org.lwjgl，API 版本面不匹配）'
      : 'LWJGL API 版本面不匹配';

  return {
    category: 'lwjgl_version',
    title: 'LWJGL 版本不兼容',
    description: '该版本（' + shortVer + '）中的游戏或模组调用了本次选中 LWJGL 兼容槽里不存在的'
      + '方法或字段，因此在初始化阶段停止。AMCL 已按游戏依赖在现代槽（'
      + LWJGL_MODERN_VERSION + '）、3.2.3 槽与 LWJGL2 槽之间路由；仅凭这条异常不能确定'
      + '应该切换 Minecraft 版本。请上传完整日志，以核对实际槽位、版本元数据'
      + '以及是否由某个模组引用了不匹配的 LWJGL API。',
    techDetail,
    errorKind: 'LWJGL Version Incompatible',
    primaryActionLabel: '上传日志',
    primaryActionKey: 'copy_log',
    suggestions: [
      {
        title: '上传完整日志（推荐）',
        desc: '完整日志可以确认本次实际选择了哪个 LWJGL 槽，并区分游戏元数据、启动路由与模组 API 不匹配。',
        recommended: true,
        actionKey: 'copy_log',
      },
      {
        title: '核对游戏与模组版本',
        desc: '如果日志中的缺失成员来自某个模组，请确认该模组明确支持当前 Minecraft 版本。'
          + '不要仅凭这条异常删除游戏版本或切换到一个固定的 MC 代际。',
        recommended: false,
        actionKey: 'open_mod_list',
      },
      {
        title: '检查版本元数据与运行时槽位',
        desc: '若未安装模组，完整日志可帮助开发者判断 version.json 声明与 LWJGL 槽路由是否存在未覆盖边界。',
        recommended: false,
        actionKey: null,
      },
    ],
  };
}

// ----------- 内存不足 -----------

function buildOomDiagnosis(): McDiagnosis {
  return {
    category: 'oom',
    title: '内存不足',
    description: '游戏运行时申请的内存超过了 JVM 分配的最大堆。常见原因是模组数量过多、'
      + '世界数据过大或者启动时分配的内存不够。',
    techDetail: 'java.lang.OutOfMemoryError: Java heap space',
    errorKind: 'OutOfMemoryError',
    primaryActionLabel: '打开内存设置',
    primaryActionKey: 'open_memory_settings',
    suggestions: [
      {
        title: '增大游戏内存上限（推荐）',
        desc: '到"设置 → 启动配置 → 最大内存"调高到 2048 MB 或 3072 MB，重启游戏。',
        recommended: true,
        actionKey: 'open_memory_settings',
      },
      {
        title: '禁用部分模组',
        desc: '如果你装了多个大型模组（地形生成 / Shader 等），尝试在模组列表里禁用几个再启动。',
        recommended: false,
        actionKey: 'open_mod_list',
      },
      {
        title: '重启系统释放内存',
        desc: '后台进程占用了过多内存时也可能触发此错误。完全退出 AMCL 和其他应用后重试。',
        recommended: false,
        actionKey: null,
      },
    ],
  };
}

// ----------- Mod 冲突 -----------

function buildModConflictDiagnosis(summary: string): McDiagnosis {
  return {
    category: 'mod_conflict',
    title: '模组冲突或缺失依赖',
    description: 'Fabric / Forge 检测到模组之间存在不兼容依赖，或者某个模组要求的版本范围与游戏版本冲突，'
      + '因此拒绝启动以保护存档。',
    techDetail: summary.length > 0 ? summary : 'Mod resolution failed',
    errorKind: 'ModResolutionException',
    primaryActionLabel: '打开模组管理',
    primaryActionKey: 'open_mod_list',
    suggestions: [
      {
        title: '查看冲突详情（推荐）',
        desc: '展开下方"技术详情"，看 Fabric 报的"requires" / "depends on"等关键字，'
          + '据此在模组管理里禁用冲突的模组。',
        recommended: true,
        actionKey: 'open_mod_list',
      },
      {
        title: '更新到匹配版本',
        desc: '如果是版本不匹配，到模组浏览页面下载与你的 MC 版本兼容的最新版本。',
        recommended: false,
        actionKey: 'open_mod_browse',
      },
      {
        title: '安装缺失依赖',
        desc: '某些模组依赖 Fabric API / Architectury 等。错误日志会列出 "Missing dependency: xxx"。',
        recommended: false,
        actionKey: 'open_mod_browse',
      },
    ],
  };
}

// ----------- MIXIN apply 失败 -----------

function buildMixinDiagnosis(summary: string): McDiagnosis {
  return {
    category: 'mixin_apply',
    title: '模组代码注入失败',
    description: '某个模组试图通过 MIXIN 修改游戏类，但目标方法/字段在当前 MC 版本里已不存在或被改名。'
      + '通常是该模组的版本与游戏版本不兼容。',
    techDetail: summary.length > 0 ? summary : 'MIXIN apply failed',
    errorKind: 'MixinApplyError',
    primaryActionLabel: '打开模组管理',
    primaryActionKey: 'open_mod_list',
    suggestions: [
      {
        title: '禁用引发错误的模组（推荐）',
        desc: '展开"技术详情"找 "Mixin apply for mod XXX failed" 字样，'
          + '在模组管理里把该模组禁用或删除。',
        recommended: true,
        actionKey: 'open_mod_list',
      },
      {
        title: '更新到匹配 MC 版本的模组',
        desc: '到模组浏览页找该模组的新版本（确保支持当前 MC 版本）。',
        recommended: false,
        actionKey: 'open_mod_browse',
      },
    ],
  };
}

// ----------- JDK 运行时不兼容（JDK 过新 / 模块不匹配） -----------

/**
 * 按 MC 版本纪元推荐 JDK 主版本号，复用 McVersionUtils 单一事实源
 * （extractGameVersionFromId 先把 "fabric-...-26.1.1" 归一化成真实 MC 版本）。
 * 返回 '25' / '21' / '17'；无法判定（快照等）返回 ''。
 */
function recommendJdkForMc(mcVersion: string): string {
  let mc = extractGameVersionFromId(mcVersion);
  let era = detectMcEra(mc);
  if (era === McEra.YEARLY) return '25';
  if (era === McEra.CLASSIC) return isMcVersionAtLeast(mc, JDK21_MIN_MC_VERSION) ? '21' : '17';
  return '';
}

function buildJdkRuntimeDiagnosis(mcVersion: string): McDiagnosis {
  let rec = recommendJdkForMc(mcVersion);
  let shortVer = extractShortVersion(mcVersion);
  let recPhrase = rec.length > 0
    ? '这个版本（' + shortVer + '）建议使用 JDK ' + rec + '。'
    : '请按版本规则选择匹配的 JDK（MC 26.1+ → 25，1.20.5–1.21.x → 21，1.20.4 及以下 → 17）。';

  let description = 'Java 运行时与该版本不兼容：游戏用到的某些接口在当前 Java 版本里不存在或已被移除。'
    + '常见于自动选择的 JDK 与版本不匹配——尤其旧版 MC 配了过新的 Java（反之亦然）。'
    + recPhrase + '到"设置 → JDK 管理"切换匹配的 Java 版本后重试。';

  let recDesc = (rec.length > 0
      ? '到"设置 → JDK 管理"安装并切换到 JDK ' + rec + '，再启动。'
      : '到"设置 → JDK 管理"按版本规则切换 JDK 后再启动。')
    + '注意：较旧的 MC（如 1.16 及更早）在过新的 JDK 上可能跑不起来，要选更低版本的 Java。';

  return {
    category: 'jdk_runtime',
    title: 'Java 版本不兼容',
    description,
    techDetail: 'JDK runtime incompatible（removed API / module mismatch）',
    errorKind: 'JDK Runtime Incompatible',
    primaryActionLabel: '打开 JDK 管理',
    primaryActionKey: 'open_jdk_manager',
    suggestions: [
      {
        title: rec.length > 0 ? '切换到 JDK ' + rec + '（推荐）' : '切换到匹配的 JDK（推荐）',
        desc: recDesc,
        recommended: true,
        actionKey: 'open_jdk_manager',
      },
      {
        title: '切回自动选择',
        desc: 'AMCL 默认按版本自动选 JDK。如果你在「设置」或「版本详情 → Java 运行时」里手动锁定了某个 JDK 版本，'
          + '把它改回"自动"，避免旧版本被塞进过新的 Java（或反之）。',
        recommended: false,
        actionKey: 'open_jdk_manager',
      },
      {
        title: '切换 / 仍崩溃则反馈日志',
        desc: '若切换 JDK 后仍崩溃，可能是版本路由或某个原生模组的问题，点击下方"复制"把完整日志贴给开发者。',
        recommended: false,
        actionKey: 'copy_log',
      },
    ],
  };
}

// ----------- 文件缺失 -----------

function buildMissingFileDiagnosis(summary: string): McDiagnosis {
  return {
    category: 'missing_file',
    title: '游戏文件缺失或损坏',
    description: '启动时游戏找不到某个必要的文件（jar / asset / library）。可能是下载未完成、'
      + '存储空间不足或文件被意外删除。',
    techDetail: summary.length > 0 ? summary : 'NoSuchFileException',
    errorKind: 'NoSuchFileException',
    primaryActionLabel: '重新下载该版本',
    primaryActionKey: 'redownload',
    suggestions: [
      {
        title: '重新下载该版本（推荐）',
        desc: '到版本管理里删除该版本，然后从版本列表重新下载，下载引擎会自动补齐所有缺失文件。',
        recommended: true,
        actionKey: 'redownload',
      },
      {
        title: '检查存储空间',
        desc: '到系统设置查看可用空间，建议至少保留 500 MB 才安全启动 MC。',
        recommended: false,
        actionKey: null,
      },
    ],
  };
}

// ----------- 原生崩溃 (SIGSEGV) -----------

function buildNativeCrashDiagnosis(): McDiagnosis {
  return {
    category: 'native_crash',
    title: 'JVM 原生崩溃',
    description: 'JVM 在执行游戏代码时收到 SIGSEGV 或 fatal error，通常由不兼容的原生模组（含 .so 文件）'
      + '或 OpenGL 驱动问题引发。',
    techDetail: 'SIGSEGV in native code',
    errorKind: 'NativeCrash',
    primaryActionLabel: '打开模组管理',
    primaryActionKey: 'open_mod_list',
    suggestions: [
      {
        title: '禁用所有原生模组（推荐）',
        desc: '把含 .so / DLL 的模组（如旧版 Sodium / iris）暂时禁用，定位是哪个模组导致崩溃。',
        recommended: true,
        actionKey: 'open_mod_list',
      },
      {
        title: '关闭 Shader',
        desc: '到游戏内"选项 → 视频设置 → Shader 包"切回 (none)，'
          + '部分 Shader 在 OHOS GPU 上不稳定。',
        recommended: false,
        actionKey: null,
      },
    ],
  };
}

// ----------- 启动参数 / 模块问题 -----------

function buildLaunchArgDiagnosis(summary: string): McDiagnosis {
  return {
    category: 'launch_arg',
    title: '启动参数配置错误',
    description: 'JVM 启动时缺少必要的 --add-opens / --add-exports 参数，或者某个模块无法加载。'
      + '通常是 AMCL 启动配置的问题，不是用户操作引起。',
    techDetail: summary.length > 0 ? summary : 'Module / access denied',
    errorKind: 'InaccessibleObjectException',
    primaryActionLabel: '复制日志反馈开发者',
    primaryActionKey: 'copy_log',
    suggestions: [
      {
        title: '复制日志反馈开发者（推荐）',
        desc: '这通常需要 AMCL 修改启动脚本。点击下方"复制"把完整日志贴给开发者。',
        recommended: true,
        actionKey: 'copy_log',
      },
      {
        title: '尝试其他版本',
        desc: '部分版本（特别是 snapshot / preview）依赖未公开的 JDK 模块，先试 release 版本。',
        recommended: false,
        actionKey: 'open_versions',
      },
    ],
  };
}

// ----------- Fabric 定位不到游戏本体 -----------

/**
 * 成因是启动器一侧的类路径传递缺陷（详见 matchFabricGameProvider）。
 *
 * ⚠️ **第二条建议是刻意写的"不要做什么"。** 这条错误的措辞里有 "The game may be absent
 * from the class path, ... suffers from jar corruption"，用户（和上一版的分类器兜底）
 * 很自然会理解成"版本文件坏了，删掉重下"。而真实情况是版本 jar 完好无损 —— 重下要花掉
 * 几百 MB 流量且结果一模一样。把这句反向指引留在建议里，比只说该做什么更有用。
 *
 * 图标：沿用 IPv6 那条的先例，McErrorSheet 的 heroIconName 没有本类专属图标，
 * 会落到 Warning 兜底。为一条分类改图标目录属于另一件事，不在本次范围内。
 */
function buildFabricGameProviderDiagnosis(summary: string): McDiagnosis {
  return {
    category: 'fabric_game_missing',
    title: 'Fabric 找不到游戏本体',
    description: 'Fabric 的加载器在启动最早期要先找到 Minecraft 本体，这一步失败了。'
      + '原因在启动器传给 Fabric 的类路径，不是你的版本文件损坏，也和装了哪些模组无关'
      + '（这一步发生在读取模组之前）。请更新 AMCL 到已修复的版本。',
    techDetail: summary.length > 0
      ? summary
      : "Fabric Knot: Minecraft game provider couldn't locate the game",
    errorKind: 'FabricGameProviderMissing',
    primaryActionLabel: '知道了',
    primaryActionKey: null,
    suggestions: [
      {
        title: '更新 AMCL 到最新版（推荐）',
        desc: '新版修好了根因：启动器现在会把完整的游戏类路径交给 Fabric 的库分类器，'
          + 'Fabric 因此能正常找到游戏本体。到「设置 → 检查更新」升级后重试。',
        recommended: true,
        actionKey: null,
      },
      {
        title: '不用删版本重新下载',
        desc: '这条错误的英文原文提到了"jar 损坏 / 游戏不在类路径上"，看起来像文件坏了，'
          + '但实际上版本 jar 是完好的 —— 问题出在启动参数。删掉重下会白花几百 MB 流量，'
          + '结果不会有任何变化。同理也不用去动模组。',
        recommended: false,
        actionKey: null,
      },
      {
        title: '已经是最新版还报这个？',
        desc: '那可能是另一条路径上的同类问题（例如某个加载器版本走了不同的定位方式）。'
          + '点下方"复制"把完整日志发给开发者，日志里的 [AMCL-FABRIC] 与 '
          + '[FabricLoader/GameProvider] 两行是定位关键。',
        recommended: false,
        actionKey: 'copy_log',
      },
    ],
  };
}

// ----------- Forge 新 bootstrap 拿不到游戏 classpath -----------

/**
 * 与 buildFabricGameProviderDiagnosis 是同一根因的两个出口，文案刻意保持同构：
 * 都要先否掉"文件坏了 / 模组坏了"这两个用户最容易自己做出的错误结论。
 *
 * 第三条建议给的是**用户能自己产出的**两份日志里的字面量：
 * `AMCL_LOADER_GENERATION` / `AMCL_LAUNCH_CONTRACT` 在 `logs/amcl_launcher.log`，
 * `[AMCL-CP-DELIVERY]` 在版本目录的 `mc_output.log`。
 * ⚠️ 方案原文写的是 `[AMCL-CP-OWNERSHIP]`，那一行只进 hilog（native 侧打的），
 * 用户上传的日志里根本没有它 —— 换成上面这三个字面量，见施工记录 §S07.2。
 */
function buildForgeBootClasspathDiagnosis(summary: string): McDiagnosis {
  return {
    category: 'forge_boot_classpath',
    title: 'Forge 拿不到游戏本体',
    description: 'Forge（1.20.2 及更新版本）在启动最早期要先用游戏的类路径搭出模块层，'
      + '这一步拿到的是空的，于是进程在一秒内退出。原因在启动器交给 Forge 的类路径，'
      + '不是你的版本文件损坏，也和装了哪些模组无关（这一步发生在读取模组之前，'
      + '所以连 Minecraft 自己的崩溃报告都不会生成）。请更新 AMCL 到已修复的版本。',
    techDetail: summary.length > 0
      ? summary
      : 'NoSuchElementException @ Bootstrap.bootstrapMain（模块层为空 —— '
        + 'java.class.path 里没有游戏 classpath）',
    errorKind: 'ForgeBootstrapClasspathMissing',
    primaryActionLabel: '知道了',
    primaryActionKey: null,
    suggestions: [
      {
        title: '更新 AMCL 到最新版（推荐）',
        desc: '新版按加载器世代决定类路径的交付方式：Forge 1.20.2+ 会拿到完整的 '
          + 'java.class.path（这也是桌面端官方启动器的做法），模块层因此能正常建起来。'
          + '到「设置 → 检查更新」升级后重试。',
        recommended: true,
        actionKey: null,
      },
      {
        title: '不用删版本重新下载，也不用动模组',
        desc: '这类崩溃里版本 jar、依赖库、模组、JDK 全都是好的 —— 缺的只是"把它们告诉 '
          + 'Forge"这一步。删掉重下会白花几百 MB 流量，结果不会有任何变化；'
          + '删模组同样无效，因为崩溃发生在模组被读取之前。',
        recommended: false,
        actionKey: null,
      },
      {
        title: '已经是最新版还报这个？',
        desc: '点下方"复制"把完整日志发给开发者。定位关键是三行：'
          + 'logs/amcl_launcher.log 里的 AMCL_LOADER_GENERATION 与 AMCL_LAUNCH_CONTRACT'
          + '（它们写明本次判成了哪个加载器世代、用了哪种交付方式），'
          + '以及版本目录 mc_output.log 里的 [AMCL-CP-DELIVERY]（JVM 里的实际值）。',
        recommended: false,
        actionKey: 'copy_log',
      },
    ],
  };
}

// ----------- IPv6 地址族不可用 -----------

/**
 * @param combined 已小写化的 summary + logTail，用来区分三种形态
 *
 * errorKind 按形态分开给，不合并成一个值：这条记录会进活动记录并作为上传日志的 meta，
 * 合并之后"到了真机就查不下去"（AGENTS §二.9）。
 *
 * 图标：McErrorSheet 的 heroIconName 里没有网络类图标，会落到 Warning 兜底。
 * 这是刻意的——为一条分类改图标目录属于另一件事，不在本次范围内。
 */
function buildIpv6UnsupportedDiagnosis(combined: string): McDiagnosis {
  let errorKind = 'UnsupportedAddressTypeException';
  let techDetail = 'UnsupportedAddressTypeException（NIO 通道是 IPv4-only，拒收 Inet6Address）';
  if (combined.indexOf('ipv6 protocol family unavailable') >= 0) {
    errorKind = 'SocketException';
    techDetail = 'SocketException: IPv6 protocol family unavailable';
  } else if (combined.indexOf('unsupportedaddresstypeexception') < 0) {
    // 只抓到 MC 的二次 NPE：真正的地址族异常被 CompletableFuture 吞掉了，没进日志尾部。
    errorKind = 'NullPointerException';
    techDetail = 'ConnectScreen NPE（异常 message 为 null，根因在 IPv6 地址族不可用）';
  }

  return {
    category: 'ipv6_unsupported',
    title: '连不上 IPv6 服务器',
    description: '当前运行时把"本机有没有 IPv6"判成了没有，于是网络层只建立 IPv4 通道，'
      + '一遇到 IPv6 地址就直接拒收——它抛出的异常还不带说明文字，Minecraft 拿去拼提示语时'
      + '会再崩一次，所以看起来像游戏闪退。这是启动器一侧的问题，不是你的服务器或网络配置错了。',
    techDetail: techDetail,
    errorKind: errorKind,
    primaryActionLabel: '知道了',
    primaryActionKey: null,
    suggestions: [
      {
        title: '更新 AMCL 到最新版（推荐）',
        desc: '新版已修好根因：鸿蒙的应用沙箱不让读 /proc/net/if_inet6，而 Java 恰好用'
          + '"能不能读到这个文件"来回答"本机有没有 IPv6"。新版会在启动 Java 时按内核格式'
          + '补上这个文件，IPv6 随之可用。',
        recommended: true,
        actionKey: null,
      },
      {
        title: '暂时先用 IPv4 地址连',
        desc: '让服务器方给一个 IPv4 地址，或改用解析到 IPv4 的域名。IPv4 通道一直是正常的，'
          + '受影响的只有 IPv6。',
        recommended: false,
        actionKey: null,
      },
      {
        title: '填 IPv6 地址要带方括号',
        desc: '在 Minecraft 的"直接连接"里，IPv6 地址必须写成 [2001:db8::1]:25565 —— '
          + '方括号包住地址，端口写在括号外面。不加方括号会被当成域名去解析，报的是另一种错。'
          + '（这个输入框是 Minecraft 自己的界面，AMCL 无法代为纠正写法。）',
        recommended: false,
        actionKey: null,
      },
      {
        title: '已经是最新版还报这个？',
        desc: '那说明这台设备当前确实没拿到可用的 IPv6 地址——AMCL 只在真的探测到 IPv6 地址时'
          + '才补那个文件，不会伪造一个不存在的能力。先确认 Wi-Fi / 移动网络已分配 IPv6，'
          + '再点下方"复制"把日志发给开发者。',
        recommended: false,
        actionKey: 'copy_log',
      },
    ],
  };
}

// ----------- 无可归因错误（不是崩溃） -----------

/**
 * 日志里找不到任何可归因的错误。
 *
 * 典型场景：用户从多任务列表划掉了 app、系统因内存压力回收了进程、或玩家正常退出
 * 但关闭标记被后续输出挤出了日志尾部。这些都**不是故障**，不能给用户任何
 * 「修复建议」——尤其不能建议换版本或重下版本。
 */
function buildNotDiagnosableDiagnosis(): McDiagnosis {
  return {
    category: 'not_diagnosable',
    title: '上次游戏已结束',
    description: '日志里没有发现崩溃或错误。这通常意味着游戏被正常关闭，或者进程被系统 / '
      + '从多任务列表结束（此时不会留下关闭记录）。如果你确实遇到了问题，可以展开下方'
      + '「技术详情」查看完整日志，或上传日志请开发者协助。',
    techDetail: '未在日志中发现错误信号',
    errorKind: 'None',
    primaryActionLabel: '知道了',
    primaryActionKey: null,
    suggestions: [
      {
        title: '无需处理',
        desc: '本次没有检测到故障。直接再次启动游戏即可。',
        recommended: true,
        actionKey: null,
      },
      {
        title: '仍然觉得有问题？',
        desc: '点下方「上传日志」把完整日志发给开发者，或用「分析日志」看看第三方工具的判断。',
        recommended: false,
        actionKey: 'copy_log',
      },
    ],
  };
}

// ----------- 通用未知 -----------

function buildUnknownDiagnosis(summary: string): McDiagnosis {
  return {
    category: 'unknown',
    title: '游戏意外退出',
    description: '从日志中没有识别出特定错误模式。展开下方"技术详情"看完整堆栈，'
      + '复制日志后向开发者反馈可加快问题定位。',
    techDetail: summary.length > 0 ? summary : '未知错误',
    errorKind: 'Unknown',
    primaryActionLabel: '复制日志',
    primaryActionKey: 'copy_log',
    suggestions: [
      {
        title: '复制日志反馈',
        desc: '点击下方"复制"按钮，把日志贴到开发者群或 issue。',
        recommended: true,
        actionKey: 'copy_log',
      },
      {
        title: '重试启动',
        desc: '某些瞬时问题（如临时文件冲突）重启游戏即可。',
        recommended: false,
        actionKey: null,
      },
    ],
  };
}

// ============================================================
//  辅助：解析 class file version / 运行时 version / mc 简短版本号
// ============================================================

/** 从 logTail 提取 "class file version X.Y" 中的 major version 数字。 */
function extractClassVersion(logTail: string): number {
  let m = logTail.match(/class file version (\d+)\.(\d+)/);
  if (m) {
    let n = parseInt(m[1], 10);
    if (!isNaN(n)) return n;
  }
  return 0;
}

/** 从 logTail 提取 "recognizes class file versions up to X.Y" 中的 major version。 */
function extractRuntimeVersion(logTail: string): number {
  let m = logTail.match(/recognizes class file versions up to (\d+)\.(\d+)/);
  if (m) {
    let n = parseInt(m[1], 10);
    if (!isNaN(n)) return n;
  }
  return 0;
}

/**
 * class file version 转 Java 版本：
 *   45 = Java 1.1, 49 = Java 5, 52 = Java 8, 55 = Java 11,
 *   61 = Java 17, 65 = Java 21, 69 = Java 25 ...
 * 公式：javaVer = classVer - 44（Java 1.x 时代之后线性）
 */
function classVerToJava(classVer: number): number {
  if (classVer <= 0) return 0;
  if (classVer < 49) return 0;  // 1.x 时代，不在 MC 范围内
  return classVer - 44;
}

/**
 * 'fabric-loader-0.19.2-26.1' → '26.1'
 * 'forge-1.20.1-47.2.0'        → '1.20.1'
 * '1.21.10'                    → '1.21.10'
 */
function extractShortVersion(mcVersion: string): string {
  if (!mcVersion) return '此版本';
  // fabric-loader-X.Y.Z-MCVER
  let m = mcVersion.match(/fabric-loader-[\d.]+-(.+)$/);
  if (m) return m[1];
  // forge-MCVER-X.Y.Z
  m = mcVersion.match(/^forge-([\d.]+)-/);
  if (m) return m[1];
  return mcVersion;
}
