/**
 * HttpClient.ets — Microsoft / Xbox / MC Services 链路的 HTTP 抽象
 *
 * 职责：
 *   - 统一 6 个端点（MS /token、/devicecode、XBL、XSTS、MC bearer、MC profile）
 *     需要的 3 种请求形态：postForm / postJson / get
 *   - 提供 RealHttpClient（包 @kit.NetworkKit）和 FakeHttpClient（单测注入）
 *   - 单测严禁连真实网，全部走 FakeHttpClient
 *
 * 设计要点：
 *   - HttpResponse 暴露 statusCode + body（原始字符串），调用方自行 JSON.parse
 *   - 不在 HttpClient 层做 retry / 错误码转换，交给上层各 service 决定
 *   - 头部用 Map<string, string>，与 ArkTS strict 兼容
 *
 * 创建日期：2026-05-09（M2 Phase A）
 */

import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';

const CONNECT_TIMEOUT_MS = 10000;
const READ_TIMEOUT_MS = 30000;

// ============================================================
//  公共类型
// ============================================================

export interface HttpResponse {
  statusCode: number;
  body: string;
  /**
   * 响应头（小写 key）。可选：老实现 / FakeHttpClient 不填时为 undefined。
   *
   * Yggdrasil / authlib-injector 的 API Location Indication（ALI）重定向需要读取
   * `x-authlib-injector-api-location` 头，故 RealHttpClient 会填充此字段。
   * Microsoft 链路不读头，留空不影响。
   */
  headers?: Map<string, string>;
}

export interface HttpClient {
  /**
   * POST application/x-www-form-urlencoded
   * @param url 端点
   * @param urlEncodedBody 已编码好的表单字符串（"k1=v1&k2=v2"），调用方负责 encodeURIComponent
   * @param extraHeaders 可选附加头（如 XBL contract version）
   */
  postForm(url: string, urlEncodedBody: string, extraHeaders?: Map<string, string>): Promise<HttpResponse>;

  /**
   * POST application/json
   */
  postJson(url: string, jsonBody: string, extraHeaders?: Map<string, string>): Promise<HttpResponse>;

  /**
   * GET，可选 Bearer token（空字符串 = 不加 Authorization）
   */
  get(url: string, bearerToken: string, extraHeaders?: Map<string, string>): Promise<HttpResponse>;

  /**
   * PUT application/json，必传 Bearer token。Mojang Profile API 修改类调用（设 active cape 等）。
   */
  putJson(url: string, bearerToken: string, jsonBody: string, extraHeaders?: Map<string, string>): Promise<HttpResponse>;

  /**
   * DELETE，必传 Bearer token。无 body。Mojang Profile API 取消 active cape 等。
   */
  delete(url: string, bearerToken: string, extraHeaders?: Map<string, string>): Promise<HttpResponse>;
}

// ============================================================
//  工具：表单编码 / 头部组装
// ============================================================

/**
 * 把 Map<string, string> 编码为 application/x-www-form-urlencoded body 串。
 * 每个 key/value 都做 encodeURIComponent。
 *
 * 单独导出方便上层（OAuth）使用同一份实现。
 */
export function buildFormBody(fields: Map<string, string>): string {
  let parts: string[] = [];
  fields.forEach((value: string, key: string) => {
    parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(value));
  });
  return parts.join('&');
}

/**
 * 把 @kit.NetworkKit 返回的 header（Object，key 大小写不定）归一化为
 * 小写 key 的 Map。ohos 的 resp.header 是 `Object`，字段值可能是 string 或 string[]。
 * 取首值即可（我们只关心 ALI 这类单值头）。解析失败返回空 Map（不抛）。
 */
function normalizeHeaders(header: object | undefined): Map<string, string> {
  let out = new Map<string, string>();
  if (!header) return out;
  try {
    let rec = header as Record<string, string | string[]>;
    let keys = Object.keys(rec);
    for (let i = 0; i < keys.length; i++) {
      let k = keys[i];
      let v = rec[k];
      let val = Array.isArray(v) ? (v.length > 0 ? v[0] : '') : (v as string);
      if (typeof val === 'string') {
        out.set(k.toLowerCase(), val);
      }
    }
  } catch (e) {
    // header 结构异常时静默返回已收集的部分
  }
  return out;
}

