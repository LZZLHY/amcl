/** 执行原ArkTS协调类；只替换UI/NAPI边界，故障回包不能覆盖用户原选择或丢退休租约。 */
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {dirname,join} from 'node:path';
import vm from 'node:vm';
import ts from './lib/ets-compiler.mjs';
const root=join(dirname(fileURLToPath(import.meta.url)),'..');
const source=readFileSync(join(root,'entry/src/main/ets/runtime/GameDialogRuntime.ets'),'utf8');
const compiled=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
let next=0,retired=[],responses=[],attempts=[],queue=[],dialog,failReplies=0,failDetach=false;
const napi={
  gameDialogAttach:()=>String(++next),
  gameDialogDetach:g=>{retired.push(g);if(failDetach)throw Error('injected detach');return true;},
  gameDialogTake:()=>queue.shift(),
  gameDialogReply:(g,id,result,user)=>{attempts.push({g,id,result,user});if(failReplies-->0)throw Error('injected reply');responses.push({g,id,result,user});return true;}
};
const ui={showAlertDialog:options=>{dialog=options;},getPromptAction:()=>({showToast:()=>{}})};
const sandbox={exports:{},require:name=>name==='libentry.so'?{default:napi}:name==='commons'?{AppLogger:{warn(){},info(){}},LOG_DOMAIN_LAUNCH:1}:{}};
vm.runInNewContext(compiled,sandbox,{filename:'GameDialogRuntime.production.js'});
const runtime=sandbox.exports.GameDialogRuntime;
runtime.attach(ui,1234);
queue.push({generation:'1',requestId:'7',kind:4,defaultButton:2,title:'中文',message:'正文'});
runtime.maintain();
assert.equal(dialog.buttons.length,3);assert.equal(dialog.buttons[1].defaultFocus,true);
failReplies=2;
dialog.buttons[1].action(); // 用户选择“否”(2)，首次NAPI失败。
dialog.onDidDisappear();  // 随后消失不能覆盖成取消(0)。
assert.equal(responses.length,0);
runtime.maintain();
assert.deepEqual(responses,[{g:'1',id:'7',result:2,user:true}]);
assert(attempts.every(x=>x.result===2&&x.user));
const oldButton=dialog.buttons[0].action;
failDetach=true;assert.throws(()=>runtime.detach());
failDetach=false;runtime.detach();assert.deepEqual(retired,['1','1']);
runtime.attach(ui,1234);oldButton();assert.equal(responses.length,1,'旧按钮不能回包给新窗口');
queue.push({generation:'2',requestId:'8',kind:2,defaultButton:1,title:'error',message:'body'});
ui.showAlertDialog=()=>{throw Error('injected show failure');};
failReplies=1;runtime.maintain();assert.equal(responses.length,1);
runtime.maintain();assert.deepEqual(responses[1],{g:'2',id:'8',result:0,user:false});
runtime.detach();
console.log('[game-dialog-runtime] PASS actual ArkTS: default focus, original choice retries, show failure, detach retry, stale callbacks');
