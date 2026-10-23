/**
 * 手机本机调试连接。端口可由用户按系统无线调试页面填写，只连接loopback。
 * TCP连通不等于用户已信任；随机挑战经daemon shell写出并传回，才认定开发者调试可用。
 * 不读取未公开的设置键，也不把无法读取设置误报成“已关闭”。
 */
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import testNapi from 'libentry.so';
import { SideloadFiles } from './SideloadFiles';

export class SideloadConnection {
  /**
   * 本设备系统授权窗实际保留180秒；旧12秒窗口会先关闭host，使用户稍后允许已失效请求。
   * 保持同一会话190秒并留少量握手余量，不重发tconn，也不以等待结束代替nonce/UDID证明。
   * 显式取消仍终止后续步骤；已进入Native的单条命令沿用底层有界超时，不能假装被立即中断。
   */
  private static readonly AUTHORIZATION_WAIT_MS: number = 190000;
  private hostPort: number = 0;
  private devicePort: number = 10178;
  private root: string;
  private checking: Promise<string> | undefined = undefined;
  private udid: string = '';
  private closing: boolean = false;
  /** 可公开诊断的候选来源，不包含设备身份或授权材料。 */
  discoveryMethod: string = 'known-port';
  /** 记录原生发现接口抛错的累计次数；回退仍可继续，但不能把ABI缺失或调用失败静默吞掉。 */
  discoveryFailures: number = 0;

  constructor(root: string) {
    this.root = root;
    // 只记住已通过完整调试验证的端口，不保存IP、设备标识或信任材料。
    const path = root + '/connection-port.json';
    try {
      if (fs.accessSync(path) && fs.statSync(path).size < 128) {
        const value = JSON.parse(fs.readTextSync(path)) as Record<string, Object>;
        const port = Number(value['port']);
        if (value['schema'] === 1 && Number.isInteger(port) && port > 0 && port <= 65535) this.devicePort = port;
      }
    } catch (_) { /* 旧提示不可读时继续发现本机端口，不把它当作更新失败。 */ }
  }
  deviceUdid(): string { return this.udid; }
  currentPort(): number { return this.devicePort; }

  /** 只接受系统页面显示的数字端口；不开放主机地址或任意命令输入。 */
  setDevicePort(value: string): void {
    if (!new RegExp('^[0-9]{1,5}$').test(value) || Number(value) < 1 || Number(value) > 65535) {
      throw new Error('请输入无线调试页面显示的端口（1–65535）');
    }
    if (this.checking !== undefined) throw new Error('正在检查连接，请稍后修改端口');
    this.devicePort = Number(value);
  }

  /** 同一时刻复用一个检查；返回设备UDID仅交给证书服务，不呈现或记录到普通日志。 */
  check(): Promise<string> {
    if (this.checking !== undefined) return this.checking;
    this.closing = false;
    this.checking = this.checkOnce().finally((): void => { this.checking = undefined; });
    return this.checking;
  }

  private async checkOnce(): Promise<string> {
    this.udid = '';
    // 优先询问实时端口，只有发现服务不可用时才尝试上次经信任验证的端口。
    // 发现不能代替授权，后面仍以完整 HDC 握手和随机文件往返确认本设备。
    let discovered = 0;
    try { discovered = await testNapi.discoverSideloadPort(); }
    catch (_) {
      // 不保存异常正文或设备授权内容；公开计数使既有支持差异回退可以被诊断核实。
      this.discoveryFailures++;
    }
    if (this.closing) throw new Error('调试连接检查已取消');
    this.discoveryMethod = discovered > 0 ? 'local-discovery' : 'known-port';
    if (discovered > 0 && discovered <= 65535) this.devicePort = discovered;
    try { await this.probePort(this.devicePort); }
    catch (_) { throw new Error('未发现可用的本机调试端口，请开启无线调试；返回后会自动重新获取'); }
    if (this.closing) throw new Error('调试连接检查已取消');
    this.hostPort = await testNapi.startSideloadHdc(this.root + '/hdc');
    if (this.closing) throw new Error('调试连接检查已取消');
    if (this.hostPort <= 0) throw new Error('无法启动更新连接，请重新打开应用后重试');
    const nonce = util.generateRandomUUID().replace(new RegExp('-', 'g'), '');
    const remote = '/data/local/tmp/amcl-update-check-' + nonce;
    const local = this.root + '/connection-' + nonce + '.txt';
    let channelReady = false;
    try {
      await this.command(['tconn', '127.0.0.1:' + this.devicePort], false);
      // tconn返回可能早于daemon完成信任握手；以实际随机文件往返收敛，不能把返回0当作已连接。
      const deadline = Date.now() + SideloadConnection.AUTHORIZATION_WAIT_MS;
      while (!this.closing && Date.now() < deadline) {
        try {
          await this.command(['shell', 'printf ' + SideloadFiles.quote(nonce + '\\n') + ' > ' + SideloadFiles.quote(remote)]);
          // 关闭可能发生在Native shell等待中；返回后不能再启动最长180秒的file命令。
          if (this.closing) break;
          await this.command(['file', 'recv', remote, local]);
          if (this.closing) break;
          if (fs.accessSync(local) && fs.statSync(local).size <= 4096 && fs.readTextSync(local).trim() === nonce) {
            channelReady = true; break;
          }
        } catch (_) { /* 握手尚未完成时有限等待，仍须真实文件证明，旧数据不能放行。 */ }
        if (this.closing) break;
        await new Promise<void>((resolve): void => { setTimeout(resolve, 500); });
      }
      if (!channelReady || this.closing) throw new Error('连接验证未完成');
      // bm在重定向到普通文件时可能quick_exit丢失stdio缓冲。保留daemon原始输出通道，
      // 由私有HDC客户端收集返回帧写入本应用文件，不能把丢失输出误判成设备未授权。
      await this.command(['shell', 'bm get -u'], true, local);
      if (this.closing) throw new Error('调试连接检查已取消');
      if (fs.statSync(local).size > 4096) throw new Error('设备标识返回过大');
      const udid = SideloadConnection.parseUdid(fs.readTextSync(local));
      await this.command(['shell', 'rm -f ' + SideloadFiles.quote(remote)]);
      if (this.closing) throw new Error('调试连接检查已取消');
      this.udid = udid;
      SideloadFiles.write(this.root + '/connection-port.json', JSON.stringify({ schema: 1, port: this.devicePort }));
      return this.udid;
    } catch (_) {
      throw new Error(channelReady ? '调试通道已连接，但设备标识查询失败，请重新检查' :
        '尚未完成调试连接验证，请允许设备上的调试提示后重新检查');
    } finally {
      if (fs.accessSync(local)) fs.unlinkSync(local);
      // 只清理本次挑战文件；检查失败时不再等待第二个网络超时。
    }
  }

