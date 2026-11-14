/**
 * 执行生产TaskCard方法和TaskDetailView Builder的原始Text表达式，验证ABORTED展示。
 * SDK AST只选正文，不重写状态判据；平台格式器作为边界注入，不声称ArkUI渲染已验收。
 * --source-ref加载真实旧组件作负控；动作Builder按Git blob LF归一后与基线相同，保护原重试/取消。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
import compiler from './lib/ets-compiler.mjs';
import {PROJECT_ROOT, assertExternalOutputPath} from './lib/workspace-paths.mjs';

const args=process.argv.slice(2);assert.equal(args[0],'--output');assert.ok(path.isAbsolute(args[1]));
const output=assertExternalOutputPath(args[1],{root:PROJECT_ROOT});
const sourceRef=args[2]==='--source-ref'?args[3]:'';
assert.ok(args.length===2||(args.length===4&&sourceRef));
const baseline='beb05511c15795fba6a6e6e78ac42541c15864e2';
const paths={card:'entry/src/main/ets/components/TaskCard.ets',detail:'entry/src/main/ets/components/TaskDetailView.ets'};
function source(file,ref=sourceRef){return ref?execFileSync('git',['-C',PROJECT_ROOT,'show',ref+':'+file],{encoding:'utf8'}):fs.readFileSync(path.join(PROJECT_ROOT,file),'utf8');}
function parsed(file,text){const ast=compiler.createSourceFile(file,text,compiler.ScriptTarget.Latest,true);
 return{ast,component:ast.statements.find(node=>node.name?.getText(ast)===path.basename(file,'.ets'))};}
function member(parsed,name){const found=parsed.component.members.find(node=>node.name?.getText(parsed.ast)===name);assert.ok(found,'missing production member '+name);return found;}
function textArgument(parsed,builder,needle){const found=[];function visit(node){if(compiler.isCallExpression(node)&&node.expression.getText(parsed.ast)==='Text'&&node.arguments[0]?.getText(parsed.ast).includes(needle))found.push(node.arguments[0]);compiler.forEachChild(node,visit);}
 visit(member(parsed,builder));assert.equal(found.length,1,'必须精确选择实际Builder Text参数：'+needle);return found[0].getText(parsed.ast);}
const texts=Object.fromEntries(Object.entries(paths).map(([key,file])=>[key,source(file)]));
const card=parsed(paths.card,texts.card),detail=parsed(paths.detail,texts.detail);
// 枚举及stateLabel直接来自生产模型，避免测试另写ABORTED的中文映射。
const modelPath='feature_core/src/main/ets/download/UnifiedDownloadTask.ets',modelText=source(modelPath,'');
const modelAst=compiler.createSourceFile(modelPath,modelText,compiler.ScriptTarget.Latest,true);
const modelNames=['UnifiedTaskState','TaskCategory','stateLabel'];
const modelCode=modelNames.map(name=>{const node=modelAst.statements.find(item=>item.name?.getText(modelAst)===name);assert.ok(node);return node.getText(modelAst).replace(/^export\s+/,'');}).join('\n');
const cardMethods=['isWaiting','isActive','isPaused','isDone','isError','metaLeft','statusIcon','formatDuration_'];
const detailMethods=['isHeroError_','heroTitleText_'];
const bindings={hero:textArgument(detail,'DetailHeroCard_','下载失败'),value:textArgument(detail,'DetailStatsRow_','errorKind'),caption:textArgument(detail,'DetailStatsRow_',"'错误'")};
const combined=modelCode+'\nclass Card {\n'+cardMethods.map(name=>member(card,name).getText(card.ast)).join('\n')+'\n}\nclass Detail {\n'+detailMethods.map(name=>member(detail,name).getText(detail.ast)).join('\n')+
 '\nhero(){return '+bindings.hero+';}\nvalue(){return '+bindings.value+';}\ncaption(){return '+bindings.caption+';}\n}\n';
const js=compiler.transpileModule(combined,{compilerOptions:{target:compiler.ScriptTarget.ES2020},reportDiagnostics:true});
assert.equal((js.diagnostics??[]).filter(item=>item.category===compiler.DiagnosticCategory.Error).length,0);
const icons=Object.fromEntries(['CheckCircle','Close','Error','Pause','Hourglass','DataPack','Check','ArrowDown'].map(x=>[x,x]));
const actual=new Function('formatSpeed','formatEta','AppIconName',js.outputText+'\nreturn{Card,Detail,UnifiedTaskState,TaskCategory};')(n=>'speed:'+n,n=>'eta:'+n,icons);
const state=actual.UnifiedTaskState,category=actual.TaskCategory,passed=[];
const left=new actual.Card(),right=new actual.Detail();
const view={state:state.ABORTED,title:'JDK 21 更新',category:category.JDK,errorKind:'stale-error',errorMessage:'old',currentLabel:'JDK 21 github 7%',durationMs:1000,speedBps:8000,etaSeconds:2,queuePosition:0,canRetry:true,canCancel:false};
left.view=view;right.view=view;
function test(name,body){body();passed.push(name);console.log('PASS '+name);}
try{
 test('实际ABORTED详情和列表显示已取消，而非失败或错误',()=>{
  assert.equal(right.hero(),'已取消','真实旧Builder会硬编码下载失败');
  assert.equal(left.metaLeft(),'已取消');assert.equal(left.statusIcon(),'Close');
  assert.equal(right.value(),'已取消');assert.equal(right.caption(),'状态');
  assert.match(right.heroTitleText_(view),/^已取消 /);
  assert.equal(right.isHeroError_(view),true,'保留原终态布局和重试/移除分组');assert.equal(left.isError(),true);
 });
 test('真正ERROR保留下载失败、错误分类和原标题',()=>{
  view.state=state.ERROR;view.errorKind='HttpStatus';
  assert.equal(right.hero(),'下载失败');assert.equal(right.value(),'HttpStatus');assert.equal(right.caption(),'错误');
  assert.equal(left.metaLeft(),'HttpStatus · 失败');assert.equal(left.statusIcon(),'Error');assert.equal(right.heroTitleText_(view),view.title);
 });
 test('DONE及下载中正例保留原进度/速度语义，导出和更新不虚称安装完成',()=>{
  view.state=state.DONE;view.errorKind='';assert.match(left.metaLeft(),/^完成/);assert.match(right.heroTitleText_(view),/^安装完成 /);
  view.category=category.GAME_EXPORT;assert.match(right.heroTitleText_(view),/^电脑文件准备完成/);
  view.category=category.APP_UPDATE;assert.match(right.heroTitleText_(view),/^下载并校验完成/);
  view.state=state.DOWNLOADING;view.category=category.JDK;assert.equal(right.isHeroError_(view),false);
  assert.equal(right.value(),'speed:8000');assert.equal(right.caption(),'速度');assert.match(left.metaLeft(),/speed:8000/);
 });
 test('原详情和列表retry/remove/cancel动作Builder保持，不改task事实',()=>{
  for(const[key,name]of[['card','ActionGroup'],['detail','DetailActionBar_']]){
   const current=key==='card'?card:detail,previous=parsed(paths[key],source(paths[key],baseline));
   // Windows检出使用CRLF，Git blob使用LF；只归一此工具契约差异，不删除空白或改正文。
   assert.equal(member(current,name).getText(current.ast).replaceAll('\r\n','\n'),
    member(previous,name).getText(previous.ast).replaceAll('\r\n','\n'));
  }
  assert.equal(view.canRetry,true);assert.equal(view.canCancel,false);
 });
}finally{
 fs.mkdirSync(output,{recursive:true});fs.writeFileSync(path.join(output,'result.json'),JSON.stringify({passed,expected:4,complete:passed.length===4,sourceRef:sourceRef||'current-worktree',baseline,
  source:Object.entries(texts).map(([key,text])=>({path:paths[key],sha256:crypto.createHash('sha256').update(text).digest('hex')})),
  scope:'生产组件方法/Builder Text表达式；非ArkUI渲染、任务执行或设备验收',fixtures:'memory only; no user data'},null,2)+'\n');
}
