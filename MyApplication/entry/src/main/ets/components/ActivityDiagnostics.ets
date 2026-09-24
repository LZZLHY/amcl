/**
 * 活动诊断的可重建索引：完整顺序扫描已归属本局的诊断文件，只保存有限的事件摘要。
 * 记录的退出结局不受 ERROR 数量影响；阶段只表示原文观测，不推测进入主菜单/世界。
 * 派生文件放在账本根的独立索引中，不进入 Evidence 文件树或默认公开分享。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { EvidenceFileRecord, EvidenceRole, EvidenceTextCursor, LogEventParser, LogEventRecord,
  LedgerManifest, LedgerState, evidenceReadable, evidenceFileStamp, evidenceTextDigest,
  writeEvidenceTextAtomic, acquireEvidenceLease, releaseEvidenceLease, listLogNoiseRules } from 'commons';

export interface ActivityFinding {
  fileId: string; fileName: string; line: number; endLine: number;
  title: string; explanation: string; occurrences: number; level: number;
}
export interface ActivityPhase {
  key: string; title: string; fileId: string; fileName: string; line: number; detail: string;
}
export interface ActivityDiagnosis {
  contentDigest?: string;
  schema: number; signature: string; activityId: number; complete: boolean;
  sourceCount: number; scannedCount: number; eventCount: number; errorCount: number;
  ignoredEvents: number;
  findings: ActivityFinding[]; phases: ActivityPhase[]; gaps: string[];
}

/** 派生索引也校验正文，避免语法仍合法的损坏 JSON 直接变成 UI 中的诊断结论。 */
function diagnosisDigest(value: ActivityDiagnosis): string {
  const content: Record<string, Object> = { 'schema': value.schema, 'signature': value.signature,
    'activityId': value.activityId, 'complete': value.complete, 'sourceCount': value.sourceCount,
    'scannedCount': value.scannedCount, 'eventCount': value.eventCount, 'errorCount': value.errorCount, 'ignoredEvents': value.ignoredEvents,
    'findings': value.findings, 'phases': value.phases, 'gaps': value.gaps };
  return evidenceTextDigest(JSON.stringify(content));
}

function validDiagnosis(value: ActivityDiagnosis, files: EvidenceFileRecord[]): boolean {
  return value !== null && typeof value === 'object' && Array.isArray(value.findings) && value.findings.length <= 80
    && Array.isArray(value.phases) && value.phases.length <= 6 && Array.isArray(value.gaps)
    && value.findings.every((item: ActivityFinding): boolean => item !== null && typeof item === 'object'
      && typeof item.title === 'string' && typeof item.explanation === 'string' && Number.isSafeInteger(item.line)
      && item.line > 0 && item.endLine >= item.line && files.some((file: EvidenceFileRecord): boolean => file.fileId === item.fileId && file.path === item.fileName))
    && value.phases.every((item: ActivityPhase): boolean => item !== null && typeof item === 'object'
      && typeof item.title === 'string' && typeof item.detail === 'string' && item.line > 0
      && files.some((file: EvidenceFileRecord): boolean => file.fileId === item.fileId && file.path === item.fileName))
    && value.contentDigest === diagnosisDigest(value);
}

/** 只有实际正文且归属不冲突的来源进入自动诊断；GC 等保留在附件，不按普通级别误解。 */
function diagnosticSource(file: EvidenceFileRecord): boolean {
  return evidenceReadable(file) && file.attribution !== 'previous-session' && file.attribution !== 'ambiguous'
    && [EvidenceRole.MINECRAFT_MAIN, EvidenceRole.MINECRAFT_OUTPUT, EvidenceRole.CRASH_REPORT,
      EvidenceRole.JVM_STDERR, EvidenceRole.JVM_FATAL, EvidenceRole.LAUNCHER, EvidenceRole.MINECRAFT_DEBUG,
      EvidenceRole.RENDERER, EvidenceRole.MOBILEGLUES].includes(file.role);
}

/** 建议描述能由当前事件直接支持的排查动作，不仅凭一个库名要求删除游戏或模组。 */
function explanation(text: string): string {
  const low: string = text.toLowerCase();
  if (low.indexOf('unsupportedclassversionerror') >= 0) return '当前 Java 无法读取所需 class 版本。核对本次环境中的 Java 与游戏/模组要求。';
  if (low.indexOf('a potential solution has been determined') >= 0 || low.indexOf('incompatible mods') >= 0) {
    return '加载器已给出依赖或版本调整说明，展开完整事件查看，保留后面的具体建议。';
  }
  if (low.indexOf('outofmemoryerror') >= 0) return '记录到内存不足。核对 JVM 上限与设备剩余内存，内存分享模板可附上 GC 日志。';
  if (new RegExp('mixinapplyerror|mixintransformererror|invalidmixinexception|mixin.*(?:apply failed|injection failed)', 'i').test(low)) {
    return '记录到 Mixin 应用或注入失败。查看完整异常链及对应模组版本，不能仅凭堆栈出现某个模组就认定它是根因。';
  }
  if (low.indexOf('sigsegv') >= 0 || low.indexOf('fatal error has been detected') >= 0) return '记录到原生/JVM 致命错误信号。结合 hs_err、渲染与系统现场查看。';
  return '这是日志中记录的错误事件；是否导致本次退出，需要结合退出事实和相邻上下文判断。';
}

