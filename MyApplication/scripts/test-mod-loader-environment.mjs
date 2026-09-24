/**
 * 加载器环境回归：生产解析器读取真实 NeoForge 快照，覆盖参数、坐标、继承与快照回退。
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
const resolver = load('mods/src/main/ets/InstalledLoaderVersion.ets');
const installed = load('mods/src/main/ets/InstalledLoaderResolver.ets');
const pure = resolver.loaderVersionFromMetadata;
const actual = JSON.parse(fs.readFileSync(path.join(root,'scripts/fixtures/mod-install/neoforge-26.2.version.json'),'utf8').replace(/^\uFEFF/,''));
assert.equal(pure(actual,'neoforge','26.2'),'26.2.0.48-beta');
assert.equal(pure({arguments:{game:['--fml.forgeVersion=65.1.3']}},'forge','26.2'),'65.1.3');
assert.equal(pure({minecraftArguments:'--fml.neoForgeVersion "26.2.0.48-beta"'},'neoforge','26.2'),'26.2.0.48-beta');
assert.equal(pure({arguments:{game:['--fml.neoForgeVersion','--fml.mcVersion','26.2']}},'neoforge','26.2'),'');
assert.equal(pure({arguments:{game:['--fml.neoForgeVersion',{rules:[{action:'disallow'}],value:'bad'},'26.2']}},'neoforge','26.2'),'');
for (const [loaderId,coordinate,game,expected] of [
  ['fabric','net.fabricmc:fabric-loader:0.19.5','26.2','0.19.5'],
  ['quilt','org.quiltmc:quilt-loader:0.29.2','1.21.1','0.29.2'],
  ['forge','net.minecraftforge:forge:1.20.1-47.4.0:universal','1.20.1','47.4.0'],
  ['forge','net.minecraftforge:fmlloader:1.19.4-45.4.5','1.19.4','45.4.5'],
  ['neoforge','net.neoforged:neoforge:21.1.209','1.21.1','21.1.209'],
  ['neoforge','net.neoforged:forge:1.20.1-47.1.106','1.20.1','47.1.106'],
]) assert.equal(pure({libraries:[{name:coordinate}]},loaderId,game),expected,coordinate);
assert.equal(pure({libraries:[{name:'net.neoforged.fancymodloader:loader:11.0.13'}]},'neoforge','26.2'),'');

/** 在相同产品目录模型中建立有中文名的继承版本；目录名不包含 loader 版本。 */
const put=(id,value)=>files.set('/mc/versions/'+id+'/'+id+'.json',JSON.stringify(value));
put('父实例',actual); put('自定义整合包',{id:'自定义整合包',inheritsFrom:'父实例'});
assert.equal(installed.resolveInstalledLoader('/mc','自定义整合包'),'neoforge');
assert.equal(installed.resolveInstalledMcVersion('/mc','自定义整合包'),'26.2');
assert.equal(resolver.resolveInstalledLoaderVersion('/mc','自定义整合包','neoforge','26.2'),'26.2.0.48-beta');
put('quilt-instance',{id:'quilt-instance',clientVersion:'1.21.1',mainClass:'org.quiltmc.loader.impl.launch.knot.KnotClient',
  libraries:[{name:'org.quiltmc:quilt-loader:0.29.2'}]});
assert.equal(installed.resolveInstalledLoader('/mc','quilt-instance'),'quilt','Quilt 的 KnotClient 不可被通用 Knot 分支误认成 Fabric');
put('loop-a',{inheritsFrom:'loop-b'});put('loop-b',{inheritsFrom:'loop-a'});
assert.equal(resolver.resolveInstalledLoaderVersion('/mc','loop-a','neoforge','26.2'),'');
put('escape',{inheritsFrom:'../../outside'});reads.length=0;
assert.equal(resolver.resolveInstalledLoaderVersion('/mc','escape','neoforge','26.2'),'');
assert.ok(reads.every(p=>!p.includes('..')));
put('snapshot',{});files.set('/mc/versions/snapshot/.amcl-modpack.json',JSON.stringify({loaderType:'fabric',loaderVersion:'0.19.5'}));
assert.equal(resolver.resolveInstalledLoaderVersion('/mc','snapshot','fabric','26.2'),'0.19.5');
assert.equal(resolver.resolveInstalledLoaderVersion('/mc','snapshot','neoforge','26.2'),'');

// 直接执行生产环境函数，验证缺少 loader 版本在下载之前得到明确错误。
const sourceFile=path.join(root,'mods/src/main/ets/ModInstallService.ets');
const source=ts.createSourceFile(sourceFile,fs.readFileSync(sourceFile,'utf8'),ts.ScriptTarget.Latest,true,ts.ScriptKind.TS);
const fn=source.statements.find(n=>ts.isFunctionDeclaration(n)&&n.name?.text==='installedModEnvironment');
const exports={};
vm.runInNewContext(ts.transpileModule(fn.getText(source),{compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText,
  {exports,...resolver,...installed});
assert.equal(exports.installedModEnvironment('/mc','自定义整合包').loaderVersion,'26.2.0.48-beta');
put('missing-version',{mainClass:'net.fabricmc.loader.impl.launch.knot.KnotClient',id:'26.2',libraries:[]});
assert.throws(()=>exports.installedModEnvironment('/mc','missing-version'),/无法确认目标版本/);
console.log('PASS: actual NeoForge JSON, four loader families, explicit/malformed args, classifier coordinates, renamed inheritance, cycles, traversal and missing-version preflight');
