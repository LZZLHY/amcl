/**
 * PreLaunchCheckSheet.ets — 启动前硬校验 Sheet
 *
 * 点击"启动游戏"后先弹出本 Sheet，依次跑各项校验（JIT / JDK 版本匹配 / 运行时环境 /
 * 版本文件完整性 / 启动契约 / 游戏资源完整性），逐项点亮。
 * 【全部通过】才回调 onProceed() 真正创建 JVM 进游戏；任一不过
 * 则停在本 Sheet，展示失败原因 + 一键修复入口，绝不启动。这样用户全程停留在启动器、零进程
 * 开销，不再像旧 JIT 校验那样"进了启动流水线才发现不行、还得杀一次进程"。
 *
 * 校验逻辑在 features/launch/PreLaunchValidator.ets（纯函数）；本组件只负责编排与展示。
 */

import { ThemeColors } from 'commons';
import { AppIconName } from 'commons';
import { DOCS_NO_JIT_URL, DOCS_NO_JIT_FALLBACK_URL } from 'commons';
import { AppIcon } from './AppIcon';
import { PreLaunchValidator, PreLaunchCheck, PreLaunchInput, LaunchProfileChecks } from 'launch';
import { JdkRange } from 'launch';
import { DownloadTaskRegistry } from 'feature_core';
import { UnifiedTaskState, stateLabel } from 'feature_core';

@Component
export struct PreLaunchCheckSheet {
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop bottomSafeHeight: number = 0;

  // 启动上下文（全 primitive，bindSheet 每次展开时由父组件传入）
  @Prop filesDir: string = '';
  @Prop mcDir: string = '';
  @Prop gameDir: string = '';
  @Prop version: string = '';
  @Prop jdkVersion: string = '';
  @Prop xmxMb: number = 0;
  /**
   * 该版本的 **JDK 可用区间**（`JdkManager.jdkRangeFor`），与 JDK 路由**同源**。
   *
   * ⚠️ 它是一个区间而不是一个点：区间内任何已装 JDK 都能启动，纪元理想只是**推荐**。
   * 把"推荐"当成"唯一"会把合法组合拦掉 —— 那是被真机否证过一次的地方（§S12）。
   * 缺上限那一维则是另一个方向的病：自检全绿然后闪退（§S09.3）。
   */
  @Prop jdkRange: JdkRange = { minMajor: 0, maxMajor: 0, preferredJdk: '',
    ceilingSource: 'none', ceilingEvidence: '', generation: '', displayName: '' };

  /** JDK 是否已安装（由父组件用 JdkManager.isInstalled 注入，避免本组件耦合服务实例） */
  checkJdkInstalled: (jdkVersion: string) => boolean = () => false;
  /** 三项全通过 → 真正启动（父组件 navigate / 创建 JVM） */
  onProceed: () => void = () => {};
  /** 失败项的一键修复（'open_jdk_manager' / 'open_versions' 等需要跳转的动作） */
  onFix: (actionKey: string) => void = () => {};
  /**
   * 在 Sheet 内就地发起"修复/补全"（不跳转下载页、不强制打开下载 sheet）。父组件应
   * enqueue 修复任务（仍走统一下载系统，照常显示在下载 sheet/FAB），本 Sheet 通过轮询
   * registry 镜像显示进度，补全完成后自动重新校验。
   */
  onStartRepair: () => void = () => {};
  /**
   * 在 Sheet 内就地发起「JDK 下载安装」（无 JDK 拦截时）。父组件应 enqueue 一个
   * JdkInstallTask（走统一下载系统，registry id = 'jdk:'+jdkVersion），本 Sheet 通过轮询
   * registry 镜像进度，装好后自动重新校验。jdkVersion 由当前 MC 版本自动匹配（高版本=25）。
   */
  onStartJdkDownload: (jdkVersion: string) => void = () => {};
  /** 关闭 Sheet（取消启动） */
  onClose: () => void = () => {};
  /**
   * 用户在 "JDK 版本匹配" 警告里点"改用自动 JDK"：父组件把当前版本的单版本 JDK 覆盖改为自动、
   * 重新路由出兼容的 JDK，并返回新的 JDK 版本号（供本 Sheet 用新值重跑校验）。返回 '' 表示无变化。
   */
  switchJdkToAuto: () => string = () => '';

