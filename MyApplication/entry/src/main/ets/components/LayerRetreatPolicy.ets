/**
 * 下载六分类与活动账本共用的辅助层退让纯数值策略。
 * 页面负责实际层高、输入资格及展示状态；本类不持有列表、查询、目标或任务身份。
 * 每次动画只推进一个完整层级；持续拖动期间的真实位移保留为有界预算，完成后串接下一层。
 * 列表始终获得原始位移，不把整层高度错误地从几个vp的触发帧中扣掉。
 */
export interface RetreatFrame {
  /** 本帧后已隐藏的辅助区高度，单位vp，始终限制在当前可退让范围内。 */
  hidden: number;
  /** 原始列表位移；本策略只触发整层展示变化，不吞掉或反转正文滚动。 */
  offsetRemain: number;
}

/** 无计时器或异步资源的方向迟滞；页面离开、查询变化与新手势时可以直接reset。 */
export class LayerRetreatPolicy {
  private direction_: number = 0;
  private pending_: number = 0;
  private accepted_: boolean = false;
  private reversePending_: number = 0;

  /** 清除旧手势方向，不改变页面保存的隐藏量或用户手动展开偏好。 */
  reset(): void {
    this.direction_ = 0;
    this.pending_ = 0;
    this.accepted_ = false;
    this.reversePending_ = 0;
  }

  /** 抬手/取消只丢弃未播放的预算，当前已开始的动画仍能正常完成并解除UI锁。 */
  cancelQueuedContinuation(): void {
    this.pending_ = 0;
    this.reversePending_ = 0;
  }

  /** 获取当前层集合中的相邻完整端点，不跳层。 */
  private adjacent_(previous: number, boundaries: number[], direction: number): number {
    if (direction > 0) {
      for (const boundary of boundaries) if (boundary > previous + 0.5) return boundary;
    } else {
      for (let index: number = boundaries.length - 1; index >= 0; index--) {
        if (boundaries[index] < previous - 0.5) return boundaries[index];
      }
    }
    return previous;
  }

  /** 预算最多覆盖剩余层数，避免长滑在末端积出无限待播距离。 */
  private capBudget_(previous: number, boundaries: number[], direction: number, budget: number): number {
    let remaining: number = 0;
    for (const boundary of boundaries) {
      if ((direction > 0 && boundary > previous + 0.5) || (direction < 0 && boundary < previous - 0.5)) remaining++;
    }
    return Math.min(Math.max(0, budget), remaining * (direction > 0 ? 18 : 6));
  }

  /**
   * 当前有效动画完成后最多取一个下一端点。只有触点仍有效且当前页面可用才续播；
   * 不足一档保留余额等后续真实输入，小反向已出现则禁止继续旧向。没有有效层或已到
   * 边界时清预算，不对相同端点开启动画，零时长模式也只能有限推进。
   */
  finishTransition(hidden: number, layers: number[], enabled: boolean, dragging: boolean): RetreatFrame {
    if (!enabled || !dragging) {
      this.reset();
      return { hidden: Number.isFinite(hidden) ? Math.max(0, hidden) : 0, offsetRemain: 0 };
    }
    const boundaries: number[] = [0];
    let total: number = 0;
    for (const height of layers) {
      if (Number.isFinite(height) && height > 0) { total += height; boundaries.push(total); }
    }
    const previous: number = Number.isFinite(hidden) ? Math.max(0, Math.min(total, hidden)) : 0;
    this.accepted_ = false;
    if (this.direction_ === 0 || this.reversePending_ > 0) return { hidden: previous, offsetRemain: 0 };
    const threshold: number = this.direction_ > 0 ? 18 : 6;
    if (this.pending_ < threshold) return { hidden: previous, offsetRemain: 0 };
    const next: number = this.adjacent_(previous, boundaries, this.direction_);
    if (next === previous) { this.reset(); return { hidden: previous, offsetRemain: 0 }; }
    this.pending_ = this.capBudget_(next, boundaries, this.direction_, this.pending_ - threshold);
    this.accepted_ = true;
    return { hidden: next, offsetRemain: 0 };
  }

