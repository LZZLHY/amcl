/**
 * 已装资源的轻量行模型与惰性列表数据源。
 * 全量磁盘清单一直保存在内存中；搜索只生成其引用投影，不截断到首屏或来源反查预算。
 * 行属性由 @Observed / @ObjectLink 更新，图片与进度变化不会更换业务 key 或复制整份数组。
 */
export interface InstalledResourceValues {
  filePath: string;
  filename: string;
  displayName: string;
  enabled: boolean;
  sizeBytes: number;
  iconUrl: string;
  updateState: string;
  latestVersionNumber: string;
  updatingPct: number;
  integrity: string;
}

/** 单个实际文件的可观察状态；相同路径刷新时复用实例，避免稳定 key 绑定旧对象。 */
@Observed
export class InstalledResourceRow implements InstalledResourceValues {
  filePath: string = '';
  filename: string = '';
  displayName: string = '';
  enabled: boolean = true;
  sizeBytes: number = 0;
  iconUrl: string = '';
  updateState: string = 'none';
  latestVersionNumber: string = '';
  updatingPct: number = 0;
  integrity: string = 'none';

  constructor(value: InstalledResourceValues) { this.assign(value); }

  /** 合并一次完整枚举记录；仅有真实变更的属性会通知持有该行的组件。 */
  assign(value: InstalledResourceValues): void {
    this.filePath = value.filePath;
    this.filename = value.filename;
    this.displayName = value.displayName;
    this.enabled = value.enabled;
    this.sizeBytes = value.sizeBytes;
    this.iconUrl = value.iconUrl;
    this.updateState = value.updateState;
    this.latestVersionNumber = value.latestVersionNumber;
    this.updatingPct = value.updatingPct;
    this.integrity = value.integrity;
  }
}

/**
 * List + LazyForEach 的稳定数据源。路径是实际文件身份，已启用与禁用副本可同时存在。
 * 查询采用忽略大小写的多词 AND，各词可命中 filename 或 displayName；不执行任何 IO。
 */
export class InstalledResourceData implements IDataSource {
  private all_: InstalledResourceRow[] = [];
  private visible_: InstalledResourceRow[] = [];
  private byPath_: Map<string, InstalledResourceRow> = new Map<string, InstalledResourceRow>();
  private text_: Map<string, string> = new Map<string, string>();
  private listeners_: DataChangeListener[] = [];
  private query_: string = '';

  totalCount(): number { return this.visible_.length; }
  getData(index: number): InstalledResourceRow { return this.visible_[index]; }
  allRows(): InstalledResourceRow[] { return this.all_; }
  find(filePath: string): InstalledResourceRow | undefined { return this.byPath_.get(filePath); }

  /** 原始清单替换仅在真实扫描完成时执行；稳定路径保留原行的观察关系。 */
  replace(rows: InstalledResourceRow[]): InstalledResourceRow[] {
    const next: InstalledResourceRow[] = [];
    const paths = new Map<string, InstalledResourceRow>();
    this.text_.clear();
    for (const row of rows) {
      const existing = this.byPath_.get(row.filePath);
      const item = existing === undefined ? row : existing;
      if (existing !== undefined) existing.assign(row);
      next.push(item);
      paths.set(item.filePath, item);
      this.text_.set(item.filePath, (item.filename + '\n' + item.displayName).toLowerCase());
    }
    this.all_ = next;
    this.byPath_ = paths;
    this.filter(this.query_);
    return this.all_;
  }

  /** 过滤完整清单并发布引用投影；空查询恢复既有排序，无匹配不代表目录为空。 */
  filter(query: string): number {
    this.query_ = query;
    const terms = query.trim().toLowerCase().split(/\s+/).filter((word: string) => word.length > 0);
    this.visible_ = terms.length === 0 ? this.all_.slice() : this.all_.filter((row: InstalledResourceRow) => {
      const text = this.text_.get(row.filePath) ?? '';
      return terms.every((term: string) => text.indexOf(term) >= 0);
    });
    for (const listener of this.listeners_) listener.onDataReloaded();
    return this.visible_.length;
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners_.indexOf(listener) < 0) this.listeners_.push(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners_.indexOf(listener);
    if (index >= 0) this.listeners_.splice(index, 1);
  }
}
