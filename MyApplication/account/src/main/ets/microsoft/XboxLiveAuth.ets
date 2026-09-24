/**
 * XboxLiveAuth.ets — Xbox Live 认证 + XSTS 授权
 *
 * 职责（规划文档 §7 步骤 3-4）：
 *   - authenticateXbl(msAccessToken) → XblTokenResult { token, uhs }
 *   - authorizeXsts(xblToken)        → XstsTokenResult { token, uhs }
 *   - 解析 XSTS 401 + XErr → 用户可读中文错误（XErr 5 个码全覆盖）
 *
 * 不在本模块范围：
 *   - 上游 OAuth（在 MicrosoftOAuth.ets）
 *   - 下游 MC bearer（在 MinecraftProfileApi.ets）
 *
 * 创建日期：2026-05-09（M2 Phase A）
 */

import { HttpClient, HttpResponse } from './HttpClient';
import { redactToken } from 'commons';
import { XBL_AUTH_URL, XSTS_AUTH_URL, LOG_DOMAIN_ACCOUNT } from 'commons';
import { AppLogger } from 'commons';

const TAG = 'XboxLiveAuth';

// ============================================================
//  返回类型
// ============================================================

/** XBL 或 XSTS 成功结果。两者形态完全相同。 */
export interface XblTokenResult {
  token: string;  // JWT
  uhs: string;    // user hash，构造 Identity Token 用
}

/** XErr 错误码 → 用户中文描述 + 是否可重试。 */
export interface XErrInfo {
  code: number;
  message: string;
  retriable: boolean;
}

/** Xbox / XSTS 认证错误。 */
export class XboxAuthError extends Error {
  readonly stage: string;     // 'xbl' | 'xsts'
  readonly httpStatus: number;
  readonly xerr: number;      // 0 表示无 XErr
  readonly userMessage: string; // 中文描述（可直接 UI 展示）
  constructor(stage: string, httpStatus: number, xerr: number, userMessage: string) {
    super('[' + stage + '] HTTP ' + httpStatus + ' XErr=' + xerr + ': ' + userMessage);
    this.name = 'XboxAuthError';
    this.stage = stage;
    this.httpStatus = httpStatus;
    this.xerr = xerr;
    this.userMessage = userMessage;
  }
}

// ============================================================
//  XErr 错误码表（基于 PCL2 / wiki.vg）
// ============================================================

const XERR_TABLE: Map<number, string> = (() => {
  let m = new Map<number, string>();
  m.set(2148916233, '该 Microsoft 账户没有关联 Xbox 账户。请到 https://xbox.com 用此账户创建 Xbox 资料后重试。');
  m.set(2148916235, '当前地区 Xbox Live 不可用。请确认 Microsoft 账户的地区设置。');
  m.set(2148916236, '该 Xbox 账户需要完成身份/年龄验证。请到 https://account.xbox.com 完成后重试。');
  m.set(2148916237, '该 Xbox 账户需要完成成年人身份验证（美国地区）。');
  m.set(2148916238, '该账户为未成年账户，需要被加入家庭组（Family）后才能登录。请联系家庭管理员。');
  return m;
})();

/** 公开供 UI / 其他模块查询。 */
export function describeXErr(code: number): XErrInfo {
  let msg = XERR_TABLE.get(code);
  if (msg === undefined) {
    return { code: code, message: '未知 Xbox 错误码 ' + code, retriable: false };
  }
  return { code: code, message: msg, retriable: false };
}

// ============================================================
//  XBL / XSTS request body shape（仅本模块构造，不暴露）
// ============================================================

interface XblRequestProperties {
  AuthMethod: string;
  SiteName: string;
  RpsTicket: string;
}

interface XblRequestBody {
  Properties: XblRequestProperties;
  RelyingParty: string;
  TokenType: string;
}

interface XstsRequestProperties {
  SandboxId: string;
  UserTokens: string[];
}

interface XstsRequestBody {
  Properties: XstsRequestProperties;
  RelyingParty: string;
  TokenType: string;
}

interface XblXuiClaim {
  uhs?: string;
}

interface XblDisplayClaims {
  xui?: XblXuiClaim[];
}

