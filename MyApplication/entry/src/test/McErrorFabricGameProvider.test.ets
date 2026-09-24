/*
 * McErrorFabricGameProvider.test.ets — Fabric 定位不到游戏本体的分类
 *
 * ⭐ 这份测试存在的直接原因：**上一版分类器缺这条规则，而缺失的代价是零信息量 + 反向建议。**
 *
 * 2026-08-29 真机现场：Fabric（1.18.2 与 1.20.1 各两次）全部崩在
 *   Minecraft game provider couldn't locate the game!
 * 而分类器里没有任何规则认领它 ⇒ 一路落到 buildUnknownDiagnosis，用户看到的是
 * 「游戏意外退出 / 复制日志反馈」。门禁全绿、日志无告警、真机看不出差别 ——
 * 这正是 McErrorIpv6.test.ets 头部所说的「分类器的失效形态是静默退化」。
 *
 * 成因侧记（写在这里是为了让判据可复核，不是背景故事）：Fabric 的 Knot 只从
 * `java.class.path` 推导游戏查找路径，而启动器刻意把该属性收窄成只有自己的 jar
 * （游戏 classpath 改由 AmclClassLoader 持有，见 AmclLauncher.setupFabricGameLibraries
 * 的头注释）。所以这一类崩溃里**版本文件、模组、JDK 全都是好的**。
 *
 * 三类判定在这里同等重要：
 *   - **正向**：真机原文要归到 `fabric_game_missing`；
 *   - **抢占顺序**：lwjgl_module_missing / missing_file / mod_conflict 的判据形状都**能**吃掉它，
 *     会分别错报成“运行时少模块” / “版本文件损坏” / “模组冲突”；后两条还会让用户重下或删模组。
 *     顺序错了不报错，所以必须钉在这里；
 *   - **不许过宽**：只有 LWJGL 信号、没有 game-provider 原文时，不能被这条新规则截胡。
 *
 * 创建日期：2026-08-29
 */
import { describe, it, expect } from '@ohos/hypium';
import { classifyMcError, McDiagnosis, McSuggestion } from 'launch';

/**
 * 真机 mc_output.log 全文（2026-08-29 20:39，设备 59JYD25815201311，全文仅 2317 字节）。
 * 注意它**不含** org.lwjgl 符号，也不含 "no such file or directory" ——
 * 那次是一路落到兜底的，不是被别的规则抢走的。抢占用例在下面单独构造。
 */
const TAIL_REAL: string =
  '[AmclLauncher] Starting...\n'
  + '[AmclLauncher] Loading net.fabricmc.loader.impl.launch.knot.KnotClient...\n'
  + '[AMCL-CLASSLOADER] schema=1 phase=main-owner status=active '
  + 'main=net.fabricmc.loader.impl.launch.knot.KnotClient '
  + 'owner=com.amcl.launcher.AmclClassLoader game_urls=47\n'
  + '[12:39:44] [ERROR] [FabricLoader/GameProvider]: Minecraft game provider couldn\'t locate '
  + 'the game! The game may be absent from the class path, lacks some expected files, suffers '
  + 'from jar corruption or is of an unsupported variety/version.\n'
  + '[AmclLauncher] mainClass.main() threw: java.lang.reflect.InvocationTargetException\n'
  + 'Exception in thread "Thread-0" java.lang.reflect.InvocationTargetException\n'
  + '\tat java.base/java.lang.reflect.Method.invoke(Method.java:565)\n'
  + 'Caused by: java.lang.RuntimeException: Minecraft game provider couldn\'t locate the game! '
  + 'The game may be absent from the class path, lacks some expected files, suffers from jar '
  + 'corruption or is of an unsupported variety/version.\n'
  + '\tat net.fabricmc.loader.impl.launch.knot.Knot.createGameProvider(Knot.java:208)\n'
  + '\tat net.fabricmc.loader.impl.launch.knot.Knot.init(Knot.java:128)\n';

/** SessionMarker 抽出的摘要（真机 amcl_launcher.log 里的同一局）。 */
const SUMMARY_REAL: string =
  'java.lang.reflect.InvocationTargetException\n'
  + '  Caused by: java.lang.RuntimeException: Minecraft game provider couldn\'t locate the game! '
  + 'The game may be absent from the class path.';

/** 只有 Fabric 自己那条 ERROR 行（Caused by 被 32KB 尾部截掉的情形）。 */
const TAIL_FABRIC_LINE_ONLY: string =
  '[12:39:44] [ERROR] [FabricLoader/GameProvider]: Minecraft game provider couldn\'t locate '
  + 'the game! The game may be absent from the class path.\n';

