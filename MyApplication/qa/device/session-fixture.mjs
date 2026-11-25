// 执行开发产品的真实设备协议和具名方法适配；仅替换沙箱、时钟调度与设备元数据。
import { makePureEtsLoader } from '../../scripts/lib/load-pure-ets.mjs';
import { readFileSync } from 'node:fs';
import ts from '../../scripts/lib/ets-compiler.mjs';

const source = readFileSync(new URL('../../entry/src/main/ProductQa.ets', import.meta.url), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
export const load = makePureEtsLoader();
const contract = JSON.parse(readFileSync(new URL('../contracts/actions.json', import.meta.url), 'utf8'));
const actions = Object.keys(contract.actions);
const session = '0'.repeat(32), revision = 'a'.repeat(40), root = '/data/files/amcl-qa-v1';
const expiry = Date.now() + 600000;
const dir = root + '/' + session;
const disk = new Map([[root, null]]);
const counters = { calls: 0, writes: 0 };
const context = { filesDir: '/data/files', abilityInfo: { bundleName: 'com.amcl.launcher' },
  resourceManager: { getRawFileContentSync: () => Buffer.from(JSON.stringify({ name: 'default', sourceRevision: revision, build: { mode: 'debug' } })) } };
const grant = { schema: 1, session, expiresAt: expiry, sourceRevision: revision, actions };
const signal = { parameters: { amclQaSession: session } };
function installGrant(value) { disk.set(root + '/session.json', JSON.stringify(value)); }
function model(allowed = true, faults = {}) {
  const io = { accessSync: p => disk.has(p), mkdirSync: p => disk.set(p,null), readTextSync: p => disk.get(p),
    lstatSync(p) { if (!disk.has(p)) throw Object.assign(Error('missing'), { code: 13900002 });
      const value = disk.get(p); return { isDirectory: () => value === null, isFile: () => typeof value === 'string', isSymbolicLink: () => false, size: value === null ? 0 : Buffer.byteLength(value) }; } };
  Object.assign(io, { OpenMode:{ READ_ONLY:0 },openSync(p) { if (!disk.has(p)) throw Error('absent directory'); return {fd:p}; },
    fsyncSync(fd) {faults.sync?.(fd);},closeSync() {} });
  const common = { AtomicFileWriter: { write(p,s) { faults.before?.(p); disk.set(p,s); counters.writes++; faults.after?.(p); } }, DiagnosticPolicy: { hasTestHooks: () => allowed } };
  const imports = { './QaLauncherSkill': load('entry/src/main/QaLauncherSkill.ets'), '@kit.CoreFileKit': { fileIo: io }, '@kit.ArkTS': { util: { TextDecoder: class {decodeWithStream(b) {return b.toString();}} } },
    commons: common, './ets/product/ProductIdentityCollector': { collectProductIdentity: () => ({ product:'default',versionName:'sample',versionCode:1 }) } };
  const module = { exports: {} };
  new Function('require','exports','setInterval','clearInterval',js)(name => {
    if (!(name in imports)) throw Error('unexpected module ' + name);
    return imports[name];
  }, module.exports, () => 3, () => {});
  return module.exports.ProductQa;
}
function send(n, id, action, args, commit = id) {
  disk.set(root + '/next-' + session + '.json', JSON.stringify({ schema:1, session, sequence:n, id, action,args }));
  disk.set(root + '/commit-' + session + '.txt',commit);
}
const reply = n => JSON.parse(disk.get(dir + '/reply-' + n + '.json'));

export { actions, session, root, dir, disk, counters, context, grant, signal, installGrant, model, send, reply };
