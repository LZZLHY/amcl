import { McVersion } from 'feature_core';
import { FrameCallback, UIContext } from '@kit.ArkUI';

/** 首帧完成后放行；持续满帧时最迟第二个 VSync 放行。两个回调竞争同一个一次性动作。 */
export class VersionRowsInitialFrame extends FrameCallback {
  private action_: (() => void) | null;
  private context_: UIContext | null;
  constructor(context: UIContext | null, action: () => void) {
    super(); this.context_ = context; this.action_ = action;
  }
  onFrame(_frameTimeInNano: number): void {
    if (this.action_ === null) return;
    const context = this.context_;
    if (context === null) { this.finish_(); return; }
    this.context_ = null;
    // 首帧起点不改姿态。若系统没有帧尾空闲，下一帧开始时首帧布局已生效。
    try { context.postFrameCallback(new VersionRowsInitialFrame(null, (): void => this.finish_())); }
    catch (_) { this.finish_(); }
  }
  onIdle(_timeLeftInNano: number): void { this.finish_(); }
  private finish_(): void {
    const action = this.action_;
    this.cancel();
    if (action !== null) action();
  }
  /** 任一排队中的系统回调稍后都不能访问已离开的页面或下轮动画。 */
  cancel(): void { this.context_ = null; this.action_ = null; }
}

/** 同一版本修订类别或日期时才重建这一行，网络地址变化不改变行的视觉身份。 */
export function downloadRowKey(row: McVersion): string {
  return JSON.stringify([row.id, row.type, row.displayDate]);
}

/** 版本下载页筛选后的行数据。增删通知带原生索引，使未改动的行继续保有身份与阅读位置。 */
export class VersionDownloadRowSource implements IDataSource {
  private rows_: McVersion[] = [];
  private ids_: Set<string> = new Set<string>();
  private listeners_: Set<DataChangeListener> = new Set<DataChangeListener>();

  totalCount(): number { return this.rows_.length; }
  getData(index: number): McVersion { return this.rows_[index]; }
  /** 查询当前筛选结果的成员，独立于整份目录是否刚收录该版本。 */
  has(id: string): boolean { return this.ids_.has(id); }
  registerDataChangeListener(listener: DataChangeListener): void { this.listeners_.add(listener); }
  unregisterDataChangeListener(listener: DataChangeListener): void { this.listeners_.delete(listener); }

  /** 相邻增删各按一段通知。只有新建视图或保留行被真正重排时，才依靠稳定键重新加载。 */
  replace(next: McVersion[]): void {
    const previous = this.rows_;
    const nextIds = new Set<string>(next.map((row: McVersion): string => row.id));
    if (previous.length === 0) {
      this.rows_ = next;
      this.ids_ = nextIds;
      if (next.length > 0) this.notify_([{ type: DataOperationType.RELOAD }]);
      return;
    }
    const retained: McVersion[] = [];
    const deletes: DataOperation[] = [];
    let index = 0;
    while (index < previous.length) {
      if (nextIds.has(previous[index].id)) {
        retained.push(previous[index]);
        index++;
      } else {
        const start = index;
        while (index < previous.length && !nextIds.has(previous[index].id)) index++;
        deletes.push({ type: DataOperationType.DELETE, index: start, count: index - start });
      }
    }
    const adds: DataOperation[] = [];
    const changes: DataOperation[] = [];
    let old = 0;
    index = 0;
    while (index < next.length) {
      if (this.ids_.has(next[index].id)) {
        if (old >= retained.length || retained[old].id !== next[index].id) {
          this.rows_ = next;
          this.ids_ = nextIds;
          this.notify_([{ type: DataOperationType.RELOAD }]);
          return;
        }
        if (next[index].type !== retained[old].type || next[index].displayDate !== retained[old].displayDate) {
          changes.push({ type: DataOperationType.CHANGE, index: index });
        }
        old++;
        index++;
      } else {
        const start = index;
        while (index < next.length && !this.ids_.has(next[index].id)) index++;
        adds.push({ type: DataOperationType.ADD, index: old, count: index - start });
      }
    }
    if (deletes.length > 0) {
      // 每批使用变化前的索引。先发布删除后的真实中间视图，保证 ADD 与 DELETE 不占用同一索引。
      this.rows_ = retained;
      this.ids_ = new Set<string>(retained.map((row: McVersion): string => row.id));
      this.notify_(deletes);
    }
    this.rows_ = next;
    this.ids_ = nextIds;
    // ADD 相对于刚保留的行，CHANGE 相对于插入完成的最终行。
    this.notify_(adds);
    this.notify_(changes);
  }

  private notify_(ops: DataOperation[]): void {
    if (ops.length === 0) return;
    for (const listener of this.listeners_) listener.onDatasetChange(ops);
  }
}

/** 卡片合成只使用不透明度和纵向位移。 */
export interface VersionRowCue {
  alpha: number;
  y: number;
  delay: number;
  duration: number;
}

/** 用布局前后的真实视口坐标计算位移，与目录索引、假定行高及滚动深度无关。
 * after 按屏幕从上到下传入；只有整页入场或在本轮新进入筛选结果的可见行消耗错峰档位。 */
export function versionRowCues(before: Map<string, number>, after: Map<string, number>, revealed: Set<string>,
  entering: boolean): Map<string, VersionRowCue> {
  const cues: Map<string, VersionRowCue> = new Map<string, VersionRowCue>();
  let revealCount = 0;
  after.forEach((top: number, id: string): void => {
    if (Number.isFinite(top) && (entering || revealed.has(id))) revealCount++;
  });
  // 小视口间隔 32ms；较高窗口压缩总错峰，最低 17ms 仍给每行约一个 60Hz 帧的独立起点。
  const step = Math.max(17, Math.min(32, 280 / Math.max(1, revealCount - 1)));
  let order = 0;
  after.forEach((top: number, id: string): void => {
    if (!Number.isFinite(top)) return;
    if (entering || revealed.has(id)) {
      const delay = (entering ? 0 : 40) + Math.round(order * step);
      cues.set(id, { alpha: 0.42, y: entering ? -7 : -9, delay: delay, duration: 230 });
      order++;
    } else {
      const previous = before.get(id);
      if (previous !== undefined && Number.isFinite(previous) && Math.abs(previous - top) > 0.5) {
        cues.set(id, { alpha: 1, y: previous - top, delay: 0, duration: 290 });
      }
    }
  });
  return cues;
}
