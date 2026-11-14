import { DistributionPolicy } from 'commons';
/**
 * RelayClient.ets — AMCL 加速网关客户端（ArkTS 侧）
 *
 * 职责边界（与 native 的 relay.cpp 配合）：
 *   ArkTS（本文件）
 *     · 生成/持久化 deviceId
 *     · 用内置密钥做 HMAC 握手，换取 ticket + sessionKey
 *     · 经同一入口自检设备票据，确认代理链路后才发布 native 配置
 *     · 票据快过期时提前续签
 *     · 把配置注入 native（downloadSetRelay）
 *   native（relay.cpp）
 *     · 把官方源 URL 改写成经网关的 URL
 *     · 为**每个分段请求**单独算持有证明签名（各段独立 nonce，ArkTS 算不了）
 *     · 网关连续失败时熔断并自动回退直连
 *
 * 安全约定：
 *   · sessionKey 只在内存流转，不写 Preferences、不打日志（日志只打长度）
 *   · 内置的 APP_KEY 只用于握手；泄露后服务端把该 keyId 标 retired 即全网失效，
 *     新版本换新 keyId 平滑过渡（无需改协议）
 *   · 握手失败一律**静默降级**为直连：加速是增强，绝不能因为它下不了东西
 *
 * 创建日期：2026-08-01
 */

import { http } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer, util } from '@kit.ArkTS';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_DOWNLOAD } from 'commons';
import { getRelayNativeBridge, RelayStatsNative } from './RelayNativeBridge';

const TAG = 'RelayClient';

// ============================================================
//  网关参数（随 App 版本内置）
// ============================================================

/**
 * App 的稳定网关入口。源站迁移及 CDN 回源由 DNS/服务端维护；客户端始终使用
 * 此 HTTPS 主机完成握手、自检和下载，不消费响应中的任意 base 来转发内存票据。
 * 旧官网 /dl 只服务已有版本和同源管理后台，新会话不跨两条入口复用 IP 绑定票据。
 */
export const RELAY_BASE: string = 'https://relay.amcl.lovedhy.cn/dl';

/**
 * 握手密钥 ID + 密钥。
 * ⚠️ 客户端密钥必然可被提取，这不是"防破解"，而是让**滥用可撤销**：
 *   服务端 .env 里把该 keyId 置 retired 即全网失效，同时通过面板看谁在滥用。
 * 轮换流程：服务端新增 k2 → App 新版本改用 k2 → 观察一段时间 → 把 k1 置 retired。
 */
const APP_KEY_ID: string = 'k1';
const APP_KEY_SECRET: string = '265b8cb632018f2fea37872b1c87c7d4f6c060272ed601e0506bca4782c967a1';

/** 握手超时 */
const HANDSHAKE_TIMEOUT_MS: number = 15000;
/** 握手/自检只收小型 JSON；限制错误页或异常 CDN 响应占用的内存。 */
const SESSION_RESPONSE_LIMIT: number = 16 * 1024;
/** 票据剩余不足这个时长就提前续签 */
const RENEW_LEAD_MS: number = 5 * 60 * 1000;

// ============================================================
//  数据结构
// ============================================================

export interface RelayDeviceInfo {
  deviceId: string;
  appVersionCode: number;
  appVersionName: string;
  model: string;
  osVersion: string;
  abi: string;
}

interface SessionResponse {
  ticket?: string;
  sessionKey?: string;
  requireProof?: boolean;
  expiresIn?: number;
  base?: string;
  serverTime?: number;
  error?: string;
}

/** 自检必须确认源站看到同一设备票据；不把任意 HTTP 200 当作鉴权成功。 */
interface SessionVerification {
  ok?: boolean;
  deviceId?: string;
  error?: string;
}

export interface RelayStatus {
  /** 用户开关 */
  enabled: boolean;
  /** 兼容既有来源消费者：只在Native当前真正可路由时为true，不能仅凭旧握手成功。 */
  active: boolean;
  /** 会话在客户端仍有效且保留Native相同的30秒余量，与熔断状态分开表达。 */
  sessionReady: boolean;
  /** 当前会话和Native usable/tripped共同确认的实际可用态；查询异常时保守false。 */
  usable: boolean;
  /** Native当前熔断事实，只投影状态，不暴露票据或会话密钥。 */
  tripped: boolean;
  /** 本代次确有握手/续签在途；只表示等待，不虚称HTTP已完成或已被取消。 */
  connecting: boolean;
  /** 最近一次失败原因（用于设置页提示） */
  lastError: string;
  /** 票据到期时刻（ms），0 = 无 */
  expiresAt: number;
  /** native 侧统计 */
  native: RelayStatsNative | null;
}

