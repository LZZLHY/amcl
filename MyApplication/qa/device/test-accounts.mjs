// 实际开发适配与账户/新增表单。只替换存储、网络授权、组件绑定与计时边界。
import assert from 'node:assert/strict';
import { environment } from '../../scripts/lib/ets-runtime-fixture.mjs';

let session = 'session-a';
let foreground = true;
let handler;
const accounts = [];
let selected = '';
const types = { OFFLINE:'legacy', MICROSOFT:'msa', AUTHLIB_INJECTOR:'mojang' };
const summaries = [];
function identity(id, type) {
  return { id, type, username:'secret-user', email:'private@example.org', token:'SECRET-TOKEN',
    getDisplayName: () => 'private-user', getUuid: () => 'private-uuid', getSkinUrl: () => '',
    getSkinVariant: () => '', getCapeUrl: () => '', getCapeAlias: () => '', isUsable: async () => true };
}
const manager = { isReady: () => true, list: () => accounts.slice(), getSelectedId: () => selected,
  findById: id => accounts.find(item=>item.id===id),
  getAvailableSelection: () => manager.findById(selected),
  add: async account => { accounts.push(account); }, select: async id => { selected = id; },
  remove: async (id,target,selection) => {
    assert.equal(manager.findById(id),target);assert.equal(selected,selection);
    accounts.splice(accounts.indexOf(target),1);
    if (id === selected) selected='';
  } };
const accountKit = { getAccountManager:()=>manager, AccountType:types, OfflineAccount:{create:() => identity('new-id',types.OFFLINE)} };
const qa = { sessionDirectory:()=>session, bindSurface:(name,owner,action)=>{assert.equal(name,'accounts');handler=action;},
  unbindSurface:()=>{} };
const adapterEnv = environment({imports:{account:accountKit,'entry/ProductQa':{ProductQa:qa}},
  globals:{setTimeout,clearTimeout}});
const adapter = adapterEnv.load('entry/src/main/ProductQaAccounts.ets').ProductQaAccounts;
const env = environment({ commons:{DeviceForm:{PHONE:'phone'},Breakpoint:{SM:'sm'},SKIN_SERVER_PRESETS:[]},
  globals:{ AppStorage:{get:()=>foreground} },
  imports:{ account:accountKit,'entry/ProductQaAccounts':{ProductQaAccounts:adapter},
    '@kit.ArkWeb':{webview:{WebviewController:class{},WebCookieManager:{clearAllCookiesSync(){}}}},
    feature_core:{ActivityCategory:{ACCOUNT:'account'},ActivityStatus:{SUCCESS:'success',FAILED:'failed',ABORTED:'aborted'},
      reserveTaskActivityId:()=>1,getTaskActivityOwner:()=>({recordSummary:(...args)=>summaries.push(args)})} } });
const Page=env.load('entry/src/main/ets/components/AccountListSheet.ets',true).AccountListSheet;
const Form=env.load('entry/src/main/ets/components/AddAccountSheet.ets',true).AddAccountSheet;
const base=identity('real-id',types.MICROSOFT);
accounts.push(base);selected=base.id;
const page=new Page();
page.onAccountsChanged=()=>{};page.onClose=()=>page.aboutToDisappear();
page.aboutToAppear();
assert.equal(page.currentAcc,base);
// 已选账号暂不可读时，其他可用账号仍可切换，但不能被当作当前身份。
selected='unavailable-id';page.refresh();
assert.equal(page.currentAcc,null);
assert.deepEqual(Array.from(page.otherAccs),[base]);
selected=base.id;page.refresh();
const call=async(action,args={})=>JSON.parse(await handler('accounts.'+action, JSON.stringify(args),'f'.repeat(32)));
let snapshot=await call('list');
const ref=snapshot.data.accounts[0].accountRef;
assert.match(ref,/^[a-f0-9]{32}$/);
assert(!JSON.stringify(snapshot).match(/private|SECRET|real-id|@/));
assert.deepEqual((await call('check',{accountRef:ref})).data,{accountRef:ref,state:'locally-usable'});
assert.equal((await call('list',{email:'private@example.org'})).status,'rejected');
const arm=async()=> (await call('prepareRemove',{accountRef:ref})).data.confirmation;
const old=await arm();
assert.equal((await call('close')).status,'needsUser');
assert.equal((await call('cancelRemove',{accountRef:ref,confirmation:old})).data.cancelled,true);
assert.equal((await call('remove',{accountRef:ref,confirmation:old})).status,'rejected');
const stale=await arm();
session='session-b';
const next=(await call('list')).data.accounts[0].accountRef;
assert.notEqual(next,ref);
assert.equal((await call('remove',{accountRef:ref,confirmation:stale})).status,'rejected');
assert.equal(accounts.length,1);
foreground=false;assert.equal((await call('prepareRemove',{accountRef:next})).status,'needsUser');foreground=true;

