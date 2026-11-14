/**
 * 离线外观编辑的定向宿主回归。
 *
 * 直接执行生产像素适配和编辑协调器，仅替换文件选择、库、账号持久化等平台边缘。
 * 检查旧皮肤镜像、草稿/共享库边界、在用删除保护、旧revision与迟到UI回调。
 * 不执行ArkUI布局，不替代SDK编译或真机显示验收。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { environment } from './lib/ets-runtime-fixture.mjs';
import { PROJECT_ROOT, assertExternalOutputPath, resolveWorkspacePath } from './lib/workspace-paths.mjs';

const outputIndex = process.argv.indexOf('--output');
const output = assertExternalOutputPath(outputIndex < 0 ? resolveWorkspacePath('run', 'offline-appearance-ui') : process.argv[outputIndex + 1]);
fs.mkdirSync(output, { recursive: true });
const PIXELS = 'entry/src/main/ets/components/OfflineSkinPixels.ets';
const MODEL = 'entry/src/main/ets/components/OfflineAppearanceEditorModel.ets';
const EDITOR = 'entry/src/main/ets/components/OfflineAppearanceEditor.ets';
const sources = [PIXELS, MODEL, EDITOR, 'entry/src/main/ets/components/AccountTextureLoader.ets',
  'entry/src/main/ets/components/AccountListSheet.ets', 'entry/src/main/ets/components/AddAccountSheet.ets',
  'entry/src/main/ets/components/SkinCanvas3D.ets', 'entry/src/main/ets/components/CapePreview.ets',
  'entry/src/main/ets/components/MinecraftHeadAvatar.ets',
  'scripts/test-offline-appearance-ui.mjs'];
const hashes = () => Object.fromEntries(sources.map(file => [file, createHash('sha256').update(fs.readFileSync(path.join(PROJECT_ROOT, file))).digest('hex')]));
const initialHashes = hashes(), groups = [], startedAt = new Date().toISOString();
const pass = label => { groups.push(label); console.log('PASS ' + label); };
const clone = value => JSON.parse(JSON.stringify(value));
const settle = async () => { for (let i = 0; i < 16; i++) await Promise.resolve(); };
const deferred = () => { let resolve; const promise = new Promise(yes => { resolve = yes; }); return { promise, resolve }; };

/** 用不对称坐标色标识不同面，避免常量色测试漏掉水平镜像或左右肢体对调。 */
function pixelsFixture(load) {
  const { normalizePreviewSkinPixels } = load(PIXELS);
  const source = new Uint8Array(64 * 32 * 4);
  for (let y = 0; y < 32; y++) for (let x = 0; x < 64; x++) {
    const p = (y * 64 + x) * 4;
    source[p] = x; source[p + 1] = y; source[p + 2] = (x * 3 + y * 7) & 255; source[p + 3] = 127;
  }
  const original = source.slice(), actual = normalizePreviewSkinPixels(source, 64, 32);
  assert.equal(actual.width, 64); assert.equal(actual.height, 64); assert.equal(actual.pixels.length, 64 * 64 * 4);
  const rgba = (array, x, y) => [...array.slice((y * 64 + x) * 4, (y * 64 + x) * 4 + 4)];
  // 左腿前面从右腿前面翻转；左臂前面独立使用右臂，不能镜像整张64×32纹理。
  assert.deepEqual(rgba(actual.pixels, 20, 52), rgba(source, 7, 20));
  assert.deepEqual(rgba(actual.pixels, 23, 63), rgba(source, 4, 31));
  assert.deepEqual(rgba(actual.pixels, 36, 52), rgba(source, 47, 20));
  assert.deepEqual(rgba(actual.pixels, 39, 63), rgba(source, 44, 31));
  assert.deepEqual(rgba(actual.pixels, 16, 52), rgba(source, 11, 20));
  assert.deepEqual(rgba(actual.pixels, 40, 52), rgba(source, 43, 20));
  assert.deepEqual(rgba(actual.pixels, 0, 48), [0, 0, 0, 0], '不存在的旧版第二层保持透明');
  assert.deepEqual(source, original, '原件像素不能被预览转换写回');
  const modern = new Uint8Array(64 * 64 * 4); modern[4] = 91;
  assert.equal(normalizePreviewSkinPixels(modern, 64, 64).pixels, modern, '现代纹理不重编码');
  assert.throws(() => normalizePreviewSkinPixels(source, 64, 64), /尺寸不匹配/);
}
pixelsFixture(makePureEtsLoader());
pass('64×32不对称UV镜像、原件不变与现代纹理保持');
const opaque = new Uint8Array(64 * 32 * 4).fill(255);
const normalized = makePureEtsLoader()(PIXELS).normalizePreviewSkinPixels(opaque, 64, 32);
assert.equal(normalized.pixels[(8 * 64 + 40) * 4 + 3], 0);
assert.equal(normalized.pixels[(8 * 64 + 8) * 4 + 3], 255);
pass('全不透明旧皮肤的帽子背景不遮盖正脸');
const pixelSource = fs.readFileSync(path.join(PROJECT_ROOT, PIXELS), 'utf8');
const wrongMirror = pixelSource.replace('sx + width - 1 - x', 'sx + x');
assert.notEqual(wrongMirror, pixelSource);
assert.throws(() => pixelsFixture(makePureEtsLoader({}, { [PIXELS]: wrongMirror })), assert.AssertionError);
pass('撤回水平镜像的负对照会被生产像素断言识别');

