/**
 * JDK续作的耐久授权账本。schema2绑定选择代次、具体App事务和完成事件；任务只有真正
 * 成功且原build/SHA已安装才确认。队列拒绝、进程死亡或页面销毁都不能靠删除意图收尾。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AtomicFileWriter, AppUpdateBinding, AppUpdateCompletionEvent, stringToUtf8 } from 'commons';
import { RuntimeCatalogRepository } from './RuntimeCatalogRepository';
import { JdkManager } from './JdkManager';
import { RuntimeBuild, RuntimeInstallReceipt, RUNTIME_INSTALL_RECEIPT_LIMIT } from './RuntimeCatalogTypes';
import { runtimeRecommendationIds, runtimeRequiredHost } from './RuntimeCatalogValidation';
import { runtimeHostProtocols } from './RuntimeHostProtocol';

export interface RuntimeAppIntent { major: string; buildId: string; sha256: string; requiredHostProtocol: number; sizeBytes?: number; }
export interface RuntimeAppDelivery extends RuntimeAppIntent { state: string; deliveryToken: string; error: string; }
interface RuntimeAppIntentRecord {
  schemaVersion: number; generation: string; channel: string; createdAt: number; phase: string;
  binding?: AppUpdateBinding; completion?: AppUpdateCompletionEvent; intents: RuntimeAppDelivery[];
  legacyArchive?: string;
}
export interface RuntimeAppIntentResult { kind: string; generation: string; majors: string[]; items: RuntimeAppDelivery[]; message: string; }
/** 仅内部确认窗口保留原字节token，不展示/不传路由；它不包含新的安装许可。 */
export interface RuntimeAppLegacy { body: string; message: string; }
interface IntentIoError { code?: number | string; message?: string; }
const INTENT_LIMIT: number=128*1024;

