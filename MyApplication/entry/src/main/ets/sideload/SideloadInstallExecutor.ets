/**
 * 自更新安装副作用的唯一执行边界。协调器拥有业务状态/Registry租约，本类只拥有本轮
 * flock、持久fence、受控HDC配方和回执证据。prepare不调用bm；dispatch先调用同步
 * durable checkpoint回调，恢复只观察或原子撤销，绝不自动重新派发。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import testNapi from 'libentry.so';
import { SideloadConnection } from './SideloadConnection';
import { SideloadFiles } from './SideloadFiles';
import { UpdateInstallGate } from './UpdateInstallGate';
import { InstallFence } from './InstallFence';
import { BmTerminalEvidence, BmLogSnapshot } from './BmTerminalEvidence';
import { InstallExecutionIdentity, InstallExecutionObservation, InstallExecutionGuards,
  InstallExecutionError, SideloadInstallProtocol } from './SideloadInstallProtocol';
export { InstallExecutionIdentity, InstallExecutionObservation, InstallExecutionGuards, InstallExecutionError } from './SideloadInstallProtocol';

export class SideloadInstallExecutor {
  private filesDir: string;
  private connection: SideloadConnection;
  private gate: UpdateInstallGate = new UpdateInstallGate();
  private fence: InstallFence;
  private activeKey: string = '';
  private prepared: boolean = false;
  private dispatchRequested: boolean = false;
  /** 只在本进程从无fence建立的新attempt中成立；冷启动不得据默认false推断没派发过。 */
  private noDispatchCertificate: string = '';
  private releaseProof: InstallExecutionObservation | undefined = undefined;
  private proofIdentity: string = '';
  private proofKind: string = '';
  private completedKey: string = '';
  private cleanupKeys: Set<string> = new Set();

  constructor(filesDir: string, connection: SideloadConnection) {
    this.filesDir = filesDir; this.connection = connection; this.fence = new InstallFence(filesDir);
  }
  private key(identity: InstallExecutionIdentity): string { return identity.installId + ':' + identity.nonce; }
  /** 公开观察对象可被调用方持有，清fence的授权事实另存不可变文本，不能靠修改对象升级。 */
  private authorize(identity: InstallExecutionIdentity, proof: InstallExecutionObservation): void {
    this.releaseProof = proof; this.proofKind = proof.kind;
    this.proofIdentity = SideloadInstallProtocol.record(identity, 'proof', false, 0);
  }
  private local(identity: InstallExecutionIdentity): string {
    const path = this.filesDir + '/sideload-update/install/' + identity.installId;
    SideloadFiles.ensureDirectory(path); return path;
  }
  private unknown(identity: InstallExecutionIdentity): InstallExecutionObservation {
    return { kind: 'unknown', safeToRelease: false, bmSubmitted: true, code: 0,
      message: '尚未取得本次系统安装的完成证据，请保持无线调试后核实', installId: identity.installId, nonce: identity.nonce };
  }
  private guards(guards: InstallExecutionGuards): void {
    try { guards.assertCurrent(); } catch (_) { throw new InstallExecutionError('cancelled', '本轮更新已撤销'); }
    try { guards.assertForeground(); } catch (_) { throw new InstallExecutionError('foreground', '已暂停安装，返回 AMCL 后会继续'); }
  }
  private validate(identity: InstallExecutionIdentity): void {
    if ((identity.protocol ?? 2) !== 2 || !SideloadInstallProtocol.validate(identity) ||
      !identity.signedPath.startsWith(this.filesDir + '/sideload-update/tasks/')) {
      throw new InstallExecutionError('preparation', '安装事务身份或内部路径无效');
    }
  }
  private async send(identity: InstallExecutionIdentity, name: string, remote: string): Promise<void> {
    const local = this.local(identity) + '/' + name;
    await this.connection.sendVerified(local, remote + '/' + name, await SideloadFiles.sha256(local));
  }

  /** EX后先持久fence，之后才上传受控配方；每个await后重新核对owner及前台。 */
  async prepare(identity: InstallExecutionIdentity, guards: InstallExecutionGuards): Promise<void> {
    this.validate(identity);
    const key = this.key(identity);
    if (this.completedKey === key) throw new InstallExecutionError('outcome-unknown', '已完结的安装身份不可再次准备');
    if (this.activeKey && this.activeKey !== key) throw new InstallExecutionError('outcome-unknown', '已有其他安装事务');
    if (this.fence.blocked() && this.activeKey !== key) throw new InstallExecutionError('outcome-unknown', '请先核实上一次安装结果');
    if (this.dispatchRequested) throw new InstallExecutionError('outcome-unknown', '安装执行权不可重复准备');
    // 本次调用尚未经过任何effect。先排除旧fence/其他owner，才登记仅本进程有效的
    // NoInvocation证书；随后前台撤销、游戏SH或EX获取失败也可安全结束本次准备。
    // 冷启动默认空证书绝不能证明旧派发不存在，同nonce已派发也不能重新取得证书。
    this.activeKey = key; this.noDispatchCertificate = key;
    this.guards(guards);
    if (this.prepared && this.activeKey === key) return;
    this.gate.acquire(this.filesDir, key);
    this.fence.arm(identity);
    await this.connection.check(); this.guards(guards);
    if (await SideloadFiles.sha256(identity.signedPath) !== identity.signedSha256) throw new InstallExecutionError('preparation', '已准备安装包发生变化');
    this.guards(guards);
    const remote = SideloadInstallProtocol.remote(identity); const local = this.local(identity);
    await this.connection.command(['shell', 'umask 077; mkdir -p ' + SideloadFiles.quote(remote)]); this.guards(guards);
    SideloadFiles.write(local + '/capability.sh', SideloadInstallProtocol.capabilityScript(remote));
    await this.send(identity, 'capability.sh', remote); this.guards(guards);
    await this.connection.command(['shell', 'sh ' + SideloadFiles.quote(remote + '/capability.sh')], true, local + '/capability.txt');
    this.guards(guards);
    let capability = '';
    try { if (fs.accessSync(local + '/capability.txt')) capability = fs.readTextSync(local + '/capability.txt').trim(); }
    catch (_) { /* 未得到精确能力收据时不能派发；读取错误不回显任意shell文字。 */ }
    const mode = capability === 'AMCL_INSTALL_CAPABILITY_V2:link' ? 'link' :
      capability === 'AMCL_INSTALL_CAPABILITY_V2:flock-rename' ? 'flock-rename' : '';
    if (!mode) {
      throw new InstallExecutionError('preparation', '设备未通过可靠安装协议能力检查，请自行下载安装包');
    }
    this.fence.setMode(identity, mode);
    const ticks = testNapi.sideloadInstallClockTicks();
    SideloadFiles.write(local + '/clock-calibration.sh', SideloadInstallProtocol.clockCalibrationScript(identity, remote, ticks));
    await this.send(identity, 'clock-calibration.sh', remote); this.guards(guards);
    await this.connection.command(['shell', 'sh ' + SideloadFiles.quote(remote + '/clock-calibration.sh')]); this.guards(guards);
    const clockProcess = await this.read(identity, 'clock-process.json', 2048);
    const clockLog = await this.read(identity, 'clock-axis.log', 65536);
    if (!BmTerminalEvidence.clockAligned(identity, clockProcess, clockLog)) {
      throw new InstallExecutionError('preparation', '未取得可靠的系统安装观测时间轴，请保留下载包后重试');
    }
    this.guards(guards);
    SideloadFiles.write(local + '/worker.sh', SideloadInstallProtocol.workerScript(identity, remote, ticks, mode));
    SideloadFiles.write(local + '/claim.record', SideloadInstallProtocol.record(identity, 'claimed', true, 2, mode));
    SideloadFiles.write(local + '/revoke.record', SideloadInstallProtocol.record(identity, 'revoked', false, 4, mode));
    await this.connection.sendVerified(identity.signedPath, remote + '/candidate.hap', identity.signedSha256); this.guards(guards);
    for (const name of ['claim.record', 'revoke.record', 'worker.sh']) { await this.send(identity, name, remote); this.guards(guards); }
    const durable = local + '/remote-durable.txt';
    await this.connection.command(['shell', 'set -e; fsync ' + ['candidate.hap', 'claim.record', 'revoke.record', 'worker.sh']
      .map((name: string): string => SideloadFiles.quote(remote + '/' + name)).join(' ') + '; fsync ' +
      SideloadFiles.quote(remote) + '; printf AMCL_INSTALL_REMOTE_DURABLE'], true, durable);
    let confirmed = false;
    try { confirmed = fs.readTextSync(durable).trim() === 'AMCL_INSTALL_REMOTE_DURABLE'; }
    catch (_) { /* HDC传输返回0不等于shell同步成功，缺精确标记不能继续。 */ }
    if (!confirmed) throw new InstallExecutionError('preparation', '设备安装包尚未可靠保存，请重试准备');
    this.guards(guards); this.prepared = true;
  }

  /** checkpoint抛错时没有发请求；一旦请求入队，网络错误保持unknown且必须经decision裁决。 */
  async dispatch(identity: InstallExecutionIdentity, commitDispatchIntent: () => void,
    guards: InstallExecutionGuards): Promise<InstallExecutionObservation> {
    this.validate(identity); this.guards(guards);
    if (!this.prepared || this.activeKey !== this.key(identity) || this.dispatchRequested) {
      throw new InstallExecutionError('outcome-unknown', '安装执行权不可重复派发');
    }
    commitDispatchIntent(); // 同步可靠Repository提交成功后才进入外部副作用窗口。
    this.fence.markDispatching(identity); // schema2 Preparing不得与任何可能迟到的请求并存。
    this.dispatchRequested = true; this.noDispatchCertificate = '';
    const remote = SideloadInstallProtocol.remote(identity);
    try {
      await this.connection.command(['shell', 'setsid /bin/sh ' + SideloadFiles.quote(remote + '/worker.sh') +
        ' > ' + SideloadFiles.quote(remote + '/worker.log') + ' 2>&1 < /dev/null &']);
      return this.unknown(identity);
    } catch (_) { throw new InstallExecutionError('outcome-unknown', '安装已请求，调试断连不能证明系统安装失败'); }
    finally { this.releaseProcessLeases(identity); await this.connection.close(); }
  }

  /** read只使用内部生成路径，捕获/截断/不存在均返回空，不把错误文字回显为终态。 */
  private async read(identity: InstallExecutionIdentity, name: string, maxBytes: number = 8192): Promise<string> {
    // remote name可能含CLAIM绑定的证据子目录；本地接收件只用UUID，不能隐式生成不存在的父目录。
    const local = this.local(identity) + '/observed-' + util.generateRandomUUID();
    try {
      await this.connection.command(['file', 'recv', SideloadInstallProtocol.remote(identity) + '/' + name, local]);
      if (!fs.statSync(local).isFile() || fs.statSync(local).size >= maxBytes) return '';
      return fs.readTextSync(local);
    } catch (_) { return ''; }
    finally { try { if (fs.accessSync(local)) fs.unlinkSync(local); } catch (_) { /* 清理不改变观测证据。 */ } }
  }
  /**
   * baseline/post必须实际取得普通文件，按原始字节读取并算SHA；缺失、短读或超界返回undefined。
   * 0B文件仍返回明确存在的空Uint8Array和空文件SHA，不能把HDC错误文字或读取失败''当baseline。
   * 本地接收件使用独占UUID名，所有句柄和临时件只属于本次读取，异常不授予清fence许可。
   */
  private async readSnapshot(identity: InstallExecutionIdentity, name: string): Promise<BmLogSnapshot | undefined> {
    const local = this.local(identity) + '/snapshot-' + util.generateRandomUUID();
    let file: fs.File | undefined = undefined;
    try {
      await this.connection.command(['file', 'recv', SideloadInstallProtocol.remote(identity) + '/' + name, local]);
      const stat = fs.statSync(local);
      if (!stat.isFile() || !Number.isSafeInteger(stat.size) || stat.size < 0 || stat.size >= 65536) return undefined;
      const bytes = new Uint8Array(stat.size); file = fs.openSync(local, fs.OpenMode.READ_ONLY);
      let copied = 0;
      while (copied < bytes.byteLength) {
        const chunk = new ArrayBuffer(bytes.byteLength - copied);
        const count = fs.readSync(file.fd, chunk, { length: chunk.byteLength });
        if (count <= 0 || count > chunk.byteLength) return undefined;
        bytes.set(new Uint8Array(chunk, 0, count), copied); copied += count;
      }
      fs.closeSync(file); file = undefined;
      // 摘要必须消费刚读取的同一份bytes，不能另开文件把第二次读取的SHA套到首次快照上。
      const digest = cryptoFramework.createMd('SHA256');
      // HarmonyOS HCF的update要求DataBlob长度大于0；真实空baseline已经通过普通文件和
      // 完整读取核验，应使用SDK允许的“零次update后digest”计算空内容摘要。仍不能把
      // 不存在/读取失败补成空文件，也不通过硬编码空SHA跳过同一份bytes的摘要流程。
      if (bytes.byteLength > 0) await digest.update({ data: bytes });
      const result = await digest.digest();
      let sha256 = '';
      for (const byte of result.data) sha256 += byte.toString(16).padStart(2, '0');
      return { bytes: bytes, sha256: sha256 };
    } catch (_) { return undefined; }
    finally {
      if (file !== undefined) { try { fs.closeSync(file); } catch (_) { /* 未完整读取仍是unknown。 */ } }
      try { if (fs.accessSync(local)) fs.unlinkSync(local); } catch (_) { /* 清理不升级证据。 */ }
    }
  }
  /** 旧schema脚本不认识decision，旧install-returned永远不能升级为合格BMS终态。 */
  async observe(identity: InstallExecutionIdentity): Promise<InstallExecutionObservation> {
    if ((identity.protocol ?? 2) !== 2) return this.unknown(identity);
    this.validate(identity);
    try {
      await this.connection.check();
      const mode = this.fence.mode(identity);
      if (['link', 'flock-rename'].indexOf(mode) < 0) return this.unknown(identity);
      const decisionBody = await this.read(identity, 'decision');
      const decision = SideloadInstallProtocol.parse(identity, decisionBody, mode);
      if (decision.kind === 'revoked' && decision.safeToRelease) { this.authorize(identity, decision); return decision; }
      const returned = SideloadInstallProtocol.parse(identity, await this.read(identity, 'result.json'), mode);
      if (decision.kind === 'claimed' && returned.kind === 'cli-returned') {
        const authority = SideloadInstallProtocol.evidenceAuthority(identity, decisionBody, mode);
        if (authority === undefined) return returned; // 旧v2没有exec前baseline，不能事后补造或升级。
        const directory = authority.directory;
        const process = await this.read(identity, directory + '/bm-process.json', 2048);
        let receipt = await this.read(identity, directory + '/bm-log-evidence.json', 4096);
        if (!receipt) {
          // 原worker完整post超时时仍有持续PID预留。只观察/封存原日志，不再派发bm；
          // 远端已有sealed receipt时脚本不会覆写，旧v2无authority也不会进入此恢复路径。
          try {
            await this.connection.command(['shell', SideloadInstallProtocol.observeEvidenceScript(identity, authority, decisionBody)]);
            receipt = await this.read(identity, directory + '/bm-log-evidence.json', 4096);
          } catch (_) { return returned; }
        }
        const baseline = await this.readSnapshot(identity, directory + '/bm-before.log');
        const post = await this.readSnapshot(identity, directory + '/bm-terminal.log');
        const terminal = BmTerminalEvidence.classify(identity, authority, process, receipt, baseline, post);
        if (terminal !== undefined) { this.authorize(identity, terminal); return terminal; }
        return returned;
      }
      return decision.kind === 'claimed' ? decision : this.unknown(identity);
    } finally { await this.connection.close(); }
  }
  /**
   * 本进程明知尚未安排dispatch时可证明NoInvocation；冷启动没有该证书必须走remote
   * revoke CAS。输给CLAIM的撤销只观察，不用自身bmSubmitted=false裁决另一个赢家。
   */
  async revoke(identity: InstallExecutionIdentity): Promise<InstallExecutionObservation> {
    if ((identity.protocol ?? 2) !== 2) return this.unknown(identity);
    this.validate(identity);
    if ((this.noDispatchCertificate === this.key(identity) && !this.dispatchRequested) || this.fence.preparing(identity)) {
      const proof: InstallExecutionObservation = { kind: 'pre-install-failed', safeToRelease: true, bmSubmitted: false,
        code: 0, message: '尚未派发系统安装，本次准备已停止', installId: identity.installId, nonce: identity.nonce };
      this.authorize(identity, proof); return proof;
    }
    try {
      await this.connection.check(); const local = this.local(identity) + '/revoke-decision-' + util.generateRandomUUID() + '.txt';
      const remote = SideloadInstallProtocol.remote(identity);
      const mode = this.fence.mode(identity);
      if (['link', 'flock-rename'].indexOf(mode) < 0) return this.unknown(identity);
      // 准备阶段崩溃可能尚未上传revoke记录。只补全一份全新撤销源，不创建CLAIM；
      // 不覆写可能已与decision硬链接的旧inode，避免让已撤销记录出现截断窗口。
      const source = 'revoke-' + util.generateRandomUUID().replace(new RegExp('-', 'g'), '') + '.record';
      await this.connection.command(['shell', 'umask 077; mkdir -p ' + SideloadFiles.quote(remote)]);
      SideloadFiles.write(this.local(identity) + '/' + source, SideloadInstallProtocol.record(identity, 'revoked', false, 4, mode));
      await this.send(identity, source, remote);
      await this.connection.command(['shell', 'fsync ' + SideloadFiles.quote(remote + '/' + source) + '; fsync ' + SideloadFiles.quote(remote)]);
      await this.connection.command(['shell', SideloadInstallProtocol.revokeScript(identity, remote, source, mode)], true, local);
      const observed = fs.accessSync(local) && fs.statSync(local).size < 8192 ?
        SideloadInstallProtocol.parse(identity, fs.readTextSync(local), mode) : this.unknown(identity);
      if (fs.accessSync(local)) fs.unlinkSync(local);
      if (observed.kind === 'revoked' && observed.safeToRelease) this.authorize(identity, observed);
      return observed;
    } catch (_) { return this.unknown(identity); }
    finally { await this.connection.close(); }
  }
  /** 只释放本owner短期FD；不删除fence/decision，也不触碰Coordinator的Registry租约。 */
  releaseProcessLeases(identity: InstallExecutionIdentity): void { this.gate.release(this.key(identity)); }
  /** 协调器先持久保存终态后调用；只接受本Executor实际核实的同一proof对象。 */
  complete(identity: InstallExecutionIdentity, proof: InstallExecutionObservation, installedIdentity: boolean): void {
    if (this.completedKey === this.key(identity)) return; // 旧owner的幂等收尾不触碰新attempt。
    if (proof !== this.releaseProof || !proof.safeToRelease || proof.kind !== this.proofKind ||
      this.proofIdentity !== SideloadInstallProtocol.record(identity, 'proof', false, 0) ||
      proof.installId !== identity.installId || proof.nonce !== identity.nonce ||
      (this.proofKind === 'bms-success' && !installedIdentity)) throw new InstallExecutionError('outcome-unknown', '安装结果或执行权尚未成立');
    if (this.proofKind === 'pre-install-failed' && this.noDispatchCertificate === this.key(identity) &&
      this.activeKey === this.key(identity) && !this.dispatchRequested && !this.fence.blocked()) {
      // guards/gate失败可能连fence都未建立。真实NoInvocation无需抢游戏持有的SH，
      // 也无需访问HDC或删除远端载荷；只关闭本owner可能已取得的FD并清内存许可。
      // 有fence（含读不确定）仍必须进入下方EX下的durable clear，不能借此分支绕过。
      this.releaseProcessLeases(identity); this.finishLocal(identity); return;
    }
    this.gate.acquire(this.filesDir, this.key(identity), true);
    try {
      this.fence.clear(identity); this.cleanupKeys.add(this.key(identity)); this.finishLocal(identity);
    }
    finally { this.releaseProcessLeases(identity); }
  }
  /** 完结一个已核实owner，不把它的内存证书或dispatch标记带到下一次安装。 */
  private finishLocal(identity: InstallExecutionIdentity): void {
    this.completedKey = this.key(identity); this.releaseProof = undefined; this.proofIdentity = ''; this.proofKind = '';
    this.activeKey = ''; this.prepared = false; this.noDispatchCertificate = ''; this.dispatchRequested = false;
  }
  /**
   * 只在安全完结后的当前收尾窗口调用并await；失败是后置清理失败，不改变安装结论。
   * decision/永久锁/claim/revoke/结果日志保留，既不能让执行权复活，也不删除未知candidate。
   */
  async cleanupPayload(identity: InstallExecutionIdentity): Promise<void> {
    const key = this.key(identity);
    if (!this.cleanupKeys.has(key)) return;
    if (this.activeKey) throw new InstallExecutionError('preparation', '已有新的安装准备，稍后清理旧候选');
    const remote = SideloadInstallProtocol.remote(identity);
    const result = this.local(identity) + '/cleanup-' + util.generateRandomUUID() + '.txt';
    try {
      await this.connection.check();
      const payloads = ['candidate.hap', 'worker.sh', 'capability.sh', 'clock-calibration.sh'];
      await this.connection.command(['shell', 'set -e; rm -f ' + payloads.map((name: string): string =>
        SideloadFiles.quote(remote + '/' + name)).join(' ') + '; fsync ' + SideloadFiles.quote(remote) +
        '; printf AMCL_INSTALL_PAYLOAD_CLEAN'], true, result);
      let cleaned = false;
      try { cleaned = fs.accessSync(result) && fs.readTextSync(result).trim() === 'AMCL_INSTALL_PAYLOAD_CLEAN'; }
      catch (_) { /* 缺少精确成功标记仍是待重试清理，不回显普通shell错误。 */ }
      if (!cleaned) {
        throw new InstallExecutionError('preparation', '候选清理尚未确认，可稍后重试');
      }
      this.cleanupKeys.delete(key);
    } finally {
      try { if (fs.accessSync(result)) fs.unlinkSync(result); } catch (_) { /* 本次诊断临时件不影响终态。 */ }
      await this.connection.close();
    }
  }
}
