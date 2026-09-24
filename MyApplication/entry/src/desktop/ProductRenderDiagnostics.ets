import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { bundleManager } from '@kit.AbilityKit';
import { AppLogger, LOG_DOMAIN_UI, LogExportTarget, exportLimitOf, sanitizeLogForExport,
  utf8ByteLength, truncateUtf8HeadTail } from 'commons';
import { ProductBuildProfile } from 'entry/ProductBuildProfile';
import { RenderDiagnosticAttachment } from '../main/ets/runtime/RenderDiagnosticAttachment';

interface StoredDiagnostic {
  schema: number;
  id: string;
  product: string;
  version: string;
  activityId: number;
  capturedAt: number;
  detailed: boolean;
  text: string;
}

const MAX_DIAGNOSTIC_BYTES: number = 1024 * 1024;
const MAX_RECORD_BYTES: number = 4 * 1024 * 1024;
const TAG: string = 'DesktopRenderDiagnostic';

export class ProductRenderDiagnostics {
  static readonly enabled: boolean = ProductBuildProfile.product === 'desktop';
  static readonly shareCategory: string = 'desktop-render-diagnostic/' + ProductBuildProfile.product;

  private static directory(filesDir: string): string {
    if (filesDir.length === 0) throw new Error('电脑诊断日志目录不可用');
    return filesDir + '/logs/desktop-render/' + ProductBuildProfile.product;
  }

  private static sessionDirectory(filesDir: string, activityId: number): string {
    if (activityId <= 0) return ProductRenderDiagnostics.directory(filesDir);
    return filesDir + '/logs/ledger/' + activityId + '/render';
  }

  static save(filesDir: string, text: string, detailed: boolean, activityId: number = 0): void {
    if (!ProductRenderDiagnostics.enabled) return;
    if (text.length === 0 || utf8ByteLength(text) > MAX_DIAGNOSTIC_BYTES) {
      throw new Error('电脑诊断输出为空或过大，未保存截断结果');
    }
    const id: string = util.generateRandomUUID().toLowerCase();
    let version: string = 'unknown';
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      version = info.versionName + ' (' + info.versionCode + ')';
    } catch (error) {
      AppLogger.warn(TAG, 'Cannot read diagnostic build version', error, LOG_DOMAIN_UI);
    }
    const record: StoredDiagnostic = { schema: 2, id: id, product: ProductBuildProfile.product,
      version: version, activityId: activityId, capturedAt: Date.now(),
      detailed: detailed, text: text };
    const directory: string = ProductRenderDiagnostics.sessionDirectory(filesDir, activityId);
    if (!fs.accessSync(directory)) fs.mkdirSync(directory, true);
    const destination: string = directory + (detailed ? '/render.json' : '/capability.json');
    const temporary: string = destination + '.' + id + '.tmp';
    const encoded: string = JSON.stringify(record);
    if (utf8ByteLength(encoded) > MAX_RECORD_BYTES) throw new Error('电脑诊断输出过大，未保存截断结果');
    let file: fs.File | undefined = undefined;
    try {
      file = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      if (fs.writeSync(file.fd, encoded) !== utf8ByteLength(encoded)) throw new Error('电脑诊断日志未完整写入');
      fs.fsyncSync(file.fd);
      fs.closeSync(file);
      file = undefined;
      fs.renameSync(temporary, destination);
    } finally {
      if (file !== undefined) { try { fs.closeSync(file); } catch (_) { /* Keep the write failure as the primary error. */ } }
      try { fs.unlinkSync(temporary); } catch (_) { /* Atomic rename already consumed the temporary file. */ }
    }
  }

  private static readFile(filesDir: string, detailed: boolean,
    activityId: number): RenderDiagnosticAttachment | undefined {
    try {
      const path: string = ProductRenderDiagnostics.sessionDirectory(filesDir, activityId)
        + (detailed ? '/render.json' : '/capability.json');
      if (!fs.accessSync(path)) return undefined;
      const size: number = fs.statSync(path).size;
      if (size <= 0 || size > MAX_RECORD_BYTES) throw new Error('电脑诊断文件大小无效');
      const record = JSON.parse(fs.readTextSync(path)) as StoredDiagnostic;
      const recordActivityId: number = Number.isFinite(record.activityId) ? record.activityId : 0;
      if (record === undefined || record === null || (record.schema !== 1 && record.schema !== 2)
        || record.product !== ProductBuildProfile.product
        || recordActivityId !== activityId
        || typeof record.id !== 'string' || !new RegExp('^[a-f0-9-]{36}$').test(record.id)
        || typeof record.version !== 'string' || !Number.isFinite(record.capturedAt) || record.capturedAt <= 0
        || record.detailed !== detailed || typeof record.text !== 'string' || record.text.length === 0
        || utf8ByteLength(record.text) > MAX_DIAGNOSTIC_BYTES) throw new Error('电脑诊断文件格式无效');
      const text: string = 'AMCL_DESKTOP_RENDER_DIAGNOSTIC_V1\n'
        + 'product=' + record.product + '\nappVersion=' + record.version
        + '\nactivityId=' + recordActivityId
        + '\ncapturedAt=' + new Date(record.capturedAt).toISOString()
        + '\nprobe=' + (record.detailed ? 'full-render-diagnostics' : 'capability-only')
        + '\n说明：这是独立电脑环境探针，采集时间与游戏会话可能不同。\n\n' + record.text;
      const attachment: RenderDiagnosticAttachment = {
        id: record.id, activityId: recordActivityId, capturedAt: record.capturedAt,
        detailed: record.detailed, text: text };
      return attachment;
    } catch (error) {
      AppLogger.warn(TAG, 'Cannot read saved desktop diagnostic', error, LOG_DOMAIN_UI);
      return undefined;
    }
  }

  static read(filesDir: string, activityId: number = 0): RenderDiagnosticAttachment | undefined {
    if (!ProductRenderDiagnostics.enabled) return undefined;
    return ProductRenderDiagnostics.readFile(filesDir, true, activityId)
      ?? ProductRenderDiagnostics.readFile(filesDir, false, activityId);
  }

  static appendForShare(content: string, diagnostic: RenderDiagnosticAttachment | undefined): string {
    if (!ProductRenderDiagnostics.enabled || diagnostic === undefined) return content;
    const attachment: string = '\n\n===== 电脑渲染专用诊断（完整输出） =====\n'
      + sanitizeLogForExport(diagnostic.text, LogExportTarget.LOGSHARE, Number.MAX_SAFE_INTEGER);
    const budget: number = exportLimitOf(LogExportTarget.LOGSHARE) - utf8ByteLength(attachment);
    if (budget < 1024) throw new Error('完整电脑诊断超过分享上限，请复制诊断结果');
    const body: string = sanitizeLogForExport(content, LogExportTarget.LOGSHARE, Number.MAX_SAFE_INTEGER);
    return truncateUtf8HeadTail(body, budget) + attachment;
  }
}