function missing(error: Object): boolean {
  const value=error as IntentIoError;
  return value.code===13900002 || value.code==='ENOENT' || value.message==='ENOENT';
}
function path(context: Context): string { return context.filesDir+'/runtime-app-intent.json'; }
/** 安装EX发布的持久fence也是意图准入边界；检测与新代次写入共用本域writer。 */
function assertNoAppFence(context: Context): void {
  try{fs.lstatSync(context.filesDir+'/sideload-update/install-fence.json');}
  catch(error){if(missing(error as Object))return;throw error as Error;}
  throw new Error('AMCL安装尚未完成，暂不能创建新的JDK续作许可');
}
/** unlink后的目录同步重试不能因为文件已经缺失而跳过，未知持久性始终上抛。 */
function syncIntentDirectory(context: Context): void {
  const directory=fs.openSync(context.filesDir,fs.OpenMode.READ_ONLY);
  try{fs.fsyncSync(directory.fd);}finally{fs.closeSync(directory);}
}
function validId(value: string): boolean { return typeof value==='string' && new RegExp('^[0-9a-f]{32}$').test(value); }
function validBinding(value: AppUpdateBinding): boolean {
  return value!==null && typeof value==='object' && validId(value.transactionId) && typeof value.assetSha256==='string' &&
    new RegExp('^[0-9a-f]{64}$').test(value.assetSha256) && ['sideload','desktop'].indexOf(value.product)>=0 &&
    typeof value.versionName==='string' && value.versionName.length>0 && value.versionName.length<=128 && Number.isSafeInteger(value.versionCode) && value.versionCode>0;
}
function sameBinding(left: AppUpdateBinding,right: AppUpdateBinding): boolean {
  return left.transactionId===right.transactionId && left.assetSha256===right.assetSha256 && left.product===right.product &&
    left.versionName===right.versionName && left.versionCode===right.versionCode;
}
function validCompletion(value: AppUpdateCompletionEvent): boolean {
  return validBinding(value) && validId(value.installId) && typeof value.sourceRevision==='string' && new RegExp('^[0-9a-f]{40}$').test(value.sourceRevision) &&
    Number.isSafeInteger(value.uid) && value.uid>0 && Number.isFinite(value.verifiedAt) && value.verifiedAt>0 && validId(value.runtimeIntentId ?? '');
}
function validItem(item: RuntimeAppDelivery): boolean {
  return item!==null && typeof item==='object' && typeof item.major==='string' && new RegExp('^[1-9][0-9]{0,2}$').test(item.major) &&
    typeof item.buildId==='string' && new RegExp('^[a-z0-9][a-z0-9._-]{0,95}$').test(item.buildId) && typeof item.sha256==='string' &&
    new RegExp('^[0-9a-f]{64}$').test(item.sha256) && Number.isInteger(item.requiredHostProtocol) && item.requiredHostProtocol>0 && item.requiredHostProtocol<=999 &&
    (item.sizeBytes===undefined || Number.isSafeInteger(item.sizeBytes) && item.sizeBytes>0) &&
    ['pending','delivering','retry','done','cancelled'].indexOf(item.state)>=0 && typeof item.deliveryToken==='string' &&
    (item.deliveryToken==='' || validId(item.deliveryToken)) && (item.state!=='delivering'||validId(item.deliveryToken)) && typeof item.error==='string' && item.error.length<=512;
}
/** 缺失以外的I/O故障失败关闭；旧schema1无代次绑定，保留字节并要求用户重新明确选择。 */
function raw(context: Context): string | undefined {
  const file=path(context);let present=false;
  try {fs.lstatSync(file);present=true;} catch(error){if(!missing(error as Object))throw error as Error;}
  if(!present)return undefined;
  const stat=fs.lstatSync(file);if(!stat.isFile() || stat.size<1 || stat.size>INTENT_LIMIT)throw new Error('JDK续作记录损坏或超限，已保留');
  const body=fs.readTextSync(file);if(stringToUtf8(body).byteLength>INTENT_LIMIT)throw new Error('JDK续作记录读取期间超限');return body;
}
function read(context: Context): RuntimeAppIntentRecord | null {
  const body=raw(context);if(body===undefined)return null;
  const record=JSON.parse(body) as RuntimeAppIntentRecord;
  if(record.schemaVersion===1)throw new Error('旧JDK续作没有绑定App事务，请重新选择原目标');
  if(record.schemaVersion===2&&['archived-legacy','archived'].indexOf(record.phase)>=0){
    if(!validId(record.generation)||record.channel!=='stable'||!Number.isFinite(record.createdAt)||record.createdAt<=0||
      record.binding!==undefined||record.completion!==undefined||!Array.isArray(record.intents)||record.intents.length!==0||
      typeof record.legacyArchive!=='string'||!new RegExp('^runtime-app-intent[.]json[.](legacy|archive)-[0-9a-f]{32}[.]json$').test(record.legacyArchive))throw new Error('旧JDK选择归档标记无效');
    return record;
  }
  if(record.schemaVersion!==2 || !validId(record.generation) || ['stable','preview'].indexOf(record.channel)<0 ||
    !Number.isFinite(record.createdAt) || record.createdAt<=0 || ['active','complete'].indexOf(record.phase)<0 ||
    !Array.isArray(record.intents) || record.intents.length<1 || record.intents.length>64 || record.intents.some((item: RuntimeAppDelivery,index: number): boolean =>
      !validItem(item) || record.intents.findIndex((other: RuntimeAppDelivery): boolean => other.major===item.major)!==index) ||
    record.binding!==undefined && !validBinding(record.binding) || record.completion!==undefined &&
      (!validCompletion(record.completion) || record.completion.runtimeIntentId!==record.generation || record.binding===undefined || !sameBinding(record.binding,record.completion)) ||
    record.phase==='complete' && record.intents.some((item: RuntimeAppDelivery): boolean=>item.state!=='done'&&item.state!=='cancelled')) {
    throw new Error('JDK续作记录格式或绑定无效，已保留现场');
  }
  return record;
}
function save(context: Context,record: RuntimeAppIntentRecord): void {
  const body=JSON.stringify(record);if(stringToUtf8(body).byteLength>INTENT_LIMIT)throw new Error('JDK续作记录超出统一读写预算');
  AtomicFileWriter.write(path(context),body);
}
/** 独立writer锁覆盖每次读取和条件提交；不会与安装SH/EX共用inode。 */
function lock(context: Context): fs.File {
  const file=fs.openSync(context.filesDir+'/runtime-app-intent.writer',fs.OpenMode.CREATE|fs.OpenMode.READ_WRITE|fs.OpenMode.NOFOLLOW);
  try {file.tryLock(true);return file;} catch(_){fs.closeSync(file);throw new Error('JDK续作记录正在交接，请稍后重试');}
}
function release(file: fs.File): void {fs.closeSync(file);}
function result(kind: string,record: RuntimeAppIntentRecord | null,message: string,items: RuntimeAppDelivery[]=[]): RuntimeAppIntentResult {
  return {kind:kind,generation:record?.generation ?? '',majors:items.map((item: RuntimeAppDelivery): string=>item.major),items:JSON.parse(JSON.stringify(items)) as RuntimeAppDelivery[],message:message};
}
function finish(record: RuntimeAppIntentRecord): void {
  if(record.intents.every((item: RuntimeAppDelivery): boolean=>item.state==='done'||item.state==='cancelled'))record.phase='complete';
}
function qualified(repository: RuntimeCatalogRepository,item: RuntimeAppIntent): boolean {
  if(repository.recommendationUnavailableReason()!=='')return false;
  const build=repository.buildFor(item.major);
  return build!==undefined && build.id===item.buildId && build.archive.sha256===item.sha256 &&
    (item.sizeBytes===undefined || build.archive.sizeBytes===item.sizeBytes) && repository.isBuildAllowed(item.buildId);
}
/** 用真实结构/宿主资格与精确安装收据认领崩溃前已提交的原包，避免forceReinstall重放。 */
function installed(context: Context,repository: RuntimeCatalogRepository,manager: JdkManager,item: RuntimeAppIntent): boolean {
  if(!qualified(repository,item) || !manager.isInstalled(item.major))return false;
  const file=context.filesDir+'/jdk/'+item.major+'/.amcl-runtime-receipt.json';
  try {
    const stat=fs.lstatSync(file);if(!stat.isFile()||stat.size<1||stat.size>RUNTIME_INSTALL_RECEIPT_LIMIT)return false;
    const receipt=JSON.parse(fs.readTextSync(file)) as RuntimeInstallReceipt;
    const expected=repository.buildFor(item.major);
    return receipt.schemaVersion===1 && receipt.origin==='catalog' && Number.isInteger(receipt.javaMajor) && receipt.javaMajor===Number(item.major) &&
      receipt.runtimeId===expected?.runtimeId && receipt.buildId===item.buildId && receipt.archiveSha256===item.sha256 && (item.sizeBytes===undefined || receipt.archiveSizeBytes===item.sizeBytes);
  } catch(error){if(!missing(error as Object))throw error as Error;return false;}
}

