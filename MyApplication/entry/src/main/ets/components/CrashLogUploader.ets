import { DistributionPolicy } from 'commons';
/** AMCL-web 薄接收端：只提交统一快照产生的 files[]，不采集、不拼接、不重新选择日志。 */

import { http } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { deviceInfo } from '@kit.BasicServicesKit';
import { bundleManager } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AMCL_WEB_BASE } from 'commons';
import { DeviceProfile } from 'commons';
import { EvidenceShareFile, sanitizeLogForExport, LogExportTarget, utf8ByteLength } from 'commons';

const TAG = 'CrashLogUploader';
const PREF_STORE = 'amcl_client';
const PREF_KEY_CLIENT_ID = 'clientId';

export interface CrashLogUploadResult {
  ok: boolean;        // true=已被服务端接受（新建或判重）
  duplicate: boolean; // true=服务端已有同一份（已上传过）
  id: string;
  error: string;      // ok=false 时的失败原因（已本地化，可直接提示）
  errorStage?: string;
}

/** 作者端实际附带的身份字段，预览与 POST 共用同一个值快照。 */
export interface AuthorUploadIdentity { clientId: string; device: string; osVersion: string; appVersion: string; }

export interface CrashLogUploadInput {
  identity?: AuthorUploadIdentity;
  files: EvidenceShareFile[];
  message?: string;
  /** 附加信息（已 JSON 序列化的字符串）；服务端原样存。 */
  metaJson?: string;
  /** 作者后台分类：crash / runtime / manual。 */
  kind?: string;
}

/** /api/logs 请求体（显式类型，规避 ArkTS arkts-no-untyped-obj-literals）。 */
interface LogPostBody {
  kind: string;
  files: EvidenceShareFile[];
  clientId: string;
  device: string;
  osVersion: string;
  appVersion: string;
  message?: string;
  meta?: string;
}

/** /api/logs 响应体（字段都可选，便于空对象兜底）。 */
interface LogPostResp {
  ok?: boolean;
  duplicate?: boolean;
  id?: string;
  error?: string;
  files?: AuthorFileReceipt[];
}
interface AuthorFileReceipt { name: string; size: number; lines: number; }
interface AuthorFileLimits { format?: string; maxFiles: number; maxBytes: number; maxLines: number; }

function ctx(): common.UIAbilityContext | undefined {
  return AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
}

/** 取（或首次生成并持久化）匿名 clientId。取不到 context / 失败时返回空串（服务端退化为按内容去重）。 */
async function getOrCreateClientId(): Promise<string> {
  const c = ctx();
  if (!c) return '';
  try {
    const store = await preferences.getPreferences(c, PREF_STORE);
    let id = await store.get(PREF_KEY_CLIENT_ID, '') as string;
    if (!id || id.length === 0) {
      id = util.generateRandomUUID(true);
      await store.put(PREF_KEY_CLIENT_ID, id);
      await store.flush();
    }
    return id;
  } catch (e) {
    hilog.warn(0x0, TAG, 'getOrCreateClientId failed: %{public}s', (e as Error)?.message ?? String(e));
    return '';
  }
}

/** 尽力取 App versionName（失败返回空串）。 */
function appVersionName(): string {
  try {
    const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    return info.versionName ?? '';
  } catch (e) {
    return '';
  }
}

/**
 * 上传一份崩溃日志。返回归一化结果（不抛异常，调用方按 result 分支提示）。
 */
