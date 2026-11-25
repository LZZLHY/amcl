/** 执行真实系统扩展/Skill查询及网页、赞助页原回调。只替换 BMS/文件 API、相册和网页边缘。 */
import assert from 'node:assert/strict';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { loadActionComponent } from './lib/unified-actions-fixture.mjs';

const trace = new Map();
let failWrites = false;
let profile = ['{"allowToBackupRestore":true}'];
let supported = true;
const logs = {info(){},warn(){},error(){}};
globalThis.canIUse = name => name === 'SystemCapability.FileManagement.StorageService.Backup' && supported;
const fs = {
  lstatSync(path) {
    if (!trace.has(path)) throw Object.assign(Error('missing'), {code:13900002});
    return {isFile:()=>true,isSymbolicLink:()=>false,size:trace.get(path).length};
  },
  readTextSync:path=>trace.get(path)
};
const deps = {'@kit.AbilityKit':{bundleManager:{getProfileByExtensionAbility:async (...args)=>{
  assert.deepEqual(args,['entry','EntryBackupAbility','ohos.extension.backup']);
  return profile;
}}},'@kit.CoreFileKit':{fileIo:fs,BackupExtensionAbility:class{}},
  commons:{AtomicFileWriter:{write(path,data){if(failWrites)throw Error('full');trace.set(path,data);}},AppLogger:logs,LogTags:{ENTRY_BACKUP:'backup'}}};
const load=makePureEtsLoader(deps);
const facts = load('entry/src/main/ets/runtime/SystemBackupState.ets');
deps['../runtime/SystemBackupState']=facts;
const Extension = load('entry/src/main/ets/entrybackupability/EntryBackupAbility.ets').default;
const callback=new Extension();
callback.context={cacheDir:'/local/cache'};
const read=()=>facts.readSystemBackupStatus(callback.context.cacheDir);
let status=await read();
assert.equal(status.allowed,true);
assert.deepEqual(status.lastBackupCallback,{state:'notObserved'});
await callback.onBackup();
status=await read();assert.ok(status.lastBackupCallback.at>0);
assert.equal(status.lastRestoreCallback.state,'notObserved');
await callback.onRestore({name:'version',code:25});
status=await read();assert.equal(status.lastRestoreCallback.state,'observed');
assert.equal(status.lastBackupCallback.state,'observed');
assert.equal(status.systemOutcome,'notReportedByExtension');
assert.equal(JSON.stringify(status).includes('/local'),false);
trace.set('/local/cache/amcl-system-restore-callback.json','{"kind":"backup","timestamp":123}');
assert.equal((await read()).lastRestoreCallback.state,'unreadable');
trace.clear();failWrites=true;await callback.onBackup();
assert.equal((await read()).lastBackupCallback.state,'notObserved','IO failure must not fail system backup or claim success');
profile=['{"allowToBackupRestore":false}'];assert.equal((await read()).allowed,false);
profile=[];assert.equal((await read()).state,'unknown');
profile=['{"allowToBackupRestore":"true"}'];assert.equal((await read()).state,'unknown');
supported=false;assert.equal((await read()).state,'unavailable');

let storeChannel=false;
const policy={isStore:()=>storeChannel};
let selections=[];
class Picker { select() { return new Promise((resolve,reject)=>selections.push({resolve,reject})); } }
const Web=loadActionComponent('entry/src/main/ets/components/WebHostView.ets','WebHostView',{
  methods:['skillWeb_','handleFileSelect_','aboutToDisappear','retry'],
  dependencies:{'commons':{DistributionPolicy:policy},'@kit.PerformanceAnalysisKit':{hilog:logs},
    '@kit.MediaLibraryKit':{photoAccessHelper:{PhotoViewPicker:Picker,PhotoViewMIMETypes:{IMAGE_TYPE:'image'}}},
    '../launcherskill/LauncherSkillBus':{LauncherSkillBus:{unbind(){}}}},globals:{TAG:'test'}
});
const web=new Web();Object.assign(web,{title:'feedback',loadFailed:false,loading:false,photoGeneration_:0,photoCount_:0,photoSelection_:'idle',albumResult:''});
web.webController={refresh(){throw Error('detached');}};
assert.equal((await web.skillWeb_('retrySupportPage',{})).state,'failed');
web.loadFailed=false;
const content=[];const pick=()=>web.handleFileSelect_({handleFileList:files=>content.push(files.slice())});
const settle=()=>new Promise(resolve=>setImmediate(resolve));
pick();pick();selections[0].resolve({photoUris:['stale']});await settle();
assert.deepEqual(content,[[]]);assert.equal(web.photoSelection_,'waiting');
selections[1].resolve({photoUris:['private-image']});await settle();
let result=await web.skillWeb_('readSupportPage',{});
assert.equal(result.selectedImages,1);assert.equal(result.remoteReceipt,'notProvidedByPage');
assert.equal(JSON.stringify(result).includes('private-image'),false);
pick();selections.at(-1).resolve({photoUris:[]});await settle();
assert.equal(web.photoSelection_,'cancelled');
pick();selections.at(-1).reject(Error('denied'));await settle();
assert.equal(web.photoSelection_,'failed');
pick();web.aboutToDisappear();selections.at(-1).resolve({photoUris:['old']});await settle();
assert.deepEqual(content.at(-1),[]);
storeChannel=true;const previous=selections.length;pick();assert.equal(selections.length,previous);storeChannel=false;

let saves=[];
const Sponsor=loadActionComponent('entry/src/main/ets/pages/SponsorPage.ets','SponsorPage',{
  methods:['handleImageDownload_','aboutToDisappear'],
  dependencies:{commons:{DistributionPolicy:policy},'@kit.PerformanceAnalysisKit':{hilog:logs},feature_system:{
    AlbumSaver:{saveImageUrl:()=>new Promise((resolve,reject)=>saves.push({resolve,reject}))}}},globals:{TAG:'test'}
});
const sponsor=new Sponsor();Object.assign(sponsor,{context:{},toast_:()=>{},albumResult_:'idle',albumGeneration_:0});
const image='https://amcl.lovedhy.cn/sample.png';
sponsor.handleImageDownload_('blob:local');assert.equal(sponsor.albumResult_,'unavailable');
sponsor.handleImageDownload_(image);sponsor.handleImageDownload_(image);
assert.equal(saves.length,1,'system save panel is single flight');
saves.at(-1).resolve('cancelled');await settle();assert.equal(sponsor.albumResult_,'cancelled');
sponsor.handleImageDownload_(image);saves.at(-1).reject(Error('write failed'));await settle();assert.equal(sponsor.albumResult_,'failed');
sponsor.handleImageDownload_(image);saves.at(-1).resolve('saved');await settle();assert.equal(sponsor.albumResult_,'saved');
sponsor.handleImageDownload_(image);sponsor.aboutToDisappear();saves.at(-1).resolve('saved');await settle();
assert.notEqual(sponsor.albumResult_,'saved');
console.log('PASS installed backup policy and actual extension callback observation; photo handoff, album save, cancellation, ownership and unknown remote outcome');
