/**
 * LogTags.ets — 全项目日志 tag 单一来源（Single Source of Truth）
 *
 * 防碰撞 + 命名一致性。全项目所有 hilog.* / AppLogger.* 调用的 tag 应从这里取。
 *
 * ArkTS 严格模式约束：
 *   - 不能用 `as const` 字典 + `typeof X[keyof typeof X]` 组合
 *     （arkts-no-untyped-obj-literals + arkts-no-type-query）
 *   - 改用 class + static readonly 字段，每个字段是 string 字面量
 *
 * 使用：
 *   import { LogTags } from '../common/LogTags';
 *   AppLogger.info(LogTags.SVC_DOWNLOAD, 'task done');
 *
 * 重点解决：
 *   - 'DownloadHistory' 在 service 和 page 同名碰撞 → 拆 SVC / PAGE 两个
 *   - 'MC_GAME' snake_case 特立独行 → 统一 PAGE_MC_GAME = 'McGamePage'
 *   - 'testTag' 占位符 → ENTRY_ABILITY / ENTRY_BACKUP
 *
 * 创建日期：2026-05-10（LOG-P1-3）
 * 关联：docs/guides/logging-system-review-and-plan.md 问题 6
 */
export class LogTags {
  // ---- Entry / Ability ----
  static readonly ENTRY_ABILITY:   string = 'EntryAbility';
  static readonly GAME_ABILITY:    string = 'GameAbility';
  static readonly ENTRY_BACKUP:    string = 'EntryBackupAbility';

  // ---- Pages ----
  static readonly PAGE_INDEX:                string = 'IndexPage';
  static readonly PAGE_MC_GAME:              string = 'McGamePage';
  static readonly PAGE_DOWNLOAD_HISTORY:     string = 'DownloadHistoryPage';
  static readonly PAGE_DEV_TOOLS:            string = 'DevToolsPage';
  static readonly PAGE_RENDER:               string = 'RenderPage';
  static readonly PAGE_VULKAN:               string = 'VulkanPage';
  static readonly PAGE_VERSION_SETTINGS:     string = 'VersionSettingsPage';

  // ---- Services（业务逻辑层）----
  static readonly SVC_DOWNLOAD:           string = 'DownloadManager';
  static readonly SVC_DOWNLOAD_HISTORY:   string = 'DownloadHistoryService'; // 与 PAGE_DOWNLOAD_HISTORY 区分
  static readonly SVC_DOWNLOAD_TASK:      string = 'DownloadTask';
  static readonly SVC_JDK:                string = 'JdkManager';
  static readonly SVC_LAUNCH_BUILDER:     string = 'LaunchProfileBuilder';
  static readonly SVC_PHASE_RUNNER:       string = 'PhaseRunner';
  static readonly SVC_MC_VERSION:         string = 'McVersionService';
  static readonly SVC_RUNTIME_DEPLOY:     string = 'RuntimeDeployer';
  static readonly SVC_PREFS:              string = 'PreferenceManager';
  static readonly SVC_METADATA_CACHE:     string = 'MetadataCacheStore';
  static readonly SVC_SOURCE_PROBER:      string = 'SourceProber';
  static readonly SVC_VERSION_MERGER:     string = 'VersionJsonMerger';
  static readonly SVC_VERSION_PARSER:     string = 'VersionParser';
  static readonly SVC_VULKAN_CAP:         string = 'VulkanCapability';

  // ---- Account（M2 正版登录）----
  static readonly ACCOUNT_MANAGER:    string = 'AccountManager';
  static readonly ACCOUNT_STORAGE:    string = 'AccountStorage';
  static readonly ACCOUNT_HUKS:       string = 'HuksCryptoProvider';
  static readonly ACCOUNT_MS:         string = 'MicrosoftAccount';
  static readonly ACCOUNT_OFFLINE:    string = 'OfflineAccount';
  static readonly ACCOUNT_OAUTH:      string = 'MicrosoftOAuth';
  static readonly ACCOUNT_XBL:        string = 'XboxLiveAuth';
  static readonly ACCOUNT_PROFILE:    string = 'MinecraftProfileApi';
  static readonly ACCOUNT_HTTP:       string = 'AccountHttpClient';

  // ---- Modloader ----
  static readonly MOD_MANAGER:        string = 'ModLoaderManager';
  static readonly MOD_FORGE:          string = 'ForgeService';
  static readonly MOD_FABRIC:         string = 'FabricService';
  static readonly MOD_MAVEN:          string = 'MavenUtils';
  static readonly MOD_FORGE_INSTALLER:string = 'ForgeInstallerUtils';

  // ---- Phases（启动管线）----
  static readonly PHASE_PREPARE:      string = 'PreparePhase';
  static readonly PHASE_CLIENT:       string = 'ClientPhase';
  static readonly PHASE_LIBRARIES:    string = 'LibrariesPhase';
  static readonly PHASE_ASSETS:       string = 'AssetsPhase';
  static readonly PHASE_MODLOADER:    string = 'ModloaderPhase';
  static readonly PHASE_MERGE:        string = 'MergePhase';

  // ---- Utils ----
  static readonly UTIL_DOWNLOADER:    string = 'McDownloader';
  static readonly UTIL_FONTCONFIG:    string = 'FontconfigUtils';
  static readonly UTIL_SANDBOX:       string = 'SandboxProbe';
  static readonly UTIL_LOGGER:        string = 'AppLogger';
  static readonly UTIL_REDACT:        string = 'Redact';

  // ---- UI Components ----
  static readonly UI_ACCOUNT_LIST:    string = 'AccountListSheet';
  static readonly UI_ADD_ACCOUNT:     string = 'AddAccountSheet';
  static readonly UI_VERSION_CONFIG:  string = 'VersionConfigPanel';
}