/** 撇号变形（部分日志转写会把 ' 变成 ’）。兜底判据必须仍然命中。 */
const TAIL_CURLY_APOSTROPHE: string =
  '[12:39:44] [ERROR] [FabricLoader/GameProvider]: Minecraft game provider couldn\u2019t locate '
  + 'the game! The game may be absent from the class path.\n';

/** 纯 LWJGL 版本不匹配，**没有** game-provider 原文 ⇒ Fabric 与模块缺失规则都不许认领。 */
const TAIL_LWJGL_ONLY: string =
  '[10:12:01] [Render thread/ERROR]: Failed to create window\n'
  + 'java.lang.NoSuchMethodError: \'org.lwjgl.glfw.GLFWImage org.lwjgl.glfw.GLFWImage.mallocStack()\'\n'
  + '\tat net.minecraft.client.Minecraft.<init>(Minecraft.java:455)\n';

/** LWJGL 字段版本面不匹配，技术详情必须保留 NoSuchFieldError 身份。 */
const TAIL_LWJGL_FIELD_ONLY: string =
  '[10:12:01] [Render thread/ERROR]: Failed to initialize renderer\n'
  + 'java.lang.NoSuchFieldError: org.lwjgl.opengl.GL_FAKE_CAPABILITY\n'
  + '\tat com.example.RenderCompat.initialize(RenderCompat.java:42)\n';

/** 26.3-pre-1 双设备实测的首个阻断：AMCL 现代槽没有 lwjgl-spng Java/native。 */
const TAIL_LWJGL_SPNG_MISSING: string =
  '---- Minecraft Crash Report ----\n'
  + 'Description: Loading library SPNG\n\n'
  + 'java.lang.NoClassDefFoundError: org/lwjgl/util/spng/SPNG\n'
  + '\tat com.mojang.blaze3d.platform.NativeLibrariesBootstrap.loadSPNG(NativeLibrariesBootstrap.java:346)\n'
  + '\tat com.mojang.blaze3d.platform.NativeLibrariesBootstrap.loadLibraries(NativeLibrariesBootstrap.java:106)\n'
  + '\tat net.minecraft.client.main.Main.main(Main.java:142)\n'
  + 'Caused by: java.lang.ClassNotFoundException: org.lwjgl.util.spng.SPNG\n'
  + '\tat com.amcl.launcher.AmclClassLoader.findClass(AmclClassLoader.java:323)\n';

const MC: string = 'fabric-loader-0.19.3-1.18.2';

/** 找出 desc/title 里含指定文本的建议（找不到返回 null）。 */
function findSuggestion(list: McSuggestion[], needle: string): McSuggestion | null {
  for (let i = 0; i < list.length; i++) {
    if (list[i].desc.indexOf(needle) >= 0 || list[i].title.indexOf(needle) >= 0) return list[i];
  }
  return null;
}

