import { ResourceBrowseAccess } from './ResourceBrowseAccess';

/** 发行产品的资源浏览保留正常业务，生命周期没有设备命令注册。 */
export class ProductQaResources {
  static bind(_owner: Object, _get: () => ResourceBrowseAccess): void {}
  static unbind(_owner: Object): void {}
}