/** fixture将库与账号作为外部边缘；Model及Component本身始终使用真实生产代码。 */
function fixture() {
  const skin = { id: 'skin-one', kind: 'skin', name: 'Shared', relativePath: 'account-textures/one.png', width: 64, height: 64 };
  const legacy = { ...skin, id: 'skin-old', name: 'Old', relativePath: 'account-textures/old.png', height: 32 };
  const cape = { ...skin, id: 'cape-one', kind: 'cape', name: 'Cape', relativePath: 'account-textures/cape.png', height: 32 };
  const state = { appearance: { revision: 3, model: 'CLASSIC' }, name: 'PlayerOne', saves: [], imports: [], removals: [], selected: [], inUse: false, items: [skin, legacy, cape] };
  const account = () => ({ id: 'one', type: 'legacy', username: state.name, getOfflineAppearance: () => clone(state.appearance) });
  const manager = { findById: id => id === 'one' ? account() : undefined,
    isAppearanceAssetUsed: () => state.inUse,
    editOfflineAccount: async (id, name, appearance) => {
      state.saves.push({ id, name, appearance: clone(appearance) });
      state.name = name.trim(); state.appearance = { ...clone(appearance), revision: appearance.revision + 1 }; return account();
    } };
  const library = { init: async () => {}, list: kind => clone(state.items.filter(item => item.kind === kind)),
    importFromUri: async (uri, kind) => { state.imports.push({ uri, kind }); return skin; },
    remove: async id => { state.removals.push(id); state.items = state.items.filter(item => item.id !== id); } };
  const boundary = { AccountType: { OFFLINE: 'legacy' }, getAccountManager: () => manager, getAppearanceLibrary: () => library };
  const picker = { DocumentSelectOptions: class {}, DocumentViewPicker: class {
    async select(options) { assert.equal(options.maxSelectNumber, 1); assert.deepEqual(options.fileSuffixFilters, ['PNG 纹理|.png']); return state.selected; }
  } };
  const dependencies = { account: boundary, '@kit.AbilityKit': {}, '@kit.CoreFileKit': { picker } };
  const load = makePureEtsLoader(dependencies);
  const model = new (load(MODEL).OfflineAppearanceEditorModel)();
  const env = environment({ imports: dependencies, globals: { AppStorage: { get: () => ({ filesDir: '/fixture' }) } } });
  return { state, model, load, env, skin, cape, legacy };
}
{
  const f = fixture(), snapshot = await f.model.load({}, 'one');
  assert.equal(snapshot.appearance.revision, 3); assert.equal(snapshot.skins.length, 2); assert.equal(snapshot.capes.length, 1);
  assert.equal(await f.model.importFile({}, 'skin'), null); assert.equal(f.state.imports.length, 0); assert.equal(f.state.saves.length, 0);
  f.state.selected = ['file://user/chosen.png']; await f.model.importFile({}, 'skin');
  assert.deepEqual(f.state.imports, [{ uri: 'file://user/chosen.png', kind: 'skin' }]); assert.equal(f.state.saves.length, 0);
  pass('文件选择取消无写入，导入只入共享库不更改账号');
  await f.model.save('one', 3, ' NewName ', f.legacy.id, f.cape.id, 'SLIM');
  assert.equal(f.state.saves.length, 1, '名称与外观只提交一次');
  assert.equal(f.state.saves[0].appearance.model, 'CLASSIC', '旧皮肤不能误选Slim');
  assert.equal(f.state.saves[0].appearance.skin.id, f.legacy.id); assert.equal(f.state.saves[0].appearance.cape.id, f.cape.id);
  pass('统一应用保留皮肤披风独立选择，旧皮肤强制Classic');
  await assert.rejects(f.model.save('one', 3, 'Stale', '', '', 'CLASSIC'), /其他位置更新/);
  await assert.rejects(f.model.save('missing', 0, 'Other', '', '', 'CLASSIC'), /已被移除/);
  await assert.rejects(f.model.save('one', 4, 'NewName', 'missing-skin', '', 'CLASSIC'), /已不在皮肤库/);
  assert.equal(f.state.saves.length, 1);
  pass('旧revision、被移除账号与已删除库条目均不能覆盖账号');
  f.state.inUse = true; await assert.rejects(f.model.removeAsset(f.skin.id), /正在使用/); assert.deepEqual(f.state.removals, []);
  f.state.inUse = false; await f.model.removeAsset(f.skin.id); assert.deepEqual(f.state.removals, [f.skin.id]);
  pass('库删除保护所有账号引用，解除后才能删除');
}
{
  const f = fixture(), Subject = f.env.load(EDITOR, true).OfflineAppearanceEditor;
  const subject = new Subject(); let closes = 0;
  subject.accountId = 'one'; subject.onClose = () => { closes++; };
  subject.aboutToAppear(); await settle();
  subject.username = 'DraftName'; subject.selectedSkinId = f.skin.id; subject.selectedCapeId = f.cape.id;
  subject.model = 'SLIM'; subject.changeKind_('cape'); subject.manage_();
  assert.equal(subject.managing, true); assert.equal(subject.activeKind, 'cape');
  subject.back_();
  assert.equal(subject.managing, false); assert.equal(closes, 0);
  assert.equal(subject.username, 'DraftName'); assert.equal(subject.selectedSkinId, f.skin.id);
  assert.equal(subject.selectedCapeId, f.cape.id); assert.equal(subject.model, 'SLIM');
  assert.equal(f.state.saves.length, 0, '离开管理模式不隐式应用账号草稿');
  subject.chooseDefault_(); assert.equal(subject.selectedCapeId, ''); assert.equal(subject.selectedSkinId, f.skin.id);
  subject.changeKind_('skin'); subject.chooseDefault_();
  assert.equal(subject.selectedSkinId, ''); assert.equal(subject.model, 'CLASSIC');
  subject.back_(); assert.equal(closes, 1);
  pass('素材管理返回保留整份草稿，默认项仅改变当前素材类型且不隐式提交');
}
{
  const f = fixture(), Subject = f.env.load(EDITOR, true).OfflineAppearanceEditor;
  const subject = new Subject(); subject.accountId = 'one'; subject.aboutToAppear(); await settle();
  subject.selectedSkinId = f.skin.id; subject.selectedCapeId = f.cape.id; subject.busy = true;
  subject.changeKind_('cape'); subject.manage_(); subject.chooseDefault_();
  assert.equal(subject.activeKind, 'skin'); assert.equal(subject.managing, false);
  assert.equal(subject.selectedSkinId, f.skin.id); assert.equal(subject.selectedCapeId, f.cape.id);
  subject.busy = false; f.state.inUse = true;
  await subject.remove_(f.skin); assert.equal(subject.pendingDeleteId, '');
  assert.match(subject.error, /正在使用/); assert.deepEqual(f.state.removals, []);
  f.state.inUse = false; await subject.remove_(f.skin);
  assert.equal(subject.pendingDeleteId, f.skin.id); assert.deepEqual(f.state.removals, []);
  await subject.confirmDelete_();
  assert.deepEqual(f.state.removals, [f.skin.id]); assert.equal(subject.selectedSkinId, '');
  assert.equal(subject.selectedCapeId, f.cape.id);
  pass('忙态拒绝重复选择，在用素材不武装删除，未用素材须再次确认并保持另一类选择');
}
{
  const f = fixture(), Subject = f.env.load(EDITOR, true).OfflineAppearanceEditor;
  const subject = new Subject(); subject.accountId = 'one'; subject.aboutToAppear(); await settle();
  assert.equal(subject.ready, true);
  const pending = deferred(); subject.editor.importFile = () => pending.promise;
  const importing = subject.import_('skin'); subject.aboutToDisappear(); pending.resolve(f.skin); await importing;
  assert.equal(subject.notice, ''); assert.equal(subject.selectedSkinId, ''); assert.equal(f.state.saves.length, 0);
  pass('关闭后的迟到导入回调不发布状态或改账号');
}
{
  const f = fixture(), Subject = f.env.load(EDITOR, true).OfflineAppearanceEditor;
  const subject = new Subject(); subject.accountId = 'one'; subject.aboutToAppear(); await settle();
  const pending = deferred(); let notifications = 0;
  subject.onChanged = () => { notifications++; };
  subject.editor.save = () => pending.promise;
  subject.username = 'SavedName';
  const saving = subject.apply_();
  assert.equal(subject.saving, true);
  subject.aboutToDisappear();
  pending.resolve({ username: 'SavedName', getOfflineAppearance: () => ({ revision: 4, model: 'CLASSIC' }) });
  await saving;
  assert.equal(notifications, 1, '确认成功即使详情被手势关闭也必须通知父owner');
  assert.equal(subject.confirmedName, 'PlayerOne', '已退役组件不发布新的本地显示状态');
  assert.equal(subject.notice, '');
  pass('保存等待期间关闭仍通知父owner一次，旧页状态保持退役');
}

