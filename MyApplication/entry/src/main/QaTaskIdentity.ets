import { TaskCategory, UnifiedTaskView, safeBaseName } from 'feature_core';

/** 对外的任务别名隐藏文件路径；零活动号的排队项另绑定一次真实列表请求与活对象。 */
let active = '';
let serial = 0;
let aliases: WeakMap<UnifiedTaskView, string> = new WeakMap<UnifiedTaskView, string>();
let references: WeakMap<UnifiedTaskView, string> = new WeakMap<UnifiedTaskView, string>();

function setSession(directory: string): void {
  if (directory === active) return;
  active=directory; serial=0;
  aliases=new WeakMap<UnifiedTaskView,string>(); references=new WeakMap<UnifiedTaskView,string>();
}

export function qaTaskId(directory: string, view: UnifiedTaskView): string {
  setSession(directory);
  if (view.category === TaskCategory.MC_VERSION && view.id === 'mc:' + view.title && view.title.length > 0 &&
    safeBaseName(view.title) === view.title && !view.title.includes(':')) return view.id;
  let alias=aliases.get(view);
  if (alias === undefined) { alias='observation-'+(++serial).toString(); aliases.set(view,alias); }
  return alias;
}

/** 只有 list 才能签发行引用；进程重建后相同队列序号和任务名也不继承旧引用。 */
export function qaTaskRef(directory: string, view: UnifiedTaskView, listing: string = ''): string {
  setSession(directory);
  let ref=references.get(view);
  if (ref === undefined && listing.length>0) {
    ref=listing+'-'+(++serial).toString(); references.set(view,ref);
  }
  return ref ?? '';
}
