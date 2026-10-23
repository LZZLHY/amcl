/** 商店网页边界回归：执行生产守卫方法，另外核对声明式可见动作及本地政策路由/正文。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import {loader, ts, root} from './mod-install-test-runtime.mjs';

const read=relative=>fs.readFileSync(path.join(root,relative),'utf8');
const components='entry/src/main/ets/components/', pages='entry/src/main/ets/pages/';
let checks=0;

/**
 * 只截取真实组件方法，不复制其业务实现。TypeScript scanner 忽略字符串/注释中的括号，
 * 因而不需要在宿主执行 ArkUI 的 build DSL；方法体仍由当前生产文件实际转译执行。
 */
function method(relative,name,policy,extra={}) {
  const source=read(relative), marker=new RegExp('  private (?:async )?'+name+'\\('), match=marker.exec(source);
  assert.ok(match,relative+': '+name);
  const start=match.index, open=source.indexOf('{',start);
  const scanner=ts.createScanner(ts.ScriptTarget.Latest,true,ts.LanguageVariant.Standard,source.slice(open));
  let depth=0,end=-1;
  for(let token=scanner.scan();token!==ts.SyntaxKind.EndOfFileToken;token=scanner.scan()) {
    if(token===ts.SyntaxKind.OpenBraceToken)depth++;
    if(token===ts.SyntaxKind.CloseBraceToken&&--depth===0){end=open+scanner.getTextPos();break;}
  }
  assert.ok(end>open,'method body '+name);
  const code=ts.transpileModule('class Probe {\n'+source.slice(start,end)+'\n}\nexports.Probe=Probe;',
    {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText;
  const exports={};
  vm.runInNewContext(code,{exports,DistributionPolicy:policy,AppStorage:{get(){return extra.context;}},
    PRIVACY_POLICY_URL:'https://lzzlhy.github.io/amcl/privacy-policy',logShareInstanceForUrl:()=> 'logshare',
    ...extra},{filename:relative+':'+name});
  return new exports.Probe();
}

/** 每个渠道使用独立的真实 DistributionPolicy 单例，不能为测试把 immutable configure 改回可切换。 */
function policy(store) {
  const {DistributionPolicy,DistributionChannel}=loader()('commons/src/main/ets/common/DistributionPolicy.ets');
  DistributionPolicy.configure(store?DistributionChannel.Store:DistributionChannel.Sideload);
  return DistributionPolicy;
}
const store=policy(true), sideload=policy(false);
const guarded=[
  [components+'WebHostView.ets','openInBrowser',[]], [components+'WebHostView.ets','retry',[]],
  [components+'PreLaunchCheckSheet.ets','openNoJitDoc',[]], [components+'VersionConfigPanel.ets','openNoJitDoc',[]],
  [pages+'ModBrowsePage.ets','openWebsiteFromSheet',[]], [pages+'ModBrowsePage.ets','openExternalUrl_',['https://example.org']],
  [pages+'ModBrowsePage.ets','openCrossSourceWeb',[0]], [components+'SkinCapeDetailSheet.ets','openMinecraftProfile',[]],
  [components+'McErrorSheet.ets','openInBrowser_',['https://example.org']], [pages+'LogShareHistoryPage.ets','open_',[{url:'https://example.org'}]],
  [pages+'SponsorPage.ets','handleImageDownload_',['https://example.org/a.png']],
  [pages+'ChangelogPage.ets','openUrl_',['https://example.org/changelog']],
  [pages+'SoftwareUpdatePage.ets','openGithub',[]], [pages+'SoftwareUpdatePage.ets','startUpdate',[]],
  [pages+'SoftwareUpdatePage.ets','chooseChannel',['preview']],
];
for(const [relative,name,args] of guarded) {
  // 没有注入网页、相册、路由等依赖；任何守卫之后的副作用被误执行都会抛错。
  const probe=method(relative,name,store);
  await probe[name](...args);checks++;
}
const menu=method(components+'ModDetailSheet.ets','buildWebMenu',store);
assert.equal(menu.buildWebMenu().length,0);checks++;
let fileSelectorCalls=0;
method(components+'WebHostView.ets','handleFileSelect_',store).handleFileSelect_({handleFileList(files){assert.equal(files.length,0);fileSelectorCalls++;}});
assert.equal(fileSelectorCalls,1);checks++;

// 本地政策必须先路由并返回，不能继续触发原浏览器流程；其他渠道保留同一生产方法的网页行为。
for(const [relative,name,kind] of [[components+'PrivacyConsentDialog.ets','openPolicy','privacy'],[components+'ActivityShareSheet.ets','openPolicy_','logshare']]) {
  for(const channel of [store,sideload]) {
    const routes=[],wants=[];
    const context={startAbility(want){wants.push(want);return Promise.resolve();}};
    const probe=method(relative,name,channel,{context});probe.context=context;
    probe.getUIContext=()=>({getRouter:()=>({pushUrl(value){routes.push(value);return Promise.resolve();}})});
    probe[name]();
    if(channel===store){assert.equal(wants.length,0);assert.equal(routes[0].url,'pages/LocalPolicyPage');assert.equal(routes[0].params['policy'],kind);}
    else {assert.equal(routes.length,0);assert.equal(wants.length,1);assert.ok(wants[0].uri.startsWith('https://'));}
    checks++;
  }
}
// 原渠道的通用浏览器函数必须仍能工作；不能用“一律返回”伪装通过商店用例。
const wants=[];const browser=method(components+'WebHostView.ets','openInBrowser',sideload);
browser.fallbackBrowserUrl='https://example.org/retained';browser.context={startAbility(want){wants.push(want);}};
browser.openInBrowser();assert.equal(wants[0].uri,'https://example.org/retained');checks++;

// 商店日志菜单删去网页动作后，索引0/1仍分别是文件明细/撤回，不得偏移成网页或误撤回。
for(const choice of [0,1]) {
  let buttons=[],revoked=0;const history=method(pages+'LogShareHistoryPage.ets','recordMenu_',store);
  history.busy=false;history.theme={primary:'#000',errorText:'#f00'};history.expandedRecord='';
  history.getUIContext=()=>({getPromptAction:()=>({showActionMenu(value){buttons=value.buttons;return Promise.resolve({index:choice});}})});
  history.confirmRevoke_=()=>{revoked++;};history.recordMenu_({url:'https://example.org/record'});
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(buttons.length,2);assert.ok(!buttons.some(button=>button.text.includes('网页')));
  assert.equal(revoked,choice===1?1:0);assert.equal(history.expandedRecord,choice===0?'https://example.org/record':'');checks++;
}
// JIT 失败保留本地原因和确认，但商店不再露出“如何解决”网页按钮。
const jit=method(components+'VersionConfigPanel.ets','promptJitUnavailableForForge',store);
jit.theme={primary:'#000',textSecondary:'#666'};let jitButtons=[];
jit.getUIContext=()=>({getPromptAction:()=>({showDialog(value){jitButtons=value.buttons;return Promise.resolve({index:0});}})});
jit.promptJitUnavailableForForge();await new Promise(resolve=>setImmediate(resolve));
assert.equal(jitButtons.length,1);assert.equal(jitButtons[0].text,'我知道了');checks++;

// 声明式可见层由源码约束验证；真实绘制和交互仍属于后续设备验收。
const host=read(components+'WebHostView.ets');
assert.match(host,/if \(!DistributionPolicy\.isStore\(\) && !this\.loadFailed\)\s*\{\s*Web\(/);
assert.match(read(components+'ModDetailSheet.ets'),/if \(!DistributionPolicy\.isStore\(\)\) \{ Row/);
assert.equal((read(components+'SkinCapeDetailSheet.ets').match(/acc\.type === AccountType\.MICROSOFT && !DistributionPolicy\.isStore\(\)/g)||[]).length,2);
const local=read(pages+'LocalPolicyPage.ets');
assert.match(local,/Text\(this\.body\)/);assert.ok(!/\bWeb\s*\(|startAbility\s*\(/.test(local));
assert.match(local,/params\['policy'\]/);
// 从真实页面读取方法验证字符串路由键选中实际随包资源；未知参数不能拼进资源路径。
for(const kind of ['privacy','logshare','license','../unexpected']) {
  const resources=[];
  const probe=method(pages+'LocalPolicyPage.ets','load_',store,{util:{TextDecoder:{create:()=>({decodeToString:bytes=>new TextDecoder().decode(bytes)})}}});
  probe.generation=0;probe.getUIContext=()=>({getRouter:()=>({getParams:()=>({'policy':kind})})});
  probe.context={resourceManager:{async getRawFileContent(name){resources.push(name);return fs.readFileSync(path.join(root,'entry/src/main/resources/rawfile',name));}}};
  await probe.load_();
  const expected=kind==='logshare'?'logshare-privacy.txt':kind==='license'?'licenses.txt':'privacy.txt';
  assert.equal(resources[0],'store-policies/'+expected);assert.equal(probe.loading,false);assert.equal(probe.errorText,'');assert.ok(probe.body.length>100);checks++;
}
assert.match(read(components+'AddAccountSheet.ets'),/Web\(\{ src: this\.authUrl/);
assert.ok(!/DistributionPolicy\.isStore/.test(read(components+'AddAccountSheet.ets')));checks+=6;
const profile=JSON.parse(read('entry/build-profile.json5'));
assert.ok(JSON.parse(read('entry/src/main/resources/base/profile/main_pages.json')).src.includes('pages/LocalPolicyPage'));
for(const target of profile.targets)if(target.source?.pages)assert.ok(target.source.pages.includes('pages/LocalPolicyPage'),target.name);
for(const file of ['privacy.txt','logshare-privacy.txt','licenses.txt'])assert.ok(read('entry/src/main/resources/rawfile/store-policies/'+file).trim().length>100);
assert.match(read('entry/src/main/resources/rawfile/store-policies/privacy.txt'),/一、本政策适用范围/);
assert.match(read('entry/src/main/resources/rawfile/store-policies/licenses.txt'),/GNU LESSER GENERAL PUBLIC LICENSE/);checks+=6;
console.log('PASS store channel policy: '+checks+' production guard/local-route/content checks; Microsoft authorization Web and non-store browser retained');