/** 账号列表必须等待选中/删除的持久Promise，失败时不能预先改主卡或广播成功。 */
{
  const makeAccount = id => ({ id, uuid: id, type: 'legacy', getDisplayName: () => id,
    getSkinUrl: () => null, getSkinVariant: () => null, getCapeUrl: () => null, getCapeAlias: () => null });
  const state = { selected: 'one', accounts: [makeAccount('one'), makeAccount('two')], failure: false,
    barrier: deferred(), selectCalls: 0, removeCalls: 0, summaries: [] };
  const manager = { list: () => [...state.accounts], getSelectedId: () => state.selected,
    select: async id => { state.selectCalls++; await state.barrier.promise; if (state.failure) throw new Error('disk rejected'); state.selected = id; },
    remove: async id => { state.removeCalls++; await state.barrier.promise; if (state.failure) throw new Error('disk rejected'); state.accounts = state.accounts.filter(item => item.id !== id); } };
  const env = environment({ commons: { DeviceForm: { PHONE: 'phone' }, Breakpoint: { SM: 'sm' } },
    imports: { feature_core: { getTaskActivityOwner: () => ({ recordSummary: async (...args) => { state.summaries.push(args); } }) },
      account: { getAccountManager: () => manager,
    AccountType: { OFFLINE: 'legacy', MICROSOFT: 'msa', AUTHLIB_INJECTOR: 'mojang' } } } });
  const Subject = env.load('entry/src/main/ets/components/AccountListSheet.ets', true).AccountListSheet;
  const subject = new Subject(); let notifications = 0; subject.onAccountsChanged = () => { notifications++; };
  subject.aboutToAppear();
  const selecting = subject.selectAccount('two'); await settle();
  assert.equal(subject.selectedId, 'one'); assert.equal(subject.accountMutationId, 'two'); assert.equal(notifications, 0);
  await subject.removeAccount('one'); assert.equal(state.removeCalls, 0, '等待确认时拒绝并发界面操作');
  state.barrier.resolve(); await selecting;
  assert.equal(subject.selectedId, 'two'); assert.equal(subject.accountMutationId, ''); assert.equal(notifications, 1);
  state.barrier = deferred(); state.failure = true;
  const rejected = subject.selectAccount('one'); state.barrier.resolve(); await rejected;
  assert.equal(subject.selectedId, 'two'); assert.equal(notifications, 1); assert.match(subject.refreshErrorMsg, /切换失败/);
  pass('账号切换等待持久确认，失败保留原选择并提示且不广播成功');
  state.barrier = deferred(); state.failure = false;
  const removing = subject.removeAccount('one'); await settle();
  assert.equal(subject.accounts.length, 2); assert.equal(subject.accountMutationAction, 'remove');
  assert.equal(state.summaries.length, 0, '持久化尚未确认不能记录删除成功');
  state.barrier.resolve(); await removing;
  assert.equal(subject.accounts.length, 1); assert.equal(subject.accountMutationId, ''); assert.equal(notifications, 2);
  assert.deepEqual(state.summaries.map(args => args.slice(0, 3)), [['account', '删除账户', 'success']]);
  subject.aboutToDisappear();
  pass('账号删除等待持久确认才更新列表与通知owner');
}