export class RuntimeAppDependency {
  /** 签名前早反馈；不会归档或更改用户许可。最终兼容检查仍必须持App EX/fence再做。 */
  static assertTargetCompatibility(context: Context,protocol: number): void {
    if(!Number.isInteger(protocol)||protocol<0||protocol>2)throw new Error('目标App恢复协议无效');
    if(protocol>=2)return;
    const body=raw(context);if(body===undefined)return;
    const version=(JSON.parse(body) as RuntimeAppIntentRecord).schemaVersion;
    if(version===1)throw new Error('目标旧版AMCL可能重新启用无绑定的旧JDK许可，请先在运行时页明确保留归档并放弃原选择');
    const record=read(context);if(record?.phase==='active')throw new Error('目标旧版AMCL不支持当前JDK续作许可，请先在运行时页明确完成或放弃原选择');
  }
  /**
   * 仅原Executor持EX/fence的安装准备可调用。旧reader不识别schema2墓碑，故完成/明确放弃
   * 记录须先耐久保原字节、再移出固定入口；active绝不自动删或伪造schema1许可。
   */
  static prepareTarget(context: Context,protocol: number): void {
    if(!Number.isInteger(protocol)||protocol<0||protocol>2)throw new Error('目标App恢复协议无效');
    if(protocol>=2)return;
    const owner=lock(context);try{
      RuntimeAppDependency.assertTargetCompatibility(context,protocol);
      const body=raw(context);
      if(body!==undefined&&(JSON.parse(body) as RuntimeAppIntentRecord).schemaVersion===2){
        const generation=util.generateRandomUUID().replace(new RegExp('-','g'),'');
        AtomicFileWriter.write(context.filesDir+'/runtime-app-intent.json.legacy-return-'+generation+'.json',body);
        fs.unlinkSync(path(context));
      }
      syncIntentDirectory(context);
    }finally{release(owner);}
  }
  /** 旧意图无可迁移许可，但必须有离线可达的明确放弃出口，不能永远仅提示“重新选择”。 */
  static legacyIntent(context: Context): RuntimeAppLegacy | null {
    const body=raw(context);if(body===undefined)return null;
    const value=JSON.parse(body) as RuntimeAppIntentRecord;
    return value.schemaVersion===1?{body:body,message:'旧JDK选择没有App事务绑定，不能自动续作。可保留原记录并放弃旧许可，再从运行时管理重新选择。'}:null;
  }
  /** 等待App的schema2也提供离线手动放弃；仅明确确认会归档，后台检查仍保持原许可。 */
  static unconfirmedIntent(context: Context): RuntimeAppLegacy | null {
    const owner=lock(context);try{
      const record=read(context);if(record===null||record.phase!=='active'||record.completion!==undefined)return null;
      const body=raw(context);if(body===undefined)return null;
      return {body:body,message:'原JDK选择仍等待绑定的AMCL更新完成。若要放弃此续作或返回不支持新账本的旧版，可保留原记录并明确结束旧许可。'};
    }finally{release(owner);}
  }
  /** 用户确认后先完整归档原字节再原子发布无权限tombstone；晚确认不能归档后来新选择。 */
  static archiveLegacy(context: Context,expectedBody: string): void {
    const owner=lock(context);try{
      const body=raw(context);if(body===undefined)return;
      const value=JSON.parse(body) as RuntimeAppIntentRecord;
      if(value.schemaVersion===2&&value.phase==='archived-legacy')return;
      if(body!==expectedBody||value.schemaVersion!==1)throw new Error('JDK选择已改变，未放弃后来选择');
      const generation=util.generateRandomUUID().replace(new RegExp('-','g'),'');
      const name='runtime-app-intent.json.legacy-'+generation+'.json';
      AtomicFileWriter.write(context.filesDir+'/'+name,body);
      save(context,{schemaVersion:2,generation:generation,channel:'stable',createdAt:Date.now(),phase:'archived-legacy',intents:[],legacyArchive:name});
    }finally{release(owner);}
  }
  /** 已过期/换通道/撤回的schema2许可也有明确放弃出口；固定原字节避免晚确认终结新代次。 */
  static unusableIntent(context: Context,repository: RuntimeCatalogRepository,channel: string): RuntimeAppLegacy | null {
    const owner=lock(context);try{
      const result=RuntimeAppDependency.takeIfCompatible(context,repository,channel);
      if(result.kind!=='changed')return null;
      const body=raw(context);if(body===undefined)return null;
      return {body:body,message:result.message+'。可保留原记录并放弃旧续作许可，再从运行时管理重新选择。'};
    }finally{release(owner);}
  }
  /** 仅明确确认可调用；归档原件后发布无许可标记，不把原App事件转授给新构建。 */
  static archiveUnusable(context: Context,expectedBody: string): void {
    const owner=lock(context);try{
      const body=raw(context);if(body===undefined)return;
      const record=read(context);if(record?.phase==='archived')return;
      if(body!==expectedBody||record?.phase!=='active')throw new Error('JDK选择已改变，未放弃后来选择');
      const generation=util.generateRandomUUID().replace(new RegExp('-','g'),'');
      const name='runtime-app-intent.json.archive-'+generation+'.json';AtomicFileWriter.write(context.filesDir+'/'+name,body);
      save(context,{schemaVersion:2,generation:generation,channel:'stable',createdAt:Date.now(),phase:'archived',intents:[],legacyArchive:name});
    }finally{release(owner);}
  }
  /** 保存刚展示的同一组目标并返回新代次；新显式选择可替换旧记录，旧回调不能确认新代次。 */
  static remember(context: Context,repository: RuntimeCatalogRepository,selected: RuntimeAppIntent[]): string {
    if(selected.length===0||selected.length>64)throw new Error('请选择需要更新的JDK');
    const current=RuntimeAppDependency.requirements(repository,selected.map((item: RuntimeAppIntent): string=>item.major));
    for(const item of selected)if(!current.some((value: RuntimeAppIntent): boolean=>JSON.stringify(value)===JSON.stringify(item)) ||
      selected.findIndex((value: RuntimeAppIntent): boolean=>value.major===item.major)!==selected.indexOf(item))throw new Error('JDK目标已改变或重复，请重新选择');
    const owner=lock(context);try {
      assertNoAppFence(context);
      const generation=util.generateRandomUUID().replace(new RegExp('-','g'),'');
      const record: RuntimeAppIntentRecord={schemaVersion:2,generation:generation,channel:repository.snapshot().channel,createdAt:Date.now(),phase:'active',
        intents:selected.map((item: RuntimeAppIntent): RuntimeAppDelivery=>({major:item.major,buildId:item.buildId,sha256:item.sha256,
          requiredHostProtocol:item.requiredHostProtocol,sizeBytes:item.sizeBytes,state:'pending',deliveryToken:'',error:''}))};
      save(context,record);return generation;
    } finally{release(owner);}
  }
  /** 只取当前第一推荐的缺失能力，保留原通道/构建/SHA/大小，不把兼容fallback当用户选择。 */
  static requirements(repository: RuntimeCatalogRepository,majors: string[]): RuntimeAppIntent[] {
    if(repository.recommendationUnavailableReason()!=='')return [];
    const catalog=repository.snapshot(),items: RuntimeAppIntent[]=[];
    for(const runtime of catalog.runtimes){const major=runtime.javaMajor.toString();if(majors.indexOf(major)<0)continue;
      const ids=runtimeRecommendationIds(runtime);if(ids.length===0)continue;
      const build=catalog.builds.find((value: RuntimeBuild): boolean=>value.id===ids[0]&&value.runtimeId===runtime.id&&value.status==='available');
      if(build===undefined||!repository.isBuildAllowed(build.id))continue;
      const required=runtimeRequiredHost(catalog,build);if(runtimeHostProtocols().indexOf(required)<0)items.push({major:major,buildId:build.id,sha256:build.archive.sha256,sizeBytes:build.archive.sizeBytes,requiredHostProtocol:required});
    }return items;
  }
  /** 只有携本代次明确进入更新流程的原App事务可绑定，普通检查或另一HAP不能挪用许可。 */
  static bindApp(context: Context,generation: string,binding: AppUpdateBinding): void {
    if(!validId(generation)||!validBinding(binding))throw new Error('App/JDK续作绑定无效');
    const owner=lock(context);try {const record=read(context);
      if(record===null||record.generation!==generation||record.phase!=='active')throw new Error('JDK选择代次已改变，请重新选择');
      if(record.binding!==undefined&&!sameBinding(record.binding,binding))throw new Error('该JDK选择已绑定另一App事务，请重新选择');
      record.binding=JSON.parse(JSON.stringify(binding)) as AppUpdateBinding;save(context,record);
    }finally{release(owner);}
  }
  /** 原安装器完成耐久双证明后直接确认，不依赖页面或AppStorage；不同代事件只被忽略。 */
  static markAppVerified(context: Context,event: AppUpdateCompletionEvent): boolean {
    if(!validCompletion(event))throw new Error('App完成事件缺少原事务身份');
    const owner=lock(context);try{const record=read(context);
      if(record===null||record.generation!==event.runtimeIntentId)return false;
      // 授权依赖不可重用generation和完整事务绑定；墙钟倒拨不能使同一耐久完成事件永久失效。
      if(record.binding===undefined||!sameBinding(record.binding,event))throw new Error('App完成事件与JDK选择不匹配');
      if(record.completion!==undefined&&JSON.stringify(record.completion)!==JSON.stringify(event))throw new Error('JDK完成事件已绑定不同执行身份');
      record.completion=JSON.parse(JSON.stringify(event)) as AppUpdateCompletionEvent;save(context,record);return true;
    }finally{release(owner);}
  }
  /** 维修包只终结精确原代次，不给其发送旧目标完成许可；后来新选择不受旧回调影响。 */
  static supersedeApp(context: Context,generation: string,binding: AppUpdateBinding): void {
    const owner=lock(context);try{const record=read(context);if(record===null||record.generation!==generation)return;
      if(record.binding===undefined||!sameBinding(record.binding,binding))throw new Error('维修收尾与JDK原选择不匹配');
      for(const item of record.intents)if(item.state!=='done'){item.state='cancelled';item.error='原App事务已由维修版本接管，请重新选择JDK更新';}
      finish(record);save(context,record);
    }finally{release(owner);}
  }
  static hasVerifiedIntent(context: Context): boolean {const record=read(context);return record!==null&&record.phase==='active'&&record.completion!==undefined;}
  /** 非破坏读取；交付中/失败的跨重入状态需要明确重试，不能复活用户已取消的任务。 */
  static takeIfCompatible(context: Context,repository: RuntimeCatalogRepository,channel: string): RuntimeAppIntentResult {
    const record=read(context);if(record===null||record.phase==='complete'||record.phase==='archived-legacy'||record.phase==='archived')return result('none',record,'');
    if(record.completion===undefined)return result('waiting',record,'先完成绑定的AMCL更新验证，再继续JDK');
    if(record.channel!==channel||Date.now()<record.createdAt||Date.now()-record.createdAt>86400000)return result('changed',record,'原JDK选择已过期或通道改变，请重新选择');
    const items=record.intents.filter((item: RuntimeAppDelivery): boolean=>item.state!=='done'&&item.state!=='cancelled');
    if(items.some((item: RuntimeAppDelivery): boolean=>runtimeHostProtocols().indexOf(item.requiredHostProtocol)<0))return result('requires-app',record,'当前AMCL仍缺少原选择所需的宿主能力');
    if(repository.recommendationUnavailableReason()!=='')return result('waiting',record,'请重新检查可信JDK目录');
    if(items.some((item: RuntimeAppDelivery): boolean=>!qualified(repository,item)))return result('changed',record,'原JDK目标已改变或撤回，请重新选择');
    const pending=items.filter((item: RuntimeAppDelivery): boolean=>item.state==='pending');
    if(pending.length>0)return result('ready',record,'继续已选择的JDK更新',pending);
    const interrupted=items.filter((item: RuntimeAppDelivery): boolean=>item.state==='delivering'||item.state==='retry');
    if(interrupted.length>0)return result('interrupted',record,'原JDK续作中断或准入失败，选择后继续原目标',interrupted);
    return result('none',record,'');
  }
  /** ack写入失败后的冷重入先核真实安装，不以forceReinstall重复已经完成的原目标。 */
  static reconcileInstalled(context: Context,repository: RuntimeCatalogRepository,manager: JdkManager): void {
    const owner=lock(context);try{const record=read(context);if(record===null||record.completion===undefined||record.phase==='complete')return;
      let changed=false;for(const item of record.intents)if(item.state!=='done'&&item.state!=='cancelled'&&installed(context,repository,manager,item)){item.state='done';item.error='';changed=true;}
      if(changed){finish(record);save(context,record);}
    }finally{release(owner);}
  }
  /** 耐久预约先于enqueue；多个Index实例只有一个条件写赢家，预约后死亡保留原目标。 */
  static beginDelivery(context: Context,generation: string,item: RuntimeAppIntent): string {
    const owner=lock(context);try{const record=read(context);if(record===null||record.generation!==generation||record.completion===undefined)return '';
      const value=record.intents.find((entry: RuntimeAppDelivery): boolean=>entry.major===item.major&&entry.buildId===item.buildId&&entry.sha256===item.sha256);
      if(value===undefined||value.state!=='pending')return '';
      value.state='delivering';value.deliveryToken=util.generateRandomUUID().replace(new RegExp('-','g'),'');value.error='';save(context,record);return value.deliveryToken;
    }finally{release(owner);}
  }
  /** 旧回调须同时匹配generation、原包和delivery；domain ack不依赖页面仍可见。 */
  static completeDelivery(context: Context,generation: string,item: RuntimeAppIntent,token: string,repository: RuntimeCatalogRepository,manager: JdkManager,state: string,error: string=''): boolean {
    const owner=lock(context);try{const record=read(context);if(record===null||record.generation!==generation)return false;
      const value=record.intents.find((entry: RuntimeAppDelivery): boolean=>entry.major===item.major&&entry.buildId===item.buildId&&entry.sha256===item.sha256&&entry.deliveryToken===token);
      if(value===undefined||value.state!=='delivering')return false;
      if(state==='done'){if(!installed(context,repository,manager,value))throw new Error('JDK任务结束但未核实原build与SHA的实际安装');value.state='done';value.error='';}
      else if(state==='aborted'){value.state='cancelled';value.error='用户已取消原JDK续作';}
      else {value.state='retry';value.error=error.substring(0,512)||'任务未被接纳或尚未完成，请明确重试';}
      finish(record);save(context,record);return true;
    }finally{release(owner);}
  }
  /** 中断后用户重新选择原major才恢复pending；下一轮仍核原包，不自动换目标。 */
  static retryInterrupted(context: Context,generation: string,majors: string[]): void {
    const owner=lock(context);try{const record=read(context);if(record===null||record.generation!==generation)throw new Error('JDK选择已改变');
      for(const item of record.intents)if(majors.indexOf(item.major)>=0&&(item.state==='delivering'||item.state==='retry')){item.state='pending';item.deliveryToken='';item.error='';}
      save(context,record);
    }finally{release(owner);}
  }
}
