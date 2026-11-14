/**
 * 整合包正文在提交 Native 前的来源约束。首包和恢复计划可携带旧版本合成的 MCIM
 * 候选；仅改变列表排序不能保证这些正文遵守“官方”。这里保留原 URL 字节和顺序，
 * 只移除本启动器认识的第三方模组镜像。作者清单中的其他原始下载站仍是内容来源，
 * 不猜测或重写其签名 query；哈希、文件身份、Range 和自家网关均由原下载链负责。
 */
import { mirrorifyModrinthCdn } from './ModrinthUrls';
import { isMcimMirrorUrl } from './ModDownloadSourcePolicy';
import { buildCurseForgeOfficialFileUrls } from './CurseForgeUrls';

/**
 * 输入为已解析的精确候选，输出为当前安装策略允许的候选副本。
 * officialOnly 时无官方候选就返回空，交由调用者报告，不偷偷扩大来源或猜 CDN 地址。
 * 非严格模式保持既有 MR 镜像补链；本函数不改变 CF 原有候选顺序。
 */
export function buildModpackDownloadUrls(urls: string[], modrinth: boolean, officialOnly: boolean): string[] {
  const result: string[] = [];
  for (const url of urls) {
    // 与列表映射共用真实authority分类，旧恢复URL的端口/尾点不能绕过正文约束。
    if (officialOnly && isMcimMirrorUrl(url)) continue;
    // 已保存的旧归档、清单和恢复请求可能只含 edge。在交给下载器前补同文件的
    // 官方别名，保持原 URL、摘要、大小和来源策略，且不会为其他模式扩展候选。
    const candidates = officialOnly && !modrinth ? buildCurseForgeOfficialFileUrls(url) : [url];
    for (const candidate of candidates) if (result.indexOf(candidate) < 0) result.push(candidate);
  }
  if (!officialOnly && modrinth) {
    for (const url of urls) {
      const mirror = mirrorifyModrinthCdn(url);
      if (result.indexOf(mirror) < 0) result.push(mirror);
    }
  }
  return result;
}
