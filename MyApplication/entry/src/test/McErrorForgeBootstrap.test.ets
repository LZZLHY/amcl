/*
 * McErrorForgeBootstrap.test.ets — Forge 新 bootstrap 拿不到游戏 classpath 的分类
 *
 * ⭐ **这份测试存在的直接原因：同一个盲区在被写下来之后又命中了一次。**
 *
 * `McErrorFabricGameProvider.test.ets` 的头注释（2026-08-29）已经写明分类器的失效形态是
 * **静默退化** —— 匹配不上就落到兜底，一条永不失败也永无信息量的结论 ⇒ 门禁全绿、
 * 真机看不出差别，只有当事用户吃亏。五天后（2026-09-04）`26.2-forge-65.1.3` 崩在
 * `NoSuchElementException @ Bootstrap.bootstrapMain`，而分类器里**又**没有任何规则认领它，
 * 用户看到的还是「游戏意外退出 / 复制日志反馈」。
 * 两次是同一根因（启动器把游戏 classpath 的交付方式弄错了），只是加载器不同。
 *
 * 三类判定在这里同等重要，**第二、三类比第一类更承重**：
 *   - **正向**：真机原文要归到 `forge_boot_classpath`；
 *   - **不许过宽**：`NoSuchElementException` 在 MC 与模组里到处都是（任何 `Optional.get()`），
 *     而 `net.minecraftforge.bootstrap` 这个字样在这一代 Forge 上**几乎恒真**
 *     （启动器每局都打一行 `Loading net.minecraftforge.bootstrap.ForgeBootstrap...`）⇒
 *     只靠"全文同时含这两个"会把该路线上的任何 Optional 故障都吞进来。
 *     真正收住范围的是"三个信号同窗口"，本文件下面有一条专门钉它的用例；
 *   - **抢占顺序**：missing_file / mod_conflict 的判据形状都能吃掉本类，
 *     而 Forge 的启动日志本来就有指向 `.jar` 的 `no such file or directory` 行 ⇒
 *     顺序错了会建议用户删版本重下几百 MB（文件是好的），或去删模组
 *     （崩溃发生在模组被读取之前）。顺序错了不报错，所以必须钉在这里。
 *
 * 创建日期：2026-09-04
 */
import { describe, it, expect } from '@ohos/hypium';
import { classifyMcError, McDiagnosis, McSuggestion } from 'launch';

/**
 * 真机 `mc_output.log` 原文（设备沙箱 `.minecraft/versions/26.2-forge-65.1.3/`，
 * 2026-09-04 13:26:57 起，前后不到 1 秒）。逐字取自
 * `docs/reports/2026-09-04_FORGE_BOOTSTRAP_CLASSPATH_OWNERSHIP_RESEARCH.md` §1.1 ——
 * 那一节里的 `...` 是报告作者的省略号，这里原样保留（分类器不关心它）。
 *
 * ⚠️ 注意它**没有** MC 自己的 crash-report：异常发生在 FML 起来之前，
 * MC 的崩溃处理还不存在。这正是"用户只看到点开就闪退"的原因。
 */
const TAIL_REAL: string =
  '[AmclLauncher] Loading net.minecraftforge.bootstrap.ForgeBootstrap...\n'
  + '[AMCL-CLASSLOADER] schema=1 phase=main-owner status=active\n'
  + '    main=net.minecraftforge.bootstrap.ForgeBootstrap '
  + 'owner=com.amcl.launcher.AmclClassLoader game_urls=98\n'
  + '[AmclLauncher] Invoking net.minecraftforge.bootstrap.ForgeBootstrap.main() with 24 args\n'
  + '[AmclLauncher] mainClass.main() threw: java.lang.reflect.InvocationTargetException\n'
  + '[AmclLauncher] root cause: java.util.NoSuchElementException: No value present\n'
  + '...\n'
  + 'Caused by: java.util.NoSuchElementException: No value present\n'
  + '\tat java.base/java.util.Optional.get(Optional.java:143)\n'
  + '\tat net.minecraftforge.bootstrap.Bootstrap.bootstrapMain(Bootstrap.java:123)\n'
  + '\tat net.minecraftforge.bootstrap.Bootstrap.start(Bootstrap.java:53)\n'
  + '\tat net.minecraftforge.bootstrap.ForgeBootstrap.main(ForgeBootstrap.java:19)\n';

