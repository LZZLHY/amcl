/**
 * 游戏会话内的离线纹理服务。仅绑定127.0.0.1，准备阶段冻结PNG字节、身份和签名；
 * 运行期只从内存返回既定profile/纹理，不读写账号、不接受登录、不依赖外网。
 * 真正游戏宿主持有本对象并在stop释放，页面隐藏或重建不改变其生命周期。
 */
import { socket, http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppearanceAsset, OfflineAppearance } from 'account';
import { GameSessionOwnedResource } from './GameSessionHost';
import { encodeStandardBase64, stringToUtf8, utf8ToString, evidenceHex } from 'commons';
import { OfflineHttpRequest, offlineAssetPath, offlineProfileId, parseOfflineHttpRequest,
  offlineTextureValue, offlinePublicKeyPem, offlineResponseHead, OFFLINE_HTTP_HEADER_LIMIT,
  OFFLINE_HTTP_BODY_LIMIT } from './OfflineAppearanceProtocol';

/** 三项都在JVM创建前冻结；prefetched避免同步premain等待ArkTS回调产生死锁。 */
export interface OfflineAppearanceLaunch {
  apiRoot: string;
  prefetched: string;
}
interface OfflineServiceMeta { serverName: string; implementationName: string; implementationVersion: string; }
interface OfflineServiceRoot { meta: OfflineServiceMeta; skinDomains: string[]; signaturePublickey: string; }
interface OfflineTextureProperty { name: string; value: string; signature?: string; }
interface OfflineProfile { id: string; name: string; properties: OfflineTextureProperty[]; }
interface OfflineSimpleProfile { id: string; name: string; }
/** 每个TCP连接独立持有分片和超时，completed围栏阻止重复发送/关闭。 */
interface OfflineConnection {
  socket: socket.TCPSocketConnection;
  bytes: Uint8Array;
  completed: boolean;
  closed: boolean;
  timer: number;
}
interface OfflineFrozenTexture { hash: string; bytes: Uint8Array; }
/** 请求计数包含准备阶段probe；readyProbeRequests用于从游戏消费计数中扣除。 */
export interface OfflineAppearanceStats {
  profileRequests: number;
  textureRequests: number;
  readyProbeRequests: number;
  activeConnections: number;
}

export class OfflineAppearanceServer implements GameSessionOwnedResource {
  private server: socket.TCPSocketServer | undefined = undefined;
  private connections: Set<OfflineConnection> = new Set<OfflineConnection>();
  private textures: Map<string, Uint8Array> = new Map<string, Uint8Array>();
  private starting: Promise<OfflineAppearanceLaunch> | undefined = undefined;
  private closing: Promise<void> | undefined = undefined;
  private cancelled: boolean = false;
  private ready: boolean = false;
  private rootJson: string = '';
  private signedProfile: string = '';
  private unsignedProfile: string = '';
  private uuid: string = '';
  private username: string = '';
  private profileRequests: number = 0;
  private textureRequests: number = 0;
  private readyProbeRequests: number = 0;
  /** 自检完成后仅首个真实profile/PNG请求与最终计数写日志，避免每帧/缓存查询刷屏。 */
  private probed: boolean = false;
  private gameProfileObserved: boolean = false;
  private gameTextureObserved: boolean = false;
  private note: (message: string) => void;

  /** 日志只接收阶段、计数、内容摘要；不导出密钥或用户文件正文。 */
  constructor(note: (message: string) => void) { this.note = note; }

  /** 一个对象只准备一次；被关闭的对象不能借迟到Promise重新打开端口。 */
  start(filesDir: string, uuid: string, username: string, appearance: OfflineAppearance): Promise<OfflineAppearanceLaunch> {
    if (this.starting !== undefined || this.cancelled) return Promise.reject(new Error('离线外观会话已使用'));
    this.starting = this.prepare(filesDir, uuid, username, appearance);
    return this.starting;
  }

  /** 值快照用于日志/验收，调用者不能修改内部计数或连接集合。 */
  statistics(): OfflineAppearanceStats {
    return { profileRequests: this.profileRequests, textureRequests: this.textureRequests,
      readyProbeRequests: this.readyProbeRequests, activeConnections: this.connections.size };
  }

