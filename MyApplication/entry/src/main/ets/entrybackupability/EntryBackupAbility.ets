import { BackupExtensionAbility, BundleVersion } from '@kit.CoreFileKit';
import { AppLogger } from 'commons';
import { LogTags } from 'commons';
import { LOG_DOMAIN_LAUNCH } from 'commons';
import { observeSystemBackupCallback } from '../runtime/SystemBackupState';

// 2026-05-10（LOG-P0-3）：从 'testTag' 占位符迁移到 LogTags.ENTRY_BACKUP。
const TAG = LogTags.ENTRY_BACKUP;

export default class EntryBackupAbility extends BackupExtensionAbility {
  async onBackup() {
    AppLogger.info(TAG, 'onBackup ok', LOG_DOMAIN_LAUNCH);
    observeSystemBackupCallback(this.context.cacheDir, 'backup');
  }

  async onRestore(bundleVersion: BundleVersion) {
    AppLogger.info(TAG, `onRestore ok ${JSON.stringify(bundleVersion)}`, LOG_DOMAIN_LAUNCH);
    observeSystemBackupCallback(this.context.cacheDir, 'restore');
  }
}
