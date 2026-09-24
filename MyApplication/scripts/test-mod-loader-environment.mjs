/**
 * 安装环境回归：生产解析器读取真实 NeoForge 清单，保留加载器类型/MC、继承与快照回退。
 * 已退役的具体加载器版本推断不再执行；缺少该信息不应妨碍来源 API 的明确选版。
 * 文件 IO 使用受控内存文件，断言越界父目录不会被读取；不访问真机或修改用户版本。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { loader, productionPathPolicy, root, ts } from './mod-install-test-runtime.mjs';

const files = new Map();
const reads = [];
const io = { readTextSync(p) { reads.push(p); if (!files.has(p)) throw new Error('ENOENT'); return files.get(p); } };
const logs = { info(){},warn(){},error(){},debug(){} };
const common = { AppLogger: logs, formatError: String, LOG_DOMAIN_DOWNLOAD: 0 };
const policy = productionPathPolicy();
const parser = loader({'@kit.CoreFileKit':{fileIo:io},commons:common,'../modloader/MavenUtils':policy})('feature_core/src/main/ets/version/VersionParser.ets').VersionParser;
const load = loader({'@kit.CoreFileKit':{fileIo:io},commons:common,
  feature_core:{...policy,VersionParser:parser,McEra:{UNKNOWN:'unknown'},detectMcEra:()=> 'unknown'}});
const installed = load('mods/src/main/ets/InstalledLoaderResolver.ets');
const actual = JSON.parse(fs.readFileSync(path.join(root,'scripts/fixtures/mod-install/neoforge-26.2.version.json'),'utf8').replace(/^\uFEFF/,''));

/** 在相同产品目录模型中建立有中文名的继承版本；目录名不包含 loader 版本。 */
const put=(id,value)=>files.set('/mc/versions/'+id+'/'+id+'.json',JSON.stringify(value));
put('父实例',actual); put('自定义整合包',{id:'自定义整合包',inheritsFrom:'父实例'});
assert.equal(installed.resolveInstalledLoader('/mc','自定义整合包'),'neoforge');
assert.equal(installed.resolveInstalledMcVersion('/mc','自定义整合包'),'26.2');
put('quilt-instance',{id:'quilt-instance',clientVersion:'1.21.1',mainClass:'org.quiltmc.loader.impl.launch.knot.KnotClient',
  libraries:[{name:'org.quiltmc:quilt-loader:0.29.2'}]});
assert.equal(installed.resolveInstalledLoader('/mc','quilt-instance'),'quilt','Quilt 的 KnotClient 不可被通用 Knot 分支误认成 Fabric');
put('loop-a',{inheritsFrom:'loop-b'});put('loop-b',{inheritsFrom:'loop-a'});
assert.equal(installed.resolveInstalledLoader('/mc','loop-a'),'');
assert.equal(installed.resolveInstalledMcVersion('/mc','loop-a'),'');
put('escape',{inheritsFrom:'../../outside'});reads.length=0;
assert.equal(installed.resolveInstalledLoader('/mc','escape'),'');
installed.resolveInstalledMcVersion('/mc','escape');
assert.ok(reads.every(p=>!p.includes('..')));
// 实际选版只依赖 loader 类型和游戏版本；各家 mainClass 必须继续被准确区分。
for (const [type,mainClass,coordinate] of [
  ['fabric','net.fabricmc.loader.impl.launch.knot.KnotClient','net.fabricmc:fabric-loader:0.19.5'],
  ['forge','cpw.mods.bootstraplauncher.BootstrapLauncher','net.minecraftforge:forge:1.20.1-47.4.0'],
  ['neoforge','net.neoforged.fml.startup.Client','net.neoforged:neoforge:21.1.209'],
  ['quilt','org.quiltmc.loader.impl.launch.knot.KnotClient','org.quiltmc:quilt-loader:0.29.2'],
]) {
  put(type+'-renamed',{id:type+'-renamed',clientVersion:'1.20.1',mainClass,libraries:[{name:coordinate}]});
  assert.equal(installed.resolveInstalledLoader('/mc',type+'-renamed'),type);
  assert.equal(installed.resolveInstalledMcVersion('/mc',type+'-renamed'),'1.20.1');
}

// 直接执行生产环境函数：旧实例缺少具体 loader 版本时仍保留类型/MC，允许明确匹配的安装计划。
const sourceFile=path.join(root,'mods/src/main/ets/ModInstallService.ets');
const source=ts.createSourceFile(sourceFile,fs.readFileSync(sourceFile,'utf8'),ts.ScriptTarget.Latest,true,ts.ScriptKind.TS);
const fn=source.statements.find(n=>ts.isFunctionDeclaration(n)&&n.name?.text==='installedModEnvironment');
const exports={};
vm.runInNewContext(ts.transpileModule(fn.getText(source),{compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText,
  {exports,...installed});
assert.equal(exports.installedModEnvironment('/mc','自定义整合包').loader,'neoforge');
assert.equal(exports.installedModEnvironment('/mc','自定义整合包').gameVersion,'26.2');
put('missing-version',{mainClass:'net.fabricmc.loader.impl.launch.knot.KnotClient',id:'26.2',libraries:[]});
const missingVersion = exports.installedModEnvironment('/mc','missing-version');
assert.equal(missingVersion.loader,'fabric');
assert.equal(missingVersion.gameVersion,'26.2');
assert.deepEqual(Object.keys(missingVersion).sort(),['gameVersion','loader']);
console.log('PASS: actual NeoForge JSON, four loader families, renamed inheritance, cycles, traversal and no unused loader-version admission');