/** UI只消费状态文本；优先显示实际可用态，续签在途时仍可使用旧有效票据。 */
export function relayStatusText(status: RelayStatus): string {
  if (!status.enabled) return '';
  if (status.usable) return 'ok';
  if (status.connecting) return '';
  if (status.lastError.length > 0) return status.lastError;
  if (status.tripped) return '网关暂时熔断，稍后会恢复探测';
  if (status.sessionReady && status.native === null) return '无法读取下载引擎的加速状态';
  if (status.sessionReady) return '下载引擎当前未启用网关';
  return status.expiresAt > 0 ? '加速票据已过期或临近过期' : '尚未建立可用加速会话';
}

/** 每个订阅者拿独立、严格列出的公开字段，不能借Native对象附带属性泄漏内存材料。 */
function copyRelayStatus(status: RelayStatus): RelayStatus {
  const native = status.native;
  return { enabled: status.enabled, active: status.active, sessionReady: status.sessionReady,
    usable: status.usable, tripped: status.tripped, connecting: status.connecting,
    lastError: status.lastError, expiresAt: status.expiresAt,
    native: native === null ? null : { requests: native.requests, failures: native.failures,
      fallbacks: native.fallbacks, authRejects: native.authRejects, tripped: native.tripped, usable: native.usable } };
}

// ============================================================
//  工具：hex / 随机数 / HMAC
// ============================================================

function bytesToHex(data: Uint8Array): string {
  let s = '';
  for (let i = 0; i < data.length; i++) {
    let b = data[i];
    s += (b < 16 ? '0' : '') + b.toString(16);
  }
  return s;
}

/** 随机 hex（真机走 CryptoArchitectureKit 真随机；异常时降级为时间+Math.random） */
function randomHex(byteLen: number): string {
  try {
    let rng = cryptoFramework.createRandom();
    let blob = rng.generateRandomSync(byteLen);
    if (blob !== null && blob !== undefined && blob.data !== null && blob.data.length > 0) {
      return bytesToHex(blob.data);
    }
  } catch (e) {
    AppLogger.warn(TAG, 'createRandom failed, falling back to weak rng', null, LOG_DOMAIN_DOWNLOAD);
  }
  let s = '';
  for (let i = 0; i < byteLen; i++) {
    let v = Math.floor(Math.random() * 256) ^ ((Date.now() + i) & 0xff);
    s += (v < 16 ? '0' : '') + (v & 0xff).toString(16);
  }
  return s;
}

/** SHA-256(hex)；用于握手签名里的 body 摘要 */
function sha256Hex(text: string): string {
  let md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: new Uint8Array(buffer.from(text, 'utf-8').buffer) });
  let d = md.digestSync();
  return bytesToHex(d.data);
}

/** HMAC-SHA256(hex)。key 为十六进制字符串形式的密钥文本（按 UTF-8 字节使用，与服务端一致） */
function hmacSha256Hex(keyText: string, message: string): string {
  let mac = cryptoFramework.createMac('SHA256');
  let keyBytes = new Uint8Array(buffer.from(keyText, 'utf-8').buffer);
  let symKeyGen = cryptoFramework.createSymKeyGenerator('HMAC');
  let key = symKeyGen.convertKeySync({ data: keyBytes });
  mac.initSync(key);
  mac.updateSync({ data: new Uint8Array(buffer.from(message, 'utf-8').buffer) });
  let out = mac.doFinalSync();
  return bytesToHex(out.data);
}

// ============================================================
//  RelayClient
// ============================================================

export class RelayClient {
  private enabled_: boolean = false;
  private device_: RelayDeviceInfo | null = null;
  private ticket_: string = '';
  private sessionKey_: string = '';
  private requireProof_: boolean = true;
  private expiresAt_: number = 0;
  private lastError_: string = '';
  private handshakeInFlight_: Promise<boolean> | null = null;
  /** 开关/设备身份改变撤销旧握手发布权；不把消费者失效伪称HTTP已停止。 */
  private generation_: number = 0;
  private handshakeGeneration_: number = -1;
  private renewTimer_: number = -1;
  /** 进程内公开状态订阅；仅页面owner持有取消函数，不能把UI闭包留到下一次页面实例。 */
  private statusListeners_: Set<(status: RelayStatus) => void> = new Set();

