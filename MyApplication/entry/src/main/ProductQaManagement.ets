import { fileIo as fs } from '@kit.CoreFileKit';
import { safeBaseName } from 'feature_core';
import { validateVersionName } from 'commons';
import { ResourceKind } from 'mods';
import { ProductQa } from 'entry/ProductQa';
import { LauncherManagementAccess } from './ets/runtime/LauncherManagementAccess';
import { OrphanCleanupPlan } from './ets/runtime/OrphanCleanup';

interface Deletion {
  session: string; request: string; root: string; version: string; identity: string; epoch: number;
}
function response(status: string, reason: string = '', data: Record<string, Object> = {}): string {
  return JSON.stringify({ status: status, reason: reason, data: data });
}

function kindOf(value: Object, local: boolean): ResourceKind | undefined {
  for (const kind of [ResourceKind.MOD, ResourceKind.SHADER, ResourceKind.RESOURCE_PACK,
    local ? ResourceKind.DATAPACK : ResourceKind.MODPACK]) {
    if (value === kind) return kind;
  }
  return undefined;
}

/** 只接受当前库存中的普通目录；确认关联目录和两个启动输入的文件身份。 */
function identity(root: string, version: string): string {
  const dir = root + '/versions/' + version;
  const facts: string[] = [];
  for (const name of ['', '/' + version + '.json', '/' + version + '.jar']) {
    const st = fs.lstatSync(dir + name);
    if (st.isSymbolicLink() || (name === '' ? !st.isDirectory() : !st.isFile())) return '';
    facts.push([ String(st.ino), String(st.size), String(st.mtime), String(st.ctime)].join('/'));
  }
  return facts.join('|');
}

export class ProductQaManagement {
  private deletion: Deletion | undefined;
  private orphan: OrphanCleanupPlan | undefined;
  private orphanSession: string = '';
  private orphanRequest: string = '';

  /** 管理场景复用 UI 的确认框、设置所有者和已装版本判据，不接受目录路径或删除通配符。 */
  async run(port: LauncherManagementAccess, action: string, raw: string, request: string): Promise<string> {
    const session = ProductQa.sessionDirectory();
    if (!session) return response('rejected', 'SESSION_CLOSED');
    const args = JSON.parse(raw) as Record<string, Object>;
    const confirm = action === 'versions.delete.confirm' || action === 'versions.delete.cancel';
    const block = port.block(confirm, action === 'launcher.home');
    if (block) return response('needsUser', block);
    if (confirm) return this.decide(port, action, args, session);
    if (action.startsWith('versions.orphans.')) return this.manageOrphan(port, action, args, session, request);
    if (action === 'resources.open') {
      const kind = kindOf(args['kind'], false);
      if (Object.keys(args).length !== 1 || !kind) return response('rejected','INVALID_KIND');
      // accepted 只表示切页已派发，实际资源视图就绪由 resources.status 回读。
      if (!port.browse(kind)) return response('needsUser','RESOURCE_NAVIGATION_UNAVAILABLE');
      return response('accepted','', { 'kind': kind });
    }
    if (action === 'accounts.open' || action === 'launcher.home') {
      if (Object.keys(args).length) return response('rejected','INVALID_ARGUMENTS');
      if (action === 'accounts.open') port.accounts();
      else if (!port.home()) return response('needsUser','DOWNLOAD_TASK_CONFIRMATION_PENDING');
      return response('accepted','',{ 'page': action === 'accounts.open' ? 'accounts' : 'home' });
    }
    const version = args['version'];
    if (typeof version !== 'string' || !version || safeBaseName(version) !== version || version.startsWith('.') ||
      version === 'download-temp') return response('rejected','INVALID_VERSION');
    const root = port.root();
    const inventory = await port.inventory();
    if (session !== ProductQa.sessionDirectory() || port.root() !== root || port.block(false)) return response('needsUser','LAUNCHER_CHANGED');
    if (!inventory.installed.includes(version)) return response('rejected','VERSION_NOT_INSTALLED');
    if (action === 'library.open') {
      const kind = kindOf(args['kind'], true);
      if (!kind || Object.keys(args).length !== 2) return response('rejected','INVALID_KIND');
      port.library(version, kind); return response('accepted','',{ 'version':version,'kind':kind });
    }
    if (action === 'settings.version') {
      if (Object.keys(args).length !== 1) return response('rejected','INVALID_ARGUMENTS');
      const settings = port.settings(version);
      return response('ok','',{ 'version':version,'jdk':settings.jdkVersion,'availableJdks':port.jdkChoices(),'resolutionPercent':settings.renderScalePercent ?? 0 });
    }
    if (port.gameBusy()) return response('needsUser','GAME_SESSION_ACTIVE_OR_UNKNOWN');
    if (action === 'settings.jdk') {
      const selection = args['choice'];
      if (Object.keys(args).length !== 2 || typeof selection !== 'string' ||
        (selection !== 'inherit' && selection !== 'auto' && !port.jdkChoices().includes(selection))) return response('rejected','INVALID_JDK');
      const choice = selection === 'inherit' ? '' : selection;
      if (!await port.saveJdk(version, choice)) return response('unknown','SETTING_NOT_CONFIRMED');
      return response('ok','',{ 'version':version,'jdk':choice });
    }
    if (action === 'settings.resolution') {
      const percent = args['percent'];
      if (typeof percent !== 'number' || !Number.isSafeInteger(percent) || Object.keys(args).length !== 2) return response('rejected','INVALID_ARGUMENTS');
      try { await port.saveResolution(version, percent); } catch (_) { return response('rejected','SETTING_SAVE_FAILED'); }
      const actual = port.settings(version).renderScalePercent ?? 0;
      if (port.root() !== root || actual !== percent) return response('unknown','SETTING_CHANGED');
      return response('ok','',{ 'version':version, 'resolutionPercent':actual });
    }
    if (action === 'versions.delete.prepare' && Object.keys(args).length === 1) {
      const stamp = identity(root, version);
      if (!stamp) return response('rejected','INVALID_TARGET');
      const epoch = port.prompt(version);
      if (!port.pending(version,epoch)) return response('rejected','TARGET_CHANGED');
      this.deletion = {session:session, request:request, root:root, version:version, identity:stamp, epoch:epoch};
      return response('needsUser','CONFIRM_VERSION_DELETE',{ 'planId':request, 'version':version });
    }
    if (action === 'versions.rename' && Object.keys(args).length === 2) {
      const name = args['newName'];
      if (typeof name !== 'string' || name === version || name!==name.trim() || validateVersionName(name) ||
        fs.accessSync(root+'/versions/'+name) || !identity(root,version)) return response('rejected','INVALID_RENAME_TARGET');
      const rename=port.prepareRename(version);
      if (!rename || !rename(version,name)) return response('rejected','RENAME_FAILED');
      return response('ok','',{ 'version':name,'previous':version });
    }
    return response('rejected','INVALID_ACTION_OR_ARGUMENTS');
  }

