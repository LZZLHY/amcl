/**
 * 活动分享的公共准备层：快捷与高级入口共用一份活动身份、文件规则和元数据。
 * 快捷路径只取白名单推荐文件，绝不继承用户上次高级勾选的可选附件，也不自动开启 AI。
 * 本模块的 prepare 只做本地冻结；所有网络发送仍通过 EvidenceShareService。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { EvidenceFileRecord, EvidenceExportSnapshot, EvidenceUploadSelection, LedgerManifest,
  ledgerManifest, listSessionEvidence, defaultEvidenceSelection, evidenceSelectionOf,
  verifySessionCaptureRotations, createEvidenceExportSnapshot, EVIDENCE_REDACTION_VERSION,
  ledgerStateLabel, evidenceTextDigest, setEvidenceSelection } from 'commons';
import { LogShareMetadata, LogSharePreflight, logShareMetadataItems, resolveLogShareSource } from './LogShareClient';
import { SessionEnvironment, readObservedSessionEnvironment, environmentValue, EVIDENCE_EXPORT_FORMAT } from 'commons';

export class ActivityShareDraft {
  activityId: number = 0;
  manifest: LedgerManifest | undefined = undefined;
  files: EvidenceFileRecord[] = [];
  selectedFileIds: string[] = [];
  revision: number = 1;
  includePublicSummary: boolean = true;
  environment: SessionEnvironment | undefined = undefined;
}

/** 确认所选活动的真实证据。高级路径可恢复选择，但不会影响快捷默认范围。 */
export async function loadActivityShareDraft(context: common.UIAbilityContext, activityId: number,
  useDefaults: boolean): Promise<ActivityShareDraft> {
  if (!Number.isSafeInteger(activityId) || activityId <= 0) throw new Error('无法识别这条活动');
  await verifySessionCaptureRotations(context.filesDir, activityId);
  const draft = new ActivityShareDraft();
  draft.activityId = activityId;
  draft.manifest = ledgerManifest(context.filesDir, activityId) ?? undefined;
  draft.environment = readObservedSessionEnvironment(context.filesDir, activityId);
  draft.files = listSessionEvidence(context.filesDir, activityId);
  const selection = evidenceSelectionOf(context.filesDir, activityId, draft.files);
  draft.revision = selection.revision;
  draft.selectedFileIds = useDefaults ? defaultEvidenceSelection(draft.files) : selection.selectedFileIds.slice();
  draft.includePublicSummary = useDefaults || selection.includePublicSummary;
  return draft;
}

/** 公共摘要只含诊断必要字段，不带游戏根目录等本地绝对路径。 */
export function activityShareSummary(draft: ActivityShareDraft): string {
  const m = draft.manifest;
  return 'AMCL_PUBLIC_SESSION_SUMMARY_V1\nactivityId=' + draft.activityId
    + '\ncategory=' + (m?.category ?? '') + '\ntitle=' + (m?.title ?? '')
    + '\ngameVersion=' + (m?.gameVersionId ?? '') + '\nloader=' + (m?.loaderType ?? '') + ' ' + (m?.loaderVersion ?? '')
    + '\njdk=' + (m?.jdk ?? '') + '\noutcome=' + (m === undefined ? 'unknown' : ledgerStateLabel(m.state))
    + '\nstartedAt=' + (m?.startedAt ?? draft.activityId) + '\nendedAt=' + (m?.endedAt ?? 0)
    + '\nevidenceRevision=' + draft.revision + '\n';
}

/** 与公开请求一一对应的元数据，供确认页显示，不再只预览日志正文。 */
export function activityShareMetadata(draft: ActivityShareDraft): LogShareMetadata {
  const m = draft.manifest;
  const environment = draft.environment;
  const value = (key: string): string => environment === undefined ? 'unknown (not recorded)' : environmentValue(environment, key);
  return { launcher: 'AMCL', appVersion: m?.appVersion ?? '', mcVersion: m?.gameVersionId ?? '',
    loader: m === undefined ? '' : m.loaderType + ' ' + m.loaderVersion,
    jdk: m?.jdk ?? '', device: m?.deviceModel ?? '', osVersion: m?.osVersion ?? '',
    outcome: m === undefined ? '' : ledgerStateLabel(m.state), activityId: draft.activityId, snapshot: '',
    uploaderVersion: resolveLogShareSource('amcl-launcher'), hostOs: value('host.os'), hostApi: value('host.api'),
    cpu: value('cpu.model'), gpu: value('gpu.model'), gpuProbe: value('gpu.probeModel'),
    graphicsProfile: value('graphics.profile'), graphicsProvider: value('graphics.provider'),
    javaBuild: value('java.version'), environmentSchema: '1' };
}

