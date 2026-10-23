/** 商店管理首页的纯投影：文件核验、写入占用与运行权限分别表达，不用目录存在冒充完整。 */
export interface StoreManagerUiInput {
  checking: boolean;
  currentReady: boolean;
  otherReady: boolean;
  hasCandidates: boolean;
  busy: boolean;
  failed: boolean;
  exporting: boolean;
}

export function storeManagerAction(input: StoreManagerUiInput): string {
  if (input.exporting) return 'progress';
  if (input.currentReady && !input.busy) return 'export';
  if (input.busy) return 'downloads';
  if (input.otherReady) return 'choose';
  if (input.checking) return 'checking';
  if (input.failed) return 'repair';
  return input.hasCandidates ? 'check' : 'download';
}

export function storeManagerActionLabel(action: string): string {
  if (action === 'progress') return '查看导出进度';
  if (action === 'export') return '导出游戏包';
  if (action === 'choose') return '选择可导出的版本';
  if (action === 'downloads') return '查看下载 / 继续下载';
  if (action === 'checking') return '正在检查版本';
  if (action === 'repair') return '检查并补全版本';
  if (action === 'check') return '检查版本文件';
  if (action === 'storage') return '检查存储位置';
  if (action === 'session') return '返回现有游戏 / 退出';
  return '引导下载';
}
