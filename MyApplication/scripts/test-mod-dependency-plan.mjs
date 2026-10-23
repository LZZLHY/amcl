/**
 * 执行真实依赖解析器与选版策略，验证精确 pin、完整依赖图及来源候选查询的边界。
 * 来源 JSON 使用既有样本；新增 Quilt 夹具只控制 API 标签过滤和故障，不复制生产匹配器。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {loader,root} from './mod-install-test-runtime.mjs';
const load=loader({'./ModSourceRouter':{}});
const T=load('mods/src/main/ets/ModTypes.ets');
const U=load('mods/src/main/ets/ModrinthUrls.ets');
const R=load('mods/src/main/ets/ModDependencyResolver.ets');
const P=load('mods/src/main/ets/ModUpdatePolicy.ets');
const dir=path.join(root,'scripts/fixtures/mod-install');
const all=JSON.parse(fs.readFileSync(path.join(dir,'versions-installed.json'),'utf8')).map(v=>U.mapModrinthVersion(v,U.ModrinthSourceMode.OFFICIAL_FIRST));
const iris=all.find(v=>v.projectId==='YL57xq9U');
const sodium=JSON.parse(fs.readFileSync(path.join(dir,'sodium-versions.json'),'utf8')).map(v=>U.mapModrinthVersion(v,U.ModrinthSourceMode.OFFICIAL_FIRST));
const pin=sodium.find(v=>v.id==='UddlN6L4');
const v=(id,pid,deps=[],number='1.0.0')=>({id,projectId:pid,source:'modrinth',name:id,versionNumber:number,versionType:'release',datePublished:'2026-01-01',loaders:['fabric'],gameVersions:['1.21.11'],dependencies:deps,files:[{filename:id+'.jar',url:'https://example.invalid/'+id+'.jar',mirrors:[],isPrimary:true,size:1}]});
const dep=(projectId,dependencyType='required',versionId)=>({projectId,dependencyType,versionId});
const opt={gameVersion:'1.21.11',loader:'fabric',installed:[],followOptional:true};
const resolver=(lists,exact={})=>new R.ModDependencyResolver(async(_,id)=>({id,title:id}),async(_,id)=>lists[id]??[],async(_,id)=>{if(!exact[id])throw new Error('Missing version '+id);return exact[id];});
let result=await resolver({AANobbMI:sodium},{UddlN6L4:pin}).resolve(iris,opt);
assert.equal(result.dependencies[0].version.id,'UddlN6L4');assert.equal(R.dependencyPlanErrors(result).length,0);
result=await resolver({}, {UddlN6L4:pin}).resolve(v('root','root',[{versionId:'UddlN6L4',dependencyType:'required'}]),opt);
assert.equal(result.dependencies[0].projectId,'AANobbMI');
result=await resolver({}, {UddlN6L4:pin}).resolve(v('root','root',[{versionId:'UddlN6L4',dependencyType:'optional'}]),{...opt,selectedOptionalIds:['AANobbMI']});
assert.equal(result.dependencies[0].selected,true);
for(const local of [{enabled:false,remoteVersionId:pin.id,integrity:'verified'},{enabled:true,remoteVersionId:'old',integrity:'verified'},{enabled:true,remoteVersionId:pin.id,integrity:'corrupt'}]){
  result=await resolver({AANobbMI:sodium},{UddlN6L4:pin}).resolve(iris,{...opt,installed:[{...local,remoteSource:'modrinth',remoteProjectId:'AANobbMI'}]});
  assert.equal(result.dependencies[0].alreadyInstalled,false);
}
const local={enabled:true,remoteSource:'modrinth',remoteProjectId:'lib',remoteVersionId:'lib1',integrity:'verified'};
result=await resolver({child:[v('child','child')]},{lib1:v('lib1','lib',[dep('child')])}).resolve(v('root','root',[dep('lib')]),{...opt,installed:[local]});
assert.equal(result.dependencies.find(d=>d.projectId==='lib').alreadyInstalled,true);
assert.ok(result.dependencies.some(d=>d.projectId==='child'));
const lists={optional:[v('optional','optional',[dep('child')])],child:[v('child','child')]};
result=await resolver(lists).resolve(v('root','root',[dep('optional','optional')]),opt);
assert.equal(result.dependencies.length,1);assert.equal(result.dependencies[0].selected,false);
result=await resolver(lists).resolve(v('root','root',[dep('optional','optional')]),{...opt,selectedOptionalIds:['optional']});
assert.equal(result.dependencies.length,2);assert.ok(result.dependencies.every(d=>d.selected));
const graph={a:[v('a','a',[dep('x','required','x1')])],b:[v('b','b',[dep('x','required','x2')])],x:[v('x2','x')]};
result=await resolver(graph,{x1:v('x1','x'),x2:v('x2','x')}).resolve(v('root','root',[dep('a'),dep('b')]),opt);
assert.ok(R.dependencyPlanErrors(result).some(e=>e.includes('不同指定版本')));
result=await resolver({a:[v('a','a',[dep('x','required','x1')])],x:[v('x2','x')]},{x1:v('x1','x')}).resolve(v('root','root',[dep('x'),dep('a')]),opt);
assert.equal(result.dependencies.find(d=>d.projectId==='x').version.id,'x1');
result=await resolver({}).resolve(v('root','root',[dep('missing')]),opt);
assert.ok(R.dependencyPlanErrors(result).length>0);assert.throws(()=>R.extractDependencyFiles(result.dependencies));
assert.equal(R.isModVersionCompatible({...v('wrong','p'),loaders:['forge'],gameVersions:['1.20.4']},'fabric','1.21.11'),false);
assert.equal(T.pickLatestModVersion([v('stable','p',[],'1.0'),{...v('beta','p',[],'2.0-beta'),versionType:'beta'}]).id,'stable');
const router={repoFor:()=>({getVersion:async id=>id===pin.id?pin:iris})};
const update=await P.pickModUpdate('modrinth','AANobbMI',pin.id,sodium,[{enabled:true,remoteSource:'modrinth',remoteProjectId:iris.projectId,remoteVersionId:iris.id}],router);
assert.equal(update,null,'Iris pin must prevent offering incompatible Sodium update');
const stable=v('stable','p');
assert.equal(await P.pickModUpdate('modrinth','p','stable',[stable,{...v('beta','p',[],'2.0-beta'),versionType:'beta'}],[],{repoFor:()=>({getVersion:async()=>stable})}),null,'Stable installations must not be moved to beta automatically');

/**
 * 构造严格筛标签的来源端口：MR 接受数组中任一标签，CF 只消费首个 loader。
 * 默认同时筛 MC；leakCandidates 用来模拟镜像返回过宽结果，证明最终生产 matcher 仍会拒绝误装。
 * 精确文件读取独立记录调用，确保候选扩展不会改写 pin 或已装复用路径；错误按原生产链路上报。
 */
