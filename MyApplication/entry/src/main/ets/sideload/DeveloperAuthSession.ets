/**
 * ArkWeb官方开发者登录与每轮更新的登录检查。回调随机码、临时令牌、访问令牌只保留内存；
 * 验证后的登录JWT由独立HUKS仓库保存，下次更新必须再次向官方服务核实，证书不能代替登录。
 * 登录页面不注入JS代理、不读取用户输入；回调在loopback接收，成功交换后通知视图关闭。
 */
import { socket, http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { DeveloperAuthVault, DeveloperCredential, DeveloperCredentialInvalidError } from './DeveloperAuthVault';

export enum DeveloperAuthState {
  Missing = 'missing', Expired = 'expired', Valid = 'valid', Unavailable = 'unavailable', Cancelled = 'cancelled'
}
const EXPIRED_MESSAGE = '华为登录已过期，请重新登录';

export class DeveloperAuthSession {
  private server: socket.TCPSocketServer | undefined = undefined;
  private code: string = '';
  private expiresAt: number = 0;
  private consumed: boolean = false;
  private accessToken: string = '';
  private uid: string = '';
  private teams: string[] = [];
  private authenticatedAt: number = 0;
  private jwtExpiresAt: number = 0;
  private jwt: string = '';
  private vault: DeveloperAuthVault | undefined = undefined;
  private epoch: number = 0;
  private timer: number = -1;
  private complete: (success: boolean, message: string) => void = (): void => {};

  /** 只绑定本机私有存储，初始化本身不读取账号或发起网络请求。 */
  initialize(context: common.UIAbilityContext): void { this.vault = new DeveloperAuthVault(context); }

  /**
   * 每次立即更新都执行：先读加密记录，再向官方JWT检查和团队接口核实。
   * 本地过期或服务端撤销进入重新登录；网络故障保留凭据并等待重试，不能误报为过期。
   */
  async restore(): Promise<DeveloperAuthState> {
    this.close();
    const epoch = this.epoch;
    let saved: DeveloperCredential | undefined;
    try { saved = await this.vault?.read(); }
    catch (error) {
      if (epoch !== this.epoch) return DeveloperAuthState.Cancelled;
      // 只有本域明确坏记录/缺原key属于重新登录；暂态存储/HUKS故障保留凭据并提供重试。
      return error instanceof DeveloperCredentialInvalidError ? DeveloperAuthState.Expired : DeveloperAuthState.Unavailable;
    }
    if (epoch !== this.epoch) return DeveloperAuthState.Cancelled;
    if (saved === undefined) return DeveloperAuthState.Missing;
    if (!saved.jwt || (saved.expiresAt > 0 && saved.expiresAt <= Date.now())) return DeveloperAuthState.Expired;
    try {
      await this.validateJwt(saved.jwt, epoch);
      return epoch === this.epoch ? DeveloperAuthState.Valid : DeveloperAuthState.Cancelled;
    } catch (error) {
      if (epoch !== this.epoch) return DeveloperAuthState.Cancelled;
      this.accessToken = ''; this.teams = []; this.authenticatedAt = 0;
      if (DeveloperAuthSession.isExpired(error as Error)) {
        await this.expireSaved(epoch);
        return DeveloperAuthState.Expired;
      }
      return DeveloperAuthState.Unavailable;
    }
  }

  /** 固定错误分类只传递状态，不把服务响应、用户标识或令牌交给UI。 */
  static isExpired(error: Error): boolean { return error.message === EXPIRED_MESSAGE; }

  /** 接收器先真实listen再生成官方URL；前台WebView会话允许10分钟，不循环申请后台任务。 */
  async begin(complete: (success: boolean, message: string) => void): Promise<string> {
    this.close();
    const epoch = this.epoch;
    this.complete = complete;
    this.code = util.generateRandomUUID().replace(new RegExp('-', 'g'), '');
    this.expiresAt = Date.now() + 10 * 60 * 1000;
    this.consumed = false;
    const server = socket.constructTCPSocketServerInstance();
    this.server = server;
    server.on('connect', (connection: socket.TCPSocketConnection): void => {
      let content = '';
      connection.on('message', (event: socket.SocketMessageInfo): void => {
        content += new util.TextDecoder().decodeWithStream(new Uint8Array(event.message));
        if (content.length > 16384) { connection.close(); return; }
        const split = content.indexOf('\r\n\r\n');
        if (split < 0) return;
        const lengthMatch = new RegExp('(?:^|\\r\\n)content-length:\\s*([0-9]+)', 'i').exec(content.substring(0, split));
        const length = lengthMatch === null ? 0 : Number(lengthMatch[1]);
        if (length > 16384) { connection.close(); return; }
        if (content.length < split + 4 + length) return;
        const request = content; content = '';
        this.receive(connection, request.substring(0, split), request.substring(split + 4, split + 4 + length));
      });
    });
    await server.listen({ address: '127.0.0.1', port: 0, family: 1 });
    if (epoch !== this.epoch) { await server.close(); throw new Error('登录已取消'); }
    const bound = await server.getLocalAddress();
    // 到期主动终止监听；不能只在收到下一份回调时才发现会话过期。
    this.timer = setTimeout((): void => {
      if (epoch !== this.epoch) return;
      this.complete(false, '授权等待超时，请重新登录'); this.close();
    }, 10 * 60 * 1000);
    return 'https://cn.devecostudio.huawei.com/console/DevEcoIDE/apply?port=' + bound.port + '&appid=1007&code=' + this.code;
  }

  /** 关闭和取消使旧回调失效；只清本会话，不修改系统浏览器或其他Web的Cookie。 */
  close(): void {
    this.epoch++;
    if (this.timer >= 0) clearTimeout(this.timer);
    this.timer = -1;
    this.consumed = true; this.code = ''; this.accessToken = ''; this.uid = '';
    this.teams = []; this.authenticatedAt = 0; this.jwt = ''; this.jwtExpiresAt = 0;
    if (this.server !== undefined) this.server.close().catch((): void => {});
    this.server = undefined;
  }

  /** 这里检查的是应用取得的开发者授权，不推断系统华为账号的登录状态。 */
  signedIn(): boolean {
    return this.accessToken.length > 0 && Date.now() - this.authenticatedAt < 5 * 60 * 1000 &&
      (this.jwtExpiresAt === 0 || Date.now() < this.jwtExpiresAt);
  }
  teamIds(): string[] { return this.teams.slice(); }

  /**
   * 令牌仅在服务域用于固定华为签名接口；调用方不能指定任意域名或获取原始认证头。
   * 服务错误只导出数字错误码，防止第三方错误消息回显令牌、CSR或账号资料。
   */
  async request(path: string, method: http.RequestMethod, team: string,
    body?: Object): Promise<Record<string, Object>> {
    const allowed: string[] = ['/api/amis/app-manage/v1/manage/app/brief-info/list',
      '/api/cps/harmony-cert-manage/v1/cert/list', '/api/cps/harmony-cert-manage/v1/cert/add',
      '/api/cps/device-manage/v1/device/list', '/api/cps/device-manage/v1/device/add',
      '/api/cps/provision-manage/v1/provision/list', '/api/cps/provision-manage/v1/ide/real/provision/add',
      '/api/amis/app-manage/v1/objects/url/reapply'];
    if (!this.signedIn()) throw new Error(EXPIRED_MESSAGE);
    if (this.teams.indexOf(team) < 0 || allowed.indexOf(path.split('?')[0]) < 0) throw new Error('无效的签名服务请求');
    const epoch = this.epoch;
    const request = http.createHttp();
    try {
      const response = await request.request('https://connect-api.cloud.huawei.com' + path, {
        method: method, header: { 'oauth2Token': this.accessToken, 'uid': this.uid, 'teamId': team,
          'Content-Type': 'application/json', 'User-Agent': 'DevEco Studio', 'Accept-Language': 'zh-CN' },
        extraData: body === undefined ? '' : JSON.stringify(body), expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000, readTimeout: 15000
      });
      if (epoch !== this.epoch) throw new Error('授权已取消');
      if (response.responseCode === 401) {
        this.accessToken = ''; this.authenticatedAt = 0;
        await this.expireSaved(epoch); throw new Error(EXPIRED_MESSAGE);
      }
      if (response.responseCode !== 200 || typeof response.result !== 'string' || response.result.length > 512 * 1024) {
        throw new Error('华为签名服务暂不可用（HTTP ' + response.responseCode + '）');
      }
      const value = JSON.parse(response.result) as Record<string, Object>;
      const ret = value['ret'] as Record<string, Object>;
      if (ret !== undefined && Number(ret['code']) !== 0) {
        // 部分服务把认证失败放在HTTP200正文中；先重新核实登录，再保留业务错误，避免猜测错误码。
        try { await this.validateJwt(this.jwt, epoch); }
        catch (error) {
          if (DeveloperAuthSession.isExpired(error as Error)) {
            await this.expireSaved(epoch); throw new Error(EXPIRED_MESSAGE);
          }
          throw new Error('无法核实华为登录状态，请检查网络后重试');
        }
        throw new Error('华为签名服务返回错误 ' + Number(ret['code']));
      }
      return value;
    } finally { request.destroy(); }
  }

  /** 只接受已验证官方form POST和当前会话，其他请求没有令牌回显或通用CORS权限。 */
  private receive(connection: socket.TCPSocketConnection, headers: string, body: string): void {
    const first = headers.split('\r\n')[0].split(' ');
    const originMatch = new RegExp('(?:^|\\r\\n)origin:\\s*([^\\r\\n]+)', 'i').exec(headers);
    const origin = originMatch === null ? '' : originMatch[1];
    if (first[0] !== 'POST' || first[1] !== '/callback' ||
      (origin !== 'null' && origin !== '' && origin !== 'https://cn.devecostudio.huawei.com' && origin !== 'https://devecostudio.huawei.com')) {
      connection.close(); return;
    }
    const fields: Record<string, string> = {};
    for (const part of body.split('&')) {
      const split = part.indexOf('=');
      if (split > 0) {
        try { fields[decodeURIComponent(part.substring(0, split))] = decodeURIComponent(part.substring(split + 1).replace(new RegExp('\\+', 'g'), ' ')); }
        catch (_) { connection.close(); return; }
      }
    }
    if (this.consumed || Date.now() > this.expiresAt || fields['code'] !== this.code || !fields['tempToken']) {
      connection.close(); return;
    }
    this.consumed = true;
    connection.send({ data: 'HTTP/1.1 302 Found\r\nLocation: https://cn.devecostudio.huawei.com/console/DevEcoIDE/loginSuccess\r\nCache-Control: no-store\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' })
      .then((): void => { connection.close(); }).catch((): void => {});
    this.exchange(fields['tempToken'], fields['siteId'] ?? '1', this.epoch);
  }

  /** 当前IDE协议只在服务内交换，不把令牌交给Web；普通授权UI只收到成功信号。 */
  private async exchange(tempToken: string, siteId: string, epoch: number): Promise<void> {
    const request = http.createHttp();
    try {
      const sites: Record<string, string> = { '1': 'CN', '5': 'SG', '7': 'DE', '8': 'RU' };
      const temporary = await request.request('https://devecostudio.huawei.com/authrouter/auth/api/temptoken/check?tempToken=' +
        encodeURIComponent(tempToken) + '&site=' + (sites[siteId] ?? 'CN') + '&version=5.0.5&appid=1007',
        { method: http.RequestMethod.GET, expectDataType: http.HttpDataType.STRING, connectTimeout: 15000, readTimeout: 15000 });
      if (temporary.responseCode !== 200 || typeof temporary.result !== 'string') throw new Error('登录令牌交换失败');
      const jwt = temporary.result.trim();
      await this.validateJwt(jwt, epoch);
      if (epoch !== this.epoch) return;
      const credential: DeveloperCredential = { schema: 1, jwt: jwt, expiresAt: this.jwtExpiresAt, savedAt: Date.now() };
      if (this.vault === undefined) throw new Error('登录存储未初始化');
      // 只有完成官方交换与团队核实的新登录，才允许恢复明确丢失的登录域key。
      await this.vault.save(credential, (): boolean => epoch === this.epoch, true);
      if (epoch !== this.epoch) return;
      if (this.timer >= 0) clearTimeout(this.timer);
      this.timer = -1;
      this.server?.close().catch((): void => {}); this.server = undefined;
      this.complete(true, '华为登录已验证，正在继续更新');
    } catch (_) {
      if (epoch === this.epoch) {
        this.complete(false, '华为登录未完成，请重新登录');
        this.close();
      }
    }
    finally { request.destroy(); }
  }

  /** 已保存JWT和新回调共用同一套在线核实；本地读取JWT声明不构成认证成功。 */
  private async validateJwt(jwt: string, epoch: number): Promise<void> {
    if (!jwt || jwt.length > 16384) throw new Error(EXPIRED_MESSAGE);
    const request = http.createHttp();
    try {
      const response = await request.request('https://devecostudio.huawei.com/authrouter/auth/api/jwToken/check',
        { method: http.RequestMethod.GET, header: { 'jwtToken': jwt, 'refresh': 'false' }, expectDataType: http.HttpDataType.STRING,
          connectTimeout: 15000, readTimeout: 15000 });
      if (response.responseCode === 401) throw new Error(EXPIRED_MESSAGE);
      if (response.responseCode !== 200 || typeof response.result !== 'string' || response.result.length > 512 * 1024) {
        throw new Error('开发者服务授权检查暂不可用');
      }
      const result = JSON.parse(response.result) as Record<string, Object>;
      const user = result['userInfo'] as Record<string, Object>;
      if (result['status'] !== true || user === undefined || typeof user['accessToken'] !== 'string' || !user['accessToken']) {
        throw new Error(EXPIRED_MESSAGE);
      }
      if (epoch !== this.epoch) return;
      this.accessToken = user['accessToken'] as string;
      const encoded = (jwt.split('.')[1] ?? '').replace(new RegExp('-', 'g'), '+').replace(new RegExp('_', 'g'), '/');
      const padded = encoded + '='.repeat((4 - encoded.length % 4) % 4);
      const payload = JSON.parse(new util.TextDecoder().decodeWithStream(new util.Base64Helper().decodeSync(padded))) as Record<string, Object>;
      this.uid = String(payload['userId'] ?? '');
      if (!this.uid) throw new Error(EXPIRED_MESSAGE);
      const expiration = Number(payload['exp']);
      this.jwtExpiresAt = Number.isFinite(expiration) && expiration > 0 ? expiration * 1000 : 0;
      if (this.jwtExpiresAt > 0 && this.jwtExpiresAt <= Date.now()) throw new Error(EXPIRED_MESSAGE);
      // 只读核实开发者服务授权确实可用，不将网页授权信号直接当作签名材料。
      const teamsResponse = await request.request('https://connect-api.cloud.huawei.com/api/ups/user-permission-service/v1/user-team-list',
        { method: http.RequestMethod.GET, header: { 'oauth2Token': this.accessToken, 'uid': this.uid,
          'User-Agent': 'DevEco Studio', 'Accept-Language': 'zh-CN' }, expectDataType: http.HttpDataType.STRING,
          connectTimeout: 15000, readTimeout: 15000 });
      if (teamsResponse.responseCode === 401) throw new Error(EXPIRED_MESSAGE);
      if (teamsResponse.responseCode !== 200 || typeof teamsResponse.result !== 'string' || teamsResponse.result.length > 512 * 1024) {
        throw new Error('开发者团队核实失败');
      }
      const teams = JSON.parse(teamsResponse.result) as Record<string, Object>;
      if (!Array.isArray(teams['teams']) || (teams['teams'] as Object[]).length === 0) throw new Error('没有可用开发者团队');
      if (epoch !== this.epoch) return;
      this.teams = (teams['teams'] as Record<string, Object>[]).map((team: Record<string, Object>): string => String(team['id'] ?? ''))
        .filter((id: string): boolean => id.length > 0);
      if (this.teams.length === 0) throw new Error('没有可用开发者团队');
      this.authenticatedAt = Date.now();
      this.jwt = jwt;
    }
    finally { request.destroy(); }
  }

  /** 保留“曾登录但已失效”的加密标记，下一次更新仍能正确显示重新登录提示。 */
  private async expireSaved(epoch: number): Promise<void> {
    this.accessToken = ''; this.authenticatedAt = 0; this.teams = [];
    const expired: DeveloperCredential = { schema: 1, jwt: '', expiresAt: 0, savedAt: Date.now() };
    await this.vault?.save(expired, (): boolean => epoch === this.epoch).catch((): void => {});
  }
}
