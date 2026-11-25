import { fileIo as fs } from '@kit.CoreFileKit';
import { AtomicFileWriter, ledgerManifest, LedgerState } from 'commons';
import { getDownloadTaskRegistry, isTerminalState, TaskCategory, UnifiedDownloadAdapter } from 'feature_core';
import { ModpackInstallTask } from 'mods';
import { matchesTaskActivity, publicTaskId, result } from './LibraryResult';

interface Trace {
  ref:string; task:string; activity:number; title:string; game:string; category:string; pack:boolean;
  phase:string; instance:string; missing:number;
}
interface LiveResource { adapter:UnifiedDownloadAdapter; trace:Trace; }

/** 终态存于原确认标识对应的记录。页面退出、人工确认和同 adapter 的新活动均不能把结果串给另一安装。 */
export class ResourceOperation {
  private static live:Map<string,LiveResource>=new Map<string,LiveResource>();
  private static path(files:string,ref:string):string {
    if (!/^[0-9a-fA-F-]{36}$/.test(ref)) throw new Error('invalidPlan');
    return files+'/launcher-skill-resource/'+ref+'/result.json';
  }
  private static save(path:string,trace:Trace):void { AtomicFileWriter.write(path,JSON.stringify(trace)); }
  static claim(files:string,ref:string):void {
    const path=ResourceOperation.path(files,ref), root=files+'/launcher-skill-resource';
    if (!fs.accessSync(root)) fs.mkdirSync(root);
    fs.mkdirSync(root+'/'+ref);
    ResourceOperation.save(path,{ref:ref,task:'',activity:0,title:'',game:'',category:'',pack:false,phase:'claimed',instance:'',missing:-1});
  }
  static watch(files:string,ref:string,adapter:UnifiedDownloadAdapter,completion:Promise<void>):void {
    const path=ResourceOperation.path(files,ref), registry=getDownloadTaskRegistry();
    const trace:Trace={ref:ref,task:adapter.view.id,activity:0,title:'',game:'',category:'',pack:adapter.view.category===TaskCategory.MODPACK,phase:'claimed',instance:'',missing:-1};
    ResourceOperation.live.set(path,{adapter:adapter,trace:trace});
    let saved='',admitted=false,settled=false,stopped=false;
    const stop=():void=>{stopped=true; ResourceOperation.live.delete(path);Promise.resolve().then(():void=>registry.removeListener(update));};
    const update=():void=>{
      if (stopped) return;
      const v=adapter.view;
      if (registry.getAdapter(v.id)!==adapter) { if (admitted || settled) stop(); return; }
      admitted=true;
      if (trace.activity>0 && !matchesTaskActivity(v,trace.activity)) {stop();return;}
      if (!trace.activity && v.startedAtMs>0) {
        trace.activity=v.startedAtMs;trace.title=v.title;trace.game=v.activityGameVersion;trace.category=v.activityCategory;
      }
      trace.phase=v.state;
      const pack=trace.pack?adapter as ModpackInstallTask:null;
      if (pack && v.state==='done' && pack.getSession()?.complete===true) {
        const outcome=pack.getResult();
        if (outcome) {trace.instance=outcome.versionName;trace.missing=outcome.missing.length;}
      }
      const json=JSON.stringify(trace);
      // 持久证据失败不打断真实队列。读取仍可依原活动核实；没有足够证据则返回未知。
      if (json!==saved) { try {ResourceOperation.save(path,trace);saved=json;} catch (_) {} }
      if (isTerminalState(v.state) && !v.canResume && !v.requiresConfirmation && !(pack && v.state==='error' && pack.canChooseOtherPackage())) stop();
    };
    registry.addListener(update);update();
    const finish=():void=>{settled=true;update();};completion.then(finish,finish);
  }
  static read(files:string,ref:string):Record<string,Object> {
    const path=ResourceOperation.path(files,ref),live=ResourceOperation.live.get(path);
    if (!live && !fs.accessSync(path)) return result('failed','operationNotFound');
    const trace=live?.trace ?? JSON.parse(fs.readTextSync(path)) as Trace;
    if (trace.ref!==ref || !Number.isSafeInteger(trace.activity) || trace.activity<0) return result('unknown','invalidReceipt');
    const view=live?.adapter.view;
    const inMemory=live && view && getDownloadTaskRegistry().getAdapter(view.id)===live.adapter &&
      matchesTaskActivity(view,trace.activity);
    const ledger=trace.activity>0?ledgerManifest(files,trace.activity):null;
    const same=ledger!==null && ledger.activityId===trace.activity && ledger.title===trace.title &&
      (ledger.gameVersionId ?? '')===trace.game && (!trace.category || ledger.category===trace.category);
    const terminal=same && ledger!==null && ledger.outcomeSource==='task.owner';
    const phase=inMemory && view?view.state:terminal && ledger?ledger.state===LedgerState.SUCCESS?'done':ledger.state===LedgerState.ABORTED?'aborted':'error':'unknown';
    const response:Record<string,Object>={'state':phase==='unknown'?'unknown':'ready','operationRef':ref,'taskId':publicTaskId(trace.task,ref),'activityId':trace.activity,'phase':phase};
    if (inMemory && view){response['bytesDone']=view.bytesDone;response['bytesTotal']=view.bytesTotal;response['requiresConfirmation']=view.requiresConfirmation;}
    if (trace.pack) {
      response['instance']=trace.instance; response['missingCount']=trace.missing;response['completeness']=trace.missing<0?'unknown':trace.missing?'partial':'complete';
      if (phase==='done' && trace.missing<0) response['state']='unknown';
    }
    return response;
  }
}
