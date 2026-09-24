/**
 * UnifiedDownloadTask.ets — 统一下载任务模型（2026-05-22）
 *
 * 该文件定义所有"用户可见的下载任务"在 UI 层的统一表示，使
 * MC 版本 / 模组 / 光影 / 资源包 / 数据包 / 整合包 / JDK 七类
 * 下载在 `DownloadTasksSheet` 里拥有一致的卡片样式 + 一致的操作集。
 *
 * 设计要点：
 *   - `UnifiedTaskView` 用 `@Observed` —— 让 TaskCard 用 `@ObjectLink` 直接订阅
 *     单个任务的字段刷新，避免每次进度 tick 都要重建整个列表
 *   - `UnifiedDownloadAdapter` 是适配器接口（不是基类）—— 三种 adapter
 *     （McVersionTask / ResourceInstallTask / JdkInstallTask）各自包装一种
 *     底层任务，对外暴露统一的 start/cancel/pause/resume/retry/canXxx API
 *
 * 相关文档：docs/guides/download-multi-task-design.md § 零
 * 设计源文件：docs/design/download_tasks_sheet.pen
 */

/** 所有下载在 sheet 中的统一类别。决定卡片色 / 图标 / 进度条颜色。 */
export enum TaskCategory {
  MC_VERSION = 'mc',         // 蓝色 ⛏ Minecraft（多阶段）
  MOD = 'mod',               // 紫色 🧩 拼图块
  SHADER = 'shader',         // 靛蓝 ✨ 闪光
  RESOURCE_PACK = 'rpack',   // 粉色 🎨 调色板
  DATAPACK = 'datapack',     // 青色 📜 卷轴
  MODPACK = 'modpack',       // 橙色 📦 礼盒
  JDK = 'jdk',               // 红橙 ☕ 咖啡杯
}

/** 任务在 sheet 中可见的统一状态。 */
export enum UnifiedTaskState {
  WAITING = 'waiting',       // 在 registry 队列里，未启动
  PREPARING = 'preparing',   // 已启动但还没开始拉文件（取版本元、解析依赖）
  DOWNLOADING = 'downloading',
  EXTRACTING = 'extracting', // JDK / modpack zip 解压
  VERIFYING = 'verifying',   // SHA-256 / 完整性
  PAUSED = 'paused',
  DONE = 'done',
  ERROR = 'error',
  ABORTED = 'aborted',
}

/**
 * 判定是否为**活跃态**（任务正在跑，不含 PAUSED）。
 *
 * 用法语义："任务能否被暂停 / 是否在执行"。UI 上"取消+暂停"按钮组的判定。
 *
 * 注意：如果你想问"任务是否还没结束（含暂停）"，请用 `isInProgressState`。
 */
export function isActiveState(s: string): boolean {
  return s === UnifiedTaskState.PREPARING
      || s === UnifiedTaskState.DOWNLOADING
      || s === UnifiedTaskState.EXTRACTING
      || s === UnifiedTaskState.VERIFYING;
}

/**
 * 判定是否为**进行中**（活跃 + 暂停）—— 任务尚未到终态、尚未离开队列。
 *
 * B-5 修复（2026-05-26）：原本各调用方在 `isActiveState() || PAUSED` 处复制了
 * 4 次，语义易漂移。统一收口到本函数，给 aggregateProgress / activeCount 等
 * 统计性场景用。详见 docs/self-inspection/2026-05-26_AMCL_多任务下载并发缺陷诊断.md §B-5
 *
 * 注意：本函数**不**包括 WAITING（"已 enqueue 但还没轮到跑"），需要 WAITING
 * 的调用方仍要单独 `|| state === WAITING`。
 */
export function isInProgressState(s: string): boolean {
  return isActiveState(s) || s === UnifiedTaskState.PAUSED;
}

/** 判定是否为终态。 */
export function isTerminalState(s: string): boolean {
  return s === UnifiedTaskState.DONE
      || s === UnifiedTaskState.ERROR
      || s === UnifiedTaskState.ABORTED;
}