  /** 设备信息由调用方（Index）提供，避免本模块依赖 bundleManager/deviceInfo */
  setDeviceInfo(info: RelayDeviceInfo): void {
    const previous = this.device_;
    if (previous !== null && JSON.stringify(previous) === JSON.stringify(info)) return;
    this.clear_();
    // 冻结协议输入。外部复用并修改原对象不能令正在等待的请求换设备身份。
    this.device_ = { deviceId: info.deviceId, appVersionCode: info.appVersionCode,
      appVersionName: info.appVersionName, model: info.model, osVersion: info.osVersion, abi: info.abi };
  }

  /** 来源规划读取当前开关意图，同时尊重产品发布者服务边界；不把usable当成内容策略。 */
  isEnabled(): boolean { return this.enabled_ && DistributionPolicy.allowPublisherServices(); }

  status(): RelayStatus {
    let native: RelayStatsNative | null = null;
    try { native = getRelayNativeBridge().stats(); } catch (e) { native = null; }
    const enabled = this.enabled_ && DistributionPolicy.allowPublisherServices();
    const sessionReady = enabled && this.ticket_.length > 0 && Date.now() < this.expiresAt_ - 30000;
    const tripped = enabled && native !== null && native.tripped === true;
    const usable = sessionReady && native !== null && native.usable === true && !tripped;
    return copyRelayStatus({
      enabled, active: usable, sessionReady, usable, tripped,
      connecting: enabled && this.handshakeInFlight_ !== null && this.handshakeGeneration_ === this.generation_,
      lastError: this.lastError_,
      expiresAt: this.expiresAt_,
      native,
    });
  }

  /** 订阅后立即给当前快照；取消只撤销监听，不关闭会话或中断其他正在进行的下载。 */
  subscribeStatus(listener: (status: RelayStatus) => void): () => void {
    this.statusListeners_.add(listener);
    this.deliverStatus_(listener, this.status());
    return (): void => { this.statusListeners_.delete(listener); };
  }

  /** 只重新采样Native状态并通知；可见设置页低频调用，不联网、不续签或重试下载。 */
  refreshStatus(): void {
    const status = this.status();
    // 固定本次消费者集合，监听内自行注销或抛异常不影响其他owner的状态交付。
    const listeners = Array.from(this.statusListeners_);
    for (const listener of listeners) this.deliverStatus_(listener, status);
  }

  /** 消费者异常不能改变握手结果或被当成网络故障，更不能把任意异常上下文写进日志。 */
  private deliverStatus_(listener: (status: RelayStatus) => void, status: RelayStatus): void {
    try { listener(copyRelayStatus(status)); }
    catch (_) { AppLogger.warn(TAG, '加速状态监听未完成；会话状态保持不变', null, LOG_DOMAIN_DOWNLOAD); }
  }

  /**
   * 打开/关闭加速。
   * 打开时立刻尝试握手；失败不抛异常，只记录 lastError 并保持直连
   * （UI 可通过 status().lastError 提示用户）。
   */
  async setEnabled(on: boolean): Promise<boolean> {
    on = on && DistributionPolicy.allowPublisherServices();
    if (on && !this.enabled_) this.generation_++;
    this.enabled_ = on;
    if (!on) {
      this.clear_();
      AppLogger.info(TAG, '加速下载已关闭，恢复直连与原有源偏好', LOG_DOMAIN_DOWNLOAD);
      return false;
    }
    this.refreshStatus();
    return this.ensureSession();
  }

  /** 确保有可用票据；已有且未临近过期则直接返回 true */
  async ensureSession(): Promise<boolean> {
    if (!this.enabled_ || !DistributionPolicy.allowPublisherServices()) return false;
    if (this.ticket_.length > 0 && Date.now() < this.expiresAt_ - RENEW_LEAD_MS) return true;
    // 并发去重：多处同时触发只发一次握手
    if (this.handshakeInFlight_ !== null && this.handshakeGeneration_ === this.generation_) return this.handshakeInFlight_;
    const generation = this.generation_;
    const pending = this.handshake_(generation);
    this.handshakeInFlight_ = pending;
    this.handshakeGeneration_ = generation;
    this.refreshStatus();
    try { return await pending; }
    finally {
      // 旧握手迟退不能移除新开关代次已经建立的去重Promise。
      if (this.handshakeInFlight_ === pending) {
        this.handshakeInFlight_ = null;
        this.refreshStatus();
      }
    }
  }

  private clear_(): void {
    this.generation_++;
    this.ticket_ = '';
    this.sessionKey_ = '';
    this.expiresAt_ = 0;
    if (this.renewTimer_ >= 0) {
      clearTimeout(this.renewTimer_);
      this.renewTimer_ = -1;
    }
    try { getRelayNativeBridge().clear(); } catch (e) { /* native 未就绪时忽略 */ }
    this.refreshStatus();
  }

