/** 同一份具名操作契约产生平台脚本签名、位置参数解析和供小艺读取的 SKILL.md。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const contracts = path.join(repo, 'config/launcher-skill');
const out = path.join(repo, 'entry/skills/amcl-launcher');
const check = process.argv.includes('--check');
const topics = {
  'account-layout': '账号、玩家外观、控制布局及输入配置',
  exports: '实例导出、内容范围、草稿、目标和校验',
  instances: '实例、启动、资源、文件、存档及任务',
  settings: '设置、运行时、更新与诊断',
  support: '开屏、文档、消息、日志和技术支持'
};
const methods = fs.readdirSync(contracts).filter(file => file.endsWith('.json')).sort()
  .flatMap(file => {
    const topic = path.basename(file,'.json');
    assert.ok(topics[topic], 'new Skill topic requires a human-readable index entry: '+topic);
    return JSON.parse(fs.readFileSync(path.join(contracts,file),'utf8').replace(/^\uFEFF/,'')).map(method=>({...method,topic}));
  });
// 契约文件按玩家操作顺序编排；保持同一流程在相邻引用页，公开方法名不依赖排列顺序。
const ordered = methods;
assert.ok(ordered.length);
assert.equal(new Set(ordered.map(m => m.name)).size, ordered.length, 'duplicate Skill method');
const quote = JSON.stringify;
const header = [
  '---','name: amcl-launcher','description: 查询及管理 AMCL 的游戏实例、下载资源、账号、控制布局、设置、活动记录与支持；通过原启动器完成用户确认。','---','',
  '## 触发场景','',
  '用户明确希望在 AMCL 中查询实例、安装游戏、管理资源或调整设置时，选择下面语义匹配的方法。需要账号授权、文件选择、公开分享或删除确认时，提示用户在原界面继续。',
  '游戏内角色操作、系统备份指令、任意网址、任意文件读写、设备命令和开发 QA 授权不属于这些方法。',
  'busy 表示另一调用或业务操作正在进行；unavailable 表示产品、当前页面或准入条件不符；unknown 表示结果尚未证实，先读取原任务或产品状态。不要重放不确定的写操作。',
  '遇到 needsUser 且 reason 为 awaitingUser 时，先请用户完成当前界面决定。用 getLauncherHandoff 传回原 method 与 operationRef 查询原结果。只要该引用仍在等待，就不要重新发起原操作。',
  '以下为 ExecuteResult.result 的契约；code 表示脚本处理结果，业务状态单独判断。位置参数按 arg1、arg2 的次序传入；省略中间可选值时须在该位置传空字符串。',''
];
const ets = ["import { scriptManager } from '@kit.AbilityKit';",
  "import { invokeSkill } from '../../../src/main/ets/launcherskill/PlatformReport';",'',
  '/** 由 scripts/generate-launcher-skill.mjs 从产品动作契约生成，每项公开能力对应一个固定的业务方法。 */',
  'export default class LauncherSkill {'];
const main = [...header, '## 业务方法', '', '按用户目标读取对应的一层能力契约。每个方法给出调用话术、位置参数、返回状态和使用边界。',''];
const references = new Map();
const counts = new Map();
const labels = {
  'account-layout':['账号、登录与离线外观','皮肤披风、角色与布局清单','布局导入导出和工作台','控件编辑、输入与保存结果'],
  exports:['导出范围、检查计划、保存与任务结果'],
  instances:['首页、实例清单与版本设置','版本安装、启动、存档与文件','实例文件、目录与资源目标','资源搜索、安装与已装内容','模组检查、更新与下载队列','队列控制、整合包选择与资源来源','版本维护、详情与运行要求'],
  settings:['查找设置、外观、内存与存储','图形、分辨率、日志与设备输入','诊断、Java 版本与启动器更新','更新进度、设置交接与文件选择结果'],
  support:['启动、日志、消息与关于','发布记录、活动证据与分享','存储、通知、技术支持及备份','分享、用户选择及操作回执']
};
function sampleField(key,schema) {
  if (Object.hasOwn(schema,'example')) return schema.example;
  if (Object.hasOwn(schema,'const')) return schema.const;
  if (schema.enum) return schema.enum[0];
  if (schema.type === 'array') return Array.from({length:schema.minItems ?? 0},()=>sampleField('item',schema.items ?? {}));
  if (schema.type === 'object') return Object.fromEntries((schema.required ?? []).map(k=>[k,sampleField(k,schema.properties[k])]));
  if (schema.type === 'boolean') return false;
  if (schema.type === 'integer' || schema.type === 'number') return Math.min(schema.maximum ?? Infinity,Math.max(schema.minimum ?? 0,1));
  return key;
}
function positionalExample(args, named) {
  const last = args.findLastIndex(a=>Object.hasOwn(named,a.name));
  return Object.fromEntries(args.slice(0,last+1).map((a,i)=>['arg'+(i+1),named[a.name] ?? '']));
}
const catalog = ["import { SkillArgument } from './SkillArguments';",'',
  '/** 由产品契约生成。两个传输入口按同一个业务名解析类型与目标，未知名称没有默认分派。 */',
  'interface ConditionalFields { key: string; value: string; required: string[]; }',
  'export interface LauncherMethodSpec {','  domain: string;','  fields: SkillArgument[];','  cases?: ConditionalFields[];','}','',
  'export function launcherMethodSpec(method: string): LauncherMethodSpec | undefined {','  switch (method) {'];
