import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { DownloadManager } from '../download/DownloadManager';
import { canRelayPublicMcMetadata } from '../download/SourceProber';
import { safeBaseName } from '../modloader/MavenUtils';
import { getMetadataCacheStore } from './MetadataCacheStore';
import { officialVersionEntry } from './McVersionManifest';

/** 校验产品官方索引列出的版本 JSON 原字节。应用的发布名、目录名、第三方 URL 均不能授权返回正文。 */
export async function verifiedVanillaMetadata(id: string): Promise<string | null> {
  if (!id || id !== safeBaseName(id)) return null;
  const entry = await officialVersionEntry(id);
  if (!entry || entry.id !== id || typeof entry.sha1 !== 'string' || !/^[a-f0-9]{40}$/.test(entry.sha1)) return null;
  const address = /^https:\/\/(?:piston-meta|launchermeta)\.mojang\.com\/v1\/packages\/([a-f0-9]{40})\/[^/?#]+\.json$/.exec(entry.url);
  if (!address || address[1] !== entry.sha1) return null;
  const store = getMetadataCacheStore();
  const cached = store.isReady() ? store.get(entry.url, -1) : null;
  const digestMatches = (text: string): boolean => {
    if (!text || text.length > 1024 * 1024) return false;
    const digest = cryptoFramework.createMd('SHA1');
    digest.updateSync({ data: new util.TextEncoder().encodeInto(text) });
    let hex = '';
    for (const n of digest.digestSync().data) hex += n.toString(16).padStart(2, '0');
    return hex === entry.sha1;
  };
  if (cached !== null && digestMatches(cached)) return cached;
  const response = await DownloadManager.instance().fetchTextEx(entry.url, [], 12, undefined, 1024 * 1024,
    canRelayPublicMcMetadata([entry.url]));
  if (response.statusCode !== 200 || !digestMatches(response.body)) return null;
  if (store.isReady()) store.put(entry.url, response.body, response.headers);
  return response.body;
}
