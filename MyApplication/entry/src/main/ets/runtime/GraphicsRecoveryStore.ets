/** 父子图形重试的私有文件控制面。只保存启动身份和失败原因，不保存账号凭据。
 * UUID 与原始字符串键固定协议；failure→claimed 原子重命名实现最多消费一次。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { stringToUtf8, writeEvidenceTextAtomic } from 'commons';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { GraphicsRecoveryTicket, GraphicsRecoveryFailure } from './GraphicsRecoveryPolicy';

export class GraphicsRecoveryStore {
  /** 仅保存设置指纹，避免自定义 JVM 参数中可能存在的凭据进入恢复票据。 */
  static preferenceHash(text: string): string {
    const digest = cryptoFramework.createMd('SHA256');
    digest.updateSync({ data: stringToUtf8(text) });
    let hash: string = '';
    for (const byte of digest.digestSync().data) hash += byte.toString(16).padStart(2, '0');
    return hash;
  }
  private static directory(filesDir: string): string { return filesDir + '/graphics-recovery'; }
  private static path(filesDir: string, id: string, suffix: string): string {
    if (!new RegExp('^[0-9a-f-]{36}$').test(id)) throw new Error('Invalid graphics recovery identity');
    return GraphicsRecoveryStore.directory(filesDir) + '/' + id + '.' + suffix + '.json';
  }
  private static write(filesDir: string, id: string, suffix: string, data: Record<string, Object>): void {
    const directory: string = GraphicsRecoveryStore.directory(filesDir);
    try { fs.mkdirSync(directory, true); } catch (error) { if (!fs.statSync(directory).isDirectory()) throw error as Error; }
    const path: string = GraphicsRecoveryStore.path(filesDir, id, suffix);
    if (fs.accessSync(path)) throw new Error('Graphics recovery record already exists');
    const text: string = JSON.stringify(data);
    const bytes: Uint8Array = stringToUtf8(text);
    if (bytes.byteLength > 16384) throw new Error('Graphics recovery record exceeds limit');
    // stringToUtf8 返回预分配缓冲区的有效子视图，不能把整个 backing buffer 写入文件。
    // 共用已验证的原子文本写入器：只写有效字节，循环处理短写，提交后同步目录，失败清暂存。
    writeEvidenceTextAtomic(path, text);
  }
  private static read(filesDir: string, id: string, suffix: string): Record<string, Object> | undefined {
    try {
      const path: string = GraphicsRecoveryStore.path(filesDir, id, suffix);
      if (fs.statSync(path).size > 16384) return undefined;
      const value: Record<string, Object> = JSON.parse(fs.readTextSync(path)) as Record<string, Object>;
      return value !== null && value['schema'] === 1 && value['id'] === id ? value : undefined;
    } catch (_) { return undefined; }
  }
  static create(filesDir: string, ticket: GraphicsRecoveryTicket): void {
    const data: Record<string, Object> = { 'schema': 1, 'id': ticket.id, 'parentPid': ticket.parentPid,
      'activityId': ticket.activityId, 'rootActivityId': ticket.rootActivityId, 'attempt': ticket.attempt,
      'createdAt': ticket.createdAt, 'version': ticket.version, 'mcDir': ticket.mcDir, 'gameDir': ticket.gameDir,
      'jdk': ticket.jdk, 'xmx': ticket.xmx, 'preferenceStamp': ticket.preferenceStamp, 'retryProfile': ticket.retryProfile };
    if (ticket.diagnosticInjected !== undefined) data['diagnosticInjected'] = ticket.diagnosticInjected;
    GraphicsRecoveryStore.write(filesDir, ticket.id, 'request', data);
  }
  static ticket(filesDir: string, id: string): GraphicsRecoveryTicket | undefined {
    const v = GraphicsRecoveryStore.read(filesDir, id, 'request');
    if (v === undefined) return undefined;
    const textKeys: string[] = ['version', 'mcDir', 'gameDir', 'jdk', 'preferenceStamp', 'retryProfile'];
    const numberKeys: string[] = ['parentPid', 'activityId', 'rootActivityId', 'attempt', 'createdAt', 'xmx'];
    for (const key of textKeys) if (typeof v[key] !== 'string') return undefined;
    for (const key of numberKeys) if (typeof v[key] !== 'number' || !Number.isSafeInteger(v[key] as number) || (v[key] as number) < 0) return undefined;
    const ticket: GraphicsRecoveryTicket = { id: id, parentPid: v['parentPid'] as number, activityId: v['activityId'] as number,
      rootActivityId: v['rootActivityId'] as number, attempt: v['attempt'] as number, createdAt: v['createdAt'] as number,
      version: v['version'] as string, mcDir: v['mcDir'] as string, gameDir: v['gameDir'] as string,
      jdk: v['jdk'] as string, xmx: v['xmx'] as number, preferenceStamp: v['preferenceStamp'] as string,
      retryProfile: v['retryProfile'] as string };
    if (typeof v['diagnosticInjected'] === 'boolean') ticket.diagnosticInjected = v['diagnosticInjected'] as boolean;
    return ticket;
  }
  static report(filesDir: string, failure: GraphicsRecoveryFailure): void {
    const data: Record<string, Object> = { 'schema': 1, 'id': failure.id, 'parentPid': failure.parentPid,
      'activityId': failure.activityId, 'childPid': failure.childPid, 'createdAt': failure.createdAt,
      'profile': failure.profile, 'nextProfile': failure.nextProfile, 'stage': failure.stage, 'code': failure.code,
      'presentCount': failure.presentCount, 'automatic': failure.automatic };
    if (failure.diagnosticInjected !== undefined) data['diagnosticInjected'] = failure.diagnosticInjected;
    GraphicsRecoveryStore.write(filesDir, failure.id, 'failure', data);
  }
  static failure(filesDir: string, id: string): GraphicsRecoveryFailure | undefined {
    const v = GraphicsRecoveryStore.read(filesDir, id, 'failure');
    if (v === undefined) return undefined;
    const textKeys: string[] = ['profile', 'nextProfile', 'stage', 'code'];
    const numberKeys: string[] = ['parentPid', 'activityId', 'childPid', 'createdAt', 'presentCount'];
    for (const key of textKeys) if (typeof v[key] !== 'string') return undefined;
    for (const key of numberKeys) if (typeof v[key] !== 'number' || !Number.isSafeInteger(v[key] as number) || (v[key] as number) < 0) return undefined;
    if (typeof v['automatic'] !== 'boolean') return undefined;
    const failure: GraphicsRecoveryFailure = { id: id, parentPid: v['parentPid'] as number,
      activityId: v['activityId'] as number, childPid: v['childPid'] as number, createdAt: v['createdAt'] as number,
      profile: v['profile'] as string, nextProfile: v['nextProfile'] as string, stage: v['stage'] as string,
      code: v['code'] as string, presentCount: v['presentCount'] as number, automatic: v['automatic'] as boolean };
    if (typeof v['diagnosticInjected'] === 'boolean') failure.diagnosticInjected = v['diagnosticInjected'] as boolean;
    return failure;
  }
  static claim(filesDir: string, id: string): boolean {
    try {
      const destination: string = GraphicsRecoveryStore.path(filesDir, id, 'claimed');
      if (fs.accessSync(destination)) return false;
      fs.renameSync(GraphicsRecoveryStore.path(filesDir, id, 'failure'), destination); return true;
    } catch (_) { return false; }
  }
}
