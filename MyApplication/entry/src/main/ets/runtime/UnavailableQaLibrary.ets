import { LocalResourceAccess } from './LocalResourceAccess';
/** 普通发行渠道不编入资源操作接收器。 */
export class ProductQaLibrary {
  async run(_access: LocalResourceAccess, _action: string, _json: string, _id: string): Promise<string> { return ''; }
}