export function activityShareDisclosure(draft: ActivityShareDraft): string {
  return 'source: ' + resolveLogShareSource('amcl-launcher') + '\n'
    + logShareMetadataItems(activityShareMetadata(draft)).map((item): string => item.key + ': ' + item.value).join('\n')
    + '\nsnapshot: 本次冻结快照的校验摘要';
}

export async function prepareActivityShare(context: common.UIAbilityContext,
  draft: ActivityShareDraft): Promise<EvidenceExportSnapshot> {
  const selection: EvidenceUploadSelection = { activityId: draft.activityId, revision: draft.revision,
    selectedFileIds: draft.selectedFileIds.slice(), includePublicSummary: draft.includePublicSummary, createdAt: Date.now() };
  return createEvidenceExportSnapshot(context.filesDir, context.tempDir, selection, activityShareSummary(draft));
}

/** 高级选择沿用账本的持久化语义；保存成功后再更新草稿，快捷路径仍忽略这份自选。 */
export function persistActivityShareSelection(context: common.UIAbilityContext, draft: ActivityShareDraft,
  selected: string[], includeSummary: boolean): void {
  const saved = setEvidenceSelection(context.filesDir, draft.activityId, selected, includeSummary);
  draft.selectedFileIds = saved.selectedFileIds.slice(); draft.revision = saved.revision;
  draft.includePublicSummary = includeSummary;
}

/**
 * 记住的是明确的默认外发规则，不是任意文件授权。实例、保留期、默认角色/元数据版本或
 * 脱敏版本变化都会改变键。不同活动的文件名/内容正常变化不要求再次走高级预览。
 */
export function quickShareConsentKey(plan: LogSharePreflight): string {
  return evidenceTextDigest('quick-public-v2|recommended-latest-stdio-jvm-trusted-crash-launcher|environment-diagnosis|metadata-v2|'
    + EVIDENCE_EXPORT_FORMAT + '|'
    + EVIDENCE_REDACTION_VERSION + '|' + plan.apiBaseUrl + '|' + plan.limits.storageTimeSec);
}

/** 偏好不可读时回退到明确确认，绝不按默认值授权公开上传。 */
export async function hasQuickShareConsent(context: common.UIAbilityContext, key: string): Promise<boolean> {
  try {
    const store = await preferences.getPreferences(context, 'amcl_quick_share');
    const text = await store.get('consents', '[]') as string;
    const keys = JSON.parse(text) as string[];
    return Array.isArray(keys) && keys.includes(key);
  } catch (e) { return false; }
}

/** 只在用户点击确认且选择记住规则时写入；最多保留八个规则版本。 */
export async function rememberQuickShareConsent(context: common.UIAbilityContext, key: string): Promise<void> {
  const store = await preferences.getPreferences(context, 'amcl_quick_share');
  let keys: string[] = [];
  try { keys = JSON.parse(await store.get('consents', '[]') as string) as string[]; }
  catch (e) { keys = []; }
  if (!Array.isArray(keys)) keys = [];
  keys = keys.filter((item: string): boolean => typeof item === 'string' && item !== key).slice(-7);
  keys.push(key); await store.put('consents', JSON.stringify(keys)); await store.flush();
}

/** 用户可在高级入口撤销“下次直接分享”，不影响已生成链接或撤回凭据。 */
export async function resetQuickShareConsent(context: common.UIAbilityContext): Promise<void> {
  const store = await preferences.getPreferences(context, 'amcl_quick_share');
  await store.put('consents', '[]'); await store.flush();
}