async function mountNewForm() {
  await Promise.resolve();
  assert(page.showAddSheet);
  const form=new Form();
  form.onSuccess=()=>{page.showAddSheet=false;page.refresh();page.onAccountsChanged();};
  form.onActionsReady=actions=>adapter.addShown(page,actions);
  form.aboutToAppear();
  return form;
}
assert.equal((await call('addOffline',{name:'private@example.org'})).status,'rejected');
const adding=call('addOffline',{name:'AMCL_QA'});
await mountNewForm();
const added=await adding;
assert.equal(added.status,'ok',JSON.stringify(added));assert.equal(selected,'new-id');
assert.equal((await call('select',{accountRef:next})).data.selected,true);
const newRef=added.data.accountRef;
const ticket=(await call('prepareRemove',{accountRef:newRef})).data.confirmation;
assert.equal((await call('remove',{accountRef:newRef,confirmation:ticket})).data.removed,true);
assert.equal(accounts.length,1);
assert.equal(summaries.some(x=>x.includes('删除账户')),true);
const login=call('login',{provider:'authlib'});
const form=await mountNewForm();
assert.equal((await login).status,'needsUser');assert.equal(form.mode,3);
assert.equal((await call('close')).status,'needsUser','用户登录表单显示中，不能收起父页');
page.showAddSheet=false;
assert.equal((await call('close')).data.closed,true);
page.aboutToAppear();
assert.equal((await call('select',{accountRef:next})).status,'rejected');
assert.equal((await call('list')).data.total,1);
// 真实经理交错：替换账号的写盘尚未完成时排入旧引用选择，必须在选择写盘前拒绝。
const {makePureEtsLoader} = await import('../../scripts/lib/load-pure-ets.mjs');
const Manager = makePureEtsLoader({
  './OfflineAccount':{OfflineAccount:{create:()=>identity('fallback',types.OFFLINE)}},
  './AccountStorage':{}, './MicrosoftAccount':{}, './AuthlibInjectorAccount':{}, './HuksCryptoProvider':{},
  './AppearanceTypes':{}, './AppearanceLibrary':{}, commons:{AppLogger:{info(){}}}
})('account/src/main/ets/AccountManager.ets').AccountManager;
const queued = new Manager();
const original=identity('replace-id',types.MICROSOFT);
const replacement={...original,serialize:()=>({id:original.id})};
const writes=[];
const persistedIds=[original.id,'unavailable-id',base.id];
const savedIndexes=[];
let enter,release;
const entered=new Promise(resolve=>{enter=resolve;});
const work=new Promise(resolve=>{release=resolve;});
// 持久索引包括暂不可读的账号，替换同 ID 的记录时应完整保留其位置。
queued.storage={getAccountIndexEntries:()=>persistedIds.slice(),
  saveRecordConfirmed:async(record,ids)=>{savedIndexes.push([record.id,ids.slice()]);enter();await work;},
  setSelectedIdConfirmed:async id=>{writes.push(id);}};
queued.accounts=[original,base];queued.selectedId=base.id;
queued.deferredIds.add('unavailable-id');
await assert.rejects(queued.add(replacement),error=>error.code==='NOT_READY');
assert.deepEqual(savedIndexes,[]);
queued._ready=true;
const replacing=queued.add(replacement);
await entered;
const staleSelect=queued.select(original.id,original);
release();await replacing;await assert.rejects(staleSelect,error=>error.code==='ACCOUNT_CHANGED');
assert.equal(queued.findById(original.id),replacement);
assert.deepEqual(savedIndexes,[[original.id,persistedIds]]);
assert.equal(queued.getSelectedId(),base.id);assert.deepEqual(writes,[]);
await queued.select(replacement.id,replacement);
assert.equal(queued.getSelectedId(),replacement.id);assert.deepEqual(writes,[replacement.id]);
await queued.select('');assert.equal(queued.getSelectedId(),'','原按 ID 选择/清空语义保留');

// 即使经理已写入选中 ID，回包前目标对象若变更，适配器也不能把后来记录归给原引用。
const refBefore=(await call('list')).data.accounts[0].accountRef;
const originalSelect=manager.select;
manager.select=async (id,target)=>{assert.equal(target,base);selected=id;accounts[0]={...base};};
assert.equal((await call('select',{accountRef:refBefore})).status,'unknown');
manager.select=originalSelect;
console.log('PASS account references/redaction, product selection and offline form, cancellation/stale plan, guarded login, confirmed close');
