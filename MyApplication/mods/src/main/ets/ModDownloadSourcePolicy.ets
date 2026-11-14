/**
 * MR/CF共用的纯正文来源契约。输入是保存的偏好和网关开关意图，不访问会随握手/
 * 熔断变化的usable，不缓存状态，不改写偏好。调用方在入队/恢复时捕获布尔约束。
 */
export function isOfficialModDownloadRequired(preference: string, gatewayEnabled: boolean): boolean {
  return gatewayEnabled || preference === 'official';
}

/**
 * 精确识别已知MCIM镜像authority：端口、大小写、尾点及userinfo不改变真实主机。
 * 相似前缀和未知作者站点仍保留原URL/query；本函数不猜测其来源身份或等价CDN。
 */
export function isMcimMirrorUrl(url: string): boolean {
  let match = /^https?:\/\/([^/?#]+)(?:\/|\?|#|$)/i.exec(url);
  if (match === null) return false;
  let authority = match[1];
  let host = authority.substring(authority.lastIndexOf('@') + 1)
    .replace(/:[0-9]+$/, '').replace(/\.$/, '').toLowerCase();
  return host === 'mod.mcimirror.top';
}