for (const m of ordered) {
  assert.match(m.name,/^[a-z][a-zA-Z0-9]+$/);
  assert.match(m.domain,/^[a-z][a-zA-Z0-9]+$/);
  assert.ok(m.description && Array.isArray(m.args) && Array.isArray(m.results) && m.results.length);
  assert.equal(new Set(m.args.map(a=>a.name)).size,m.args.length);
  const properties = {}, example = {}, required = [], fields = [];
  m.args.forEach((a,i) => {
    assert.match(a.name,/^[a-z][a-zA-Z0-9_]*$/);
    assert.ok(['string','integer','boolean'].includes(a.type) && typeof a.required==='boolean' && a.description);
    const key = 'arg'+(i+1);
    properties[key] = {type:a.required ? a.type : [a.type,...(a.type === 'string' ? [] : ['string'])],description:a.description};
    if (a.type === 'string') properties[key].maxLength = 16384;
    else if (!a.required) properties[key] = {anyOf:[{type:a.type},{const:''}],description:a.description};
    if (a.required) required.push(key);
    if (a.enum) properties[key].enum=a.required ? a.enum : [...new Set([...a.enum,''])];
    if (a.required) example[key]=a.example ?? a.enum?.[0] ?? (a.type==='integer'?1:a.type==='boolean'?true:a.name);
    fields.push('{ name: '+quote(a.name)+', kind: '+quote(a.type)+', required: '+a.required+
      (a.enum?', choices: '+JSON.stringify(a.enum.map(String)):'')+' }');
  });
  ets.push('  public async '+m.name+'(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {',
    '    await invokeSkill(info, '+quote(m.name)+', argv);','  }','');
  const cases=(m.cases ?? []).map(rule=>{
    const entries=Object.entries(rule.when);
    assert.equal(entries.length,1);
    const [key,value]=entries[0];
    assert.ok(m.args.some(a=>a.name===key && a.enum?.includes(value)) && rule.require.every(k=>m.args.some(a=>a.name===k)));
    return '{ key: '+quote(key)+', value: '+quote(value)+', required: '+quote(rule.require)+' }';
  });
  catalog.push('    case '+quote(m.name)+': return { domain: '+quote(m.domain)+', fields: ['+fields.join(', ')+']'+
    (cases.length?', cases: ['+cases.join(', ')+']':'')+' };');
  // 平台按位置传递；若提供后面的参数，前面被省略的可选项须显式占位。
  const names=Object.keys(properties);
  const dependentRequired=Object.fromEntries(names.slice(1).map((name,i)=>[name,names.slice(0,i+1)]));
  const input={type:'object',properties,required,additionalProperties:false,...(names.length>1?{dependentRequired}:{})};
  for (let i=0;i<names.length;i++) {
    if (!(names[i] in example) && names.slice(i+1).some(n=>n in example)) example[names[i]]='';
  }
  const states=[...new Set([...m.results,'busy','unavailable','unknown','failed'])];
  const result={type:'object',required:['state'],properties:{state:{enum:states},reason:{type:'string'},...m.output},additionalProperties:true};
  const branches=Object.entries(m.requiredOutput ?? {});
  for (const [state,keys] of branches) {
    assert.ok(states.includes(state) && keys.every(k=>Object.hasOwn(m.output ?? {},k)), 'invalid result branch '+m.name);
  }
  if (branches.length) result.allOf=branches.map(([state,keys])=>({
    if:{properties:{state:{const:state}},...(m.userHandoff && state==='needsUser'?{not:{required:['reason'],properties:{reason:{const:'awaitingUser'}}}}:{})},
    then:{required:keys}}));
  for (const branch of m.outputCases ?? []) {
    const when=Object.entries(branch.when);
    assert.ok(when.length && branch.require.every(k=>Object.hasOwn(m.output,k)) &&
      when.every(([k])=>k==='state' || k==='reason' || Object.hasOwn(m.output,k)),m.name+' invalid output condition');
    if (branch.args) {
      assert.ok(Object.keys(branch.args).every(k=>m.args.some(a=>a.name===k)),m.name+' unknown condition input');
      continue; // 输入判定在宿主与下方分支示例中；单份输出 Schema 无法看到请求参数。
    }
    result.allOf ??= [];
    const types=Object.entries(branch.whenTypes ?? {});
    result.allOf.push({if:{required:[...new Set([...when,...types].map(([k])=>k))],
      properties:{...Object.fromEntries(when.map(([k,v])=>[k,{const:v}])),...Object.fromEntries(types.map(([k,type])=>[k,{type}]))}},
      then:{required:[...new Set([...branch.require,...Object.keys(branch.fields ?? {})])],
        properties:{...branch.fields,...Object.fromEntries(Object.entries(branch.expect ?? {}).map(([k,v])=>[k,{const:v}]))}}});
  }
  if (m.userHandoff) {
    result.properties.method ??= {type:'string'};
    result.properties.operationRef ??= {type:'string',minLength:1};
    result.allOf ??= [];
    result.allOf.push({if:{required:['reason'],properties:{reason:{const:'awaitingUser'}}},
      then:{properties:{state:{const:'needsUser'},method:{const:m.name}},required:['operationRef','method']}});
  }
  const pos=name=>{const index=m.args.findIndex(a=>a.name===name);assert.ok(index>=0,name);return 'arg'+(index+1);};
  if (m.cases) input.allOf=m.cases.map(rule=>({
    if:{properties:Object.fromEntries(Object.entries(rule.when).map(([k,v])=>[pos(k),{const:v}])),required:Object.keys(rule.when).map(pos)},
    then:{required:rule.require.map(pos),properties:Object.fromEntries(rule.require.map(k=>{
      const type=m.args.find(a=>a.name===k).type;
      return [pos(k),type==='string'?{type,minLength:1}:{type}];
    }))}
  }));
  const count = counts.get(m.topic) ?? 0;
  counts.set(m.topic,count+1);
  const part = Math.floor(count/12) + 1;
  const file = 'references/'+m.topic+'-'+part+'.md';
  const doc = references.get(file) ?? [];
  if (!doc.length) {
    const label=labels[m.topic][part-1] ?? m.description;
    main.push('- ['+label+']('+file+')');
    doc.push('# '+label,'');
    references.set(file, doc);
  }
  doc.push('### '+m.name,'',m.description,'','执行参数','');
  const supplied=Object.fromEntries(Object.entries(example).map(([key,v])=>[m.args[Number(key.slice(3))-1].name,v]));
  const commands=[...(m.inputExamples ?? [supplied])];
  const match=(ex,conditions)=>Object.entries(conditions).every(([k,v])=>ex[k]===v);
  for (const branch of m.outputCases ?? []) {
    if (branch.args && !commands.some(ex=>match(ex,branch.args))) commands.push({...supplied,...branch.args});
  }
  function factExample(field, branch) {
    const source=commands.find(ex=>match(ex,branch?.args ?? {})) ?? commands[0];
    const arg=branch?.echoArgs?.[field] ?? m.echoArgs?.[field] ?? m.echoTrimArgs?.[field];
    if (arg && Object.hasOwn(source,arg)) return m.echoTrimArgs?.[field] ? source[arg].trim() : source[arg];
    return sampleField(field,{...result.properties[field],...branch?.fields?.[field]});
  }
  for (const values of commands.map(v=>positionalExample(m.args,v))) {
    doc.push('```text',"exec-cli(command: ohos-arkTSScript --skillName 'amcl-launcher' --scriptPath 'scripts/LauncherSkill.ets' --functionName '"+m.name+"' --args '"+JSON.stringify(values)+"')",'```','');
  }
  doc.push('```json',JSON.stringify(input),'```','','执行返回值','');
  // 一项能力可按不同输入进入互斥的业务分支，示例必须标出原选择，不能借最后一条命令的参数。
  function publishSample(sample, original) {
    const conditions={...original};
    if (!(sample.reason==='awaitingUser' && m.userHandoff)) {
      const echo={...m.echoArgs,...m.echoTrimArgs};
      for (const b of m.outputCases ?? []) {
        if (Object.entries(b.when).every(([k,v])=>sample[k]===v)) Object.assign(echo,b.echoArgs);
      }
      for (const [field,arg] of Object.entries(echo)) {
        if (Object.hasOwn(sample,field) && (m.args.find(a=>a.name===arg)?.required || commands.some(ex=>ex[arg]!==undefined && ex[arg]!==''))) conditions[arg]=sample[field];
      }
      for (const [field,arg] of Object.entries(m.targetMembers ?? {})) {
        if (!Object.hasOwn(sample,field)) continue;
        const targets=Array.isArray(sample[field]) ? sample[field] : [sample[field]];
        for (const target of targets) {
          assert.ok(conditions[arg]===undefined || conditions[arg]===target,m.name+' inconsistent example target');
          conditions[arg]=target;
        }
      }
      const byInput=(m.outputCases ?? []).find(b=>b.args && b.expect && Object.keys(b.expect).length &&
        [...Object.entries(b.when),...Object.entries(b.expect)].every(([k,v])=>sample[k]===v));
      Object.assign(conditions,byInput?.args);
    }
    if (Object.keys(conditions).length) {
      const trimmed=new Set(Object.values(m.echoTrimArgs ?? {}));
      const full=commands.find(ex=>Object.entries(conditions).every(([k,v])=>ex[k]===v ||
        (trimmed.has(k) && typeof ex[k]==='string' && ex[k].trim()===v)));
      assert.ok(full,m.name+' output example has no matching published request: '+JSON.stringify(conditions));
      doc.push('当请求参数为 `'+JSON.stringify(full)+'` 时：');
    }
    doc.push('- `'+JSON.stringify(sample)+'`');
  }
  for (const [field,arg] of Object.entries(m.echoArgs ?? {})) {
    assert.ok(Object.hasOwn(m.output,field) && m.args.some(a=>a.name===arg),m.name+' invalid echoed field');
    doc.push('返回 `'+field+'` 时，该值等于原请求的 `'+pos(arg)+'`（'+arg+'）。','');
  }
  for (const [field,arg] of Object.entries(m.echoTrimArgs ?? {})) doc.push('返回 `'+field+'` 时取原请求 `'+pos(arg)+'`（'+arg+'）去除首尾空白后的值。','');
  for (const branch of m.outputCases ?? []) for (const [field,arg] of Object.entries(branch.echoArgs ?? {})) {
    doc.push('当结果为 `'+JSON.stringify(branch.when)+'` 时，`'+field+'` 等于原请求 `'+pos(arg)+'`（'+arg+'）。','');
  }
  for (const [field,arg] of Object.entries(m.targetMembers ?? {})) {
    doc.push('结果 `'+field+'` 中的目标必须来自本次请求的 `'+pos(arg)+'`（'+arg+'）。','');
  }
  for (const group of m.disjointOutput ?? []) doc.push(group.map(k=>'`'+k+'`').join('、')+' 合起来每个目标最多出现一次。','');
  for (const [field,collection] of Object.entries(m.memberOf ?? {})) doc.push('返回 `'+field+'` 时，该目标必须在 `'+collection+'` 中。','');
  for (const state of states) {
    const branch=(m.outputCases ?? []).find(b=>!b.args && !b.whenTypes && Object.keys(b.when).length===1 && b.when.state===state);
    const keys=[...new Set([...(m.requiredOutput?.[state] ?? []),...(branch?.require ?? [])])];
    const facts=Object.fromEntries(keys.map(k=>[k,factExample(k,branch)]));
    const common={failed:'invalidArguments',unavailable:'launcherNotReady',busy:'anotherRequest',unknown:'operationUnconfirmed'};
    if (state==='needsUser' && m.userHandoff) {
      publishSample({state,reason:'awaitingUser',method:m.name,operationRef:'current-operation'});
      if (!m.examples?.[state] && !m.requiredOutput?.[state]) continue;
    }
    const sample={state,...(common[state]?{reason:common[state]}:{}),...facts,...branch?.expect,...branch?.example,...m.examples?.[state]};
    publishSample(sample);
  }
  for (const branch of m.outputCases ?? []) {
    if (branch.reject) {
      doc.push('请求参数为 `'+JSON.stringify(branch.args)+'` 时不会返回 `'+JSON.stringify(branch.when)+'`。','');
      continue;
    }
    const fields=Object.fromEntries([...(m.requiredOutput?.[branch.when.state] ?? []),...branch.require].map(k=>[k,factExample(k,branch)]));
    publishSample({...fields,...branch.when,...branch.expect,...branch.example},branch.args);
  }
  doc.push('','```json',JSON.stringify(result),'```','');
}
ets.push('}');
catalog.push('    default: return undefined;', '  }', '}');
main.push('');
assert.ok(main.length <= 500);
const files=[['scripts/LauncherSkill.ets',ets.join('\n')+'\n'],['SKILL.md',main.join('\n')],
  ['../../src/main/ets/launcherskill/SkillMethodCatalog.ets',catalog.join('\n')+'\n'],
  ...[...references].map(([file,lines])=>[file,lines.join('\n')])];
for(const [file,body] of files) {
  const target=path.join(out,file);
  if(check) assert.equal(fs.readFileSync(target,'utf8').replaceAll('\r\n','\n'),body,'stale '+file);
  else { fs.mkdirSync(path.dirname(target),{recursive:true}); fs.writeFileSync(target,body); }
}
console.log((check?'Verified ':'Generated ')+ordered.length+' named launcher Skill methods');