/** 去除显示头部只用于去重摘要；每个保留的问题仍指向第一份原文，不改写正文。 */
function findingTitle(event: LogEventRecord): string {
  return event.title.replace(new RegExp('^(?:\\[[^\\]]+\\]\\s*){1,4}:?\\s*'), '').substring(0, 260);
}

/** 用具体日志语句建立观察节点，不把“开始初始化”改写成“初始化成功”。 */
function phaseOf(event: LogEventRecord, file: EvidenceFileRecord): ActivityPhase | undefined {
  const text: string = event.title;
  let key: string = ''; let title: string = '';
  if (new RegExp('Launch params resolved|LaunchProfile|版本校验|校验版本|PRE_LAUNCH', 'i').test(text)) { key = 'prepare'; title = '启动准备'; }
  else if (new RegExp('JNI_CreateJavaVM|createVM|JVM (?:created|initialized)|JVM_INIT', 'i').test(text)) { key = 'java'; title = 'Java 初始化记录'; }
  else if (new RegExp('Loading Minecraft|Loading [0-9]+ mods|Incompatible mods|ModLauncher|FMLLoader', 'i').test(text)) { key = 'loader'; title = '加载器与模组'; }
  else if (new RegExp('AMCL_RENDERER|GL_VENDOR|GL_RENDERER|graphics_plan_selected|context created|EGL.*(?:error|fail)', 'i').test(text)) { key = 'graphics'; title = '图形环境与上下文'; }
  else if (new RegExp('Preparing start region|Starting integrated minecraft server|Reloading ResourceManager', 'i').test(text)) { key = 'resources'; title = '游戏资源／世界加载记录'; }
  else if (new RegExp('Stopping!|AMCL-SESSION-END|GAME_RETURN', 'i').test(text)) { key = 'exit'; title = '退出记录'; }
  if (key.length === 0) return undefined;
  return { key: key, title: title, fileId: file.fileId, fileName: file.path, line: event.startLine, detail: text.substring(0, 200) };
}

/** 索引只缓存有高精度文件身份的稳定会话；低精度时间无法排除同秒等长重写，重新扫描。 */
function signatureOf(files: EvidenceFileRecord[], manifest: LedgerManifest): string {
  const fingerprints: string[] = [];
  for (const file of files) {
    const stat = fs.statSync(file.localPath);
    if (stat.mtimeNs === undefined || stat.ctimeNs === undefined) return '';
    fingerprints.push(file.fileId + ':' + evidenceFileStamp(file.localPath));
  }
  return evidenceTextDigest('activity-diagnosis-v2|' + manifest.state + '|' + manifest.outcomeSummary + '|' + fingerprints.join('\n'));
}

/** 聚合有界错误列表与阶段观察；重复源只增加出现次数，不声称发生了多次独立崩溃。 */
function collectEvent(result: ActivityDiagnosis, event: LogEventRecord, file: EvidenceFileRecord): void {
  result.eventCount++;
  const phase: ActivityPhase | undefined = phaseOf(event, file);
  if (phase !== undefined && !result.phases.some((item: ActivityPhase): boolean => item.key === phase.key)) result.phases.push(phase);
  const fatal: boolean = event.startLine === 1 && (file.role === EvidenceRole.CRASH_REPORT || file.role === EvidenceRole.JVM_FATAL);
  if (event.level < 2 && !fatal) return;
  result.errorCount++;
  // 只折叠已有证据支持的兼容提示，复用项目噪声注册表；不删除原文、不影响退出裁决。
  // 事件中出现 OOM/致命信号/明确 Mixin 失败时，即使标题含可选功能名称也保留线索。
  const body: string = event.lines.map((line): string => line.text).join('\n');
  const critical: boolean = new RegExp('OutOfMemoryError|UnsupportedClassVersionError|SIGSEGV|a fatal error has been detected|MixinApplyError|MixinTransformerError|InvalidMixinException', 'i').test(body);
  const lowerTitle: string = event.title.toLowerCase();
  if (!fatal && !critical && listLogNoiseRules().some((rule): boolean => lowerTitle.indexOf(rule.needle) >= 0)) {
    result.ignoredEvents++; return;
  }
  const title: string = findingTitle(event);
  if (title.trim().length === 0) return;
  const existing = result.findings.find((item: ActivityFinding): boolean => item.title === title);
  if (existing !== undefined) { existing.occurrences++; return; }
  if (result.findings.length >= 80) return;
  result.findings.push({ fileId: file.fileId, fileName: file.path, line: event.startLine,
    endLine: event.endLine, title: title, explanation: explanation(body), occurrences: 1, level: event.level });
}