function mergeHeaders(base: Record<string, string>, extra?: Map<string, string>): Record<string, string> {
  let merged: Record<string, string> = {};
  let baseKeys = Object.keys(base);
  for (let i = 0; i < baseKeys.length; i++) {
    let k = baseKeys[i];
    merged[k] = base[k];
  }
  if (extra) {
    extra.forEach((v: string, k: string) => {
      merged[k] = v;
    });
  }
  return merged;
}

// ============================================================
//  RealHttpClient — 包 @kit.NetworkKit
// ============================================================

export class RealHttpClient implements HttpClient {
  async postForm(url: string, urlEncodedBody: string, extraHeaders?: Map<string, string>): Promise<HttpResponse> {
    let headers = mergeHeaders({
      'Content-Type': 'application/x-www-form-urlencoded',
      'Accept': 'application/json',
    }, extraHeaders);
    return this.execute(url, http.RequestMethod.POST, headers, urlEncodedBody);
  }

  async postJson(url: string, jsonBody: string, extraHeaders?: Map<string, string>): Promise<HttpResponse> {
    let headers = mergeHeaders({
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    }, extraHeaders);
    return this.execute(url, http.RequestMethod.POST, headers, jsonBody);
  }

  async get(url: string, bearerToken: string, extraHeaders?: Map<string, string>): Promise<HttpResponse> {
    let baseHeaders: Record<string, string> = { 'Accept': 'application/json' };
    if (bearerToken && bearerToken.length > 0) {
      baseHeaders['Authorization'] = 'Bearer ' + bearerToken;
    }
    let headers = mergeHeaders(baseHeaders, extraHeaders);
    return this.execute(url, http.RequestMethod.GET, headers, undefined);
  }

  async putJson(url: string, bearerToken: string, jsonBody: string, extraHeaders?: Map<string, string>): Promise<HttpResponse> {
    let baseHeaders: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (bearerToken && bearerToken.length > 0) {
      baseHeaders['Authorization'] = 'Bearer ' + bearerToken;
    }
    let headers = mergeHeaders(baseHeaders, extraHeaders);
    return this.execute(url, http.RequestMethod.PUT, headers, jsonBody);
  }

  async delete(url: string, bearerToken: string, extraHeaders?: Map<string, string>): Promise<HttpResponse> {
    let baseHeaders: Record<string, string> = { 'Accept': 'application/json' };
    if (bearerToken && bearerToken.length > 0) {
      baseHeaders['Authorization'] = 'Bearer ' + bearerToken;
    }
    let headers = mergeHeaders(baseHeaders, extraHeaders);
    return this.execute(url, http.RequestMethod.DELETE, headers, undefined);
  }

  // 2026-05-23 ArkTS 严格模式：req.request 会报 'Function may throw'。
  // try-finally 已保证 req.destroy()，再加一层 try-catch 让异常显式 rethrow。
  // 详见 docs/guides/api-migration-2026-05.md。
  private async execute(
    url: string,
    method: http.RequestMethod,
    headers: Record<string, string>,
    body: string | undefined
  ): Promise<HttpResponse> {
    let req = http.createHttp();
    try {
      let options: http.HttpRequestOptions = {
        method: method,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        header: headers,
      };
      if (body !== undefined) {
        options.extraData = body;
      }
      let resp: http.HttpResponse;
      try {
        resp = await req.request(url, options);
      } catch (e) {
        throw e as Error;  // 由调用方 (OAuth 流) 处理网络错误
      }
      let bodyStr = '';
      if (typeof resp.result === 'string') {
        bodyStr = resp.result;
      } else if (resp.result instanceof ArrayBuffer) {
        // 极少数情况：服务器没声明 charset，鸿蒙返回 ArrayBuffer
        let decoder = util.TextDecoder.create('utf-8');
        bodyStr = decoder.decodeToString(new Uint8Array(resp.result));
      } else {
        bodyStr = JSON.stringify(resp.result);
      }
      return { statusCode: resp.responseCode, body: bodyStr, headers: normalizeHeaders(resp.header) };
    } finally {
      req.destroy();
    }
  }
}
