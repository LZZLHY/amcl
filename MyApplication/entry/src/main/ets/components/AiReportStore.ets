/**
 * AI 报告的本地结果与来源索引。
 * 正文单独原子保存，列表只读取小型索引；索引绑定会话、分享实例与快照摘要。
 * 本模块不发网络请求，不保存撤回 token，也不把作者后台的分析当作客户端报告。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { ensureDirSync, evidenceTextDigest, evidenceFileStamp, writeEvidenceTextAtomic, utf8ByteLength } from 'commons';
import { aiPreviewText } from './ActivityUiModel';

/** 分析启动时确定的来源；空摘要表示旧调用方尚未携带快照身份，不能推断为最新快照。 */
export interface AiReportSource {
  shareId: string;
  apiBaseUrl: string;
  snapshotDigest: string;
}

/** 索引不含正文和凭据，供活动列表低成本读取；正文标记用于拒绝不完整或错配写入。 */
export interface SavedAiReport {
  schema: number;
  sessionKey: number;
  shareId: string;
  apiBaseUrl: string;
  snapshotDigest: string;
  completedAt: number;
  summary: string;
  bodyDigest: string;
  bodyStamp: string;
  bodyBytes: number;
}

const MAX_REPORT_BYTES: number = 4 * 1024 * 1024;
const MAX_INDEX_BYTES: number = 8192;

/** 只从正整数会话号派生本地路径，绝不接受服务端提供的绝对路径。 */
function reportBase(filesDir: string, sessionKey: number): string {
  if (filesDir.length === 0 || !Number.isSafeInteger(sessionKey) || sessionKey <= 0) throw new Error('AI 报告会话标识无效');
  return filesDir + '/logs/ai/' + sessionKey + '.report';
}

/**
 * 正文写入成功且已 fsync 后才发布索引；任何异常交给调用方显示“尚未保存”。
 * 即使进程恰好在两次原子写入之间退出，读取时也会凭文件标记拒绝错配的旧索引。
 */
export function saveAiReport(filesDir: string, sessionKey: number, text: string, source: AiReportSource): SavedAiReport {
  const base: string = reportBase(filesDir, sessionKey);
  const bytes: number = utf8ByteLength(text);
  if (bytes <= 0 || bytes > MAX_REPORT_BYTES) throw new Error('AI 报告为空或超过本地保存上限');
  ensureDirSync(filesDir + '/logs/ai');
  writeEvidenceTextAtomic(base + '.md', text);
  const report: SavedAiReport = {
    schema: 1, sessionKey: sessionKey, shareId: source.shareId, apiBaseUrl: source.apiBaseUrl,
    snapshotDigest: source.snapshotDigest, completedAt: Date.now(), summary: aiPreviewText(text),
    bodyDigest: evidenceTextDigest(text), bodyStamp: evidenceFileStamp(base + '.md'), bodyBytes: bytes,
  };
  writeEvidenceTextAtomic(base + '.json', JSON.stringify(report));
  return report;
}

/**
 * 读取小型索引并核验正文存在及文件标记。不存在返回 undefined，损坏抛错。
 * “没有报告”和“读取失败”必须由 UI 分别呈现，不能把存储错误显示成尚未分析。
 */
export function loadAiReport(filesDir: string, sessionKey: number): SavedAiReport | undefined {
  try {
  const base: string = reportBase(filesDir, sessionKey);
  if (!fs.accessSync(base + '.json')) {
    if (fs.accessSync(base + '.md')) throw new Error('AI 报告索引未完成，本地正文仍保留');
    return undefined;
  }
  const size: number = fs.statSync(base + '.json').size;
  if (size <= 0 || size > MAX_INDEX_BYTES) throw new Error('AI 报告索引损坏');
  const report = JSON.parse(fs.readTextSync(base + '.json')) as SavedAiReport;
  if (report.schema !== 1 || report.sessionKey !== sessionKey || typeof report.shareId !== 'string'
    || typeof report.apiBaseUrl !== 'string' || typeof report.snapshotDigest !== 'string'
    || typeof report.summary !== 'string' || typeof report.bodyDigest !== 'string'
    || typeof report.bodyStamp !== 'string' || typeof report.bodyBytes !== 'number'
    || report.bodyBytes <= 0 || report.bodyBytes > MAX_REPORT_BYTES) throw new Error('AI 报告索引无效');
  if (!fs.accessSync(base + '.md') || evidenceFileStamp(base + '.md') !== report.bodyStamp) {
    throw new Error('AI 报告正文未完整保存，请重新分析');
  }
  return report;
  } catch (e) {
    // 系统 IO 和格式异常统一向上报告；禁止返回 undefined 掩盖损坏或无权限。
    throw new Error('本地 AI 报告读取失败：' + (e as Error).message);
  }
}

/** 仅详情页按需加载全文并核验摘要，不让活动列表同时读入所有长回答。 */
export function loadAiReportBody(filesDir: string, report: SavedAiReport): string {
  try {
  const base: string = reportBase(filesDir, report.sessionKey);
  if (fs.statSync(base + '.md').size !== report.bodyBytes) throw new Error('AI 报告正文大小不匹配');
  const text: string = fs.readTextSync(base + '.md');
  if (evidenceTextDigest(text) !== report.bodyDigest) throw new Error('AI 报告正文校验失败');
  return text;
  } catch (e) { throw new Error('AI 报告正文读取失败：' + (e as Error).message); }
}
