import { LauncherVersionAccess } from '../main/ets/runtime/LauncherVersionAccess';

/** 可交付产品没有版本自动化分派或设备协议。 */
export class ProductQaVersions {
  static async run(_port: LauncherVersionAccess, _action: string, _json: string, _request: string,
    _session: () => string): Promise<string> { return ''; }
}
