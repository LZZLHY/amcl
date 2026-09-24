import { DistributionPolicy } from 'commons';
/**
 * RelayClient.ets — AMCL 加速网关客户端（ArkTS 侧）
 *
 * 职责边界（与 native 的 relay.cpp 配合）：
 *   ArkTS（本文件）
 *     · 生成/持久化 deviceId
 *     · 用内置密钥做 HMAC 握手，换取 ticket + sessionKey
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

/** 网关基址。以后换域名只改这里。 */
export const RELAY_BASE: string = 'https://amcl.lovedhy.cn/dl';

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

export interface RelayStatus {
  /** 用户开关 */
  enabled: boolean;
  /** 是否已成功握手且票据有效 */
  active: boolean;
  /** 最近一次失败原因（用于设置页提示） */
  lastError: string;
  /** 票据到期时刻（ms），0 = 无 */
  expiresAt: number;
  /** native 侧统计 */
  native: RelayStatsNative | null;
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
  private renewTimer_: number = -1;

  /** 设备信息由调用方（Index）提供，避免本模块依赖 bundleManager/deviceInfo */
  setDeviceInfo(info: RelayDeviceInfo): void {
    this.device_ = info;
  }

  isEnabled(): boolean { return this.enabled_; }

  status(): RelayStatus {
    let native: RelayStatsNative | null = null;
    try { native = getRelayNativeBridge().stats(); } catch (e) { native = null; }
    return {
      enabled: this.enabled_,
      active: this.enabled_ && this.ticket_.length > 0 && Date.now() < this.expiresAt_,
      lastError: this.lastError_,
      expiresAt: this.expiresAt_,
      native,
    };
  }

  /**
   * 打开/关闭加速。
   * 打开时立刻尝试握手；失败不抛异常，只记录 lastError 并保持直连
   * （UI 可通过 status().lastError 提示用户）。
   */
  async setEnabled(on: boolean): Promise<boolean> {
    on = on && DistributionPolicy.allowPublisherServices();
    this.enabled_ = on;
    if (!on) {
      this.clear_();
      AppLogger.info(TAG, '加速下载已关闭，恢复直连与原有源偏好', LOG_DOMAIN_DOWNLOAD);
      return false;
    }
    return this.ensureSession();
  }

  /** 确保有可用票据；已有且未临近过期则直接返回 true */
  async ensureSession(): Promise<boolean> {
    if (!this.enabled_ || !DistributionPolicy.allowPublisherServices()) return false;
    if (this.ticket_.length > 0 && Date.now() < this.expiresAt_ - RENEW_LEAD_MS) return true;
    // 并发去重：多处同时触发只发一次握手
    if (this.handshakeInFlight_ !== null) return this.handshakeInFlight_;
    this.handshakeInFlight_ = this.handshake_();
    let ok = await this.handshakeInFlight_;
    this.handshakeInFlight_ = null;
    return ok;
  }

  private clear_(): void {
    this.ticket_ = '';
    this.sessionKey_ = '';
    this.expiresAt_ = 0;
    if (this.renewTimer_ >= 0) {
      clearTimeout(this.renewTimer_);
      this.renewTimer_ = -1;
    }
    try { getRelayNativeBridge().clear(); } catch (e) { /* native 未就绪时忽略 */ }
  }

  private async handshake_(): Promise<boolean> {
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
        header: {
          'Content-Type': 'application/json',
          'User-Agent': 'amcl/1.0 (OHOS)',
          'X-AMCL-Key': APP_KEY_ID,
          'X-AMCL-Ts': String(ts),
          'X-AMCL-Nonce': nonce,
          'X-AMCL-Sig': sig,
        },
        extraData: body,
        connectTimeout: HANDSHAKE_TIMEOUT_MS,
        readTimeout: HANDSHAKE_TIMEOUT_MS,
      });

      let code = resp.responseCode;
      let text = typeof resp.result === 'string' ? resp.result : '';
      if (code !== 200) {
        let err = '';
        try {
          let j = JSON.parse(text) as SessionResponse;
          err = j.error !== undefined ? j.error : '';
        } catch (e) { /* 非 JSON */ }
        this.lastError_ = '握手失败 HTTP ' + code + (err.length > 0 ? '（' + err + '）' : '');
        AppLogger.warn(TAG, this.lastError_, null, LOG_DOMAIN_DOWNLOAD);
        this.clear_();
        return false;
      }

      let data = JSON.parse(text) as SessionResponse;
      let ticket = data.ticket !== undefined ? data.ticket : '';
      let sk = data.sessionKey !== undefined ? data.sessionKey : '';
      let needProof = data.requireProof !== undefined ? data.requireProof : true;
      let ttlSec = data.expiresIn !== undefined ? data.expiresIn : 1800;
      if (ticket.length === 0 || (needProof && sk.length === 0)) {
        this.lastError_ = '握手响应缺少票据或会话密钥';
        this.clear_();
        return false;
      }

      this.ticket_ = ticket;
      this.sessionKey_ = sk;
      this.requireProof_ = needProof;
      this.expiresAt_ = Date.now() + ttlSec * 1000;
      this.lastError_ = '';

      // 注入 native：之后所有官方源下载自动经网关
      getRelayNativeBridge().configure(RELAY_BASE, ticket, sk, needProof, this.expiresAt_);
      AppLogger.info(TAG,
        `加速已就绪：base=${RELAY_BASE} ttl=${ttlSec}s proof=${needProof ? 'on' : 'off'} skLen=${sk.length}`,
        LOG_DOMAIN_DOWNLOAD);

      this.scheduleRenew_(ttlSec);
      return true;
    } catch (e) {
      this.lastError_ = '无法连接加速服务：' + errMsg(e);
      AppLogger.warn(TAG, this.lastError_ + '（已回退直连）', null, LOG_DOMAIN_DOWNLOAD);
      this.clear_();
      return false;
    } finally {
      req.destroy();
    }
  }

  /** 到期前提前续签，保证长时间下载不断票 */
  private scheduleRenew_(ttlSec: number): void {
    if (this.renewTimer_ >= 0) clearTimeout(this.renewTimer_);
    let delay = Math.max(30000, ttlSec * 1000 - RENEW_LEAD_MS);
    this.renewTimer_ = setTimeout(() => {
      this.renewTimer_ = -1;
      if (!this.enabled_) return;
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