export async function uploadCrashLog(input: CrashLogUploadInput): Promise<CrashLogUploadResult> {
  const result: CrashLogUploadResult = { ok: false, duplicate: false, id: '', error: '' };

  // 上架轨（APP 备案「无自有服务器」）：不向自有服务器 amcl.lovedhy.cn 上报崩溃日志。
  // 侧载轨保持上报（帮助作者定位问题）。上架轨直接返回"未上报"，调用方按 error 分支提示即可。
  if (!DistributionPolicy.allowPublisherServices()) {
    result.error = '当前版本不上报日志';
    return result;
  }

  const identity = input.identity ?? await prepareAuthorUploadIdentity();

  const body: LogPostBody = {
    kind: (input.kind && input.kind.length > 0) ? input.kind : 'crash',
    files: input.files,
    clientId: identity.clientId,
    device: identity.device,
    osVersion: identity.osVersion,
    appVersion: identity.appVersion,
  };
  if (input.message && input.message.length > 0) body.message = sanitizeLogForExport(input.message, LogExportTarget.LOGSHARE, 2000);
  if (input.metaJson && input.metaJson.length > 0) body.meta = input.metaJson;

  const req = http.createHttp();
  let postStarted: boolean = false;
  try {
    // 作者端尚未升级时先停止，不能退回旧 content 路径丢掉文件边界。
    const probe = await req.request(AMCL_WEB_BASE + '/api/logs/limits', {
      method: http.RequestMethod.GET, connectTimeout: 10000, readTimeout: 10000,
    });
    if (probe.responseCode !== 200) throw new Error('提交给作者暂不可用，可使用 LogShare 分享');
    const limits = JSON.parse(probe.result as string) as AuthorFileLimits;
    if (limits.format !== 'logshare-files-v1') throw new Error('提交给作者暂不可用，可使用 LogShare 分享');
    let totalBytes: number = 0;
    let totalLines: number = 0;
    for (const file of input.files) { totalBytes += utf8ByteLength(file.content); totalLines += file.content.split('\n').length; }
    if (input.files.length > limits.maxFiles || totalBytes > limits.maxBytes || totalLines > limits.maxLines) {
      throw new Error('所选文件超过作者端限额，请生成节选预览或使用 ZIP 导出');
    }
    postStarted = true;
    const res = await req.request(AMCL_WEB_BASE + '/api/logs', {
      method: http.RequestMethod.POST,
      header: { 'Content-Type': 'application/json' },
      extraData: JSON.stringify(body),
      connectTimeout: 10000,
      readTimeout: 20000,
    });
    const code = res.responseCode;
    result.errorStage = code >= 500 || code === 408 ? 'unknown-outcome' : 'http';
    let parsed: LogPostResp = {};
    try {
      parsed = JSON.parse(res.result as string) as LogPostResp;
    } catch (e) { /* 非 JSON 响应，忽略 */ }

    if (code === 201) {
      result.ok = parsed.ok === true && (parsed.id ?? '').length > 0;
      result.id = parsed.id ?? '';
    } else if (code === 200) {
      result.ok = parsed.ok === true && (parsed.id ?? '').length > 0;
      result.duplicate = parsed.duplicate === true;
      result.id = parsed.id ?? '';
    } else if (code === 429) {
      result.error = '上传过于频繁，请稍后再试';
    } else if (code === 403) {
      result.error = '上传被拒绝（IP 被限制）';
    } else {
      const msg = parsed.error;
      result.error = (msg && msg.length > 0) ? msg : ('上传失败 (' + code + ')');
    }
    if (result.ok) {
      const receipts: AuthorFileReceipt[] = parsed.files ?? [];
      result.ok = receipts.length === input.files.length && input.files.every((file: EvidenceShareFile): boolean =>
        receipts.some((receipt: AuthorFileReceipt): boolean => receipt.name === file.name && receipt.size === utf8ByteLength(file.content)));
      if (!result.ok) result.error = '作者端接收的文件集合未通过核对，请保留本地证据';
    } else if (result.error.length === 0) result.error = '作者端未返回完整的接收凭据';
  } catch (e) {
    result.errorStage = postStarted ? 'unknown-outcome' : 'preflight';
    result.error = (postStarted ? '作者端接收结果尚未确认：' : '提交准备未完成：') + ((e as Error)?.message ?? String(e));
    hilog.warn(0x0, TAG, 'uploadCrashLog request failed: %{public}s', result.error);
  } finally {
    req.destroy();
  }
  return result;
}

/** 仅读本机信息和安装标识；生成确认摘要不调用作者网络接口。 */
export async function prepareAuthorUploadIdentity(): Promise<AuthorUploadIdentity> {
  return { clientId: await getOrCreateClientId(),
    device: (deviceInfo.marketName && deviceInfo.marketName.length > 0) ? deviceInfo.marketName : deviceInfo.productModel,
    osVersion: deviceInfo.osFullName, appVersion: appVersionName() };
}