/**
 * `SessionMarker.extractErrorSummary(TAIL_REAL)` 的产出，**逐条按它的规则推出来的**，
 * 不是随手编的：优先级 1（Fabric 标题）不命中；优先级 2（Java 异常顶行）要求整行匹配
 * `^[a-z][\w.$]+(Exception|Error):`，而这份日志里的异常行都带 `[AmclLauncher]` 前缀或
 * 以大写 `Caused by:` 开头 ⇒ 全部落空；于是走兜底"最后一条像错误的非续行"，
 * 从尾部往前跳过所有 `at ` 与 `Caused by:`，第一条含 `exception` 的就是下面这行。
 */
const SUMMARY_REAL: string =
  '[AmclLauncher] root cause: java.util.NoSuchElementException: No value present';

/**
 * 一次**正常**的 Forge 会话，后来某个模组抛了 `NoSuchElementException`。
 *
 * ⭐ 这是本文件最承重的一条反向用例：`no value present` 与
 * `net.minecraftforge.bootstrap` 两个字样在这份日志里**都在**，只是隔了很远。
 * 若判据写成"全文同时命中"，这条会被误报成"启动器交付方式弄错了"，
 * 而实际上游戏已经跑起来了 —— 用户会被指去更新启动器，真正的模组问题没人看。
 */
const TAIL_FORGE_HEALTHY_THEN_MOD_ERROR: string =
  '[AmclLauncher] Loading net.minecraftforge.bootstrap.ForgeBootstrap...\n'
  + '[cp.mo.mo.Launcher/MODLAUNCHER]: ModLauncher 10.2.6 starting: java version 25.0.4\n'
  + '[mixin/]: SpongePowered MIXIN Subsystem Version=0.8.7 Service=ModLauncher Env=CLIENT\n'
  + '[main/INFO]: Loading 42 mods\n'
  + '[main/INFO]: Reading registries\n'
  + '[main/INFO]: Injecting registries\n'
  + '[Render thread/INFO]: Setting user\n'
  + '[Render thread/INFO]: Backend library: LWJGL\n'
  + '[Render thread/INFO]: Reloading ResourceManager\n'
  + '[Worker/INFO]: Baking models\n'
  + '[Render thread/INFO]: Sound engine started\n'
  + '[Render thread/INFO]: OpenAL initialized\n'
  + '[Render thread/INFO]: Created: 1024x512 textures-atlas\n'
  + '[Render thread/INFO]: Narrator unavailable\n'
  + '[Render thread/INFO]: Reached main menu\n'
  + '[Render thread/ERROR]: Exception caught during firing event\n'
  + 'java.util.NoSuchElementException: No value present\n'
  + '\tat java.base/java.util.Optional.get(Optional.java:143)\n'
  + '\tat com.example.somemod.ConfigHolder.active(ConfigHolder.java:57)\n';

/** 模组自己的 `Optional.get()` 失败，与 Forge bootstrap 完全无关。 */
const TAIL_MOD_OPTIONAL_ONLY: string =
  '[Render thread/ERROR]: Failed to load structure set\n'
  + 'java.util.NoSuchElementException: No value present\n'
  + '\tat java.base/java.util.Optional.get(Optional.java:143)\n'
  + '\tat com.example.worldgen.StructureRegistry.lookup(StructureRegistry.java:88)\n';

/** 错误级别的缺文件（没有任何 NoSuchElement 信号）仍归 missing_file。 */
const TAIL_REAL_MISSING_FILE: string =
  '[17:39:03] [Worker/ERROR]: java.nio.file.NoSuchFileException: '
  + '/data/storage/el2/base/haps/entry/files/.minecraft/versions/1.20.4/1.20.4.jar\n'
  + '\tat java.base/sun.nio.fs.UnixException.translateToIOException(UnixException.java:92)\n';

const MC: string = '26.2-forge-65.1.3';