  /**
   * 不等待UI，先围栏新请求，再等正在进行的listen/签名完成后释放原对象。
   * prepare失败使用release而非递归close，避免close等待自身启动Promise的循环等待。
   */
  close(): Promise<void> {
    if (this.closing !== undefined) return this.closing;
    this.cancelled = true; this.ready = false;
    this.closing = this.closeAfterPreparation();
    return this.closing;
  }

  private async closeAfterPreparation(): Promise<void> {
    if (this.starting !== undefined) { try { await this.starting; } catch (_) { /* 失败的原prepare已执行release。 */ } }
    await this.release();
  }

  /** 准备全程只保留当前账号快照；即使原库稍后删文件，本局PNG仍保持原始内容。 */
  private async prepare(filesDir: string, uuid: string, username: string,
    appearance: OfflineAppearance): Promise<OfflineAppearanceLaunch> {
    try {
      this.uuid = offlineProfileId(uuid); this.username = username;
      if (username.trim().length === 0 || username.length > 128) throw new Error('离线角色名无效');
      const skin: OfflineFrozenTexture | undefined = appearance.skin === undefined ? undefined : this.freeze(filesDir, appearance.skin, 'skin');
      const cape: OfflineFrozenTexture | undefined = appearance.cape === undefined ? undefined : this.freeze(filesDir, appearance.cape, 'cape');
      if (skin === undefined && cape === undefined) throw new Error('没有可加载的离线外观');
      if (skin !== undefined) this.textures.set(skin.hash, skin.bytes);
      if (cape !== undefined) this.textures.set(cape.hash, cape.bytes);
      // 非对称生成与签名都使用异步API；私钥只在本方法的准备期引用，不序列化/落盘。
      const pair = await cryptoFramework.createAsyKeyGenerator('RSA2048').generateKeyPair();
      this.assertCurrent();
      const publicKey: string = offlinePublicKeyPem(pair.pubKey.getEncoded().data);
      const root: OfflineServiceRoot = { meta: { serverName: 'AMCL Local Appearance',
        implementationName: 'AMCL', implementationVersion: '1' }, skinDomains: ['127.0.0.1'], signaturePublickey: publicKey };
      this.rootJson = JSON.stringify(root);
      const server = socket.constructTCPSocketServerInstance(); this.server = server;
      await server.listen({ address: '127.0.0.1', port: 0, family: 1 });
      this.assertCurrent();
      // 官方契约要求listen成功后订阅connect。此时尚未发布URL，也不允许JVM提前请求。
      server.on('connect', (connection: socket.TCPSocketConnection): void => { this.accept(connection); });
      server.on('error', (error: BusinessError): void => { this.note('offline appearance socket error code=' + error.code); });
      const address = await server.getLocalAddress(); this.assertCurrent();
      if (address.address !== '127.0.0.1' || !Number.isSafeInteger(address.port) || (address.port ?? 0) <= 0) {
        throw new Error('本机纹理服务未取得有效回环端口');
      }
      const apiRoot: string = 'http://127.0.0.1:' + address.port + '/';
      const value: string = offlineTextureValue(apiRoot, this.uuid, username, appearance.model,
        skin?.hash ?? '', cape?.hash ?? '', Date.now());
      const sign = cryptoFramework.createSign('RSA2048|PKCS1|SHA1');
      await sign.init(pair.priKey);
      const signature = await sign.sign({ data: stringToUtf8(value) });
      const verify = cryptoFramework.createVerify('RSA2048|PKCS1|SHA1');
      await verify.init(pair.pubKey);
      if (!await verify.verify({ data: stringToUtf8(value) }, signature)) throw new Error('本地纹理签名自检失败');
      this.assertCurrent();
      const signed: OfflineProfile = { id: this.uuid, name: username,
        properties: [{ name: 'textures', value: value, signature: encodeStandardBase64(signature.data) }] };
      const unsigned: OfflineProfile = { id: this.uuid, name: username, properties: [{ name: 'textures', value: value }] };
      this.signedProfile = JSON.stringify(signed); this.unsignedProfile = JSON.stringify(unsigned); this.ready = true;
      // 真正穿过TCP、HTTP解析、profile和PNG响应；listen成功或构造URL不单独算服务就绪。
      await this.probe(apiRoot, skin, cape); this.assertCurrent();
      this.readyProbeRequests = this.profileRequests + this.textureRequests;
      this.probed = true;
      this.note('offline appearance ready revision=' + appearance.revision + ' textures=' + this.textures.size +
        ' profileProbe=' + this.profileRequests + ' textureProbe=' + this.textureRequests);
      return { apiRoot: apiRoot, prefetched: encodeStandardBase64(stringToUtf8(this.rootJson)) };
    } catch (error) {
      this.cancelled = true; this.ready = false;
      try { await this.release(); } catch (cleanupError) { this.note('offline appearance preparation cleanup failed: ' + (cleanupError as Error).message); }
      throw error as Error;
    }
  }

