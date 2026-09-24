/*
 * LaunchContractCheck.test.ets — 启动契约结论 → Phase 0 检查列表的映射
 *
 * ⭐ **这份测试钉的是一条"看不见的错报"：契约类失败曾经伪装成"版本文件缺失"。**
 *
 * 批次 A 之后，`LaunchProfileBuilder.build()` 在契约不满足时会阻断启动并写
 * `lastBuildError`。但 Phase 0 的检查列表（用户唯一看得到的那个列表）里只有
 * jdk / jit / runtime / files / assets —— 于是契约失败**只能**从 `files` 那一项冒出来，
 * 而那一项的修复动作是 `redownload`：删掉版本、重下几百 MB。
 * 而这类失败里版本文件是**完好**的（契约校验排在 build() 的最后，走到它就意味着
 * version.json、主 jar、依赖库、ZIP 头、Forge 产物全过了）⇒ 重下之后一模一样。
 *
 * 四类断言在这里同等重要：
 *   - **归属**：契约失败要落在 `contract` 项上，且 `files` 项必须是 `pass`；
 *   - **不给破坏性动作**：`contract` 失败**不许**带 `redownload`（这一类没有用户侧修复动作）；
 *   - **Warn 不阻断**：未识别世代是注册表刻意 fail-open 到"能启动"的，压成 fail 会把
 *     那条设计意图反过来；
 *   - **"没校验"不是"校验通过"**：文件先失败时契约留痕根本不存在，那一项必须显示成
 *     未执行，而不是绿的（本仓 `1000544` 那一族：通道建起来但一个事件都没流过，
 *     与工作正常在日志/UI 上长得一模一样）。
 *
 * ⚠️ 本文件只测**纯映射**（verdict → PreLaunchCheck）。判定本身归
 * `LoaderGenerationContract.test.ets`，两者不要合并：那边坏了是"判错世代"，
 * 这边坏了是"判对了但报给用户的是另一件事"。
 *
 * 创建日期：2026-09-04
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  PreLaunchValidator, PreLaunchCheck,
  LaunchContractReport, reportLaunchContract,
  describeLaunchContractViolations, describeLaunchContractWarnings,
  ClasspathDelivery, LoaderGeneration, LoaderGenerationContract, loaderGenerationContract,
} from 'launch';

function contractOf(g: LoaderGeneration): LoaderGenerationContract {
  return loaderGenerationContract(g) as LoaderGenerationContract;
}

/** 一份"各项都合法"的留痕。 */
function okReport(g: LoaderGeneration): LaunchContractReport {
  const c: LoaderGenerationContract = contractOf(g);
  const args: string[] = [];
  if (c.requiresLegacyClassPathProperty) args.push('-DlegacyClassPath=/a.jar:/b.jar');
  return reportLaunchContract({
    contract: c,
    effectiveDelivery: c.classpathDelivery,
    gameClasspathEntries: 98,
    jvmArgs: args,
    jdkMajor: c.pinnedJdkMajor.length > 0 ? c.pinnedJdkMajor : '25',
  });
}

/**
 * `642edf87` 的最小复现：给只认 `java.class.path` 的 Forge 新 bootstrap 发收窄的 delivery。
 * 这正是 2026-09-04 那次真机故障，也是本文件所有 fail 用例的原型。
 */
function forgeBootMismatchReport(): LaunchContractReport {
  return reportLaunchContract({
    contract: contractOf(LoaderGeneration.ForgeBootstrap),
    effectiveDelivery: ClasspathDelivery.AmclLoaderOnly,
    gameClasspathEntries: 98,
    jvmArgs: [],
    jdkMajor: '25',
  });
}