/** 找出 desc/title 里含指定文本的建议（找不到返回 null）。 */
function findSuggestion(list: McSuggestion[], needle: string): McSuggestion | null {
  for (let i = 0; i < list.length; i++) {
    if (list[i].desc.indexOf(needle) >= 0 || list[i].title.indexOf(needle) >= 0) return list[i];
  }
  return null;
}

export default function mcErrorForgeBootstrapTest() {
  describe('McErrorForgeBootstrap', () => {

    // ---------- 正向 ----------

    it('真机原文（含 summary）归到 forge_boot_classpath', 0, () => {
      let d: McDiagnosis = classifyMcError(SUMMARY_REAL, TAIL_REAL, MC);
      expect(d.category).assertEqual('forge_boot_classpath');
      expect(d.errorKind).assertEqual('ForgeBootstrapClasspathMissing');
    });

    it('只有 logTail 没有 summary 时同样归因（两个调用方传的组合不同）', 0, () => {
      let d: McDiagnosis = classifyMcError('', TAIL_REAL, MC);
      expect(d.category).assertEqual('forge_boot_classpath');
    });

    it('判据边界：只剩摘要那一行时**不**认领，这是刻意的', 0, () => {
      // 摘要只有 `root cause: NoSuchElementException` 一行，三个信号里只剩第一个。
      // 认领它就等于"这一代 Forge 上的任何 NoSuchElementException 都算交付方式错了"。
      // ⇒ 宁可退回兜底。产品里两个调用方（Index 冷启动、McErrorSheet）**都**同时传
      // 32 KB 的 logTail，堆栈在那里面，所以这条边界不影响真实链路。
      let d: McDiagnosis = classifyMcError(SUMMARY_REAL, '', MC);
      expect(d.category === 'forge_boot_classpath').assertFalse();
    });

    // ---------- 不许过宽（本文件的承重项）----------

    it('⭐ 正常 Forge 会话里模组抛的 NoSuchElementException 不许被认领', 0, () => {
      // 两个字样全在，只是隔了十几行。判据若是"全文同时命中"，这条就会红。
      let d: McDiagnosis = classifyMcError('', TAIL_FORGE_HEALTHY_THEN_MOD_ERROR, MC);
      expect(d.category === 'forge_boot_classpath').assertFalse();
    });

    it('没有 Forge bootstrap 上下文的 Optional.get 失败不许被认领', 0, () => {
      let d: McDiagnosis = classifyMcError('', TAIL_MOD_OPTIONAL_ONLY, MC);
      expect(d.category === 'forge_boot_classpath').assertFalse();
    });

    it('真的缺版本 jar 时仍归 missing_file（不许反向吞掉别人的故障）', 0, () => {
      let d: McDiagnosis = classifyMcError('', TAIL_REAL_MISSING_FILE, MC);
      expect(d.category).assertEqual('missing_file');
    });

    it('仅 WARN 的文件探测没有故障证据，不许据此建议重下版本', 0, () => {
      const tail: string = TAIL_REAL_MISSING_FILE.replace('[Worker/ERROR]', '[Worker/WARN]');
      const d: McDiagnosis = classifyMcError('', tail, MC);
      expect(d.category).assertEqual('not_diagnosable');
    });

    it('真的模组冲突仍归 mod_conflict（同一条路线上的另一类故障）', 0, () => {
      // 新规则排在 mod_conflict 之前，所以必须证明它**不会**顺手把模组冲突也拿走 ——
      // 那样用户会被指去更新启动器，而真正该做的是禁用冲突模组。
      let tail = '[AmclLauncher] Loading net.minecraftforge.bootstrap.ForgeBootstrap...\n'
        + '[main/ERROR]: Mod resolution failed\n'
        + '[main/ERROR]: Incompatible mods found\n';
      let d: McDiagnosis = classifyMcError('', tail, MC);
      expect(d.category).assertEqual('mod_conflict');
    });

    // ---------- 抢占顺序：两条会给反向建议的规则都不许截胡 ----------

    it('尾部同时有 no such file or directory *.jar 时，仍归 forge_boot_classpath', 0, () => {
      // Forge 的启动日志本来就有这类行（native 库探测、可选资源）。被 missing_file
      // 抢走的后果最贵：主操作是 redownload（删版本重下几百 MB），而版本 jar 完好。
      let tail = TAIL_REAL
        + '[13:26:57] [main/WARN]: /data/.minecraft/libraries/foo/bar-natives.jar: '
        + 'no such file or directory\n';
      let d: McDiagnosis = classifyMcError('', tail, MC);
      expect(d.category).assertEqual('forge_boot_classpath');
    });

    it('尾部同时有 NoSuchFileException + .jar 时，仍归 forge_boot_classpath', 0, () => {
      let tail = TAIL_REAL
        + '[13:26:57] [Worker/WARN]: java.nio.file.NoSuchFileException: '
        + '/data/.minecraft/libraries/foo/bar.jar\n';
      let d: McDiagnosis = classifyMcError('', tail, MC);
      expect(d.category).assertEqual('forge_boot_classpath');
    });

    it('尾部同时有 mod resolution failed 时，仍归 forge_boot_classpath', 0, () => {
      // 被 mod_conflict 抢走的后果：让用户去删模组。而这条崩溃发生在模组发现**之前**，
      // 模组一个都还没被读取过。
      let tail = TAIL_REAL + '[13:26:57] [main/ERROR]: Mod resolution failed\n';
      let d: McDiagnosis = classifyMcError('', tail, MC);
      expect(d.category).assertEqual('forge_boot_classpath');
    });

    // ---------- 文案：三条指引必须在 ----------

    it('第一条建议是"更新 AMCL"且被标为推荐（根因在启动器侧）', 0, () => {
      let d: McDiagnosis = classifyMcError('', TAIL_REAL, MC);
      expect(d.suggestions.length >= 3).assertTrue();
      expect(d.suggestions[0].recommended).assertTrue();
      expect(d.suggestions[0].title.indexOf('更新') >= 0).assertTrue();
    });

    it('必须明说"不用删版本重新下载"，且不给任何破坏性一键操作', 0, () => {
      let d: McDiagnosis = classifyMcError('', TAIL_REAL, MC);
      expect(findSuggestion(d.suggestions, '不用删版本') !== null).assertTrue();
      expect(d.primaryActionKey === null).assertTrue();
      for (let i = 0; i < d.suggestions.length; i++) {
        expect(d.suggestions[i].actionKey === 'redownload').assertFalse();
        expect(d.suggestions[i].actionKey === 'open_mod_list').assertFalse();
        expect(d.suggestions[i].actionKey === 'open_versions').assertFalse();
      }
    });

    it('兜底建议要给出**日志里真的存在**的字面量', 0, () => {
      // ⚠️ 方案原文让附 `[AMCL-CP-OWNERSHIP]`，但那一行只进 hilog（native 侧打的），
      // 用户上传的日志里没有它 —— 让用户去 grep 一个不存在的字符串比不给更糟。
      // 这三个是用户自己就能拿到的：前两个在 logs/amcl_launcher.log，第三个在 mc_output.log。
      let d: McDiagnosis = classifyMcError('', TAIL_REAL, MC);
      let s: McSuggestion | null = findSuggestion(d.suggestions, 'AMCL_LOADER_GENERATION');
      expect(s !== null).assertTrue();
      if (s !== null) {
        expect(s.actionKey).assertEqual('copy_log');
        expect(s.desc.indexOf('AMCL_LAUNCH_CONTRACT') >= 0).assertTrue();
        expect(s.desc.indexOf('[AMCL-CP-DELIVERY]') >= 0).assertTrue();
        expect(s.desc.indexOf('AMCL-CP-OWNERSHIP') >= 0).assertFalse();
      }
    });

    it('技术详情不冒充别的异常：无 summary 时自己写明抛出点', 0, () => {
      let d: McDiagnosis = classifyMcError('', TAIL_REAL, MC);
      expect(d.techDetail.indexOf('bootstrapMain') >= 0).assertTrue();
      expect(d.techDetail.indexOf('java.class.path') >= 0).assertTrue();
    });
  });
}