/**
 * Sheet 用的统一任务视图。`@Observed` 让 TaskCard `@ObjectLink` 它后
 * 单字段刷新即可重绘卡片，无需父组件重建数组。
 */
@Observed
export class UnifiedTaskView {
  /** registry 内唯一 key（"mc:1.20.4" / "mod:sodium-0.5.8" / "jdk:17"） */
  id: string = '';
  category: TaskCategory = TaskCategory.MC_VERSION;
  /** 卡片标题（"Minecraft 1.20.4" / "Sodium" / "JDK 17"） */
  title: string = '';
  /** 副标题（"Fabric 0.16.10 · 285 MB" / "+ 2 依赖" / "OpenJDK 17.0.13-ohos-4"） */
  subtitle: string = '';
  /** 远程图标 URL（模组/资源的项目图标）；为空时卡片回退用分类图标。 */
  iconUrl: string = '';

  state: string = UnifiedTaskState.WAITING;
  /** 0-100；waiting 状态时为 0。多阶段任务为工作量估算，终态 DONE 必须为 100。 */
  progress: number = 0;
  /** true 表示当前百分比是阶段/工作量估算，而非端到端精确字节比。 */
  progressEstimated: boolean = false;
  /** 当前活跃阶段 / 主文件名（"libraries (32/47)" / "fabric-api-0.91.3.jar"） */
  currentLabel: string = '';

  /** 字节进度。bytesTotal=0 表示未知 */
  bytesDone: number = 0;
  bytesTotal: number = 0;
  /** 文件计数。filesTotal=0 表示单文件任务 */
  filesDone: number = 0;
  filesTotal: number = 0;
  speedBps: number = 0;
  etaSeconds: number = -1;   // -1 = 未知
  durationMs: number = 0;
  startedAtMs: number = 0;
  /** 明确的上次尝试/父任务身份；只由入队调用方或 retry 操作设置，不按标题猜关系。 */
  parentActivityId: number = 0;
  activityRelation: string = '';

  /** 可执行的操作（决定卡片右侧按钮组）。 */
  canPause: boolean = false;
  canResume: boolean = false;
  canCancel: boolean = false;
  canRetry: boolean = false;
  /** MC 整版有 6 阶段详情；JDK 有 3 阶段；mod 有文件级 */
  canViewDetail: boolean = false;

  /** 仅 ERROR 态：错误类型（"Network" / "Sha1Mismatch"）+ 文案 */
  errorKind: string = '';
  errorMessage: string = '';

  /** 队列位置（仅 WAITING 态使用，1-based） */
  queuePosition: number = 0;
}

/**
 * 适配器接口。Registry 仅持有 adapter 引用；adapter 自己 hold underlying
 * task（DownloadTask / ModInstaller invocation / JdkManager invocation）。
 *
 * 生命周期约定：
 *   - 构造 adapter 时已经预填好 view（title / subtitle / category）
 *   - registry.enqueue() 调 start()
 *   - adapter 在内部回调里持续刷 view 字段（自动触发 @ObjectLink）
 *   - 终态时 adapter 不要清 view —— 等用户主动清理 / 自动 purge
 */
export interface UnifiedDownloadAdapter {
  readonly view: UnifiedTaskView;

  /** 启动任务。返回 Promise 用于 registry 串联终态 */
  start(): Promise<void>;

  /** 取消（用户主动）。adapter 内部决定是否清理已下文件 */
  cancel(cleanupFiles: boolean): Promise<void>;

  /** 暂停（部分类型不支持，看 view.canPause） */
  pause(): Promise<void>;

  /** 恢复 */
  resume(): Promise<void>;

  /** 重试（仅 ERROR / ABORTED / PAUSED 态可用） */
  retry(): Promise<void>;

  /**
   * 可选 native owner purge hook。返回 false 时 Registry 必须保留 adapter，供稍后重试清理。
   * 老 adapter 无此 hook 时仍只走 dispose，保持结构兼容。
   */
  purgeNativeOwner?: () => boolean;