  /**
   * 按当前有效层高生成完整端点。正值达到18vp退一层，反向达到6vp恢复一层；
   * 动画中同向帧只增加未消耗预算、不重启动画；完成时由finishTransition串接下一层。
   * 小幅反向抖动不解除已触发的同向锁；真正反向可以立即重定向正在播放的动画。
   * 这些值是待用户体验的样例参数；惯性、回弹、程序定位不改变展示端点。
   */
  step(offset: number, hidden: number, layers: number[], enabled: boolean, userInput: boolean): RetreatFrame {
    const boundaries: number[] = [0];
    let capacity: number = 0;
    for (const height of layers) {
      if (Number.isFinite(height) && height > 0) {
        capacity += height;
        boundaries.push(capacity);
      }
    }
    const previous: number = Number.isFinite(hidden) ? Math.min(capacity, Math.max(0, hidden)) : 0;
    if (!Number.isFinite(offset)) return { hidden: previous, offsetRemain: 0 };
    if (!enabled) {
      this.reset();
      return { hidden: previous, offsetRemain: offset };
    }
    if (!userInput || Math.abs(offset) < 0.01) return { hidden: previous, offsetRemain: offset };
    const direction: number = offset > 0 ? 1 : -1;
    const threshold: number = direction > 0 ? 18 : 6;
    if (this.direction_ === 0) {
      this.direction_ = direction;
      this.pending_ = Math.abs(offset);
    } else if (direction !== this.direction_) {
      // 首个反向帧即废弃旧向待播距离，避免尚未过反向迟滞时旧动画又向前补播。
      this.pending_ = 0;
      this.reversePending_ += Math.abs(offset);
      if (this.reversePending_ < threshold) return { hidden: previous, offsetRemain: offset };
      this.direction_ = direction;
      this.pending_ = this.reversePending_;
      this.reversePending_ = 0;
      this.accepted_ = false;
    } else {
      this.reversePending_ = 0;
      if (this.accepted_) {
        this.pending_ = this.capBudget_(previous, boundaries, direction, this.pending_ + Math.abs(offset));
        return { hidden: previous, offsetRemain: offset };
      }
      this.pending_ += Math.abs(offset);
    }
    if (this.pending_ < threshold) return { hidden: previous, offsetRemain: offset };
    const next: number = this.adjacent_(previous, boundaries, direction);
    if (next === previous) { this.reset(); return { hidden: previous, offsetRemain: offset }; }
    this.accepted_ = true;
    this.pending_ = this.capBudget_(next, boundaries, direction, this.pending_ - threshold);
    return { hidden: next, offsetRemain: offset };
  }
}

/**
 * 根据退让优先级分配单层可见高度。precedingHeight是先于本层收起的层高总和，
 * 与屏幕视觉排列独立；因此可以先收最靠近结果的排序，再收Loader，最后收目标。
 */
export function retreatLayerHeight(fullHeight: number, hidden: number, precedingHeight: number): number {
  return Math.max(0, fullHeight - Math.max(0, hidden - precedingHeight));
}

/** 完整内容只沿Y轴移出裁剪壳；内容自身保持缓存的全高，不做缩放或逐帧压扁。 */
export function retreatLayerOffset(fullHeight: number, hidden: number, precedingHeight: number): number {
  return retreatLayerHeight(fullHeight, hidden, precedingHeight) - fullHeight;
}

/**
 * 固定结果视口的内容首占位：开始浏览前跟随自然测量，首次滚动/显式辅助操作时冻结。
 * 收展只改变覆盖层，不能把隐藏量或当前手动偏好回写到已冻结占位，否则条目又会跳动。
 */
export function retreatStableInset(frozen: number, expanded: number): number {
  if (Number.isFinite(frozen) && frozen >= 0) return frozen;
  return Number.isFinite(expanded) ? Math.max(0, expanded) : 0;
}

/** 首占位是实际ListItem，扣除其后的List.space，保持第一条内容原有初始位置。 */
export function retreatLeadItemHeight(inset: number, spacing: number): number {
  return Math.max(0, inset - spacing);
}

/**
 * 真实起点的展示复位规则，独立于逐层方向阈值。必须有有效的实际总偏移，且已在
 * 向起点返回，或原生滚动已静止；不能把未绑定/非有限偏移或首个正向预计帧当到顶。
 * 当前结构没有contentStartOffset，负总偏移表示已经过起点的Spring回弹，同样可恢复。
 */
export function retreatNeedsTopRestore(hidden: number, actualOffset: number,
  returning: boolean, settled: boolean): boolean {
  return hidden > 0 && Number.isFinite(actualOffset) && actualOffset <= 0.5 && (returning || settled);
}