interface XblResponseBody {
  Token?: string;
  DisplayClaims?: XblDisplayClaims;
  XErr?: number;
  Message?: string;
  Redirect?: string;
}

// ============================================================
//  主类
// ============================================================

export class XboxLiveAuth {
  private http: HttpClient;

  constructor(http: HttpClient) {
    this.http = http;
  }

  /**
   * 步骤 3：用 MS access_token 换 XBL token + uhs。
   */
  async authenticateXbl(msAccessToken: string): Promise<XblTokenResult> {
    let body: XblRequestBody = {
      Properties: {
        AuthMethod: 'RPS',
        SiteName: 'user.auth.xboxlive.com',
        RpsTicket: 'd=' + msAccessToken,
      },
      RelyingParty: 'http://auth.xboxlive.com',
      TokenType: 'JWT',
    };
    let extraHeaders = new Map<string, string>();
    extraHeaders.set('x-xbl-contract-version', '1');
    let resp = await this.http.postJson(XBL_AUTH_URL, JSON.stringify(body), extraHeaders);
    return this.parseResult(resp, 'xbl');
  }

  /**
   * 步骤 4：用 XBL token 换 XSTS token + uhs。
   * XSTS 返回 401 时 body 含 XErr → 解析成中文错误（不可重试）。
   */
  async authorizeXsts(xblToken: string): Promise<XblTokenResult> {
    let body: XstsRequestBody = {
      Properties: {
        SandboxId: 'RETAIL',
        UserTokens: [xblToken],
      },
      RelyingParty: 'rp://api.minecraftservices.com/',
      TokenType: 'JWT',
    };
    let resp = await this.http.postJson(XSTS_AUTH_URL, JSON.stringify(body));
    return this.parseResult(resp, 'xsts');
  }

  // ============================================================
  //  内部解析
  // ============================================================

  private parseResult(resp: HttpResponse, stage: string): XblTokenResult {
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      let json = parseXblResponse(resp.body);
      let token = (json.Token !== undefined) ? json.Token : '';
      let uhs = '';
      if (json.DisplayClaims && json.DisplayClaims.xui && json.DisplayClaims.xui.length > 0) {
        let xui = json.DisplayClaims.xui[0];
        if (xui.uhs !== undefined) uhs = xui.uhs;
      }
      if (token.length === 0 || uhs.length === 0) {
        throw new XboxAuthError(stage, resp.statusCode, 0,
          '认证响应缺字段（Token=' + (token.length === 0 ? 'missing' : 'ok') +
          ', uhs=' + (uhs.length === 0 ? 'missing' : 'ok') + '）');
      }
      return { token: token, uhs: uhs };
    }
    // 4xx / 5xx：尝试解析 XErr
    let json = parseXblResponse(resp.body);
    let xerr = (typeof json.XErr === 'number') ? json.XErr : 0;
    if (xerr > 0) {
      let info = describeXErr(xerr);
      AppLogger.warn(TAG, `${stage} rejected: XErr=${xerr} ${info.message}`, null, LOG_DOMAIN_ACCOUNT);
      throw new XboxAuthError(stage, resp.statusCode, xerr, info.message);
    }
    // 没有 XErr 的失败：通用错误
    let serverMsg = (typeof json.Message === 'string') ? json.Message : '';
    let preview = serverMsg.length > 0 ? serverMsg
      : (resp.body.length > 200 ? resp.body.substring(0, 200) : resp.body);
    // 2026-05-10 (LOG-P0-2)：preview 可能来自 resp.body 截断，未来上游变更可能
    // 在错误体里夹带 token，强制 redactToken 兜底。
    let safePreview = redactToken(preview);
    AppLogger.warn(TAG, `${stage} failed: HTTP ${resp.statusCode} body=${safePreview}`, null, LOG_DOMAIN_ACCOUNT);
    throw new XboxAuthError(stage, resp.statusCode, 0,
      'Xbox 服务返回 HTTP ' + resp.statusCode + (preview.length > 0 ? '：' + preview : ''));
  }
}

// ============================================================
//  内部工具
// ============================================================

function parseXblResponse(body: string): XblResponseBody {
  if (!body || body.length === 0) return {};
  try {
    let v = JSON.parse(body) as XblResponseBody;
    return v ? v : {};
  } catch (e) {
    return {};
  }
}
