/** Explicit developer probe of the sharing-only instance. Synthetic content only. */
import { common, Want } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { AppLogger, DiagnosticPolicy, LOG_DOMAIN_UI } from 'commons';
import { ActivityLogger, ledgerBegin, ledgerEnd, ledgerDirOf, LedgerState, ensureDirSync,
  writeEvidenceTextAtomic, listSessionEvidence, evidenceSelectionOf, createEvidenceExportSnapshot,
  EvidenceExportSnapshot, disposeEvidenceExportSnapshot } from 'commons';
import { shareEvidenceSnapshot } from './EvidenceShareService';
import { getLimits, revokeShare, LogShareRecord,
  LOGSHARE_BACKUP_API_BASE, logShareInstanceForUrl } from './LogShareClient';

interface ProbeStep { name: string; ok: boolean; detail: string; }
interface ProbeReport { nonce: string; startedAt: number; finishedAt: number; capabilities: number; syntheticOnly: boolean; steps: ProbeStep[]; }
let probeRunning: boolean = false;

function saveReport(context: common.UIAbilityContext, report: ProbeReport): void {
  const path = context.filesDir + '/logshare-connectivity-' + report.nonce + '.json';
  const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try { fs.writeSync(file.fd, JSON.stringify(report)); } finally { fs.closeSync(file); }
}
function recordStep(context: common.UIAbilityContext, report: ProbeReport, name: string, ok: boolean, detail: string): void {
  const step: ProbeStep = { name: name, ok: ok, detail: detail };
  report.steps.push(step); saveReport(context, report);
  AppLogger.info('LogShareClient', 'device-probe ' + report.nonce + ' ' + name + ' ok=' + ok + ' ' + detail, LOG_DOMAIN_UI);
}
export function runLogShareConnectivityWant(context: common.UIAbilityContext, want: Want): void {
  if (!DiagnosticPolicy.hasTestHooks() || probeRunning) return;
  const raw = want.parameters?.['amclLogShareProbe'];
  if (typeof raw !== 'string' || !new RegExp('^[a-zA-Z0-9_-]{1,64}$').test(raw)) return;
  probeRunning = true;
  runProbe(context, raw, want.parameters?.['amclLogShareMode'] === 'render').catch((error: Error): void => {
    AppLogger.warn('LogShareClient', 'device-probe failed', error, LOG_DOMAIN_UI);
  }).finally((): void => { probeRunning = false; });
}
async function checkRead(context: common.UIAbilityContext, report: ProbeReport, name: string,
  url: string, expectedStatus: number, marker: string = '', forbidden: string = ''): Promise<void> {
  const req = http.createHttp();
  try {
    const response = await req.request(url, { method: http.RequestMethod.GET, connectTimeout: 10000, readTimeout: 30000 });
    const text = typeof response.result === 'string' ? response.result : '';
    recordStep(context, report, name, response.responseCode === expectedStatus && text.includes(marker) && (forbidden.length === 0 || !text.includes(forbidden)),
      'HTTP=' + response.responseCode + ' markerFound=' + text.includes(marker));
  } finally { req.destroy(); }
}
async function runProbe(context: common.UIAbilityContext, nonce: string, includeRender: boolean): Promise<void> {
  const report: ProbeReport = { nonce: nonce, startedAt: Date.now(), finishedAt: 0,
    capabilities: DiagnosticPolicy.resolvedCapabilities(), syntheticOnly: true, steps: [] };
  saveReport(context, report);
  let share: LogShareRecord | undefined = undefined;
  let snapshot: EvidenceExportSnapshot | undefined = undefined;
  try {
    const limits = await getLimits();
    recordStep(context, report, 'official limits', limits.ok, limits.error || 'retentionSeconds=' + limits.storageTimeSec);
    const backupLimits = await getLimits(LOGSHARE_BACKUP_API_BASE);
    recordStep(context, report, 'backup limits', backupLimits.ok, backupLimits.error || 'retentionSeconds=' + backupLimits.storageTimeSec);
    const marker = 'AMCL synthetic routing probe ' + nonce;
    const activityId: number = Date.now();
    ledgerBegin(context.filesDir, activityId, { category: 'diagnostic', title: '日志分享合成验证' });
    const directory: string = ledgerDirOf(context.filesDir, activityId);
    ensureDirSync(directory + '/game/logs'); ensureDirSync(directory + '/render');
    writeEvidenceTextAtomic(directory + '/game/logs/latest.log', '[main/INFO]: ' + marker + '\n'
      + '合成日志，不含用户数据。\n'.repeat(4000) + 'password="synthetic short secret"\n');
    writeEvidenceTextAtomic(directory + '/render/renderer.log', 'AMCL_SYNTHETIC_RENDER ' + nonce + '\n');
    const logger = new ActivityLogger(activityId);
    logger.info('LogShareClient', 'LONG_BEGIN ' + '合成长堆栈 '.repeat(2000) + ' LONG_END', LOG_DOMAIN_UI);
    ledgerEnd(context.filesDir, activityId, { state: LedgerState.SUCCESS, source: 'synthetic.probe', summary: marker });
    const evidence = listSessionEvidence(context.filesDir, activityId);
    const selection = evidenceSelectionOf(context.filesDir, activityId, evidence);
    const renderer = evidence.find((file): boolean => file.path === 'render/renderer.log');
    recordStep(context, report, 'default excludes renderer', renderer !== undefined
      && selection.selectedFileIds.indexOf(renderer.fileId) < 0, 'default latest/crash/launcher only');
    if (includeRender && renderer !== undefined) selection.selectedFileIds.push(renderer.fileId);
    snapshot = await createEvidenceExportSnapshot(context.filesDir, context.tempDir, selection, marker);
    const launcher = snapshot.files.find((file): boolean => file.role === 'launcher');
    recordStep(context, report, 'native long entry survives', launcher !== undefined
      && fs.readTextSync(launcher.path).includes('LONG_END'), 'explicit flush + frozen native launcher');
    share = await shareEvidenceSnapshot(context, snapshot, { launcher: 'AMCL', appVersion: '',
      mcVersion: 'synthetic-routing-probe', loader: '', jdk: '', device: '', osVersion: '', outcome: 'synthetic' });
    recordStep(context, report, 'routed upload', true, 'provider=' + share.apiBaseUrl + ' id=' + share.id);
    recordStep(context, report, 'remote file list verified', share.remoteFilesVerified === true,
      share.verificationError ?? 'all selected files verified');
    const instance = logShareInstanceForUrl(share.url);
    await checkRead(context, report, 'raw round-trip', instance + '/v1/raw/' + share.id, 200, marker, 'synthetic short secret');
    await checkRead(context, report, 'share viewer', share.url, 200);
    if (includeRender) {
      await checkRead(context, report, 'optional renderer round-trip', instance + '/v1/raw/' + share.id
        + '/render/renderer.log', 200, 'AMCL_SYNTHETIC_RENDER');
    }
  } catch (e) {
    recordStep(context, report, 'probe-error', false, (e as Error).message);
  } finally {
    if (snapshot !== undefined) { try { disposeEvidenceExportSnapshot(snapshot); } catch (e) { /* 撤回仍必须执行 */ } }
    if (share !== undefined) {
      try {
        const deleted = await revokeShare(context, share);
        recordStep(context, report, 'origin revoke', deleted.ok, deleted.ok ? 'synthetic log revoked' : deleted.error);
        if (deleted.ok) await checkRead(context, report, 'deleted raw unavailable', logShareInstanceForUrl(share.url) + '/v1/raw/' + share.id, 404);
      } catch (e) { recordStep(context, report, 'origin revoke', false, (e as Error).message); }
    }
    report.finishedAt = Date.now(); saveReport(context, report);
  }
}
