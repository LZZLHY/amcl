import { AccountSheetActions, AddAccountActions } from './AccountSheetActions';

/** 发行产品的空装配。宿主动作和账号引用映射仅存在于开发目标。 */
export class ProductQaAccounts {
  static bind(_owner: Object, _make: () => AccountSheetActions): void {}
  static unbind(_owner: Object): void {}
  static addShown(_owner: Object, _actions: AddAccountActions): void {}
}