/** 真实预览组件的非布局逻辑：像素读取延后返回，检验publish前的世代围栏。 */
{
  const requests = new Map();
  const env = environment({ commons: { DiagnosticPolicy: { isDeveloperBuild: () => false } },
    imports: { '@kit.ImageKit': { image: {} }, './AccountTextureLoader': { loadAccountTexture: source => {
      const request = deferred(); requests.set(source, request); return request.promise;
    } } }, globals: { RenderingContextSettings: class {}, CanvasRenderingContext2D: class {} } });
  const Subject = env.load('entry/src/main/ets/components/SkinCanvas3D.ets', true).SkinCanvas3D;
  const subject = new Subject(); subject.skinUrl = 'amcl-texture:A'; subject.aboutToAppear();
  const pixelsA = deferred();
  requests.get('amcl-texture:A').resolve({ getImageInfo: async () => ({ size: { width: 64, height: 64 } }),
    readPixelsToBuffer: async buffer => { await pixelsA.promise; new Uint8Array(buffer).fill(11); } });
  await settle();
  subject.skinUrl = 'amcl-texture:B'; subject.onInputsChange('skinUrl');
  requests.get('amcl-texture:B').resolve({ getImageInfo: async () => ({ size: { width: 64, height: 64 } }),
    readPixelsToBuffer: async buffer => { new Uint8Array(buffer).fill(77); } });
  await settle(); assert.equal(subject._skinRGBA[0], 77);
  pixelsA.resolve(); await settle(); assert.equal(subject._skinRGBA[0], 77, '旧像素读取不能覆盖新账号');
  subject.skinUrl = ''; subject.onInputsChange('skinUrl');
  assert.equal(subject._skinRGBA.length, 64 * 64 * 4, '无自定义皮肤仍建立程序化默认RGBA');
  subject.aboutToDisappear();
  pass('3D预览的迟到像素读取不串账号，默认RGBA不被空来源拦截');
}
{
  const requests = new Map(), pendingCrop = deferred(); let retired = 0;
  const env = environment({ imports: { '@kit.ImageKit': { image: {} }, './AccountTextureLoader': { loadAccountTexture: source => {
    const request = deferred(); requests.set(source, request); return request.promise;
  } } }, globals: { RenderingContextSettings: class {}, CanvasRenderingContext2D: class {} } });
  const Subject = env.load('entry/src/main/ets/components/CapePreview.ets', true).CapePreview;
  const subject = new Subject();
  const staleCrop = { release: async () => { retired++; } }, activeCrop = {};
  subject.cropCapePM = async original => original.name === 'A' ? pendingCrop.promise : activeCrop;
  subject.capeUrl = 'amcl-texture:A'; subject.aboutToAppear(); requests.get(subject.capeUrl).resolve({ name: 'A' }); await settle();
  subject.capeUrl = 'amcl-texture:B'; subject.onUrlChange(); requests.get(subject.capeUrl).resolve({ name: 'B' }); await settle();
  pendingCrop.resolve(staleCrop); await settle();
  assert.equal(subject._capePM, activeCrop); assert.equal(retired, 1);
  subject.aboutToDisappear();
  pass('披风裁剪过期结果退役，不能覆盖新的披风');
}
{
  let remoteRequests = 0;
  const env = environment({ commons: { getRemotePixelMap: async () => { remoteRequests++; return null; } },
    imports: { '@kit.ImageKit': { image: {} }, './AccountTextureLoader': { loadAccountTexture: async () => null,
      isLocalAccountTexture: source => source.startsWith('amcl-texture:') } } });
  const Subject = env.load('entry/src/main/ets/components/MinecraftHeadAvatar.ets', true).MinecraftHeadAvatar;
  const subject = new Subject(); subject.uuid = '00000000-0000-4000-8000-000000000000'; subject.skinUrl = 'amcl-texture:missing';
  subject.aboutToAppear(); await settle(); assert.equal(remoteRequests, 0); assert.equal(subject.pixelMap, null);
  subject.aboutToDisappear();
  pass('本地头像失败不泄漏到第三方UUID头像请求');
}

assert.deepEqual(hashes(), initialHashes, '测试执行期间生产源码不能被改写');
fs.writeFileSync(path.join(output, 'receipt.json'), JSON.stringify({ schemaVersion: 1, startedAt,
  completedAt: new Date().toISOString(), status: 'PASS', groups, sourceHashes: initialHashes,
  limitations: ['未执行ArkUI Builder', '未进行SDK编译', '未进行设备界面验收'] }, null, 2) + '\n');
console.log('PASS offline appearance UI host regressions; receipt=' + path.join(output, 'receipt.json'));
