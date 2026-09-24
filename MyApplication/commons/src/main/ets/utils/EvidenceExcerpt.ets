/** 用户主动请求的上传节选。只处理已冻结脱敏副本，原始账本不变。 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { EvidenceExportSnapshot, FrozenEvidenceFile, sealEvidenceExportSnapshot } from './EvidenceExportSnapshot';
import { EvidenceTextCursor, evidenceTextDigest, writeEvidenceTextAtomic } from './EvidenceIo';
import { allocateExportBudget, ExportPartDemand } from './LogExportBudget';
import { utf8ByteLength } from './LogExport';
import { ensureDirSync, removeDirRecursive } from './FileUtils';

function priority(file: FrozenEvidenceFile): number {
  if (file.role === 'crash-report' || file.role === 'jvm-fatal' || file.role === 'system-crash') return 0;
  if (file.role === 'minecraft-main') return 1;
  if (file.role === 'launcher' || file.role === 'public-summary') return 2;
  return 3;
}

/** 头尾都保留完整逻辑行，字节与行数各自有预算；超长单行以明确省略标记说明。 */
async function excerptFile(file: FrozenEvidenceFile, bytes: number, lines: number): Promise<string> {
  const usable: number = bytes - 512;
  if (usable < 128 || lines < 5) throw new Error('所选文件过多，无法给每份证据保留最小节选，请减少文件');
  const headBytes: number = Math.floor(usable * 0.3);
  const tailBytes: number = usable - headBytes;
  const headLines: number = Math.max(1, Math.floor((lines - 3) * 0.3));
  const tailLines: number = Math.max(1, lines - 3 - headLines);
  const head: string[] = [];
  const tail: string[] = [];
  let headUsed: number = 0;
  let tailUsed: number = 0;
  let headClosed: boolean = false;
  let pending: string = '';
  const cursor = new EvidenceTextCursor();
  try {
    await cursor.open(file.path);
    let eof: boolean = false;
    while (!eof || pending.length > 0) {
      if (pending.indexOf('\n') < 0 && !eof) {
        const page = await cursor.read(); pending += page.text; eof = page.eof;
        if (pending.indexOf('\n') < 0 && !eof) continue;
      }
      if (pending.length === 0) break;
      const end: number = pending.indexOf('\n');
      const line: string = (end < 0 ? pending : pending.substring(0, end)) + '\n';
      pending = end < 0 ? '' : pending.substring(end + 1);
      const size: number = utf8ByteLength(line);
      if (!headClosed && head.length < headLines && headUsed + size <= headBytes) {
        head.push(line); headUsed += size;
      } else {
        headClosed = true;
        tail.push(line); tailUsed += size;
        while (tail.length > tailLines || tailUsed > tailBytes) tailUsed -= utf8ByteLength(tail.shift() ?? '');
      }
    }
  } finally { await cursor.close(); }
  const marker: string = '\n[AMCL 用户确认的上传节选：原脱敏文件 ' + file.bytes + ' 字节 / '
    + file.lines + ' 行；保留文件头尾，中间内容省略。完整证据保留在本地。]\n';
  return head.join('') + marker + tail.join('');
}

export async function createEvidenceExcerptSnapshot(original: EvidenceExportSnapshot,
  maxBytes: number, maxLines: number): Promise<EvidenceExportSnapshot> {
  const files: FrozenEvidenceFile[] = original.files.filter((file: FrozenEvidenceFile): boolean => file.name !== '_amcl/evidence-manifest.json');
  const demands: ExportPartDemand[] = files.map((file: FrozenEvidenceFile): ExportPartDemand => {
    return { id: file.name, bytes: file.bytes, priority: priority(file), floorBytes: priority(file) <= 1 ? 32768 : 8192 };
  });
  const lineDemands: ExportPartDemand[] = files.map((file: FrozenEvidenceFile): ExportPartDemand => {
    return { id: file.name, bytes: file.lines, priority: priority(file), floorBytes: 20 };
  });
  // 公开清单保留独立预算，不从某个正文尾部扣除。
  const byteBudget: number = maxBytes - files.length * 2048 - 4096;
  const lineBudget: number = maxLines - files.length * 14 - 32;
  if (byteBudget <= 0 || lineBudget <= 0) throw new Error('文件清单已超过服务预算，请减少所选文件');
  const grants = allocateExportBudget(demands, byteBudget);
  const lineGrants = allocateExportBudget(lineDemands, lineBudget);
  const result: EvidenceExportSnapshot = { activityId: original.activityId, revision: original.revision,
    createdAt: Date.now(), directory: original.directory + '-excerpt-' + Date.now(), digest: '',
    redactionVersion: original.redactionVersion, files: [] };
  try {
    for (let index = 0; index < files.length; index++) {
      const file = files[index];
      const path: string = result.directory + '/' + file.name;
      ensureDirSync(path.substring(0, path.lastIndexOf('/')));
      if (!grants[index].truncated && !lineGrants[index].truncated) {
        fs.copyFileSync(file.path, path);
        result.files.push({ name: file.name, path: path, role: file.role, bytes: file.bytes,
          sourceBytes: file.sourceBytes, digest: file.digest, lines: file.lines, state: file.state, reason: file.reason,
          rawSha256: file.rawSha256, captureMode: file.captureMode, verification: file.verification });
      } else {
        const text: string = await excerptFile(file, grants[index].granted, lineGrants[index].granted);
        writeEvidenceTextAtomic(path, text);
        result.files.push({ name: file.name, path: path, role: file.role, bytes: utf8ByteLength(text),
          sourceBytes: file.sourceBytes, digest: evidenceTextDigest(text), lines: text.split('\n').length,
          state: 'partial', reason: '用户主动生成的上传节选，原始证据保留在本地',
          rawSha256: file.rawSha256, captureMode: 'excerpt', verification: 'excerpt-of-verified-snapshot' });
      }
    }
    // 主概览不得继续声称附件完整；节选与原快照使用不同正文/摘要，AI 同样能看到降级事实。
    const diagnosis = result.files.find((file: FrozenEvidenceFile): boolean => file.name === '_amcl/diagnosis.txt');
    if (diagnosis !== undefined) {
      const text: string = '[AMCL UPLOAD EXCERPT: selected attachments may omit middle ranges; see evidence-manifest.json]\n'
        + fs.readTextSync(diagnosis.path);
      writeEvidenceTextAtomic(diagnosis.path, text);
      diagnosis.bytes = utf8ByteLength(text); diagnosis.lines = text.split('\n').length;
      diagnosis.digest = evidenceTextDigest(text); diagnosis.state = 'partial';
      diagnosis.reason = '上传节选，完整原件保留在本地';
    }
    sealEvidenceExportSnapshot(result);
    return result;
  } catch (e) {
    try { removeDirRecursive(result.directory); } catch (ignored) { /* 尚未创建 */ }
    throw new Error((e as Error).message);
  }
}