  /** 当前开关、产品与代次共同授予内存票据发布权。 */
  private current_(generation: number): boolean {
    return generation === this.generation_ && this.enabled_ && DistributionPolicy.allowPublisherServices();
  }

  private async handshake_(generation: number): Promise<boolean> {
    if (!this.current_(generation)) return false;
    let dev = this.device_;
    if (dev === null) {
      this.lastError_ = '设备信息未初始化';
      return false;
    }

    let bodyObj: Record<string, string | number> = {
      'deviceId': dev.deviceId,
      'appVersionCode': dev.appVersionCode,
      'appVersionName': dev.appVersionName,
      'model': dev.model,
      'osVersion': dev.osVersion,
      'abi': dev.abi,
    };
    let body = JSON.stringify(bodyObj);
    let ts = Date.now();
    let nonce = randomHex(16);
    let path = '/api/v1/session';

    let canon = 'v1\nPOST\n' + path + '\n' + ts + '\n' + nonce + '\n' + sha256Hex(body);
    let sig = '';
    try {
      sig = hmacSha256Hex(APP_KEY_SECRET, canon);
    } catch (e) {
      this.lastError_ = '签名计算失败：' + errMsg(e);
      AppLogger.error(TAG, this.lastError_, null, LOG_DOMAIN_DOWNLOAD);
      return false;
    }

    let req = http.createHttp();
    try {
      let resp = await req.request(RELAY_BASE + path, {
        method: http.RequestMethod.POST,
        usingCache: false,
        expectDataType: http.HttpDataType.STRING,
        maxLimit: SESSION_RESPONSE_LIMIT,
        header: {
          'Content-Type': 'application/json',
          'User-Agent': 'amcl/1.0 (OHOS)',
          'Cache-Control': 'no-store',
          'X-AMCL-Key': APP_KEY_ID,
          'X-AMCL-Ts': String(ts),
          'X-AMCL-Nonce': nonce,
          'X-AMCL-Sig': sig,
        },
        extraData: body,
        connectTimeout: HANDSHAKE_TIMEOUT_MS,
        readTimeout: HANDSHAKE_TIMEOUT_MS,
      });

      // 关闭、重开或设备信息变化均撤销旧请求的结果；旧失败也不得clear新票据。
      if (!this.current_(generation)) return false;

      let code = resp.responseCode;
      let text = typeof resp.result === 'string' ? resp.result : '';
      if (code !== 200) {
        let err = '';
        try {
          let j = JSON.parse(text) as SessionResponse;
          err = j.error !== undefined ? j.error : '';
        } catch (e) { /* 非 JSON */ }
        // proof 同样使用系统时钟；只修正握手时间不能修好后续下载签名，因此明确
        // 提示校准设备时间，不用无限重签掩盖持续的时钟错误。
        this.lastError_ = err === 'ts_out_of_window' ? '设备时间与加速服务不一致，请校准系统时间' :
          '握手失败 HTTP ' + code + (err.length > 0 ? '（' + err + '）' : '');
        AppLogger.warn(TAG, this.lastError_, null, LOG_DOMAIN_DOWNLOAD);
        this.clear_();
        return false;
      }

      let data = JSON.parse(text) as SessionResponse;
      let ticket = data.ticket !== undefined ? data.ticket : '';
      let sk = data.sessionKey !== undefined ? data.sessionKey : '';
      let needProof = data.requireProof !== undefined ? data.requireProof : true;
      let ttlSec = data.expiresIn;
      // JSON 强转不校验运行时类型。先核对凭据边界、协议布尔值及有效期限，再做
      // 任何 native 发布；30 秒是 native 自身停用余量，不能接受一开始就不可用的票据。
      if (typeof ticket !== 'string' || ticket.length === 0 || ticket.length > 4096 ||
        /[^\x21-\x7e]/.test(ticket) || typeof sk !== 'string' || sk.length > 512 ||
        /[^\x21-\x7e]/.test(sk) || typeof needProof !== 'boolean' ||
        (needProof && sk.length === 0) || typeof ttlSec !== 'number' || !Number.isFinite(ttlSec) ||
        ttlSec <= 30 || !Number.isSafeInteger(Date.now() + ttlSec * 1000)) {
        this.lastError_ = '加速服务返回了无效的票据或有效期';
        this.clear_();
        return false;
      }

      const expiresAt = Date.now() + ttlSec * 1000;
      const verificationError = await this.verifySession_(ticket, dev.deviceId);
      // 自检也是异步边界：关闭、重开或设备变化后，旧结果不能重新开启 native，
      // 旧失败也不能清掉新代次配置。仅在同一代次真正自检通过后发布内存凭据。
      if (!this.current_(generation)) return false;
      if (verificationError.length > 0 || Date.now() >= expiresAt - 30000) {
        this.lastError_ = verificationError.length > 0 ? verificationError : '加速票据已临近过期';
        this.clear_();
        return false;
      }

      this.ticket_ = ticket;
      this.sessionKey_ = sk;
      this.requireProof_ = needProof;
      this.expiresAt_ = expiresAt;
      this.lastError_ = '';

      // 注入 native：之后所有官方源下载自动经网关
      getRelayNativeBridge().configure(RELAY_BASE, ticket, sk, needProof, this.expiresAt_);
      this.refreshStatus();
      AppLogger.info(TAG,
        `加速已就绪：base=${RELAY_BASE} ttl=${ttlSec}s proof=${needProof ? 'on' : 'off'} skLen=${sk.length}`,
        LOG_DOMAIN_DOWNLOAD);

      this.scheduleRenew_(ttlSec, generation);
      return true;
    } catch (e) {
      if (!this.current_(generation)) return false;
      this.lastError_ = '无法连接加速服务：' + errMsg(e);
      AppLogger.warn(TAG, this.lastError_ + '（已回退直连）', null, LOG_DOMAIN_DOWNLOAD);
      this.clear_();
      return false;
    } finally {
      req.destroy();
    }
  }

