// Execute production providers and page methods with the shared, network-isolated
// evidence runtime. Only platform services and ArkUI component syntax are adapted.
import fs from 'node:fs';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

function method(source, name) {
  const match = new RegExp('^  (?:private )?(?:async )?' + name + '\\([^;{}]*\\)[^{]*\\{', 'm').exec(source);
  if (!match) throw new Error('Method missing: ' + name);
  const masked = source.replace(/\/\*[\s\S]*?\*\/|\/\/[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\x60(?:\\.|[^\x60\\])*\x60/g, text => ' '.repeat(text.length));
  let end = masked.indexOf('{', match.index) + 1, depth = 1;
  while (depth && end < masked.length) { depth += (masked[end] === '{') - (masked[end] === '}'); end++; }
  if (depth) throw new Error('Unclosed method: ' + name);
  return source.slice(match.index, end);
}

export function runtime(product, forceDesktopProvider = false) {
  const state = { product, reads: 0, writes: 0, clipboard: '', clipboardFails: false,
    writeFails: false, shortWrite: false, fsyncFails: false, prefsFail: false,
    probeFails: false, probeCalls: 0, toasts: [], routes: [], newProbeText: 'FULL_RENDER_PROBE' };
  const methods = new Map([
    ['DesktopDeveloperToolsPage.ets', ['context', 'desktopProfileSummary', 'restoreSaved', 'refreshShares', 'verify', 'shareResult', 'copyShareUrl', 'revokeDiagnostic']],
    ['McErrorSheet.ets', ['lsSubmit_', 'lsUseShare_', 'openShareComposer_']],
    ['ActivityShareSheet.ets', ['prepare_', 'send_', 'release_', 'samePlan_', 'planCaption_', 'receiptCaption_',
      'busy_', 'setPhase_', 'fail_', 'advanced_', 'retrySave_', 'copy_', 'fits_', 'totalBytes_']],
  ]);
  const options = {
    imports: {
      'entry/ProductBuildProfile': { ProductBuildProfile: { product } },
      launch: { graphicsProfileById: () => ({ id: 'nativegl', api: 'OPENGL', windowProviders: ['GLFW', 'SDL3'], transport: 'UNKNOWN', capabilityKind: 'native-gl', lifecycle: 'platform-default', admission: 'VALIDATION', requirementId: 'desktop-system-gl-validation-v1' }) },
      feature_core: { ActivityCategory: { LAUNCH: 'launch' } },
      './AiAnalysisService': { cancelAiAnalysis() {}, detachAiObserver() {} },
      '../components/AiAnalysisService': { startAiAnalysis() {}, getAiTaskSnapshot: () => ({ shareId: '' }), cancelAiAnalysis() {} },
      './AppNotifier': { ensureNotifyPermission: async () => false },
      '../components/AppNotifier': { ensureNotifyPermission: async () => false },
      '../components/McSessionSnapshot': { saveSessionShare: async () => {}, clearSessionShare: async () => {} },
      './McSessionSnapshot': { saveSessionShare: async () => {}, clearSessionShare: async () => {} },
      'libentry.so': { default: { getNativeGlCapability: async () => {
        state.probeCalls++;
        if (state.probeFails) throw new Error('PROBE_EXCEPTION_SENTINEL');
        return { ready: true, stage: 'complete', error: '', renderDiagnostics: state.newProbeText };
      } } },
    },
    basicServices: { deviceInfo: { deviceType: '2in1', sdkApiVersion: 22 }, pasteboard: {
      MIMETYPE_TEXT_PLAIN: 'text/plain', createData: (_type, text) => text,
      getSystemPasteboard: () => ({ setData: async text => {
        if (state.clipboardFails) throw new Error('clipboard denied');
        state.clipboard = text;
      } }),
    } },
    commons: {},
    transform(file, source) {
      const names = methods.get(file.split(/[\\/]/).at(-1));
      if (!names) return source;
      const first = /^@(Entry|Component)\b/m.exec(source);
      return source.slice(0, first.index) + '\nexport class Subject {\n' + names.map(name => method(source, name)).join('\n') + '\n}';
    },
  };
  const fixture = evidenceRuntime(options), { load, context, control, kitFs } = fixture;
  state.temp = state.filesDir = context.filesDir;
  Object.defineProperty(state, 'posts', { get: () => control.requests.filter(r => r.options.method === 'POST') });
  control.failWrite = name => state.writeFails || (state.prefsFail && name.includes('share-records'));
  const write = kitFs.writeSync, sync = kitFs.fsyncSync;
  kitFs.writeSync = (fd, data) => write(fd, state.shortWrite ? (typeof data === 'string' ? data.slice(0, 2) : Buffer.from(data).subarray(0, 2)) : data);
  kitFs.fsyncSync = fd => { if (state.fsyncFails) throw new Error('injected fsync failure'); sync(fd); };
  for (const [name, operation] of Object.entries(kitFs)) {
    if (typeof operation !== 'function') continue;
    kitFs[name] = (...args) => {
      if (typeof args[0] === 'string' && args[0].includes('/logs/desktop-render/')) {
        state[/write|rename|unlink|mkdir|open/i.test(name) ? 'writes' : 'reads']++;
      }
      return operation(...args);
    };
  }
  const logExport = load('commons/src/main/ets/utils/LogExport.ets');
  const ledger = load('commons/src/main/ets/utils/ActivityLedger.ets');
  const evidence = load('commons/src/main/ets/utils/SessionEvidence.ets');
  Object.assign(options.commons, ledger);
  const desktop = forceDesktopProvider || product === 'desktop';
  const Provider = load('entry/src/' + (desktop ? 'desktop' : 'main') + '/ProductRenderDiagnostics.ets').ProductRenderDiagnostics;
  options.imports['entry/ProductRenderDiagnostics'] = { ProductRenderDiagnostics: Provider };
  const client = load('entry/src/main/ets/components/LogShareClient.ets');
  const Page = load('entry/src/main/ets/pages/DesktopDeveloperToolsPage.ets').Subject;
  const Sheet = load('entry/src/main/ets/components/McErrorSheet.ets').Subject;
  const Activity = load('entry/src/main/ets/components/ActivityShareSheet.ets').Subject;
  const ShareDraft = load('entry/src/main/ets/components/ActivitySharePreparation.ets').ActivityShareDraft;
  const getUIContext = () => ({ getRouter: () => ({ pushUrl: async route => { state.routes.push(route); } }),
    getPromptAction: () => ({ showDialog: async () => ({ index: 1 }) }) });
  function page() {
    return Object.assign(new Page(), { busy: false, sharing: false, result: '', savedLabel: '', saveError: '', shareStatus: '', diagnosticShares: [], getUIContext });
  }
  function seed(id = 1789050000000) {
    const mc = context.filesDir + '/mc'; fs.mkdirSync(mc, { recursive: true });
    ledger.ledgerBegin(context.filesDir, id, { category: 'launch', title: 'synthetic', gameVersionId: '1.21.11', mcDir: mc });
    fixture.write('logs/ledger/' + id + '/launcher/launcher-host.log', 'BOOT_BEGIN\n');
    fixture.write('logs/ledger/' + id + '/game/logs/latest.log', 'GAME_HEAD\n'
      + ('game trace ' + 'x'.repeat(190) + '\n').repeat(1200)
      + 'SCOPED_RENDER_FAILURE EGL_BAD_SURFACE=0x300d\n'
      + ('game trace ' + 'x'.repeat(190) + '\n').repeat(1800) + 'GAME_END\n');
    ledger.ledgerEnd(context.filesDir, id, { state: ledger.LedgerState.FAILED, source: 'fixture', summary: 'synthetic' });
    return { id, mc };
  }
  function sheet(id, mc) {
    return Object.assign(new Sheet(), { sessionKey: id, session: { mcDir: mc, version: '1.21.11', startedAt: id }, lsShareId: '', lsShareUrl: '',
      uiCtx_: () => context, theme: {}, shortVersion: value => value, onShareChanged() {}, onClose() {}, getUIContext, toast_: text => state.toasts.push(text) });
  }
  function activity(id) {
    const selection = evidence.evidenceSelectionOf(context.filesDir, id);
    const draft = Object.assign(new ShareDraft(), { activityId: id, manifest: ledger.ledgerManifest(context.filesDir, id),
      revision: selection.revision, selectedFileIds: selection.selectedFileIds.slice(), includePublicSummary: false,
      files: evidence.listSessionEvidence(context.filesDir, id) });
    return Object.assign(new Activity(), { context, activityId: id, draft, generation: 0, alive: true, advanced: true,
      destination: 'logshare', phase: 'select', shared: undefined, snapshot: undefined,
      previewName: '', previews: [], requestAi: false, onBusyChanged() {}, onShared() {}, onAdvancedChanged() {},
      getUIContext, toast_: text => state.toasts.push(text) });
  }
  return { state, Provider, client, logExport, ledger, evidence, page, sheet, activity, seed, context, control,
    cleanup: () => fixture.close() };
}
