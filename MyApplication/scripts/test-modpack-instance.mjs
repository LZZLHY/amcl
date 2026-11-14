/**
 * 完整实例适配器专项：执行生产只读解析及数据根策略，不模拟被测算法。
 * 夹具只写显式外置运行根；成功后生命周期回收，失败保留原始源包供复核。
 */
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { loader, productionPathPolicy } from './mod-install-test-runtime.mjs';
import { createHostTestScope } from './lib/host-test-lifecycle.mjs';

const output = process.env.AMCL_TEST_OUTPUT_DIR || 'E:/AMCL/.workspace/run/mp-fix-1028/instance';
fs.mkdirSync(output, { recursive: true });
const scope = createHostTestScope('fixtures-', { parent: path.resolve(output), automatic: false });
const fixture = scope.directory.replaceAll('\\', '/');
const coreLoad = loader();
const core = { ...productionPathPolicy(),
  ...coreLoad('feature_core/src/main/ets/export/ExportVersionResolver.ets') };
const load = loader({ feature_core: core });
const I = load('mods/src/main/ets/ModpackInstance.ets');
const cases = [];
let failure;
/** 写入的是本测试亲建文件；每个用例独立子目录，不访问真实 Minecraft 实例。 */
function put(root, relative, value) {
  const target = root + '/' + relative;
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, typeof value === 'string' ? value : JSON.stringify(value));
}
function directory(name) { const dir = fixture + '/' + name; fs.mkdirSync(dir); return dir; }
const vanilla = id => ({ id, mainClass: 'net.minecraft.client.main.Main', libraries: [], arguments: { game: [], jvm: [] } });
function version(root, id, json = { ...vanilla(id), clientVersion: '1.20.1' }) { put(root, 'versions/' + id + '/' + id + '.json', json); }
function passed(name) { cases.push(name); console.log('PASS ' + name); }
try {
  let root = directory('pcl-isolated');
  version(root, 'Custom');
  put(root, 'mods/shared.jar', 'shared'); put(root, 'versions/Custom/mods/chosen.jar', 'chosen');
  put(root, 'versions/Custom/PCL/Setup.ini', 'VersionArgumentIndieV2:true\r\nVersionArgumentIndie:2\r\n');
  let parsed = I.parseInstancePackage(root, 'instance', 'Custom');
  assert.equal(parsed.plan.gameVersion, '1.20.1'); assert.equal(parsed.plan.loaderType, 'none');
  assert.equal(parsed.plan.overrideDirs[0], 'versions/Custom'); assert.equal(parsed.plan.contentOnly, true);
  assert.equal(parsed.plan.instanceVersionId, 'Custom');
  passed('PCL modern isolation is authoritative and source identity survives target rename');

  root = directory('pcl-shared'); version(root, 'Custom'); put(root, 'mods/a.jar', 'shared');
  put(root, 'versions/Custom/PCL/Setup.ini', 'VersionArgumentIndieV2:false\n');
  assert.equal(I.parseInstancePackage(root, 'instance', 'Custom').plan.overrideDirs[0], '.');
  passed('PCL explicit shared root becomes the local root sentinel');

  root = directory('hmcl-isolated'); version(root, 'Custom'); put(root, 'mods/shared.jar', 'shared');
  put(root, 'versions/Custom/.hmcl/config/instance-game-settings.json', { overrideProperties: ['runningDirectory'], runningDirectory: '' });
  assert.equal(I.discoverInstanceDataRoots(root, 'Custom')[0].path, 'versions/Custom');
  put(root, 'versions/Custom/.hmcl/config/instance-game-settings.json', { overrideProperties: ['runningDirectory'], runningDirectory: 'C:/Users/private' });
  assert.throws(() => I.discoverInstanceDataRoots(root, 'Custom'), /包外/);
  passed('HMCL explicit isolation is read, external Java or game directories cannot escape the archive');

  root = directory('ambiguous-data'); version(root, 'Custom');
  put(root, 'mods/shared.jar', 'shared'); put(root, 'versions/Custom/config/local.json', '{}');
  const choices = I.discoverInstanceDataRoots(root, 'Custom');
  assert.deepEqual(Array.from(choices, c => c.path), ['.', 'versions/Custom']);
  assert.throws(() => I.parseInstancePackage(root, 'instance', 'Custom'), /先选择/);
  assert.equal(I.parseInstancePackage(root, 'instance', 'Custom', '.').plan.overrideDirs[0], '.');
  assert.equal(I.parseInstancePackage(root, 'instance', 'Custom', 'versions/Custom').plan.overrideDirs[0], 'versions/Custom');
  assert.throws(() => I.parseInstancePackage(root, 'instance', 'Custom', '../outside'), /不属于/);
  put(root, 'versions/Custom/PCL/Setup.ini', 'VersionArgumentIndieV2:false\n');
  put(root, 'versions/Custom/.hmcl/config/instance-game-settings.json', { overrideProperties: ['runningDirectory'], runningDirectory: '' });
  assert.equal(I.discoverInstanceDataRoots(root, 'Custom').length, 2);
  assert.equal(I.parseInstancePackage(root, 'instance', 'Custom', 'versions/Custom').plan.overrideDirs[0], 'versions/Custom');
  passed('shared/isolated ambiguity yields real UI choices and only a selected candidate is accepted');

  root = directory('multi-version'); version(root, 'A'); version(root, 'B');
  assert.throws(() => I.parseInstancePackage(root, 'instance'), /多个版本/);
  put(root, 'versions/B/B.json', 'broken unrelated JSON');
  assert.equal(I.parseInstancePackage(root, 'instance', 'A').plan.gameVersion, '1.20.1');
  passed('multiple versions require explicit selection, unrelated broken versions do not taint the selected closure');

  root = directory('fabric-inheritance'); version(root, '1.20.1', vanilla('1.20.1'));
  version(root, 'Fabric', { id: 'Fabric', inheritsFrom: '1.20.1', mainClass: 'net.fabricmc.loader.impl.launch.knot.KnotClient', libraries: [{ name: 'net.fabricmc:fabric-loader:0.16.0' }] });
  put(root, 'versions/Fabric/mods/a.jar', 'mod');
  parsed = I.parseInstancePackage(root, 'instance', 'Fabric');
  assert.equal(parsed.plan.gameVersion, '1.20.1'); assert.equal(parsed.plan.loaderType, 'fabric'); assert.equal(parsed.plan.loaderVersion, '0.16.0');
  passed('parent client identity and exact Fabric version are resolved without copying the desktop profile');

  root = directory('missing-parent'); version(root, 'Child', { id: 'Child', inheritsFrom: 'Missing' });
  assert.throws(() => I.parseInstancePackage(root, 'instance', 'Child'), /父版本/);
  root = directory('cycle'); version(root, 'A', { id: 'A', inheritsFrom: 'B' }); version(root, 'B', { id: 'B', inheritsFrom: 'A' });
  assert.throws(() => I.parseInstancePackage(root, 'instance', 'A'), /继承存在环/);
  root = directory('bad-id'); version(root, 'Chosen', { ...vanilla('Other'), clientVersion: '1.20.1' });
  assert.throws(() => I.parseInstancePackage(root, 'instance', 'Chosen'), /JSON 身份/);
  passed('missing parent, inheritance cycles and directory/JSON identity mismatches fail before installation');

  root = directory('loader-conflict');
  version(root, 'Conflict', { ...vanilla('Conflict'), clientVersion: '1.20.1', libraries: [{ name: 'net.fabricmc:fabric-loader:0.16.0' }, { name: 'org.quiltmc:quilt-loader:0.26.0' }] });
  assert.throws(() => I.parseInstancePackage(root, 'instance', 'Conflict'), /互斥/);
  root = directory('server'); version(root, 'Server', { ...vanilla('Server'), clientVersion: '1.20.1', mainClass: 'net.minecraft.server.Main' });
  assert.throws(() => I.parseInstancePackage(root, 'instance', 'Server'), /加载器/);
  passed('conflicting loader declarations and server-only main classes are not accepted as a client');

  root = directory('fabric-server-with-loader');
  const fabricProfile = { ...vanilla('Chosen'), clientVersion: '1.20.1', mainClass: 'net.fabricmc.loader.impl.launch.knot.KnotServer', libraries: [{ name: 'net.fabricmc:fabric-loader:0.16.0' }] };
  version(root, 'Chosen', fabricProfile);
  assert.throws(() => I.parseInstancePackage(root, 'instance', 'Chosen'), /服务端入口/);
  version(root, 'Chosen', { ...fabricProfile, mainClass: 'net.fabricmc.loader.impl.launch.knot.KnotClient' });
  assert.equal(I.parseInstancePackage(root, 'instance', 'Chosen').plan.loaderType, 'fabric');
  version(root, 'Chosen', { ...fabricProfile, mainClass: 'cpw.mods.bootstraplauncher.BootstrapLauncher', arguments: { game: ['--launchTarget', 'forgeserver'] } });
  assert.throws(() => I.parseInstancePackage(root, 'instance', 'Chosen'), /服务端入口/);
  passed('loader libraries cannot grant client qualification to KnotServer or explicit server launch targets');

  root = directory('conflicting-game-identities');
  const forgeProfile = { ...vanilla('Chosen'), clientVersion: '1.20.1', mainClass: 'cpw.mods.bootstraplauncher.BootstrapLauncher', arguments: { game: ['--fml.mcVersion', '1.21.1', '--fml.forgeVersion', '47.4.0'] }, libraries: [{ name: 'net.minecraftforge:forge:1.20.1-47.4.0' }] };
  version(root, 'Chosen', forgeProfile);
  assert.throws(() => I.parseInstancePackage(root, 'instance', 'Chosen'), /冲突的 Minecraft/);
  version(root, 'Chosen', { ...forgeProfile, arguments: { game: ['--fml.mcVersion=1.20.1', '--fml.forgeVersion', '47.4.0'] } });
  assert.equal(I.parseInstancePackage(root, 'instance', 'Chosen').plan.gameVersion, '1.20.1');
  version(root, 'Chosen', { ...forgeProfile, arguments: { game: ['--fml.mcVersion=1.20.1', '--fml.mcVersion', '1.21.1', '--fml.forgeVersion', '47.4.0'] } });
  assert.throws(() => I.parseInstancePackage(root, 'instance', 'Chosen'), /冲突的 Minecraft/);
  version(root, 'Chosen', { ...forgeProfile, arguments: { game: ['--fml.mcVersion=1.20.1', '--fml.forgeVersion', '47.4.0'] }, libraries: [{ name: 'net.minecraftforge:forge:1.19.2-47.4.0' }] });
  assert.throws(() => I.parseInstancePackage(root, 'instance', 'Chosen'), /冲突的 Minecraft/);
  passed('clientVersion, every FML argument and Forge coordinate game identity must agree');

  root = directory('parent-game-identity'); version(root, '1.20.1', vanilla('1.20.1'));
  version(root, 'Child', { id: 'Child', inheritsFrom: '1.20.1', clientVersion: '1.21.1' });
  assert.throws(() => I.parseInstancePackage(root, 'instance', 'Child'), /冲突的 Minecraft/);
  passed('explicit child identity cannot silently override a conflicting vanilla inheritance root');

  root = directory('launcher-root-no-false-content'); version(root, 'Chosen');
  put(root, 'HMCL-3.16.4.jar', 'desktop launcher'); put(root, 'hmcl.json', '{"token":"fixture"}');
  put(root, 'jre-17.0.12/bin/java', 'desktop Java'); put(root, 'jdk-21/bin/javac', 'desktop Java');
  put(root, 'versions/Chosen/mods/needed.jar', 'mod');
  assert.deepEqual(Array.from(I.discoverInstanceDataRoots(root, 'Chosen'), c => c.path), ['versions/Chosen']);
  assert.equal(I.parseInstancePackage(root, 'instance', 'Chosen').plan.overrideDirs[0], 'versions/Chosen');
  for (const denied of ['HMCL.jar', 'HMCL-3.16.4.jar', 'hmcl.json', 'PCL2.jar', 'Launcher.jar', 'jre-17.0.12/bin/java', 'jdk-21/bin/javac']) assert.equal(I.isInstanceContentPath(denied), false, denied);
  for (const allowed of ['mods/HMCL-3.16.4.jar', 'mods/Launcher.jar', 'config/hmcl.json', 'unknown-mod-data/data.jar', 'jre-local-data/world.bin']) assert.equal(I.isInstanceContentPath(allowed), true, allowed);
  passed('root launcher JAR/config and versioned Java do not create fake shared roots or suppress ordinary mod data');

  root = directory('mcbbs-dual');
  const local = 'mcbbs local config'; const sha1 = crypto.createHash('sha1').update(local).digest('hex');
  put(root, 'mcbbs.packmeta', { manifestType: 'minecraftModpack', manifestVersion: 2, name: 'Author Pack', version: '2',
    addons: [{ id: 'game', version: '1.20.1' }, { id: 'fabric', version: '0.16.0' }], libraries: [],
    files: [{ type: 'addon', path: 'config/author.json', hash: sha1 }, { type: 'curse', projectID: 10, fileID: 20 }] });
  put(root, 'manifest.json', { manifestType: 'minecraftModpack', manifestVersion: 1, minecraft: { version: '1.20.1' }, files: [] });
  put(root, 'overrides/config/author.json', local);
  parsed = I.parseInstancePackage(root, 'mcbbs');
  assert.equal(parsed.plan.loaderType, 'fabric'); assert.equal(parsed.plan.source, 'mcbbs');
  assert.equal(parsed.plan.requiredLocalFiles[0].sha1, sha1); assert.equal(parsed.plan.requiredLocalFiles[0].root, 'overrides');
  assert.equal(parsed.plan.files[0].cfProjectId, 10); assert.equal(parsed.plan.files[0].cfFileId, 20);
  passed('authoritative MCBBS addons survive dual manifests, addon hashes and CurseForge identities remain in the plan');

  put(root, 'mcbbs.packmeta', { manifestType: 'minecraftModpack', manifestVersion: 1, addons: [{ id: 'game', version: '1.20.1' }, { id: 'optifine', version: 'HD_U_I6' }], files: [] });
  assert.throws(() => I.parseInstancePackage(root, 'mcbbs'), /optifine/);
  put(root, 'mcbbs.packmeta', { manifestType: 'minecraftModpack', manifestVersion: 1, addons: [{ id: 'game', version: '1.20.1' }], files: [{ type: 'addon', path: '../outside', hash: sha1 }] });
  assert.throws(() => I.parseInstancePackage(root, 'mcbbs'), /路径/);
  passed('unsupported MCBBS component semantics and escaping local addon paths fail explicitly');

  root = directory('legacy-hmcl'); put(root, 'modpack.json', { name: 'Legacy Author', version: '1', gameVersion: '1.12.2' });
  put(root, 'minecraft/pack.json', { id: 'pack', jar: '1.12.2', mainClass: 'net.minecraft.launchwrapper.Launch', minecraftArguments: '--tweakClass net.minecraftforge.fml.common.launcher.FMLTweaker', libraries: [{ name: 'net.minecraftforge:forge:1.12.2-14.23.5.2860' }] });
  parsed = I.parseInstancePackage(root, 'hmcl');
  assert.equal(parsed.plan.gameVersion, '1.12.2'); assert.equal(parsed.plan.loaderType, 'forge'); assert.equal(parsed.plan.loaderVersion, '14.23.5.2860');
  assert.equal(parsed.plan.overrideDirs[0], 'minecraft'); assert.equal(parsed.plan.instanceVersionId, 'pack');
  passed('legacy HMCL modpack metadata plus minecraft/pack.json reconstructs the exact game and Forge identity');

  root = directory('multimc');
  put(root, 'mmc-pack.json', { formatVersion: 1, components: [{ uid: 'net.minecraft', version: '1.20.1' }, { uid: 'org.lwjgl3', version: '3.3.1' }, { uid: 'net.fabricmc.fabric-loader', version: '0.16.0' }] });
  put(root, 'instance.cfg', 'name=My Prism Instance\nOverrideCommands=true\nPreLaunchCommand=arbitrary.exe\nJvmArgs=-javaagent:private.jar\n');
  put(root, 'minecraft/mods/a.jar', 'mod');
  parsed = I.parseInstancePackage(root, 'multimc');
  assert.equal(parsed.plan.name, 'My Prism Instance'); assert.equal(parsed.plan.loaderType, 'fabric'); assert.equal(parsed.plan.overrideDirs[0], 'minecraft');
  assert.ok(!JSON.stringify(parsed).includes('arbitrary.exe')); assert.ok(!JSON.stringify(parsed).includes('javaagent'));
  put(root, '.minecraft/mods/b.jar', 'other');
  assert.throws(() => I.parseInstancePackage(root, 'multimc'), /多个目录/);
  assert.equal(I.parseInstancePackage(root, 'multimc', undefined, '.minecraft').plan.overrideDirs[0], '.minecraft');
  passed('MMC/Prism components and game roots are recognized while launch commands and desktop Java flags stay out');

  for (const allowed of ['mods/a.jar', 'config/author.json', 'kubejs/server_scripts/x.js', 'scripts/a.zs', 'saves/World/level.dat', 'options.txt', 'servers.dat', 'unknown-mod-data/data.bin']) assert.equal(I.isInstanceContentPath(allowed, 'Chosen'), true, allowed);
  for (const denied of ['libraries/a.jar', 'assets/indexes/1.json', 'versions/Other/Other.json', 'PCL/Setup.ini', '.hmcl/config/x.json', 'jdk/bin/java', 'launcher_accounts.json', 'mods/native.dll', 'Chosen.jar', 'Chosen.json', 'mcbbs.packmeta', 'instance.cfg', '../outside', 'start.cmd', 'native.so.1', 'user_jvm_args.txt']) assert.equal(I.isInstanceContentPath(denied, 'Chosen'), false, denied);
  passed('content migration preserves mod/user data and excludes profiles, accounts, desktop execution and native/runtime files');

} catch (error) { failure = error; throw error; }
finally {
  fs.writeFileSync(path.join(output, 'summary.json'), JSON.stringify({ checkedAt: new Date().toISOString(), state: failure ? 'FAIL' : 'PASS', total: cases.length, cases,
    ...(failure ? { error: failure.stack } : {}) }, null, 2));
  await scope.close({ success: !failure });
}
