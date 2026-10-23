/**
 * 版本行的只读视图数据源。LazyForEach 只为当前视口构造行，版本发现、筛选与
 * 持久化仍由原页面负责；本类仅复制版本主键和通知 ArkUI，不读取文件或改偏好。
 * SDK onDataMove 的语义是交换两个位置，原拖拽的移除/插入通过相邻交换实现。
 */
export class VersionListDataSource implements IDataSource {
  private versions: string[] = [];
  /** 监听者由 LazyForEach 注册/注销，组件销毁后不继续持有其更新资格。 */
  private listeners: Set<DataChangeListener> = new Set<DataChangeListener>();

  totalCount(): number { return this.versions.length; }

  /** 仅返回已发现版本的稳定主键；框架索引越界不能伪造成一个空版本行。 */
  getData(index: number): string {
    if (!Number.isInteger(index) || index < 0 || index >= this.versions.length) {
      throw new RangeError('版本行索引越界');
    }
    return this.versions[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void { this.listeners.add(listener); }
  unregisterDataChangeListener(listener: DataChangeListener): void { this.listeners.delete(listener); }

  /** 筛选/安装/删除后的完整视图副本；原数组后续变化不会绕开框架通知。 */
  replace(versions: string[]): void {
    this.versions = versions.slice();
    for (const listener of this.listeners) listener.onDataReloaded();
  }

  /**
   * 保持原拖拽的“移除后插入”顺序，并逐次通知实际发生的相邻交换；每次通知时
   * 数据与 Native 子项索引一致，稳定版本 key 不变。非法索引不修改任何视图数据，
   * 页面可从自己的最终业务顺序重新发布，不能以错误位置交换另一个版本。
   */
  relocate(from: number, to: number): boolean {
    if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to < 0
      || from >= this.versions.length || to >= this.versions.length) return false;
    const direction: number = from < to ? 1 : -1;
    for (let current: number = from; current !== to; current += direction) {
      const next: number = current + direction;
      const previous: string = this.versions[current];
      this.versions[current] = this.versions[next];
      this.versions[next] = previous;
      for (const listener of this.listeners) listener.onDataMove(current, next);
    }
    return true;
  }
}