export default function launchContractCheckTest() {
  describe('LaunchContractCheck', () => {

    // ── 一、契约失败：归属与文案 ────────────────────────────────────
    it('契约失败落在 contract 项上并指名道姓', 0, () => {
      const r: LaunchContractReport = forgeBootMismatchReport();
      expect(r.verdict.ok).assertFalse();
      const c: PreLaunchCheck = PreLaunchValidator.contractCheck(r, true);
      expect(c.id).assertEqual('contract');
      expect(c.status).assertEqual('fail');
      // 世代的展示名必须在文案里 —— 否则用户与开发者都无法判断是哪条路线出的事。
      expect(c.detail.indexOf(r.displayName) >= 0).assertTrue();
      expect(c.detail.indexOf('jvm-classpath-full') >= 0).assertTrue();
    });

    it('⭐ 契约失败时 files 项必须是 pass，且不许出现 redownload', 0, () => {
      // 这一条就是整份测试的理由：旧行为是 files=fail + redownload（删版本重下），
      // 而文件是好的。两项的 fixActionKey 都要看 —— 错报的代价全在那个动作上。
      const r: LaunchContractReport = forgeBootMismatchReport();
      const files: PreLaunchCheck = PreLaunchValidator.versionFilesCheck(null, '启动契约校验失败…', r);
      expect(files.id).assertEqual('files');
      expect(files.status).assertEqual('pass');
      expect(files.fixActionKey).assertEqual('');
      expect(files.detail.indexOf('98') >= 0).assertTrue();

      const contract: PreLaunchCheck = PreLaunchValidator.contractCheck(r, true);
      expect(contract.fixActionKey).assertEqual('');
    });

    // ── 二、Warn 不阻断 ─────────────────────────────────────────────
    it('未识别世代只给 warn，不给 fail', 0, () => {
      const r: LaunchContractReport = okReport(LoaderGeneration.Unknown);
      expect(r.verdict.ok).assertTrue();     // Warn 不影响 ok
      const c: PreLaunchCheck = PreLaunchValidator.contractCheck(r, true);
      expect(c.status).assertEqual('warn');
      // 文案要说清"仍然启动了"，否则黄色图标会被读成"启动被拒"。
      expect(c.detail.indexOf('不阻断') >= 0).assertTrue();
    });

    // ── 三、正向：通过时要写明世代与交付方式 ────────────────────────
    it('通过时写明世代与 classpath 交付方式', 0, () => {
      const r: LaunchContractReport = okReport(LoaderGeneration.Vanilla);
      const c: PreLaunchCheck = PreLaunchValidator.contractCheck(r, true);
      expect(c.status).assertEqual('pass');
      expect(c.detail.indexOf(r.displayName) >= 0).assertTrue();
      expect(c.detail.indexOf('amcl-loader-only') >= 0).assertTrue();
    });

    it('每个世代的合法留痕都通过（留痕字段与校验输入同源）', 0, () => {
      const all: LoaderGeneration[] = [
        LoaderGeneration.Vanilla, LoaderGeneration.FmlLegacy,
        LoaderGeneration.ModlauncherLegacy, LoaderGeneration.ForgeBsl,
        LoaderGeneration.ForgeBootstrap, LoaderGeneration.NeoForge,
        LoaderGeneration.FabricKnot,
      ];
      for (let i = 0; i < all.length; i++) {
        const r: LaunchContractReport = okReport(all[i]);
        // 留痕不许与校验输入漂移：delivery / 世代 / 条目数都必须是刚才传进去的那份。
        expect(r.delivery).assertEqual(contractOf(all[i]).classpathDelivery);
        expect(r.generation).assertEqual(contractOf(all[i]).generation);
        expect(r.gameClasspathEntries).assertEqual(98);
        expect(PreLaunchValidator.contractCheck(r, true).status).assertEqual('pass');
      }
    });

    // ── 四、"没校验"不是"校验通过"────────────────────────────────
    it('文件校验失败时 contract 项停在 pending，而不是 pass', 0, () => {
      const c: PreLaunchCheck = PreLaunchValidator.contractCheck(null, false);
      expect(c.status).assertEqual('pending');
      expect(c.detail.indexOf('未进行') >= 0).assertTrue();
    });

    it('文件通过却没有留痕 ⇒ warn（结构上不该发生，但不许静默变绿）', 0, () => {
      const c: PreLaunchCheck = PreLaunchValidator.contractCheck(null, true);
      expect(c.status).assertEqual('warn');
      expect(c.status === 'pass').assertFalse();
    });

    // ── 五、文件类失败仍然要给 redownload ───────────────────────────
    it('真正的文件缺失仍归 files 项并保留 redownload', 0, () => {
      // 反向护栏：上面那条 pass 分支不许把"文件真的坏了"也一起变绿。
      const files: PreLaunchCheck = PreLaunchValidator.versionFilesCheck(
        null, '缺少 3 个依赖库', null);
      expect(files.status).assertEqual('fail');
      expect(files.fixActionKey).assertEqual('redownload');
      expect(files.detail.indexOf('缺少 3 个依赖库') >= 0).assertTrue();
    });

    it('留痕存在但校验通过、profile 仍为 null ⇒ 按文件失败处理（不冒充通过）', 0, () => {
      // 结构上不该发生（契约通过之后 build() 不再有失败点）。这里钉的是方向：
      // 未知原因的 build 失败宁可报文件失败，也不要报成"一切正常"。
      const files: PreLaunchCheck = PreLaunchValidator.versionFilesCheck(
        null, '内部错误：JVM 参数 SSOT 不可用', okReport(LoaderGeneration.Vanilla));
      expect(files.status).assertEqual('fail');
    });

    // ── 六、两个渲染函数必须严格分工 ────────────────────────────────
    it('Fail 与 Warn 的渲染互不串台', 0, () => {
      const failed: LaunchContractReport = forgeBootMismatchReport();
      expect(describeLaunchContractViolations(failed.verdict).length > 0).assertTrue();
      expect(describeLaunchContractWarnings(failed.verdict).length).assertEqual(0);

      const warned: LaunchContractReport = okReport(LoaderGeneration.Unknown);
      expect(describeLaunchContractWarnings(warned.verdict).length > 0).assertTrue();
      expect(describeLaunchContractViolations(warned.verdict).length).assertEqual(0);
    });

    // ── 七、列表里必须真的多了这一项 ────────────────────────────────
    it('pendingChecks 含 contract 项，且紧跟 files', 0, () => {
      const list: PreLaunchCheck[] = PreLaunchValidator.pendingChecks();
      let filesAt = -1;
      let contractAt = -1;
      for (let i = 0; i < list.length; i++) {
        if (list[i].id === 'files') filesAt = i;
        if (list[i].id === 'contract') contractAt = i;
      }
      expect(filesAt >= 0).assertTrue();
      // 顺序即因果：契约校验发生在文件校验之后（文件不全时走不到它）。
      // PreLaunchCheckSheet 用下标逐项点亮，顺序错了 UI 会把结论贴到另一行上。
      expect(contractAt).assertEqual(filesAt + 1);
    });
  });
}
