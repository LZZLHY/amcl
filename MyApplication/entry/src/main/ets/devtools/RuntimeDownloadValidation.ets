/**
 * default/TestHooks的传输边界夹具。只将固定运行时目录/公开JDK原件地址映射到本机回环，
 * 不改JDK业务选择、签名、摘要或安装事务，不接受Want中的URL、密钥或文件路径。
 * 隔离验签键由专用QA构建资源提供，不在这里替换产品信任根；正式产品完全不读取夹具。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { DiagnosticPolicy, AppLogger } from 'commons';

interface ValidationRoute { url: string; relativePath: string; }
interface ValidationTransport { schema: number; nonce: string; port: number; routes: ValidationRoute[]; }
export interface ValidationTransportPort { installValidationTransport(resolver: (url: string) => string): void; }

/** 只允许现有目录来源和固定发行仓；授权服务、账户及任意第三方地址不能被本夹具接管。 */
function allowedRuntimeSource(url: string): boolean {
  return new RegExp('^https://amcl[.]lovedhy[.]cn/runtimes/(catalog/v[12]/(stable|preview)[.]json|packages/[A-Za-z0-9._-]+[.]zip)$').test(url) ||
    new RegExp('^(https://(ghfast[.]top|gh-proxy[.]com)/)?https://raw[.]githubusercontent[.]com/LZZLHY/mc-ohos-resources/main/catalog/v[12]/(stable|preview)[.]json$').test(url) ||
    new RegExp('^https://github[.]com/LZZLHY/mc-ohos-resources/releases/download/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+[.]zip$').test(url);
}

/** 固定沙箱文件只有显式设备验收准备才会创建；解析失败安装拒绝器，不能悄悄改用真实网络。 */
export function installRuntimeDownloadValidation(context: Context, engine: ValidationTransportPort): void {
  if (!DiagnosticPolicy.hasTestHooks()) return;
  const path = context.filesDir + '/runtime-download-validation.json';
  if (!fs.accessSync(path)) return;
  try {
    const stat=fs.statSync(path);
    if (!stat.isFile() || stat.size <= 0 || stat.size > 65536) throw new Error('运行时验收夹具大小无效');
    const value=JSON.parse(fs.readTextSync(path)) as ValidationTransport;
    if (value.schema !== 1 || !new RegExp('^[a-z0-9-]{8,64}$').test(value.nonce) || !Number.isSafeInteger(value.port) ||
      value.port < 1024 || value.port > 65535 || !Array.isArray(value.routes) || value.routes.length === 0 || value.routes.length > 64) {
      throw new Error('运行时验收传输声明无效');
    }
    const routes: Record<string,string> = {};
    for (const route of value.routes) {
      if (typeof route.url !== 'string' || !allowedRuntimeSource(route.url) || routes[route.url] !== undefined ||
        typeof route.relativePath !== 'string' || !new RegExp('^(catalog/v[12]/(stable|preview)[.]json|archives/[0-9a-f]{64}/[A-Za-z0-9._-]+[.]zip)$').test(route.relativePath)) {
        throw new Error('运行时验收传输路径无效');
      }
      routes[route.url]='http://127.0.0.1:'+value.port.toString()+'/'+route.relativePath;
    }
    engine.installValidationTransport((url: string): string => routes[url] ?? url);
    AppLogger.info('RuntimeValidation','已启用隔离传输，nonce='+value.nonce+'；签名/哈希/安装仍走生产路径');
  } catch (error) {
    engine.installValidationTransport((_url: string): string => { throw new Error('运行时验收夹具无效，未发出下载'); });
    throw error as Error;
  }
}