  /** 各项校验的实时状态（顺序与 PreLaunchValidator.pendingChecks() 一致） */
  @State private checks: PreLaunchCheck[] = PreLaunchValidator.pendingChecks();
  /** 总体阶段：running（校验中）/ passed（全通过）/ failed（有失败）/ repairing（就地修复中） */
  @State private phase: string = 'running';
  /** 就地修复进度镜像（轮询 registry 得到） */
  @State private repairLabel: string = '';
  @State private repairProgress: number = 0;
  @State private repairError: string = '';
  /** 组件销毁标志：避免异步校验链在 Sheet 已关闭后还回调 onProceed */
  private aborted: boolean = false;

  /** 本次校验实际使用的 JDK 版本（初始 = jdkVersion prop；用户"改用自动"后更新为新路由值）。 */
  @State private currentJdk: string = '';
  /** 用户是否已对"JDK 版本不匹配"点了"保留并继续"（接受后不再 warn 阻断）。 */
  @State private jdkWarnAccepted: boolean = false;

  aboutToAppear() {
    this.aborted = false;
    this.currentJdk = this.jdkVersion;
    this.jdkWarnAccepted = false;
    this.runAll();
  }

  aboutToDisappear() {
    this.aborted = true;
  }

  // ============================================================
  //  校验编排
  // ============================================================

