/**
 * ArkWeb官方开发者登录与每轮更新的登录检查。回调随机码、临时令牌、访问令牌只保留内存；
 * 验证后的登录JWT由独立HUKS仓库保存，下次更新必须再次向官方服务核实，证书不能代替登录。
 * 登录页面不注入JS代理、不读取用户输入；回调在loopback接收，成功交换后通知视图关闭。
 */
import { socket, http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DeveloperAuthVault, DeveloperCredential, DeveloperCredentialInvalidError } from './DeveloperAuthVault';
import { SigningPreparationError, SigningPreparationIssue } from './SigningPreparationError';

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
  private accessRevision: number = 0;
  /** 同一会话的并发401共享一次刷新，旧会话的迟到结果不能触碰新登录。 */
  private refreshPromise: Promise<void> | undefined = undefined;
  private jwt: string = '';
  private vault: DeveloperAuthVault | undefined = undefined;
  private epoch: number = 0;
  private timer: number = -1;
  private complete: (success: boolean, message: string) => void = (): void => {};

  /** 只绑定本机私有存储，初始化本身不读取账号或发起网络请求。 */
  initialize(context: common.UIAbilityContext): void { this.vault = new DeveloperAuthVault(context); }

  /**
   * 每次立即更新都执行：先读加密记录，再向官方JWT检查和团队接口核实。
   * 旧expiresAt只作格式兼容；是否仍可复用由官方refresh检查决定，暂态错误不擦掉凭据。
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
    if (!saved.jwt) return DeveloperAuthState.Expired;
    try {
      await this.validateWithRetry(saved.jwt, epoch);
      return epoch === this.epoch ? DeveloperAuthState.Valid : DeveloperAuthState.Cancelled;
    } catch (error) {
      if (epoch !== this.epoch) return DeveloperAuthState.Cancelled;
      this.accessToken = ''; this.teams = []; this.authenticatedAt = 0;
      return DeveloperAuthSession.isExpired(error as Error) ? DeveloperAuthState.Expired : DeveloperAuthState.Unavailable;
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
    this.teams = []; this.authenticatedAt = 0; this.jwt = ''; this.refreshPromise = undefined;
    if (this.server !== undefined) this.server.close().catch((): void => {});
    this.server = undefined;
  }

  /** 这里检查的是应用取得的开发者授权，不推断系统华为账号的登录状态。 */
  signedIn(): boolean {
    return this.accessToken.length > 0 && this.authenticatedAt > 0 && this.teams.length > 0;
  }
  teamIds(): string[] { return this.teams.slice(); }
  /** 新签名优先使用本人团队；团队成员沿官方返回的首个已授权团队。 */
  preferredTeamId(): string { return this.teams.includes(this.uid) ? this.uid : this.teams[0] ?? ''; }

  /**
   * 令牌仅在服务域用于固定华为签名接口；调用方不能指定任意域名或获取原始认证头。
   * 服务错误只导出数字错误码，防止第三方错误消息回显令牌、CSR或账号资料。
   */
  async request(path: string, method: http.RequestMethod, team: string,
    body?: Object, appId?: string): Promise<Record<string, Object>> {
    const epoch = this.epoch;
    const usedRevision = this.accessRevision;
    try { return await this.requestOnce(path, method, team, body, appId); }
    catch (error) {
      if (epoch !== this.epoch || !DeveloperAuthSession.isExpired(error as Error)) throw error as Error;
      // 另一个请求可能已刷新成功；迟到的旧401只重试，不撤销或再刷新新访问令牌。
      if (!this.signedIn() || this.accessRevision === usedRevision) await this.refreshAccessToken(epoch);
      if (epoch !== this.epoch) throw new Error('授权已取消');
      // 仅明确认证失效可重发一次；网络超时或业务失败不能借刷新重复云端写操作。
      return this.requestOnce(path, method, team, body, appId);
    }
  }

  private async refreshAccessToken(epoch: number): Promise<void> {
    if (epoch !== this.epoch) throw new Error('授权已取消');
    if (!this.jwt) throw new Error(EXPIRED_MESSAGE);
    if (this.refreshPromise !== undefined) return this.refreshPromise;
    const pending = this.validateWithRetry(this.jwt, epoch, this.uid);
    this.refreshPromise = pending;
    try { await pending; }
    finally { if (this.refreshPromise === pending) this.refreshPromise = undefined; }
  }

  private async requestOnce(path: string, method: http.RequestMethod, team: string,
    body?: Object, appId?: string): Promise<Record<string, Object>> {
    const allowed: string[] = ['/api/amis/app-manage/v1/manage/app/brief-info/list',
      '/api/cps/harmony-cert-manage/v1/cert/list', '/api/cps/harmony-cert-manage/v1/cert/add',
      '/api/cps/device-manage/v1/device/list', '/api/cps/device-manage/v1/device/add',
      '/api/cps/provision-manage/v1/provision/list', '/api/cps/provision-manage/v1/provision/add',
      '/api/cps/provision-manage/v1/ide/test/provision/add',
      '/api/amis/app-manage/v1/objects/url/reapply'];
    if (!this.signedIn()) throw new Error(EXPIRED_MESSAGE);
    if (this.teams.indexOf(team) < 0 || allowed.indexOf(path.split('?')[0]) < 0) throw new Error('无效的签名服务请求');
    const epoch = this.epoch;
    const usedRevision = this.accessRevision;
    const request = http.createHttp();
    try {
      // Profile 查询按官方协议绑定已核实的注册应用；其他接口不发送伪造或空的 appId。
      const headers: Record<string, string> = { 'oauth2Token': this.accessToken, 'uid': this.uid, 'teamId': team,
        'Content-Type': 'application/json', 'User-Agent': 'DevEco Studio', 'Accept-Language': 'zh-CN' };
      if (appId !== undefined && appId.length > 0) headers['appId'] = appId;
      const options: http.HttpRequestOptions = {
        method: method, header: headers,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000, readTimeout: 15000
      };
      // 空字符串会被鸿蒙网络栈当作非法请求体；没有业务正文时必须省略extraData。
      if (body !== undefined) options.extraData = JSON.stringify(body);
      const response = await request.request('https://connect-api.cloud.huawei.com' + path, options);
      if (epoch !== this.epoch) throw new Error('授权已取消');
      if (response.responseCode === 401) {
        if (this.accessRevision === usedRevision) { this.accessToken = ''; this.authenticatedAt = 0; }
        throw new Error(EXPIRED_MESSAGE);
      }
      if (response.responseCode !== 200 || typeof response.result !== 'string' || response.result.length > 512 * 1024) {
        if (response.responseCode === 403) throw new SigningPreparationError(SigningPreparationIssue.Permission,
          '华为登录已验证，但当前授权无权访问签名服务，请检查开发者团队权限后重试');
        throw new SigningPreparationError(SigningPreparationIssue.Service,
          '华为签名服务暂不可用（HTTP ' + response.responseCode + '），请重试获取签名');
      }
      let value: Record<string, Object>;
      try { value = JSON.parse(response.result) as Record<string, Object>; }
      catch (_) { throw new SigningPreparationError(SigningPreparationIssue.Response, '签名服务返回格式异常，请重试获取签名'); }
      if (value === null || Array.isArray(value) || typeof value !== 'object') {
        throw new SigningPreparationError(SigningPreparationIssue.Response, '签名服务返回格式异常，请重试获取签名');
      }
      const ret = value['ret'] as Record<string, Object>;
      if (ret !== undefined && (ret === null || Array.isArray(ret) || typeof ret !== 'object' ||
        !Number.isSafeInteger(Number(ret['code'])))) {
        throw new SigningPreparationError(SigningPreparationIssue.Response, '签名服务返回格式异常，请重试获取签名');
      }
      if (ret !== undefined && Number(ret['code']) !== 0) {
        const code = Number(ret['code']);
        if (code === 401 || code === 10001 || code === 10002) {
          if (this.accessRevision === usedRevision) { this.accessToken = ''; this.authenticatedAt = 0; }
          throw new Error(EXPIRED_MESSAGE);
        }
        throw new SigningPreparationError(SigningPreparationIssue.Service,
          '华为签名服务返回错误 ' + code + '，请重试获取签名');
      }

      return value;
    } catch (error) {
      // 只有官方认证检查确认失效才重新登录。传输失败不要求用户寻找原安装账号或导入材料。
      if (DeveloperAuthSession.isExpired(error as Error) || error instanceof SigningPreparationError) throw error as Error;
      // BusinessError 401发生在本机参数校验阶段，不是服务端HTTP 401，不能刷新账号或误报网络。
      if ((error as BusinessError).code === 401) throw new SigningPreparationError(SigningPreparationIssue.Preparation,
        '当前版本的签名请求参数异常（401）');
      throw new SigningPreparationError(SigningPreparationIssue.Service, '连接华为签名服务失败，请检查网络后重试');
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
      // 官方交换有原始文本与JSON两种有效返回；不能把整段JSON当JWT再误报账号过期。
      let jwt = temporary.result.trim();
      if (jwt.startsWith('{')) {
        const wrapped = JSON.parse(jwt) as Record<string, Object>;
        jwt = typeof wrapped['jwtToken'] === 'string' ? wrapped['jwtToken'] as string : '';
      }
      if (!jwt || jwt.length > 16384 || new RegExp('[\\r\\n\\x00]').test(jwt)) throw new Error('登录返回格式异常');
      await this.validateWithRetry(jwt, epoch);
      if (epoch !== this.epoch) return;
      const credential: DeveloperCredential = { schema: 1, jwt: jwt, expiresAt: 0, savedAt: Date.now() };
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

  /** 恢复、新回调和401刷新共用有界读请求重试；明确失效不重试、不改写原有密文。 */
  private async validateWithRetry(jwt: string, epoch: number, expectedUid: string = ''): Promise<void> {
    for (let attempt = 0; attempt < 3; attempt++) {
      if (epoch !== this.epoch) throw new Error('授权已取消');
      try { await this.validateJwt(jwt, epoch, expectedUid); return; }
      catch (error) {
        if (epoch !== this.epoch || DeveloperAuthSession.isExpired(error as Error) || attempt === 2) throw error as Error;
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 1000); });
      }
    }
  }

  /** 官方refresh检查和团队验证共同授予使用资格；不把本地JWT声明或五分钟计时当作失效证明。 */
  private async validateJwt(jwt: string, epoch: number, expectedUid: string = ''): Promise<void> {
    if (!jwt || jwt.length > 16384) throw new Error(EXPIRED_MESSAGE);
    const request = http.createHttp();
    try {
      const response = await request.request('https://devecostudio.huawei.com/authrouter/auth/api/jwToken/check',
        { method: http.RequestMethod.GET, header: { 'jwtToken': jwt, 'refresh': 'true' }, expectDataType: http.HttpDataType.STRING,
          connectTimeout: 15000, readTimeout: 15000 });
      if (response.responseCode === 401) throw new Error(EXPIRED_MESSAGE);
      if (response.responseCode !== 200 || typeof response.result !== 'string' || response.result.length > 512 * 1024) {
        throw new Error('开发者服务授权检查暂不可用');
      }
      const result = JSON.parse(response.result) as Record<string, Object>;
      if (result === null || Array.isArray(result) || typeof result !== 'object') {
        throw new SigningPreparationError(SigningPreparationIssue.Response, '开发者授权返回格式异常，请稍后重试');
      }
      const nested = result['userInfo'] as Record<string, Object>;
      const user = nested !== null && typeof nested === 'object' && !Array.isArray(nested) ? nested : result;
      const access = DeveloperAuthSession.text(user['accessToken']) || DeveloperAuthSession.text(result['accessToken']);
      const uid = DeveloperAuthSession.identityText(user['userId']) || DeveloperAuthSession.identityText(result['userId']);
      if (!access || !uid) {
        const ret = result['ret'] as Record<string, Object>;
        const code = ret !== null && typeof ret === 'object' ? Number(ret['code']) : 0;
        if (result['status'] === false || code === 401 || code === 10001 || code === 10002) throw new Error(EXPIRED_MESSAGE);
        throw new SigningPreparationError(SigningPreparationIssue.Response, '开发者授权返回信息不完整，请稍后重试');
      }
      if (access.length > 16384 || uid.length > 256 || new RegExp('[\\r\\n\\x00]').test(access + uid)) {
        throw new SigningPreparationError(SigningPreparationIssue.Response, '开发者授权返回格式异常，请稍后重试');
      }
      if (expectedUid && uid !== expectedUid) {
        throw new SigningPreparationError(SigningPreparationIssue.Response, '华为授权身份发生变化，请重新核实登录');
      }
      if (epoch !== this.epoch) return;
      // 只读核实开发者服务授权确实可用，不将网页授权信号直接当作签名材料。
      const teamsResponse = await request.request('https://connect-api.cloud.huawei.com/api/ups/user-permission-service/v1/user-team-list',
        { method: http.RequestMethod.GET, header: { 'oauth2Token': access, 'uid': uid,
          'User-Agent': 'DevEco Studio', 'Accept-Language': 'zh-CN' }, expectDataType: http.HttpDataType.STRING,
          connectTimeout: 15000, readTimeout: 15000 });
      if (teamsResponse.responseCode === 401) throw new Error(EXPIRED_MESSAGE);
      if (teamsResponse.responseCode !== 200 || typeof teamsResponse.result !== 'string' || teamsResponse.result.length > 512 * 1024) {
        throw new Error('开发者团队核实失败');
      }
      const teams = JSON.parse(teamsResponse.result) as Record<string, Object>;
      if (!Array.isArray(teams['teams']) || (teams['teams'] as Object[]).length === 0) throw new Error('没有可用开发者团队');
      if (epoch !== this.epoch) return;
      const authorizedTeams = (teams['teams'] as Record<string, Object>[]).map((team: Record<string, Object>): string =>
        team !== null && typeof team === 'object' ? DeveloperAuthSession.identityText(team['id']) : '')
        .filter((id: string): boolean => id.length > 0);
      if (authorizedTeams.length === 0) throw new Error('没有可用开发者团队');
      // 完整核实后一起提交身份和访问令牌。修订号代表一次验证，不假定刷新必定更换字符串。
      this.accessToken = access; this.uid = uid; this.teams = authorizedTeams; this.accessRevision++;
      this.authenticatedAt = Date.now();
      this.jwt = jwt;
    }
    finally { request.destroy(); }
  }

  /** 仅接受服务器DTO中的标量文本；响应对象不能隐式变成认证头。 */
  private static text(value: Object | undefined): string {
    return typeof value === 'string' ? value.trim() : '';
  }
  private static identityText(value: Object | undefined): string {
    return typeof value === 'number' && Number.isSafeInteger(value) && value > 0 ? value.toString() : DeveloperAuthSession.text(value);
  }
}