  /** 最大两个1MiB静态PNG；验证普通目录/文件、精确读取和SHA256，禁止链接及任意沙箱访问。 */
  private freeze(filesDir: string, asset: AppearanceAsset, kind: string): OfflineFrozenTexture {
    try {
      if (asset.kind !== kind) throw new Error('离线外观资产类型不匹配');
      const path: string = offlineAssetPath(filesDir, asset.relativePath, asset.sha256);
      const directory = fs.lstatSync(filesDir + '/account-textures');
      const entry = fs.lstatSync(path);
      if (!directory.isDirectory() || directory.isSymbolicLink() || !entry.isFile() || entry.isSymbolicLink()) {
        throw new Error('离线外观资产不是普通沙箱文件');
      }
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const size: number = fs.statSync(file.fd).size;
        if (size < 24 || size > 1024 * 1024) throw new Error('离线外观资产大小无效');
        const bytes = new Uint8Array(size); let offset: number = 0;
        while (offset < size) {
          const buffer = new ArrayBuffer(size - offset);
          const got: number = fs.readSync(file.fd, buffer, { length: buffer.byteLength });
          if (got <= 0) throw new Error('离线外观资产读取不完整');
          bytes.set(new Uint8Array(buffer, 0, got), offset); offset += got;
        }
        if (bytes[0] !== 137 || bytes[1] !== 80 || bytes[2] !== 78 || bytes[3] !== 71 ||
            bytes[4] !== 13 || bytes[5] !== 10 || bytes[6] !== 26 || bytes[7] !== 10 || this.digest(bytes) !== asset.sha256) {
          throw new Error('离线外观资产内容校验失败，请重新导入');
        }
        return { hash: asset.sha256, bytes: bytes };
      } finally { fs.closeSync(file); }
    } catch (error) { throw error as Error; }
  }

  private digest(bytes: Uint8Array): string {
    try {
      const md = cryptoFramework.createMd('SHA256'); md.updateSync({ data: bytes }); return evidenceHex(md.digestSync().data);
    } catch (error) { throw error as Error; }
  }

  private assertCurrent(): void { if (this.cancelled) throw new Error('离线外观准备已取消'); }

  /** 接收上限和5秒期限都按连接计算；慢发送者不会永久占用本局资源。 */
  private accept(connection: socket.TCPSocketConnection): void {
    if (this.cancelled || this.connections.size >= 16) { connection.close().catch((): void => {}); return; }
    const state: OfflineConnection = { socket: connection, bytes: new Uint8Array(0), completed: false, closed: false, timer: -1 };
    this.connections.add(state);
    state.timer = setTimeout((): void => { this.finish(state).catch((error: Error): void => { this.note(error.message); }); }, 5000);
    connection.on('close', (): void => { this.finish(state, false).catch((): void => {}); });
    connection.on('error', (): void => { this.finish(state).catch((): void => {}); });
    connection.on('message', (event: socket.SocketMessageInfo): void => {
      if (state.completed || state.closed || this.cancelled) return;
      const next = new Uint8Array(event.message);
      if (state.bytes.byteLength + next.byteLength > OFFLINE_HTTP_HEADER_LIMIT + OFFLINE_HTTP_BODY_LIMIT + 4) {
        state.completed = true; this.finish(state).catch((): void => {}); return;
      }
      const joined = new Uint8Array(state.bytes.byteLength + next.byteLength);
      joined.set(state.bytes); joined.set(next, state.bytes.byteLength); state.bytes = joined;
      const request: OfflineHttpRequest = parseOfflineHttpRequest(joined);
      if (request.state === 'pending') return;
      state.completed = true; state.bytes = new Uint8Array(0);
      this.respond(state, request).catch((error: Error): void => { this.note('offline appearance response failed: ' + error.message); })
        .finally((): void => { this.finish(state).catch((): void => {}); });
    });
  }

  /** 只有明确纹理路由可成功；join/hasJoined不会伪造外部服务器认证。 */
  private async respond(state: OfflineConnection, request: OfflineHttpRequest): Promise<void> {
    if (request.state === 'error') { await this.send(state, '400 Bad Request', 'text/plain', new Uint8Array(0), false); return; }
    if (!this.ready || this.cancelled) { await this.send(state, '503 Service Unavailable', 'text/plain', new Uint8Array(0), false); return; }
    const path: string = request.target.split('?')[0]; const head: boolean = request.method === 'HEAD';
    if (request.method !== 'POST' && path === '/') {
      await this.send(state, '200 OK', 'application/json; charset=utf-8', stringToUtf8(this.rootJson), head); return;
    }
    if (request.method !== 'POST' && path === '/sessionserver/session/minecraft/profile/' + this.uuid) {
      const signed: boolean = new RegExp('(?:[?&])unsigned=false(?:&|$)').test(request.target);
      this.profileRequests++;
      if (this.probed && !this.gameProfileObserved) {
        this.gameProfileObserved = true;
        this.note('offline appearance game profile request signed=' + signed + ' count=' + this.profileRequests);
      }
      await this.send(state, '200 OK', 'application/json; charset=utf-8', stringToUtf8(signed ? this.signedProfile : this.unsignedProfile), head); return;
    }
    if (request.method !== 'POST' && new RegExp('^/sessionserver/session/minecraft/profile/[0-9a-f]{32}$').test(path)) {
      await this.send(state, '204 No Content', 'application/json', new Uint8Array(0), head); return;
    }
    if (request.method === 'POST' && path === '/api/profiles/minecraft') {
      try {
        const raw = JSON.parse(utf8ToString(request.body)) as Object;
        if (!Array.isArray(raw)) throw new Error('姓名查询必须是数组');
        const names = raw as string[];
        if (names.length > 16 || names.some((name: string): boolean => typeof name !== 'string' || name.length > 128)) throw new Error('姓名查询超限');
        const result: OfflineSimpleProfile[] = names.some((name: string): boolean => name.toLowerCase() === this.username.toLowerCase()) ?
          [{ id: this.uuid, name: this.username }] : [];
        await this.send(state, '200 OK', 'application/json; charset=utf-8', stringToUtf8(JSON.stringify(result)), false);
      } catch (_) { await this.send(state, '400 Bad Request', 'text/plain', new Uint8Array(0), false); }
      return;
    }
    if (request.method !== 'POST' && new RegExp('^/textures/[0-9a-f]{64}$').test(path)) {
      const bytes: Uint8Array | undefined = this.textures.get(path.substring('/textures/'.length));
      if (bytes !== undefined) {
        this.textureRequests++;
        if (this.probed && !this.gameTextureObserved) {
          this.gameTextureObserved = true;
          this.note('offline appearance game PNG request sha256=' + path.substring('/textures/'.length) + ' bytes=' + bytes.byteLength);
        }
        await this.send(state, '200 OK', 'image/png', bytes, head); return;
      }
    }
    const authentication: boolean = path.startsWith('/authserver/') || path === '/sessionserver/session/minecraft/join' ||
      path === '/sessionserver/session/minecraft/hasJoined';
    await this.send(state, authentication ? '403 Forbidden' : '404 Not Found', 'text/plain', new Uint8Array(0), head);
  }

  /** 单条响应后断开；PNG按64KiB顺序发送，避免一条大send影响其他游戏Socket回调。 */
  private async send(state: OfflineConnection, status: string, type: string, bytes: Uint8Array, head: boolean): Promise<void> {
    if (state.closed || this.cancelled) return;
    await state.socket.send({ data: offlineResponseHead(status, type, bytes.byteLength) });
    if (head) return;
    for (let offset: number = 0; offset < bytes.byteLength; offset += 65536) {
      if (state.closed || this.cancelled) return;
      await state.socket.send({ data: bytes.slice(offset, offset + 65536).buffer as ArrayBuffer });
    }
  }

  /** 原连接只退休一次，先移除本地事件和期限，再等待平台close；不会修改后来连接。 */
  private async finish(state: OfflineConnection, closeSocket: boolean = true): Promise<void> {
    if (state.closed) return;
    state.closed = true; state.completed = true;
    if (state.timer >= 0) clearTimeout(state.timer); state.timer = -1;
    this.connections.delete(state); state.bytes = new Uint8Array(0);
    try { state.socket.off('message'); state.socket.off('close'); state.socket.off('error'); }
    finally { if (closeSocket) await state.socket.close(); }
  }

  private async probe(root: string, skin: OfflineFrozenTexture | undefined, cape: OfflineFrozenTexture | undefined): Promise<void> {
    const rootBody: string = await this.probeText(root);
    if (rootBody !== this.rootJson) throw new Error('本机纹理元数据探测不一致');
    const profileBody: string = await this.probeText(root + 'sessionserver/session/minecraft/profile/' + this.uuid + '?unsigned=false');
    if (profileBody !== this.signedProfile) throw new Error('本机角色纹理探测不一致');
    if (skin !== undefined) await this.probeTexture(root, skin);
    if (cape !== undefined && cape.hash !== skin?.hash) await this.probeTexture(root, cape);
  }

  /** 本机probe设短期限，失败只中止本局准备；不循环重开端口或静默丢弃用户外观。 */
  private async probeText(url: string): Promise<string> {
    const client = http.createHttp();
    try {
      const response = await client.request(url, { method: http.RequestMethod.GET, expectDataType: http.HttpDataType.STRING,
        usingCache: false, connectTimeout: 3000, readTimeout: 3000 });
      if (response.responseCode !== 200 || typeof response.result !== 'string') throw new Error('本机纹理HTTP自检失败');
      return response.result;
    } catch (error) { throw error as Error; }
    finally { client.destroy(); }
  }

  private async probeTexture(root: string, texture: OfflineFrozenTexture): Promise<void> {
    const client = http.createHttp();
    try {
      const response = await client.request(root + 'textures/' + texture.hash, { method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER, usingCache: false, connectTimeout: 3000, readTimeout: 3000 });
      if (response.responseCode !== 200 || !(response.result instanceof ArrayBuffer) ||
          this.digest(new Uint8Array(response.result as ArrayBuffer)) !== texture.hash) throw new Error('本机PNG内容探测失败');
    } catch (error) { throw error as Error; }
    finally { client.destroy(); }
  }

  /** server.close只停监听，必须显式关闭已接受连接；任何单个失败不跳过其他资源。 */
  private async release(): Promise<void> {
    this.ready = false;
    const server: socket.TCPSocketServer | undefined = this.server; this.server = undefined;
    let failed: boolean = false;
    if (server !== undefined) {
      try { server.off('connect'); server.off('error'); } catch (_) { failed = true; }
      try { await server.close(); } catch (_) { failed = true; }
    }
    for (const connection of Array.from(this.connections)) {
      try { await this.finish(connection); } catch (_) { failed = true; }
    }
    if (this.probed) this.note('offline appearance closed profileRequests=' + this.profileRequests +
      ' textureRequests=' + this.textureRequests + ' readyProbeRequests=' + this.readyProbeRequests + ' cleanupFailed=' + failed);
    this.textures.clear(); this.rootJson = ''; this.signedProfile = ''; this.unsignedProfile = '';
    if (failed) throw new Error('离线纹理服务有资源关闭失败，进程结束后释放');
  }
}