  /** 只有绑定本会话、原目标和原文件指纹的显式确认能执行残留清理。 */
  private async manageOrphan(port:LauncherManagementAccess, action:string, args:Record<string,Object>,
    session:string, request:string):Promise<string> {
    const version=args['version'];
    if (typeof version!=='string' || !version || safeBaseName(version)!==version) return response('rejected','INVALID_VERSION');
    if (action==='versions.orphans.prepare') {
      if (Object.keys(args).length!==1) return response('rejected','INVALID_ARGUMENTS');
      if (port.gameBusy()) return response('needsUser','GAME_SESSION_ACTIVE_OR_UNKNOWN');
      try {
        const plan=await port.prepareOrphan(version);
        if (ProductQa.sessionDirectory()!==session || port.block(false) || port.root()!==plan.root) {
          return response('needsUser','LAUNCHER_CHANGED');
        }
        this.orphan=plan; this.orphanSession=session; this.orphanRequest=request;
        return response('needsUser','CONFIRM_ORPHAN_CLEANUP',{'version':version,'planId':request,'files':plan.items[0].content});
      } catch (error) {
        const reason=(error as Error).message;
        return response('rejected',reason==='userContentPresent'?'ORPHAN_USER_CONTENT':'ORPHAN_TARGET_UNAVAILABLE');
      }
    }
    const plan=this.orphan;
    if (Object.keys(args).length!==2 || !plan || plan.names[0]!==version || this.orphanSession!==session ||
      this.orphanRequest!==args['planId'] || port.root()!==plan.root) return response('rejected','STALE_CONFIRMATION');
    if (action==='versions.orphans.cancel') {
      this.orphan=undefined;
      return response('ok','',{'version':version,'removed':[], 'remaining':[version]});
    }
    if (action!=='versions.orphans.confirm') return response('rejected','INVALID_ARGUMENTS');
    if (port.gameBusy()) return response('needsUser','GAME_SESSION_ACTIVE_OR_UNKNOWN');
    this.orphan=undefined;
    const outcome=await port.removeOrphan(plan);
    const data:Record<string,Object>={'version':version,'removed':outcome['removed'],'remaining':outcome['remaining']};
    return outcome['state']==='ready'?response('ok','',data):response('unknown',String(outcome['reason']),data);
  }

  private async decide(port: LauncherManagementAccess, action: string, args: Record<string, Object>, session: string): Promise<string> {
    const item = this.deletion;
    if (!item || Object.keys(args).length !== 2 || args['version'] !== item.version || args['planId'] !== item.request ||
      session !== item.session || port.root() !== item.root || !port.pending(item.version,item.epoch)) return response('rejected','STALE_CONFIRMATION');
    if (action === 'versions.delete.cancel') {
      port.cancel(); this.deletion = undefined;
      return response('ok','',{ 'version':item.version, 'removed':false });
    }
    if (port.gameBusy()) return response('needsUser','GAME_SESSION_ACTIVE_OR_UNKNOWN');
    if (identity(item.root,item.version) !== item.identity) return response('rejected','TARGET_CHANGED');
    this.deletion = undefined;
    const removed = await port.remove();
    if (!removed || fs.accessSync(item.root+'/versions/'+item.version)) return response('unknown','DELETE_NOT_VERIFIED');
    return response('ok','',{ 'version':item.version,'removed':true });
  }
}
