import { fileIo as fs } from '@kit.CoreFileKit';
import { safeBaseName } from 'feature_core';
import { toggleEnabledFilename } from 'mods';
import { ProductQa } from 'entry/ProductQa';
import { InstalledResourceRow } from './ets/components/InstalledResourceData';
import { LocalResourceAccess } from './ets/runtime/LocalResourceAccess';

interface ResourceRef { row: InstalledResourceRow; identity: string; }
interface Choice { token: string; ref: string; epoch: number; }
function answer(status: string, reason: string = '', data: Record<string,Object> = {}): string {
  return JSON.stringify({status:status,reason:reason,data:data});
}
function fileKey(dir: string, row: InstalledResourceRow): string {
  if (!dir || !row.filename || safeBaseName(row.filename) !== row.filename || row.filePath !== dir + '/' + row.filename) return '';
  const st = fs.lstatSync(row.filePath);
  return st.isFile() && !st.isSymbolicLink() ? [String(st.ino),String(st.size),String(st.mtime),String(st.ctime)].join('/') : '';
}

/** 不透明行标识只服务一次页面扫描和设备会话，文件替换或切换隔离根后不得继续写。 */
export class ProductQaLibrary {
  private scope: string = '';
  private rows: Map<string,ResourceRef> = new Map<string,ResourceRef>();
  private choice: Choice | undefined;

  async run(access: LocalResourceAccess, action: string, json: string, id: string): Promise<string> {
    const dir = ProductQa.sessionDirectory();
    if (!dir || !access.active) return answer('needsUser','RESOURCE_PAGE_INACTIVE');
    const scope = JSON.stringify([dir,access.version,access.kind,access.directory,String(access.epoch)]);
    if (scope !== this.scope) {
      this.scope = scope;
      this.rows.clear(); this.choice = undefined;
    }
    const args = JSON.parse(json) as Record<string,Object>;
    if (action === 'library.close' && !Object.keys(args).length && !access.pending) {
      access.back(); return answer('ok','',{ 'closed':true });
    }
    if (!access.ready || access.error) return answer('unknown', access.error ? 'RESOURCE_SCAN_FAILED' : 'RESOURCE_SCAN_PENDING');
    if (action === 'library.list') {
      const offset = args['offset'] as number ?? 0;
      const limit = args['limit'] as number ?? 50;
      if (Object.keys(args).some((k:string):boolean=>k!=='limit' && k!=='offset') || !Number.isSafeInteger(offset) ||
        offset < 0 || !Number.isSafeInteger(limit) || limit < 1 || limit > 100) return answer('rejected','INVALID_ARGUMENTS');
      const items: Record<string,Object>[] = [];
      for (let i=offset;i<Math.min(access.rows.length,offset+limit);i++) {
        const row = access.rows[i];
        const ref = id + '-' + String(i);
        const key = fileKey(access.directory,row);
        if (!key) return answer('unknown','RESOURCE_CHANGED');
        this.rows.set(ref, {row:row,identity:key});
        items.push({'ref':ref,'filename':row.filename,'enabled':row.enabled,'size':row.sizeBytes});
      }
      return answer('ok','',{ 'version':access.version,'kind':access.kind,'shared':access.shared,'items':items,'total':access.rows.length,'offset':offset });
    }
    const ref = args['ref'];
    const item = typeof ref === 'string' ? this.rows.get(ref) : undefined;
    if (typeof ref !== 'string' || !item || !access.rows.includes(item.row)) return answer('rejected','STALE_RESOURCE');
    const row = item.row;
    try {
      if (item.identity !== fileKey(access.directory,row)) return answer('rejected','RESOURCE_CHANGED');
      if (action === 'library.toggle' && typeof args['enabled'] === 'boolean' && Object.keys(args).length === 2 && !access.pending) {
        if (!access.togglable) return answer('rejected','TOGGLE_UNAVAILABLE');
        const enabled = args['enabled'] as boolean;
        const target = access.directory + '/' + toggleEnabledFilename(row.filename,enabled);
        if (enabled !== row.enabled && fs.accessSync(target)) return answer('rejected','TARGET_EXISTS');
        const outcome=await access.toggle(row,enabled);
        if (outcome['state']!=='ready') return answer(outcome['state']==='unknown'?'unknown':'rejected',String(outcome['reason'] ?? outcome['state']));
        if (!fs.accessSync(target) || (target !== row.filePath && fs.accessSync(row.filePath))) return answer('unknown','TOGGLE_NOT_VERIFIED');
        return answer('ok','',{ 'ref':ref,'enabled':enabled });
      }
      if (action === 'library.delete.prepare' && Object.keys(args).length === 1 && !access.pending) {
        const epoch = access.prompt(row.filename);
        if (epoch<0) return answer('rejected','RESOURCE_CHANGED');
        this.choice = {token:id,ref:ref,epoch:epoch};
        return answer('needsUser','CONFIRM_RESOURCE_DELETE',{ 'planId':id,'ref':ref,'filename':row.filename,'version':access.version,'shared':access.shared });
      }
      const choice = this.choice;
      if (!choice || Object.keys(args).length !== 2 || args['planId'] !== choice.token || ref !== choice.ref ||
        access.pending !== row.filename || choice.epoch !== access.confirmation) return answer('rejected','STALE_CONFIRMATION');
      if (action === 'library.delete.cancel') { access.cancel(); this.choice=undefined; return answer('ok','',{ 'ref':ref,'removed':false }); }
      if (action === 'library.delete.confirm') {
        this.choice=undefined;
        if (!access.remove() || fs.accessSync(row.filePath)) return answer('unknown','DELETE_NOT_VERIFIED');
        return answer('ok','',{ 'ref':ref,'removed':true });
      }
    } catch (_) { return answer('unknown','RESOURCE_STATE_UNAVAILABLE'); }
    return answer('rejected','INVALID_ACTION_OR_ARGUMENTS');
  }
}
