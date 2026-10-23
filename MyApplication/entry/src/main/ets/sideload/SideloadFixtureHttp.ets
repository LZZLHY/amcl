/** default真机夹具的loopback HTTP传输器。只服务固定已暂存HAP，不实现下载/签名/安装业务。 */
import { socket } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

export class SideloadFixtureHttp {
  private server: socket.TCPSocketServer | undefined = undefined;
  private static activeUrls: Set<string> = new Set();
  private url: string = '';
  /** 只有当前固定沙箱HAP服务器真实listen后登记的loopback URL才可作为诊断候选。 */
  static registered(url: string): boolean { return SideloadFixtureHttp.activeUrls.has(url); }
  private source: string = '';
  private active: number = 0;
  requests: number = 0;
  bytesSent: number = 0;

  /** 动态端口真实listen后返回唯一URL，不能用线程创建或预估端口作为就绪依据。 */
  async start(source: string): Promise<string> {
    if (!fs.statSync(source).isFile()) throw new Error('HTTP测试来源不是普通文件');
    this.source = source;
    const server = socket.constructTCPSocketServerInstance(); this.server = server;
    server.on('connect', (connection: socket.TCPSocketConnection): void => {
      if (this.active >= 16) { connection.close(); return; }
      this.active++;
      let request = '', received = false;
      connection.on('message', (event: socket.SocketMessageInfo): void => {
        if (received) return;
        request += new util.TextDecoder().decodeToString(new Uint8Array(event.message));
        if (request.length > 16384) { received = true; this.active--; connection.close(); return; }
        if (!request.includes('\r\n\r\n')) return;
        received = true;
        this.serve(connection, request).catch((): void => {}).finally((): void => { this.active--; connection.close(); });
      });
    });
    await server.listen({ address: '127.0.0.1', port: 0, family: 1 });
    this.url = 'http://127.0.0.1:' + (await server.getLocalAddress()).port + '/candidate.hap';
    SideloadFixtureHttp.activeUrls.add(this.url); return this.url;
  }

  /** Native下载器会探测HEAD和Range；仅实现单段范围，响应范围/总大小与实际字节保持一致。 */
  private async serve(connection: socket.TCPSocketConnection, request: string): Promise<void> {
    const first = request.split('\r\n')[0].split(' ');
    if ((first[0] !== 'GET' && first[0] !== 'HEAD') || first[1] !== '/candidate.hap') {
      await connection.send({ data: 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' }); return;
    }
    this.requests++;
    const total = fs.statSync(this.source).size;
    const match = new RegExp('(?:^|\\r\\n)range:\\s*bytes=([0-9]+)-([0-9]*)', 'i').exec(request);
    let start = 0, end = total - 1;
    if (match !== null) { start = Number(match[1]); if (match[2]) end = Math.min(Number(match[2]), end); }
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || start > end || start >= total) {
      await connection.send({ data: 'HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' }); return;
    }
    const length = end - start + 1;
    const range = match === null ? '' : 'Content-Range: bytes ' + start + '-' + end + '/' + total + '\r\n';
    await connection.send({ data: 'HTTP/1.1 ' + (match === null ? '200 OK' : '206 Partial Content') + '\r\n' +
      'Content-Type: application/octet-stream\r\nAccept-Ranges: bytes\r\nContent-Length: ' + length + '\r\n' + range +
      'Connection: close\r\n\r\n' });
    if (first[0] === 'HEAD') return;
    const file = fs.openSync(this.source, fs.OpenMode.READ_ONLY);
    try {
      // 显式seek一次，后续使用文件当前位置，避免offset含义差异导致重复或跳过数据。
      fs.lseek(file.fd, start, fs.WhenceType.SEEK_SET);
      let left = length;
      const buffer = new ArrayBuffer(65536);
      while (left > 0) {
        const size = fs.readSync(file.fd, buffer, { length: Math.min(left, buffer.byteLength) });
        if (size <= 0) throw new Error('测试来源提前结束');
        await connection.send({ data: buffer.slice(0, size) });
        this.bytesSent += size; left -= size;
      }
    } finally { fs.closeSync(file); }
  }

  /** 生命周期只属于本次prepare；业务完成/失败即关闭本应用测试端口，不触碰系统daemon。 */
  async close(): Promise<void> { SideloadFixtureHttp.activeUrls.delete(this.url); this.url = ''; if (this.server !== undefined) await this.server.close(); this.server = undefined; }
}