  /** 销毁 adapter —— registry purge 时调用，给 adapter 一次释放 ArkTS 回调/资源的机会 */
  dispose(): void;
}

// ============================================================
//  纯函数：分类色 + 图标映射 + 状态文本（UI 复用）
// ============================================================

/** 分类对应的主色 token 名（直接给 fill 字符串用）。 */
export function categoryColorToken(c: TaskCategory): string {
  switch (c) {
    case TaskCategory.MC_VERSION:    return '$taskMcBlue';
    case TaskCategory.MOD:           return '$taskModPurple';
    case TaskCategory.SHADER:        return '$taskShaderIndigo';
    case TaskCategory.RESOURCE_PACK: return '$taskRpackPink';
    case TaskCategory.DATAPACK:      return '$taskDatapackTeal';
    case TaskCategory.MODPACK:       return '$taskModpackOrange';
    case TaskCategory.JDK:           return '$taskJdkRedOrange';
    default:                          return '$primary';
  }
}

/** 分类对应的浅色背景 token（徽章背景用）。 */
export function categoryBgToken(c: TaskCategory): string {
  switch (c) {
    case TaskCategory.MC_VERSION:    return '$taskMcBg';
    case TaskCategory.MOD:           return '$taskModBg';
    case TaskCategory.SHADER:        return '$taskShaderBg';
    case TaskCategory.RESOURCE_PACK: return '$taskRpackBg';
    case TaskCategory.DATAPACK:      return '$taskDatapackBg';
    case TaskCategory.MODPACK:       return '$taskModpackBg';
    case TaskCategory.JDK:           return '$taskJdkBg';
    default:                          return '$primaryLight';
  }
}

/** 状态对应的中文文案（用于 TaskCard 状态行）。 */
export function stateLabel(s: string): string {
  switch (s) {
    case UnifiedTaskState.WAITING:     return '等待中';
    case UnifiedTaskState.PREPARING:   return '准备中';
    case UnifiedTaskState.DOWNLOADING: return '下载中';
    case UnifiedTaskState.EXTRACTING:  return '解压中';
    case UnifiedTaskState.VERIFYING:   return '校验中';
    case UnifiedTaskState.PAUSED:      return '已暂停';
    case UnifiedTaskState.DONE:        return '已完成';
    case UnifiedTaskState.ERROR:       return '失败';
    case UnifiedTaskState.ABORTED:     return '已取消';
    default:                            return s;
  }
}

/** 分类对应的中文短标签（用于副标题前缀）。 */
export function categoryLabel(c: TaskCategory): string {
  switch (c) {
    case TaskCategory.MC_VERSION:    return 'Minecraft';
    case TaskCategory.MOD:           return '模组';
    case TaskCategory.SHADER:        return '光影';
    case TaskCategory.RESOURCE_PACK: return '资源包';
    case TaskCategory.DATAPACK:      return '数据包';
    case TaskCategory.MODPACK:       return '整合包';
    case TaskCategory.JDK:           return 'JDK';
    default:                          return '';
  }
}

/**
 * 把若干 view 的进度按字节加权平均。若全部 bytesTotal=0 用等权重。
 * Registry 给 FAB 提供"全局进度"用。
 */
export function aggregateProgress(views: UnifiedTaskView[]): number {
  let actives: UnifiedTaskView[] = [];
  for (let v of views) {
    if (isInProgressState(v.state)) {
      actives.push(v);
    }
  }
  if (actives.length === 0) return 0;
  // 按 bytesTotal 加权
  let totalWeight = 0;
  let weightedSum = 0;
  let anyKnown = false;
  for (let v of actives) {
    if (v.bytesTotal > 0) {
      anyKnown = true;
      totalWeight += v.bytesTotal;
      weightedSum += v.bytesTotal * v.progress;
    }
  }
  if (anyKnown && totalWeight > 0) {
    return weightedSum / totalWeight;
  }
  // 全部未知字节 → 等权重
  let sum = 0;
  for (let v of actives) sum += v.progress;
  return sum / actives.length;
}
