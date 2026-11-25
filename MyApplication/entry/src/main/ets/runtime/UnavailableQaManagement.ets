import { LauncherManagementAccess } from './LauncherManagementAccess';

/** 非开发产品不注册设备会话，也不解析管理指令。 */
export class ProductQaManagement {
  async run(_port: LauncherManagementAccess, _action: string, _json: string, _id: string): Promise<string> { return ''; }
}