  /**
   * 同一公开入口再验一次票据，检查 CDN 到源站的真实 IP 交付是否一致。
   * 返回空串表示设备身份核对成功，其他字符串仅作为不含凭据的用户错误提示。
   * 每次新建并在 finally 销毁 HTTP 对象；不缓存、不跟随响应 base、不持久化票据。
   */
  private async verifySession_(ticket: string, deviceId: string): Promise<string> {
    const request = http.createHttp();
    try {
      const response = await request.request(RELAY_BASE + '/api/v1/session/verify', {
        method: http.RequestMethod.GET,
        usingCache: false,
        expectDataType: http.HttpDataType.STRING,
        maxLimit: SESSION_RESPONSE_LIMIT,
        header: { 'User-Agent': 'amcl/1.0 (OHOS)', 'Authorization': 'Bearer ' + ticket,
          'Cache-Control': 'no-store' },
        connectTimeout: HANDSHAKE_TIMEOUT_MS,
        readTimeout: HANDSHAKE_TIMEOUT_MS,
      });
      const text = typeof response.result === 'string' ? response.result : '';
      const data = JSON.parse(text) as SessionVerification;
      if (response.responseCode === 200 && data.ok === true && data.deviceId === deviceId) return '';
      if (data.error === 'ticket_ip_mismatch') return '加速线路的客户端 IP 不一致，请重试或检查 CDN 回源配置';
      return '加速票据自检失败 HTTP ' + response.responseCode;
    } catch (e) {
      // 平台异常文本可能包含请求上下文，避免把 Bearer 或响应正文带进用户提示/日志。
      return '无法完成加速票据自检，请稍后重试';
    } finally {
      request.destroy();
    }
  }

  /** 到期前提前续签，保证长时间下载不断票 */
  private scheduleRenew_(ttlSec: number, generation: number): void {
    if (this.renewTimer_ >= 0) clearTimeout(this.renewTimer_);
    let delay = Math.max(30000, ttlSec * 1000 - RENEW_LEAD_MS);
    this.renewTimer_ = setTimeout(() => {
      this.renewTimer_ = -1;
      if (!this.current_(generation)) return;
      this.ensureSession().then((ok: boolean) => {
        if (!ok) AppLogger.warn(TAG, '票据续签失败，下载将回退直连', null, LOG_DOMAIN_DOWNLOAD);
      });
    }, delay);
  }
}

function errMsg(e: Object): string {
  let err = e as Error;
  if (err.message !== undefined && err.message.length > 0) return err.message;
  return String(e);
}

// ============================================================
//  单例
// ============================================================

let instance_: RelayClient | null = null;

export function getRelayClient(): RelayClient {
  if (instance_ === null) instance_ = new RelayClient();
  return instance_;
}

/** 生成/复用稳定 deviceId（调用方负责持久化；这里只提供生成逻辑） */
export function generateDeviceId(): string {
  // 32 hex 满足服务端 ^[A-Za-z0-9_-]{8,64}$
  return randomHex(16);
}