  /** TCP探测仅确认本机端口可达，仍须后续握手、随机文件和UDID验证才算连接完成。 */
  private async probePort(port: number): Promise<void> {
    const tcp = socket.constructTCPSocketInstance();
    try { await tcp.connect({ address: { address: '127.0.0.1', port: port, family: 1 }, timeout: 1500 }); }
    finally { await tcp.close().catch((): void => {}); }
  }

  /** 只解析官方固定前缀及合法端口；尾随命令、负数、零或溢出都不能进入连接参数。 */
  static parseDiscoveredPort(body: string): number {
    const match = new RegExp('^OHOS HDC-([0-9]{1,5})$').exec(body.trim());
    if (match === null) return 0;
    const port = Number(match[1]);
    return port > 0 && port <= 65535 ? port : 0;
  }

  /** 只接受独占一行的64位UDID，空输出、重复标识和错误文字不提供签名资格。 */
  static parseUdid(body: string): string {
    const ids = body.trim().split(new RegExp('[\\r\\n]+')).filter((line: string): boolean => new RegExp('^[0-9a-fA-F]{64}$').test(line));
    if (ids.length !== 1) throw new Error('未读取到唯一设备标识');
    return ids[0].toUpperCase();
  }

  /** 业务层仅传固定配方；HDC返回码不能单独证明bm安装成功。 */
  async command(args: string[], targeted: boolean = true, privateOutputPath?: string): Promise<void> {
    if (this.hostPort <= 0) throw new Error('调试连接尚未准备完成');
    let argv = ['hdc', '-s', '127.0.0.1:' + this.hostPort, '-p'];
    if (targeted) argv = argv.concat(['-t', '127.0.0.1:' + this.devicePort]);
    const command = argv.concat(args).join('\t');
    const code = privateOutputPath === undefined ? await testNapi.runSideloadHdcCommand(command) :
      await testNapi.runSideloadHdcCommand(command, privateOutputPath);
    if (code !== 0) throw new Error('更新连接执行失败：' + code);
  }

  /**
   * 文件发送完成后通过daemon自身的sha256sum再次核对落盘字节，最多重试一次完整传输。
   * 校验通过前调用方不能派发安装；取消/断连不重新发送，临时摘要文件始终清理。
   */
  async sendVerified(local: string, remote: string, expectedSha: string): Promise<void> {
    if (!new RegExp('^[0-9a-f]{64}$').test(expectedSha)) throw new Error('无效的传输摘要');
    const result = this.root + '/received-' + util.generateRandomUUID().replace(new RegExp('-', 'g'), '') + '.txt';
    try {
      for (let attempt = 0; attempt < 2; attempt++) {
        if (this.closing) throw new Error('更新连接已关闭');
        try {
          await this.command(['file', 'send', local, remote]);
          await this.command(['shell', 'sha256sum ' + SideloadFiles.quote(remote)], true, result);
          if (fs.accessSync(result) && fs.statSync(result).size <= 4096) {
            const response = fs.readTextSync(result).trim();
            if (new RegExp('^' + expectedSha + '[ \\t]+').test(response)) return;
          }
        } catch (_) { /* 保留原始包，仅在本连接仍活动时进行一次有界重传。 */ }
      }
      throw new Error('安装包传送不完整，已停止安装，请重试更新');
    } finally { if (fs.accessSync(result)) fs.unlinkSync(result); }
  }

  /** 先等待检查退出，再停止本应用host；不关闭系统无线调试或其他电脑的会话。 */
  async close(): Promise<void> {
    this.closing = true;
    if (this.checking !== undefined) await this.checking.catch((): string => '');
    await testNapi.stopSideloadHdc();
    this.hostPort = 0;
  }
}