  private input(): PreLaunchInput {
    return {
      filesDir: this.filesDir, mcDir: this.mcDir, gameDir: this.gameDir,
      version: this.version, jdkVersion: this.currentJdk, xmxMb: this.xmxMb,
    };
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => { setTimeout(() => { resolve(); }, ms); });
  }

  /** 整表重新赋值以确保 ArkUI 重渲染（避免对数组元素就地改属性导致脏标记漏报）。 */
  private setCheck(index: number, c: PreLaunchCheck): void {
    let next = this.checks.slice();
    next[index] = c;
    this.checks = next;
  }

  private setRunning(index: number): void {
    let cur = this.checks[index];
    this.setCheck(index, {
      id: cur.id, title: cur.title, status: 'running', detail: '检查中…', fixActionKey: '',
    });
  }

  /**
   * 顺序执行各项校验，逐项点亮；任一 fail 即停（phase=failed）；JDK 版本匹配 warn 且未确认时
   * 停在 jdkWarn（让用户选"改自动/保留"）；全过 → onProceed。
   *
   * ⚠️ 下标与 `PreLaunchValidator.pendingChecks()` 的顺序一一对应，改一处就要改另一处。
   * 「版本文件完整性」与「启动契约」由**一次** build() 同时产出（见 runProfileChecks），
   * 所以它们在这里是一步两格。
   */
  private async runAll(): Promise<void> {
    this.phase = 'running';
    this.checks = PreLaunchValidator.pendingChecks();

    // 0) JIT 可执行内存
    if (this.aborted) return;
    this.setRunning(0);
    await this.sleep(300);
    if (this.aborted) return;
    let c0 = PreLaunchValidator.runJit();
    this.setCheck(0, c0);
    if (c0.status === 'fail') { this.phase = 'failed'; return; }

    // 1) JDK 版本匹配（JIT 之后）。warn 且未确认 → 暂停等用户决策。
    this.setRunning(1);
    await this.sleep(300);
    if (this.aborted) return;
    let cJdk = PreLaunchValidator.runJdk(this.currentJdk, this.jdkRange, this.jdkWarnAccepted);
    this.setCheck(1, cJdk);
    // fail（JDK 越上限）不给"保留并继续"：越界必崩，而且崩在指不到真因的地方。
    if (cJdk.status === 'fail') { this.phase = 'failed'; return; }
    if (cJdk.status === 'warn' && !this.jdkWarnAccepted) { this.phase = 'jdkWarn'; return; }

    // 2) 运行时环境
    this.setRunning(2);
    await this.sleep(300);
    if (this.aborted) return;
    let c1 = await PreLaunchValidator.runRuntime(this.input(), this.checkJdkInstalled(this.currentJdk));
    if (this.aborted) return;
    this.setCheck(2, c1);
    if (c1.status === 'fail') { this.phase = 'failed'; return; }

    // 3+4) 版本文件完整性（存在/ZIP 头 + 主 jar SHA1）与启动契约（同一次 build 的产物）
    this.setRunning(3);
    this.setRunning(4);
    await this.sleep(300);
    if (this.aborted) return;
    let profileChecks: LaunchProfileChecks = await PreLaunchValidator.runProfileChecks(this.input());
    if (this.aborted) return;
    this.setCheck(3, profileChecks.files);
    this.setCheck(4, profileChecks.contract);
    if (profileChecks.files.status === 'fail') { this.phase = 'failed'; return; }
    // 契约 warn 不阻断：未识别世代是刻意 fail-open 到"能启动"的（见世代注册表）。
    if (profileChecks.contract.status === 'fail') { this.phase = 'failed'; return; }

    // 5) 游戏资源（assets）完整性
    this.setRunning(5);
    await this.sleep(300);
    if (this.aborted) return;
    let c3 = PreLaunchValidator.runAssets(this.input());
    this.setCheck(5, c3);
    if (c3.status === 'fail') { this.phase = 'failed'; return; }

    this.setRunning(6);
    const mods = await PreLaunchValidator.runMods(this.input());
    if (this.aborted) return;
    this.setCheck(6, mods);
    if (mods.status === 'fail') { this.phase = 'failed'; return; }

    // 全部通过 → 真正启动
    this.phase = 'passed';
    await this.sleep(500);
    if (this.aborted) return;
    this.onProceed();
  }

  private firstFailed(): PreLaunchCheck | null {
    for (let c of this.checks) {
      if (c.status === 'fail') return c;
    }
    return null;
  }

  /** 首个失败项是否为 JIT 可执行内存（用于展示「无 JIT 解决办法」入口）。 */
  private isJitFailed(): boolean {
    let f = this.firstFailed();
    return f !== null && f.id === 'jit';
  }

  /** 打开「无 JIT 权限的解决办法」文档（内嵌 WebView）。 */
  private openNoJitDoc(): void {
    try {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/DocWebPage',
        params: { src: DOCS_NO_JIT_URL, title: 'JIT 的解决办法', fallback: DOCS_NO_JIT_FALLBACK_URL },
      });
    } catch (e) { /* ignore */ }
  }

  private fixLabel(actionKey: string): string {
    if (actionKey === 'open_jdk_manager') return '去 JDK 管理';
    if (actionKey === 'download_jdk') return '一同下载 JDK';
    if (actionKey === 'redownload') return '一键修复';
    if (actionKey === 'open_versions') return '版本管理';
    // JDK 越上限 / 过低：两者的正确动作都是"回到自动路由"（自动路由**不会**越界）。
    if (actionKey === 'jdk_mismatch') return '改用自动 JDK';
    return '';
  }

  /** 首个失败项是否为「JDK 未安装」（可在本 Sheet 内一键下载安装）。 */
  private isJdkMissingFailed(): boolean {
    let f = this.firstFailed();
    return f !== null && f.fixActionKey === 'download_jdk';
  }

  /** 失败项是否可在本 Sheet 内就地修复（文件/资源类）。JDK / 版本管理类需跳转。 */
  private canRepairInSheet(actionKey: string): boolean {
    return actionKey === 'redownload';
  }

  /**
   * 就地修复流程：发起修复（父组件 enqueue，仍走统一下载系统）→ 在本 Sheet 内镜像显示
   * registry 里该任务的进度 → 完成后自动重新校验。失败 / 取消则回到 failed 态。
   */
  private async startRepairFlow(): Promise<void> {
    this.phase = 'repairing';
    this.repairError = '';
    this.repairProgress = 0;
    this.repairLabel = '正在准备修复…';
    this.onStartRepair();

    let id = 'repair:' + this.version;
    let waitedMs = 0;
    while (!this.aborted) {
      await this.sleep(400);
      if (this.aborted) return;
      let v = DownloadTaskRegistry.instance().get(id);
      if (!v) {
        waitedMs += 400;
        // 8s 内还没出现修复任务 → 视为启动失败
        if (waitedMs > 8000) {
          this.repairError = '未能启动修复任务，请重试或到下载页查看。';
          this.phase = 'failed';
          return;
        }
        continue;
      }
      this.repairProgress = Math.max(0, Math.min(100, Math.round(v.progress)));
      this.repairLabel = (v.currentLabel && v.currentLabel.length > 0) ? v.currentLabel : stateLabel(v.state);
      if (v.state === UnifiedTaskState.DONE) {
        // 补全完成 → 自动重新校验一遍完整性
        this.runAll();
        return;
      }
      if (v.state === UnifiedTaskState.ERROR) {
        this.repairError = (v.errorMessage && v.errorMessage.length > 0) ? v.errorMessage : '修复失败';
        this.phase = 'failed';
        return;
      }
      if (v.state === UnifiedTaskState.ABORTED) {
        this.repairError = '修复已取消';
        this.phase = 'failed';
        return;
      }
    }
  }

  /**
   * 就地 JDK 下载安装流程：enqueue JdkInstallTask（父组件）→ 在本 Sheet 内镜像
   * registry 里 'jdk:<ver>' 任务的下载/校验/解压进度 → 装好后自动重新校验（此时运行时
   * 环境校验通过 → 继续后续校验 → 全过则启动）。失败 / 取消回到 failed 态。
   */
  private async startJdkDownloadFlow(): Promise<void> {
    let ver = this.currentJdk;
    this.phase = 'repairing';
    this.repairError = '';
    this.repairProgress = 0;
    this.repairLabel = '正在准备下载 JDK ' + ver + '…';
    this.onStartJdkDownload(ver);

    let id = 'jdk:' + ver;
    let waitedMs = 0;
    while (!this.aborted) {
      await this.sleep(400);
      if (this.aborted) return;
      let v = DownloadTaskRegistry.instance().get(id);
      if (!v) {
        waitedMs += 400;
        if (waitedMs > 8000) {
          this.repairError = '未能启动 JDK 下载任务，请重试或到「设置 → JDK 管理」下载。';
          this.phase = 'failed';
          return;
        }
        continue;
      }
      this.repairProgress = Math.max(0, Math.min(100, Math.round(v.progress)));
      this.repairLabel = (v.currentLabel && v.currentLabel.length > 0) ? v.currentLabel : stateLabel(v.state);
      if (v.state === UnifiedTaskState.DONE) {
        this.runAll();   // JDK 已装 → 重新校验，运行时环境这次会通过
        return;
      }
      if (v.state === UnifiedTaskState.ERROR) {
        this.repairError = (v.errorMessage && v.errorMessage.length > 0) ? v.errorMessage : 'JDK 下载失败';
        this.phase = 'failed';
        return;
      }
      if (v.state === UnifiedTaskState.ABORTED) {
        this.repairError = 'JDK 下载已取消';
        this.phase = 'failed';
        return;
      }
    }
  }

  // ============================================================
  //  build
  // ============================================================

  build() {
    Column() {
      this.Header_()

      Scroll() {
        Column({ space: 10 }) {
          ForEach(this.checks, (c: PreLaunchCheck) => {
            this.CheckRow_(c);
          }, (c: PreLaunchCheck) => c.id + ':' + c.status)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 12 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      this.Footer_()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bgPrimary)
  }

  @Builder
  Header_() {
    Row({ space: 10 }) {
      Stack() {
        AppIcon({ name: AppIconName.Play, iconSize: 18, color: this.theme.primary })
      }
      .width(40).height(40)
      .borderRadius(20)
      .backgroundColor(this.theme.primaryLight)

      Column({ space: 1 }) {
        Text('启动前检查')
          .fontSize(18)
          .fontWeight(700)
          .fontColor(this.theme.textPrimary)
        Text(this.version || '<unknown>')
          .fontSize(11)
          .fontWeight(500)
          .fontColor(this.theme.textHint)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Stack() {
        AppIcon({ name: AppIconName.Close, iconSize: 18, color: this.theme.textSecondary })
      }
      .width(40).height(40)
      .borderRadius(20)
      .backgroundColor(this.theme.bgCard)
      .onClick(() => { this.onClose() })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  CheckRow_(c: PreLaunchCheck) {
    Row({ space: 12 }) {
      // 状态图标 / 转圈
      Stack() {
        if (c.status === 'running') {
          LoadingProgress()
            .width(22).height(22)
            .color(this.theme.primary)
        } else {
          AppIcon({
            name: this.statusIcon(c.status),
            iconSize: 22,
            color: this.statusColor(c.status),
          })
        }
      }
      .width(28).height(28)

      Column({ space: 3 }) {
        Text(c.title)
          .fontSize(14)
          .fontWeight(600)
          .fontColor(this.theme.textPrimary)
          .width('100%')
        Text(c.detail)
          .fontSize(11)
          .lineHeight(16)
          .fontColor(c.status === 'fail' ? this.theme.error : (c.status === 'warn' ? this.theme.warning : this.theme.textSecondary))
          .width('100%')
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(14)
    .alignItems(VerticalAlign.Top)
  }

  private statusIcon(status: string): AppIconName {
    if (status === 'pass') return AppIconName.CheckCircle;
    if (status === 'fail') return AppIconName.Error;
    if (status === 'warn') return AppIconName.Warning;
    return AppIconName.Hourglass;   // pending
  }

  private statusColor(status: string): ResourceColor {
    if (status === 'pass') return this.theme.success;
    if (status === 'fail') return this.theme.error;
    if (status === 'warn') return this.theme.warning;
    return this.theme.textHint;     // pending
  }

  @Builder
  Footer_() {
    Column() {
      if (this.phase === 'running') {
        Row({ space: 10 }) {
          LoadingProgress().width(20).height(20).color(this.theme.primary)
          Text('正在校验启动环境…')
            .fontSize(14)
            .fontWeight(600)
            .fontColor(this.theme.textSecondary)
        }
        .width('100%')
        .height(48)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
      } else if (this.phase === 'passed') {
        Row({ space: 8 }) {
          AppIcon({ name: AppIconName.CheckCircle, iconSize: 18, color: this.theme.success })
          Text('校验通过，正在进入游戏…')
            .fontSize(15)
            .fontWeight(700)
            .fontColor(this.theme.success)
        }
        .width('100%')
        .height(48)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
      } else if (this.phase === 'repairing') {
        this.RepairingView_()
      } else if (this.phase === 'jdkWarn') {
        this.JdkWarnActions_()
      } else {
        // failed —— 一键修复（若有）+ 重试 + 取消
        this.FailedActions_()
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: Math.max(16, this.bottomSafeHeight) })
    .backgroundColor(this.theme.bgPrimary)
  }

  @Builder
  FailedActions_() {
    Column({ space: 8 }) {
      if (this.repairError.length > 0) {
        Text(this.repairError)
          .fontSize(12)
          .fontColor(this.theme.error)
          .width('100%')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      // JIT 失败：显著入口打开「无 JIT 解决办法」文档（该失败无一键修复，只能按教程处理）
      if (this.isJitFailed()) {
        Row({ space: 6 }) {
          AppIcon({ name: AppIconName.Help, iconSize: 16, color: this.theme.textOnPrimary })
          Text('如何解决：无 JIT 权限的办法')
            .fontSize(15).fontWeight(700).fontColor(this.theme.textOnPrimary)
        }
        .width('100%').height(48)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.theme.primary)
        .borderRadius(24)
        .onClick(() => { this.openNoJitDoc() })
      }
      // JDK 未安装：主按钮「一同下载 JDK X」→ 就地下载安装（进度内联显示）
      if (this.isJdkMissingFailed()) {
        Row({ space: 6 }) {
          AppIcon({ name: AppIconName.Download, iconSize: 16, color: this.theme.textOnPrimary })
          Text('一同下载 JDK ' + this.currentJdk)
            .fontSize(15).fontWeight(700).fontColor(this.theme.textOnPrimary)
        }
        .width('100%').height(48)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.theme.primary)
        .borderRadius(24)
        .onClick(() => { this.startJdkDownloadFlow() })
      }
      Row({ space: 10 }) {
      // 一键修复（失败项带 fixActionKey 时；JDK 缺失走下方专用块，此处跳过）
      if (this.firstFailed() !== null && (this.firstFailed() as PreLaunchCheck).fixActionKey.length > 0 && !this.isJdkMissingFailed()) {
        Text(this.fixLabel((this.firstFailed() as PreLaunchCheck).fixActionKey))
          .layoutWeight(1)
          .height(48)
          .fontSize(15)
          .fontWeight(700)
          .fontColor(this.theme.textOnPrimary)
          .backgroundColor(this.theme.primary)
          .borderRadius(24)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            let f = this.firstFailed();
            if (f !== null) {
              if (this.canRepairInSheet(f.fixActionKey)) {
                this.startRepairFlow();        // 就地修复，不跳转下载页
              } else if (f.fixActionKey === 'jdk_mismatch') {
                // 就地改回自动路由并重跑 —— 与 jdkWarn 那条分支同一个动作。
                let nv = this.switchJdkToAuto();
                if (nv.length > 0) this.currentJdk = nv;
                this.jdkWarnAccepted = false;
                this.runAll();
              } else {
                this.onFix(f.fixActionKey);     // JDK / 版本管理等需跳转
              }
            }
          })
      }

      // 重试
      Text('重试')
        .layoutWeight(1)
        .height(48)
        .fontSize(15)
        .fontWeight(600)
        .fontColor(this.theme.primary)
        .backgroundColor(this.theme.primaryLight)
        .borderRadius(24)
        .textAlign(TextAlign.Center)
        .onClick(() => { this.runAll(); })

      // 去 JDK 管理（仅 JDK 缺失时作为副选项，去下载页手动管理/换版本）
      if (this.isJdkMissingFailed()) {
        Text('去 JDK 管理')
          .layoutWeight(1)
          .height(48)
          .fontSize(15)
          .fontWeight(600)
          .fontColor(this.theme.textSecondary)
          .backgroundColor(this.theme.bgCard)
          .borderRadius(24)
          .textAlign(TextAlign.Center)
          .onClick(() => { this.onFix('open_jdk_manager'); })
      }

      // 取消
      Text('取消')
        .height(48)
        .padding({ left: 20, right: 20 })
        .fontSize(15)
        .fontWeight(600)
        .fontColor(this.theme.textSecondary)
        .backgroundColor(this.theme.bgCard)
        .borderRadius(24)
        .textAlign(TextAlign.Center)
        .onClick(() => { this.onClose() })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }

  /** JDK 版本不匹配时的决策视图（phase === 'jdkWarn'）：改用自动 / 保留并继续 / 取消。 */
  @Builder
  JdkWarnActions_() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        AppIcon({ name: AppIconName.Warning, iconSize: 18, color: this.theme.warning })
        Text('JDK 版本可能不匹配')
          .fontSize(14).fontWeight(700).fontColor(this.theme.warning)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text('为此版本单独指定的 JDK ' + this.currentJdk + ' 低于建议的 JDK ' + this.jdkRange.minMajor
        + '，可能无法正常运行。可改用自动选择，或坚持以此 JDK 启动（调试用）。')
        .fontSize(12).lineHeight(17).fontColor(this.theme.textSecondary).width('100%')

      Row({ space: 10 }) {
        // 改用自动 JDK（推荐）
        Text('改用自动 JDK')
          .layoutWeight(1)
          .height(48)
          .fontSize(15)
          .fontWeight(700)
          .fontColor(this.theme.textOnPrimary)
          .backgroundColor(this.theme.primary)
          .borderRadius(24)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            let nv = this.switchJdkToAuto();
            if (nv.length > 0) this.currentJdk = nv;
            this.jdkWarnAccepted = false;
            this.runAll();
          })

        // 保留此 JDK 继续（调试）
        Text('保留并继续')
          .layoutWeight(1)
          .height(48)
          .fontSize(15)
          .fontWeight(600)
          .fontColor(this.theme.warning)
          .backgroundColor(this.theme.warningBg)
          .borderRadius(24)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.jdkWarnAccepted = true;
            this.runAll();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 取消启动
      Text('取消')
        .width('100%')
        .height(44)
        .fontSize(14)
        .fontWeight(600)
        .fontColor(this.theme.textSecondary)
        .backgroundColor(this.theme.bgCard)
        .borderRadius(22)
        .textAlign(TextAlign.Center)
        .onClick(() => { this.onClose() })
    }
    .width('100%')
  }

  /** 就地修复进度视图（phase === 'repairing'）：镜像 registry 里修复任务的进度。 */
  @Builder
  RepairingView_() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        LoadingProgress().width(20).height(20).color(this.theme.primary)
        Text(this.repairLabel.length > 0 ? this.repairLabel : '正在修复…')
          .fontSize(13)
          .fontWeight(600)
          .fontColor(this.theme.textPrimary)
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.repairProgress + '%')
          .fontSize(13)
          .fontWeight(700)
          .fontColor(this.theme.primary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Progress({ value: this.repairProgress, total: 100, type: ProgressType.Linear })
        .width('100%')
        .color(this.theme.primary)

      Text('修复仍走统一下载器（下载页可查看）。完成后将自动重新校验。')
        .fontSize(11)
        .fontColor(this.theme.textHint)
        .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(14)
  }
}
