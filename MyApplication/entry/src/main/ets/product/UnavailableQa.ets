import { common, Want } from '@kit.AbilityKit';

/** 发行产品的静态空装配。未装配设备会话、传输和回执实现，普通页面仍走原有业务入口。 */
export class ProductQa {
  static bind(_owner: Object, _versions: (action: string, args: string, id: string) => Promise<string>,
    _game: (action: string, args: string, id: string) => Promise<string>): void {}
  static unbind(_owner: Object): void {}
  static bindSurface(_name: string, _owner: Object,
    _handler: (action: string, args: string, id: string) => Promise<string>): void {}
  static unbindSurface(_name: string, _owner: Object): void {}
  static activate(_context: common.UIAbilityContext, _want: Want, _cold: boolean): boolean { return false; }
  static detach(_context: common.UIAbilityContext): void {}
  static sessionDirectory(): string { return ''; }
}