export default function mcErrorFabricGameProviderTest() {
  describe('McErrorFabricGameProvider', () => {

    // ---------- 正向 ----------

    it('真机原文（含 summary）归到 fabric_game_missing', 0, () => {
      let d: McDiagnosis = classifyMcError(SUMMARY_REAL, TAIL_REAL, MC);
      expect(d.category).assertEqual('fabric_game_missing');
      expect(d.errorKind).assertEqual('FabricGameProviderMissing');
    });

    it('只有 logTail 没有 summary 时同样归因（两个调用方传的组合不同）', 0, () => {
      let d: McDiagnosis = classifyMcError('', TAIL_REAL, MC);
      expect(d.category).assertEqual('fabric_game_missing');
    });

    it('尾部只剩 Fabric 自己那条 ERROR 行也要命中（Caused by 可能被截掉）', 0, () => {
      // 这一条钉的是「不要只依赖 Java 堆栈」：LogNoiseFilter 的 isStackContinuation 把
      // "Caused by:" 当堆栈续行，任何一条 dropStack 噪声都可能把它连带吞掉，
      // 而 Fabric 自打的这行不是续行，是更可靠的锚。
      //
      // ⭐ 它**同时**钉住 hasAnyErrorSignal 对 Fabric 行格式的支持，这是两件独立的事：
      // 规则本身写对了，但如果早退门控不认 `[ERROR]`（Fabric 的级别不带斜杠，与 MC 的
      // `[线程/ERROR]` 排版不同），根本走不到规则链 —— 首次运行本用例正是这样失败的，
      // 结果是 not_diagnosable（用户看到「上次游戏已结束」，而实际启动失败了）。
      let d: McDiagnosis = classifyMcError('', TAIL_FABRIC_LINE_ONLY, MC);
      expect(d.category).assertEqual('fabric_game_missing');
    });

    it('撇号被转写成 U+2019 时，不含撇号的兜底判据仍然命中', 0, () => {
      let d: McDiagnosis = classifyMcError('', TAIL_CURLY_APOSTROPHE, MC);
      expect(d.category).assertEqual('fabric_game_missing');
    });

    // ---------- 抢占顺序：三条会给反向建议的规则都不许截胡 ----------

    it('尾部同时有 SPNG NoClassDefFoundError 时，仍归 fabric_game_missing', 0, () => {
      // 精确 SPNG 信号若抢占，会把 Fabric 的 classpath 缺陷错说成 AMCL 少交付模块。
      // 旧规则会归到 lwjgl_version 并建议用户"改用 1.19+ 版本"——而这台设备上
      // 1.20.1 同样崩在这里（真机 21:19 连续两次），照做等于白忙一轮。
      let tail = TAIL_REAL
        + '[12:39:45] [Render thread/WARN]: java.lang.NoClassDefFoundError: '
        + 'org/lwjgl/util/spng/SPNG\n';
      let d: McDiagnosis = classifyMcError('', tail, MC);
      expect(d.category).assertEqual('fabric_game_missing');
    });

    it('尾部同时有 NoSuchFileException + .jar 时，仍归 fabric_game_missing', 0, () => {
      // 被 missing_file 抢走的后果最贵：它的主操作是 redownload（删版本重下几百 MB），
      // 而本类的版本 jar 完好 —— 重下之后一模一样。
      let tail = TAIL_REAL
        + '[12:39:45] [Worker/WARN]: java.nio.file.NoSuchFileException: '
        + '/data/storage/el2/base/haps/entry/files/.minecraft/libraries/foo/bar.jar\n';
      let d: McDiagnosis = classifyMcError('', tail, MC);
      expect(d.category).assertEqual('fabric_game_missing');
    });

    it('尾部同时有 mod resolution failed 时，仍归 fabric_game_missing', 0, () => {
      // 被 mod_conflict 抢走的后果：让用户去删模组。而定位游戏发生在模组发现**之前**，
      // 这一类崩溃里模组一个都还没被读取过。
      let tail = TAIL_REAL
        + '[12:39:45] [main/ERROR]: Mod resolution failed\n';
      let d: McDiagnosis = classifyMcError('', tail, MC);
      expect(d.category).assertEqual('fabric_game_missing');
    });

    // ---------- 三类互斥：模块缺失 / 版本 API 不匹配 / Fabric game-provider ----------

    it('纯 SPNG NoClassDefFoundError 归到 lwjgl_module_missing', 0, () => {
      let d: McDiagnosis = classifyMcError('', TAIL_LWJGL_SPNG_MISSING, '26.3-pre-1');
      expect(d.category).assertEqual('lwjgl_module_missing');
      expect(d.errorKind).assertEqual('LWJGLSpngMissing');
      expect(d.techDetail.indexOf('org.lwjgl.util.spng.SPNG') >= 0).assertTrue();
      expect(d.techDetail.indexOf('lwjgl-spng') >= 0).assertTrue();
      expect(d.description.indexOf('AMCL') >= 0).assertTrue();
      expect(d.description.indexOf('不是游戏文件损坏') >= 0).assertTrue();
      expect(d.description.indexOf('更新 AMCL') >= 0).assertTrue();
      expect(d.description.indexOf('完整 SPNG 运行时') >= 0).assertTrue();
      expect(d.primaryActionKey === null).assertTrue();
      for (let i = 0; i < d.suggestions.length; i++) {
        expect(d.suggestions[i].actionKey === 'redownload').assertFalse();
        expect(d.suggestions[i].actionKey === 'open_mod_list').assertFalse();
        expect(d.suggestions[i].actionKey === 'open_versions').assertFalse();
      }
    });

    // ---------- 不许过宽 ----------

    it('NoSuchMethodError 代表 API 版本面不匹配，仍归 lwjgl_version', 0, () => {
      let d: McDiagnosis = classifyMcError('', TAIL_LWJGL_ONLY, MC);
      expect(d.category).assertEqual('lwjgl_version');
      expect(d.description.indexOf('3.2.3 槽') >= 0).assertTrue();
      expect(d.description.indexOf('改用 1.19+') >= 0).assertFalse();
      expect(d.description.indexOf('等待尚未上线') >= 0).assertFalse();
      expect(d.primaryActionKey).assertEqual('copy_log');
    });

    it('NoSuchFieldError 保留真实异常类型，不冒充 jar/native 自检失败', 0, () => {
      let d: McDiagnosis = classifyMcError('', TAIL_LWJGL_FIELD_ONLY, MC);
      expect(d.category).assertEqual('lwjgl_version');
      expect(d.techDetail.indexOf('NoSuchFieldError') >= 0).assertTrue();
      expect(d.techDetail.indexOf('Incompatible Java and native library versions') >= 0).assertFalse();
    });

    it('未知 org.lwjgl 缺类不自动归因成 AMCL 模块交付缺口', 0, () => {
      let tail = 'java.lang.NoClassDefFoundError: org/lwjgl/openxr/XR10\n'
        + '\tat com.example.OptionalVrBridge.initialize(OptionalVrBridge.java:27)\n';
      let d: McDiagnosis = classifyMcError('', tail, MC);
      expect(d.category === 'lwjgl_module_missing').assertFalse();
    });

    it('模组引用未知 LWJGL 类时保留 MIXIN 归因，不被模块缺失规则抢占', 0, () => {
      let tail = '[Render thread/ERROR]: Mixin apply failed for mod optional-renderer\n'
        + 'java.lang.NoClassDefFoundError: org/lwjgl/openxr/XR10\n'
        + '\tat com.example.mixin.RenderMixin.apply(RenderMixin.java:51)\n';
      let d: McDiagnosis = classifyMcError('', tail, MC);
      expect(d.category).assertEqual('mixin_apply');
    });

    it('NoClassDefFoundError 的目标不是 org.lwjgl 时，不与尾部别处的 LWJGL 字样交叉命中', 0, () => {
      let tail = 'java.lang.NoClassDefFoundError: com/example/OptionalBridge\n'
        + '\tat com.example.ModEntrypoint.start(ModEntrypoint.java:42)\n'
        + '[main/INFO]: LWJGL owner is org.lwjgl.system.MemoryUtil\n';
      let d: McDiagnosis = classifyMcError('', tail, MC);
      expect(d.category === 'lwjgl_module_missing').assertFalse();
      expect(d.category === 'lwjgl_version').assertFalse();
    });

    it('Could not initialize class 表示类初始化失败，不冒充模块缺失', 0, () => {
      let tail = 'java.lang.NoClassDefFoundError: Could not initialize class org.lwjgl.opengl.GL\n'
        + 'Caused by: java.lang.ExceptionInInitializerError\n';
      let d: McDiagnosis = classifyMcError('', tail, MC);
      expect(d.category === 'lwjgl_module_missing').assertFalse();
    });

    it('单独出现 "game provider" 字样但没说定位失败 ⇒ 不认领', 0, () => {
      // 兜底判据要求 "game provider" 与 "locate the game" 同时命中，
      // 否则这条规则会把 Fabric 其它阶段的报错也吞进来。
      let tail = '[10:00:00] [main/INFO]: Loading Minecraft 1.18.2 with Fabric Loader 0.19.3\n'
        + '[10:00:01] [main/ERROR]: game provider initialization threw an exception\n'
        + 'java.lang.IllegalStateException: duplicate mod id\n';
      let d: McDiagnosis = classifyMcError('', tail, MC);
      expect(d.category === 'fabric_game_missing').assertFalse();
    });

    // ---------- 文案：两条反向指引必须在 ----------

    it('第一条建议是"更新 AMCL"且被标为推荐（根因在启动器侧）', 0, () => {
      let d: McDiagnosis = classifyMcError('', TAIL_REAL, MC);
      expect(d.suggestions.length >= 2).assertTrue();
      expect(d.suggestions[0].recommended).assertTrue();
      expect(d.suggestions[0].title.indexOf('更新') >= 0).assertTrue();
    });

    it('必须明说"不用删版本重新下载"（这条错误的原文会把人骗去重下）', 0, () => {
      // 原文里有 "jar corruption" 与 "absent from the class path"，读起来就像文件坏了。
      // 少了这句反向指引，用户仍然会去做那个最贵且无效的操作。
      let d: McDiagnosis = classifyMcError('', TAIL_REAL, MC);
      let s: McSuggestion | null = findSuggestion(d.suggestions, '不用删版本');
      expect(s !== null).assertTrue();
    });

    it('没有一键修复就不假装有：primaryActionKey 为 null，兜底建议走 copy_log', 0, () => {
      let d: McDiagnosis = classifyMcError('', TAIL_REAL, MC);
      expect(d.primaryActionKey === null).assertTrue();
      let s: McSuggestion | null = findSuggestion(d.suggestions, '复制');
      expect(s !== null).assertTrue();
      if (s !== null) {
        expect(s.actionKey).assertEqual('copy_log');
      }
    });
  });
}