/**
 * UI 可随时取消，扫描完成前不保存假“已分析”缓存。读失败只记录对应来源缺口，
 * 其他文件继续扫描；完成率按实际文件数呈现，不显示猜测的 AI 进度。
 */
export async function buildActivityDiagnosis(filesDir: string, manifest: LedgerManifest, files: EvidenceFileRecord[],
  cancelled: () => boolean, progress: (finished: number, total: number) => void): Promise<ActivityDiagnosis> {
  const sources: EvidenceFileRecord[] = files.filter(diagnosticSource);
  const indexPath: string = filesDir + '/logs/ledger/' + manifest.activityId + '/experience-index.json';
  let signature: string = '';
  try { signature = signatureOf(sources, manifest); } catch (e) { /* 文件变化时按实际扫描处理。 */ }
  if (signature.length > 0 && manifest.state !== LedgerState.RUNNING) {
    try {
      if (fs.statSync(indexPath).size < 512 * 1024) {
        const saved = JSON.parse(fs.readTextSync(indexPath)) as ActivityDiagnosis;
        if (saved.schema === 2 && saved.activityId === manifest.activityId && saved.signature === signature
          && saved.complete && validDiagnosis(saved, sources)) return saved;
      }
    } catch (e) { /* 派生索引可重建，不把损坏当成原件丢失。 */ }
  }
  const result: ActivityDiagnosis = { schema: 2, signature: signature, activityId: manifest.activityId, complete: false,
    sourceCount: sources.length, scannedCount: 0, eventCount: 0, errorCount: 0, ignoredEvents: 0, findings: [], phases: [], gaps: [] };
  acquireEvidenceLease(filesDir, manifest.activityId);
  try {
    for (const file of sources) {
      if (cancelled()) throw new Error('诊断索引已取消');
      const cursor = new EvidenceTextCursor(); const parser = new LogEventParser();
      let pending: string = ''; let lineNumber: number = 0; let eof: boolean = false;
      try {
        await cursor.open(file.localPath, file.path.endsWith('.gz'));
        while (!eof) {
          const page = await cursor.read(); eof = page.eof; pending += page.text;
          if (cancelled()) throw new Error('诊断索引已取消');
          if (pending.length > 8 * 1024 * 1024) throw new Error('单行超过诊断预算，请在完整原文查看');
          let newline: number = pending.indexOf('\n');
          while (newline >= 0) {
            let line: string = pending.substring(0, newline); pending = pending.substring(newline + 1);
            if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
            const event = parser.feed(line, ++lineNumber); if (event !== undefined) collectEvent(result, event, file);
            if (lineNumber % 1024 === 0) await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 0); });
            newline = pending.indexOf('\n');
          }
        }
        if (pending.length > 0) { const event = parser.feed(pending, ++lineNumber); if (event !== undefined) collectEvent(result, event, file); }
        const tail = parser.finish(); if (tail !== undefined) collectEvent(result, tail, file);
        result.scannedCount++;
      } catch (e) {
        if (cancelled()) throw new Error('诊断索引已取消');
        result.gaps.push(file.path + '：' + (e as Error).message);
      } finally { await cursor.close(); }
      progress(result.scannedCount, result.sourceCount);
    }
    if (cancelled()) throw new Error('诊断索引已取消');
    const order: string[] = ['prepare', 'java', 'loader', 'graphics', 'resources', 'exit'];
    result.phases.sort((a: ActivityPhase, b: ActivityPhase): number => order.indexOf(a.key) - order.indexOf(b.key));
    result.complete = result.gaps.length === 0;
    result.contentDigest = diagnosisDigest(result);
    // 对变化中的日志不写缓存；新一轮会按实际文件身份继续核对。
    if (signature.length > 0 && manifest.state !== LedgerState.RUNNING && signatureOf(sources, manifest) === signature) {
      try { writeEvidenceTextAtomic(indexPath, JSON.stringify(result)); }
      catch (e) { result.gaps.push('诊断索引未保存，原始日志不受影响'); }
    }
    return result;
  } finally { releaseEvidenceLease(filesDir, manifest.activityId); }
}
