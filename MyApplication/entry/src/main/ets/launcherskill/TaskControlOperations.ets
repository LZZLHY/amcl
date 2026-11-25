import { DownloadTaskRegistry, UnifiedDownloadAdapter } from 'feature_core';

import { isQueuedRetry, publicTaskId } from './LibraryResult';

type Data = Record<string,Object>;
interface Control {
  ref: string;
  action: string;
  selectedId: string;
  rowRef: string;
  originalActivity: number;
  owner: UnifiedDownloadAdapter|null;
  id: string;
  activity: number;
  started: boolean;
  choice: string;
  outcome: string;
  phase: string;
}
type Started=(owner:UnifiedDownloadAdapter)=>void;
type SubmitControl=(started:Started,committed:()=>void)=>Promise<void>;

/** 控制请求与自然下载分离。只在本次 Registry 调度闭包真正出队时绑定活动，之后的 retry 不继承这份证明。 */
export class TaskControlOperations {
  private static records:Map<string,Control>=new Map<string,Control>();

  private static phase(record:Control,registry:DownloadTaskRegistry):string {
    if (record.outcome!=='pending') return record.phase;
    const owner=record.owner;
    if (!owner || registry.getAdapter(record.id)!==owner || owner.view.startedAtMs!==record.activity) return 'unknown';
    if (!record.started && ['retry','resume','confirm'].includes(record.action)) return owner.view.state==='waiting'?'waiting':'unconfirmed';
    if (isQueuedRetry(owner.view)) return 'unknown';
    return owner.view.state;
  }
  static read(key:string,registry:DownloadTaskRegistry):Data {
    const record=TaskControlOperations.records.get(key);
    if (!record) return {'state':'unknown','reason':'operationNotRetained','operationRef':key};
    return {'state':record.outcome==='rejected'?'failed':record.outcome==='unknown'?'unknown':record.outcome==='pending'?'accepted':'ready',
      'operationRef':key,'action':record.action,'selectedTaskId':publicTaskId(record.selectedId,record.rowRef),'selectedRef':record.rowRef,'originalActivityId':record.originalActivity,
      'taskId':publicTaskId(record.id,key),'activityId':record.started?record.activity:0,'started':record.started,'choiceState':record.choice,
      'outcome':record.outcome,'phase':TaskControlOperations.phase(record,registry)};
  }
  static prior(key:string,action:string,registry:DownloadTaskRegistry,rowRef:string):Data|null {
    const record=TaskControlOperations.records.get(key);
    if (!record) return null;
    // 确认票和当时提交的行引用共同识别原意图；即使队列刷新，原参数仍可幂等取回记录。
    if (record.action !== action || record.rowRef !== rowRef) return {'state':'failed','reason':'operationConflict'};
    return TaskControlOperations.read(key,registry);
  }
  static submit(key:string,action:string,adapter:UnifiedDownloadAdapter,registry:DownloadTaskRegistry,rowRef:string,work:SubmitControl):Data {
    const prior=TaskControlOperations.prior(key,action,registry,rowRef);
    if (prior) return prior;
    if (TaskControlOperations.records.size>=256) {
      let finished='';
      TaskControlOperations.records.forEach((row:Control,ref:string):void=>{if (!finished && row.outcome!=='pending') finished=ref;});
      if (!finished) return {'state':'busy','reason':'tooManyPendingControls'};
      TaskControlOperations.records.delete(finished);
    }
    const v=adapter.view;
    // 排队取消也可能先分配新活动号，或转交被附属行的真实 owner。
    const scheduled=['retry','resume','confirm','cancel'].includes(action);
    const record:Control={ref:key,action:action,rowRef:rowRef,selectedId:v.id,originalActivity:isQueuedRetry(v)?0:v.startedAtMs,owner:adapter,id:v.id,activity:v.startedAtMs,
      started:!scheduled,choice:action==='confirm'?'offered':'notApplicable',outcome:'pending',phase:'unknown'};
    TaskControlOperations.records.set(key,record);
    const started=(owner:UnifiedDownloadAdapter):void=>{
      if (record.started || record.outcome!=='pending') return;
      record.owner=owner;record.id=owner.view.id;record.activity=owner.view.startedAtMs;record.started=true;
    };
    const committed=():void=>{record.choice='committed';};
    const finish=(returned:boolean):void=>{
      record.phase=TaskControlOperations.phase(record,registry);
      if (!returned && record.action==='confirm' && record.choice==='offered') record.choice='unknown';
      record.outcome=!returned?'rejected':!record.started || record.phase==='unknown'?'unknown':'returned';
      record.owner=null;
    };
    try { work(started,committed).then(():void=>finish(true),():void=>finish(false)); }
    catch (_) {finish(false);}
    return TaskControlOperations.read(key,registry);
  }
}