function quiltCandidateResolver(source, candidates, {failLoader = '', leakCandidates = false, exactVersions = {}} = {}) {
  const calls = [];
  const exactCalls = [];
  const subject = new R.ModDependencyResolver(
    async (requestedSource, id) => ({source: requestedSource, id, title: id}),
    async (requestedSource, id, loaders, games) => {
      calls.push({source: requestedSource, id, loaders: Array.from(loaders), games: Array.from(games)});
      if (loaders.includes(failLoader)) throw new Error('候选分支失败：' + failLoader);
      if (leakCandidates) return candidates;
      const apiLoaders = source === T.ModSource.CURSEFORGE ? loaders.slice(0, 1) : loaders;
      return candidates.filter(candidate =>
        (apiLoaders.length === 0 || apiLoaders.some(label => candidate.loaders.includes(label)))
        && (games.length === 0 || games.some(game => candidate.gameVersions.includes(game))));
    },
    async (requestedSource, id) => {
      exactCalls.push({source: requestedSource, id});
      if (exactVersions[id] === undefined) throw new Error('精确文件不存在：' + id);
      return exactVersions[id];
    },
  );
  return {subject, calls, exactCalls};
}

// 两来源均运行同一业务场景，API 模拟分别保留各自 loader 数组语义，防止只修好 MR 而漏掉 CF。
for (const source of [T.ModSource.MODRINTH, T.ModSource.CURSEFORGE]) {
  const candidate = (id, loaders, number = '1.0', gameVersions = ['1.21.11']) =>
    ({...v(id, 'quilt-lib', [], number), source, loaders, gameVersions});
  const fabricOnly = candidate('fabric-only', ['fabric']);
  const quiltNative = candidate('quilt-native', ['quilt'], '2.0');
  const shared = candidate('shared', ['quilt', 'fabric'], '3.0');
  const wrongLoader = candidate('wrong-loader', ['forge'], '99.0');
  const wrongMc = candidate('wrong-mc', ['fabric'], '98.0', ['1.20.4']);
  const rootVersion = {...v('quilt-root', 'quilt-root', [dep('quilt-lib')]), source};
  const quiltOpt = {...opt, loader: 'quilt'};

  // 完整目录可以推荐 Fabric 根文件给 Quilt；依赖候选请求也必须覆盖同一单向兼容集合。
  assert.equal(R.isModVersionCompatible(rootVersion, 'quilt', opt.gameVersion), true);
  assert.equal(R.isModVersionCompatible(quiltNative, 'fabric', opt.gameVersion), false,
    'Fabric 不能反向接受仅 Quilt 的文件');
  let replay = quiltCandidateResolver(source, [fabricOnly]);
  let plan = await replay.subject.resolve(rootVersion, quiltOpt);
  assert.equal(R.dependencyPlanErrors(plan).length, 0, source + ' 应解析 Fabric-only 的 Quilt 前置');
  assert.equal(plan.dependencies[0].version.id, fabricOnly.id);
  assert.deepEqual(replay.calls.map(call => call.loaders).sort(), [['fabric'], ['quilt']],
    'CF 只消费首标签，两个兼容标签必须分别查询');
  assert.ok(replay.calls.every(call => call.source === source && call.id === 'quilt-lib'
    && call.games.length === 1 && call.games[0] === opt.gameVersion));

  // 同一共享文件可能同时出现在两个查询中；按统一新旧规则选择，保留一次依赖与一次下载。
  replay = quiltCandidateResolver(source, [fabricOnly, quiltNative, shared, wrongLoader, wrongMc]);
  plan = await replay.subject.resolve(rootVersion, quiltOpt);
  assert.equal(R.dependencyPlanErrors(plan).length, 0);
  assert.equal(plan.dependencies.length, 1);
  assert.equal(plan.dependencies[0].version.id, shared.id);
  assert.equal(R.extractDependencyFiles(plan.dependencies).length, 1);

  // 即使镜像没有落实筛选，99.0 Forge、98.0 其他 MC 与服务端分发也不得压过兼容客户端文件。
  const serverPack = {...candidate('server-pack', ['fabric'], '100.0'), isServerPack: true};
  replay = quiltCandidateResolver(source, [fabricOnly, wrongLoader, wrongMc, serverPack], {leakCandidates: true});
  plan = await replay.subject.resolve(rootVersion, quiltOpt);
  assert.equal(R.dependencyPlanErrors(plan).length, 0);
  assert.equal(plan.dependencies[0].version.id, fabricOnly.id);
  replay = quiltCandidateResolver(source, [wrongLoader, wrongMc, serverPack], {leakCandidates: true});
  plan = await replay.subject.resolve(rootVersion, quiltOpt);
  assert.ok(R.dependencyPlanErrors(plan).length > 0, '没有兼容客户端文件时不能生成可安装计划');
  assert.throws(() => R.extractDependencyFiles(plan.dependencies));

  // 任一分支失败都意味着候选集合未知；另一支已有可用共享文件也不能让必需前置静默成功。
  for (const failLoader of ['quilt', 'fabric']) {
    replay = quiltCandidateResolver(source, [shared], {failLoader});
    plan = await replay.subject.resolve(rootVersion, quiltOpt);
    assert.ok(R.dependencyPlanErrors(plan).some(message => message.includes('候选分支失败：' + failLoader)));
    assert.throws(() => R.extractDependencyFiles(plan.dependencies), '不完整候选查询不能授予安装资格');
  }

  // 精确 pin 仍直接取原文件；CF 坐标必须保留项目 ID，不能被兼容候选查询替换为另一个版本。
  const pinnedRoot = {...rootVersion, dependencies: [dep('quilt-lib', 'required', fabricOnly.id)]};
  const exactKey = source === T.ModSource.CURSEFORGE ? 'quilt-lib/' + fabricOnly.id : fabricOnly.id;
  replay = quiltCandidateResolver(source, [], {failLoader: 'quilt', exactVersions: {[exactKey]: fabricOnly}});
  plan = await replay.subject.resolve(pinnedRoot, quiltOpt);
  assert.equal(R.dependencyPlanErrors(plan).length, 0);
  assert.equal(plan.dependencies[0].version.id, fabricOnly.id);
  assert.equal(replay.calls.length, 0);
  assert.ok(replay.exactCalls.length > 0 && replay.exactCalls.every(call => call.source === source && call.id === exactKey));

  // 已装且完整的 Fabric 前置也可由 Quilt 复用，不触发额外目录请求或重复下载。
  const installed = {enabled: true, remoteSource: source, remoteProjectId: 'quilt-lib',
    remoteVersionId: fabricOnly.id, integrity: 'verified'};
  replay = quiltCandidateResolver(source, [], {failLoader: 'quilt', exactVersions: {[exactKey]: fabricOnly}});
  plan = await replay.subject.resolve(rootVersion, {...quiltOpt, installed: [installed]});
  assert.equal(R.dependencyPlanErrors(plan).length, 0);
  assert.equal(plan.dependencies[0].alreadyInstalled, true);
  assert.equal(replay.calls.length, 0);
  assert.equal(R.extractDependencyFiles(plan.dependencies).length, 0);

  // 普通 Fabric 目标仍只查询自身标签；候选扩展不能反向扩大其他目标的兼容范围。
  replay = quiltCandidateResolver(source, [fabricOnly, quiltNative]);
  plan = await replay.subject.resolve(rootVersion, opt);
  assert.equal(R.dependencyPlanErrors(plan).length, 0);
  assert.deepEqual(replay.calls.map(call => call.loaders), [['fabric']]);
  assert.equal(plan.dependencies[0].version.id, fabricOnly.id);
}
console.log('PASS: MR/CF Quilt dual single-loader queries, Fabric-only fallback, shared file, MC/loader/client checks, branch errors, exact pins and installed reuse');
console.log('PASS: actual Iris pin, ID-only dependencies, inactive/corrupt/old deps, recursive installed deps, optional subtrees, conflicting/all incoming pins, required errors, selected loader/MC, stable default and update pin');
