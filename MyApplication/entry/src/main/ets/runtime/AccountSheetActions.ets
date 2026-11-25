import { Account } from 'account';

/** 账号页持有持久化操作和确认世代；调用者只能按同一页已确认的目标继续。 */
export interface AccountRemovalChoice {
  target: Account;
  selectedId: string;
  epoch: number;
  confirmation: number;
}

export interface AddAccountActions {
  offline: (name: string) => Promise<string>;
  login: (provider: string) => Promise<boolean>;
}

export interface AccountSheetActions {
  ready: () => boolean;
  hasConfirmation: () => boolean;
  openAdd: () => void;
  close: () => void;
  select: (target: Account) => Promise<boolean>;
  prepareRemove: (id: string) => AccountRemovalChoice | undefined;
  confirmRemove: (choice: AccountRemovalChoice) => Promise<boolean>;
  cancelRemove: (choice: AccountRemovalChoice) => boolean;
}
