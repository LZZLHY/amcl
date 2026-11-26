import { scriptManager } from '@kit.AbilityKit';
import { invokeSkill } from '../../../src/main/ets/launcherskill/PlatformReport';

/** 由 scripts/generate-launcher-skill.mjs 从产品动作契约生成，每项公开能力对应一个固定的业务方法。 */
export default class LauncherSkill {
  public async listPlayerAccounts(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "listPlayerAccounts", argv);
  }

  public async closePlayerAccounts(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "closePlayerAccounts", argv);
  }

  public async selectPlayerAccount(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "selectPlayerAccount", argv);
  }

  public async checkPlayerAccount(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "checkPlayerAccount", argv);
  }

  public async showPlayerProfile(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "showPlayerProfile", argv);
  }

  public async addOfflinePlayer(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "addOfflinePlayer", argv);
  }

  public async beginPlayerLogin(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "beginPlayerLogin", argv);
  }

  public async readPlayerLogin(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readPlayerLogin", argv);
  }

  public async refreshPlayerCredentials(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "refreshPlayerCredentials", argv);
  }

  public async requestRemovePlayer(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "requestRemovePlayer", argv);
  }

  public async openPlayerAppearance(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "openPlayerAppearance", argv);
  }

  public async readOfflineAppearance(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readOfflineAppearance", argv);
  }

  public async importAppearanceImage(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "importAppearanceImage", argv);
  }

  public async requestRemoveAppearanceAsset(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "requestRemoveAppearanceAsset", argv);
  }

  public async discardOfflineAppearance(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "discardOfflineAppearance", argv);
  }

  public async saveOfflineAppearance(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "saveOfflineAppearance", argv);
  }

  public async readPlayerRoles(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readPlayerRoles", argv);
  }

  public async choosePlayerRole(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "choosePlayerRole", argv);
  }

  public async readPlayerAppearance(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readPlayerAppearance", argv);
  }

  public async syncPlayerAppearance(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "syncPlayerAppearance", argv);
  }

  public async previewPlayerCape(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "previewPlayerCape", argv);
  }

  public async changePlayerCape(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "changePlayerCape", argv);
  }

  public async openMinecraftProfileSite(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "openMinecraftProfileSite", argv);
  }

  public async listControlLayouts(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "listControlLayouts", argv);
  }

  public async importControlLayout(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "importControlLayout", argv);
  }

  public async useControlLayout(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "useControlLayout", argv);
  }

  public async copyControlLayout(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "copyControlLayout", argv);
  }

  public async renameControlLayout(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "renameControlLayout", argv);
  }

  public async requestRemoveControlLayout(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "requestRemoveControlLayout", argv);
  }

  public async exportControlLayout(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "exportControlLayout", argv);
  }

  public async shareControlLayout(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "shareControlLayout", argv);
  }

  public async openLayoutWorkbench(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "openLayoutWorkbench", argv);
  }

  public async readControlWorkbench(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readControlWorkbench", argv);
  }

  public async finishControlWorkbench(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "finishControlWorkbench", argv);
  }

  public async addWorkbenchControl(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "addWorkbenchControl", argv);
  }

  public async editWorkbenchControl(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "editWorkbenchControl", argv);
  }

  public async setWorkbenchGeometry(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "setWorkbenchGeometry", argv);
  }

  public async setWorkbenchAppearance(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "setWorkbenchAppearance", argv);
  }

  public async setWorkbenchBinding(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "setWorkbenchBinding", argv);
  }

  public async arrangeWorkbenchSelection(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "arrangeWorkbenchSelection", argv);
  }

  public async editWorkbenchGroup(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "editWorkbenchGroup", argv);
  }

  public async readInputWorkbench(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readInputWorkbench", argv);
  }

  public async finishInputWorkbench(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "finishInputWorkbench", argv);
  }

  public async setTouchOption(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "setTouchOption", argv);
  }

  public async setLookOption(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "setLookOption", argv);
  }

  public async readWorkbenchOutcome(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readWorkbenchOutcome", argv);
  }

  public async getExportPlan(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getExportPlan", argv);
  }

  public async configureExport(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "configureExport", argv);
  }

  public async selectExportContent(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "selectExportContent", argv);
  }

  public async resetExportContent(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "resetExportContent", argv);
  }

  public async saveExportDraft(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "saveExportDraft", argv);
  }

  public async discardExportEdits(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "discardExportEdits", argv);
  }

  public async retryExport(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "retryExport", argv);
  }

  public async checkExportPlan(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "checkExportPlan", argv);
  }

  public async startExport(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "startExport", argv);
  }

  public async getExportTask(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getExportTask", argv);
  }

  public async cancelExportTask(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "cancelExportTask", argv);
  }

  public async listInstances(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "listInstances", argv);
  }

  public async getLauncherHome(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getLauncherHome", argv);
  }

  public async openLauncherSection(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "openLauncherSection", argv);
  }

  public async performStoreManagerAction(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "performStoreManagerAction", argv);
  }

  public async getLauncherTasks(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getLauncherTasks", argv);
  }

  public async moveInstanceBefore(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "moveInstanceBefore", argv);
  }

  public async selectGameInstance(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "selectGameInstance", argv);
  }

  public async openInstancePanel(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "openInstancePanel", argv);
  }

  public async getInstanceSettings(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getInstanceSettings", argv);
  }

  public async setInstanceJdk(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "setInstanceJdk", argv);
  }

  public async setInstanceResolution(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "setInstanceResolution", argv);
  }

  public async requestInstanceDeletion(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "requestInstanceDeletion", argv);
  }

  public async listGameCatalog(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "listGameCatalog", argv);
  }

  public async listGameLoaders(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "listGameLoaders", argv);
  }

  public async installGameInstance(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "installGameInstance", argv);
  }

  public async launchGameInstance(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "launchGameInstance", argv);
  }

  public async getLauncherOperation(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getLauncherOperation", argv);
  }

  public async listWorlds(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "listWorlds", argv);
  }

  public async importWorlds(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "importWorlds", argv);
  }

  public async exportWorld(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "exportWorld", argv);
  }

  public async requestWorldDeletion(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "requestWorldDeletion", argv);
  }

  public async listInstanceFiles(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "listInstanceFiles", argv);
  }

  public async navigateInstanceParent(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "navigateInstanceParent", argv);
  }

  public async createInstanceFolder(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "createInstanceFolder", argv);
  }

  public async enterInstanceFolder(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "enterInstanceFolder", argv);
  }

  public async importInstanceFiles(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "importInstanceFiles", argv);
  }

  public async exportInstanceFile(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "exportInstanceFile", argv);
  }

  public async requestInstanceFileDeletion(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "requestInstanceFileDeletion", argv);
  }

  public async requestInstanceFileRename(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "requestInstanceFileRename", argv);
  }

  public async searchResources(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "searchResources", argv);
  }

  public async nextResourcePage(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "nextResourcePage", argv);
  }

  public async getResourceVersions(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getResourceVersions", argv);
  }

  public async prepareResourceInstall(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "prepareResourceInstall", argv);
  }

  public async selectResourceDependency(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "selectResourceDependency", argv);
  }

  public async installResourcePlan(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "installResourcePlan", argv);
  }

  public async getResourceInstall(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getResourceInstall", argv);
  }

  public async closeResourceDetails(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "closeResourceDetails", argv);
  }

  public async chooseLocalModpack(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "chooseLocalModpack", argv);
  }

  public async prepareLocalModpack(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "prepareLocalModpack", argv);
  }

  public async installLocalModpack(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "installLocalModpack", argv);
  }

  public async listInstalledResources(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "listInstalledResources", argv);
  }

  public async refreshInstalledResources(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "refreshInstalledResources", argv);
  }

  public async importInstalledResources(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "importInstalledResources", argv);
  }

  public async verifyInstalledMods(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "verifyInstalledMods", argv);
  }

  public async setInstalledResourceEnabled(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "setInstalledResourceEnabled", argv);
  }

  public async checkInstalledModUpdate(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "checkInstalledModUpdate", argv);
  }

  public async ignoreInstalledModUpdate(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "ignoreInstalledModUpdate", argv);
  }

  public async requestInstalledResourceDelete(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "requestInstalledResourceDelete", argv);
  }

  public async repairInstalledMod(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "repairInstalledMod", argv);
  }

  public async updateInstalledMod(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "updateInstalledMod", argv);
  }

  public async listDownloadQueue(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "listDownloadQueue", argv);
  }

  public async getDownloadTaskDetail(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getDownloadTaskDetail", argv);
  }

  public async controlDownloadTask(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "controlDownloadTask", argv);
  }

  public async clearFinishedTasks(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "clearFinishedTasks", argv);
  }

  public async getModpackChoices(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getModpackChoices", argv);
  }

  public async changeModpackChoice(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "changeModpackChoice", argv);
  }

  public async confirmModpackChoices(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "confirmModpackChoices", argv);
  }

  public async listResourceTargets(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "listResourceTargets", argv);
  }

  public async selectResourceTarget(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "selectResourceTarget", argv);
  }

  public async listModpackRecovery(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "listModpackRecovery", argv);
  }

  public async continueModpackRecovery(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "continueModpackRecovery", argv);
  }

  public async dismissModpackRecovery(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "dismissModpackRecovery", argv);
  }

  public async resourceProjectSource(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "resourceProjectSource", argv);
  }

  public async renameGameInstance(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "renameGameInstance", argv);
  }

  public async verifyGameInstance(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "verifyGameInstance", argv);
  }

  public async repairGameInstance(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "repairGameInstance", argv);
  }

  public async clearIncompleteInstances(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "clearIncompleteInstances", argv);
  }

  public async getInstancePack(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getInstancePack", argv);
  }

  public async repairInstancePack(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "repairInstancePack", argv);
  }

  public async copyInstancePackMissing(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "copyInstancePackMissing", argv);
  }

  public async openInstanceSystemFolder(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "openInstanceSystemFolder", argv);
  }

  public async setInstanceLanguage(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "setInstanceLanguage", argv);
  }

  public async getLaunchChecks(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getLaunchChecks", argv);
  }

  public async chooseLaunchCheckAction(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "chooseLaunchCheckAction", argv);
  }

  public async getGraphicsRecovery(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getGraphicsRecovery", argv);
  }

  public async showCatalogVersion(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "showCatalogVersion", argv);
  }

  public async getGameVersionRequirements(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getGameVersionRequirements", argv);
  }

  public async listActivityHistory(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "listActivityHistory", argv);
  }

  public async openHistoryRecord(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "openHistoryRecord", argv);
  }

  public async manageActivityHistory(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "manageActivityHistory", argv);
  }

  public async inspectGameInstance(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "inspectGameInstance", argv);
  }

  public async focusRunningGame(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "focusRunningGame", argv);
  }

  public async getTaskControlOperation(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getTaskControlOperation", argv);
  }

  public async findLauncherSettings(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "findLauncherSettings", argv);
  }

  public async readLauncherSetting(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readLauncherSetting", argv);
  }

  public async openLauncherSetting(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "openLauncherSetting", argv);
  }

  public async setLauncherChoice(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "setLauncherChoice", argv);
  }

  public async setLauncherSwitch(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "setLauncherSwitch", argv);
  }

  public async setLauncherAppearance(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "setLauncherAppearance", argv);
  }

  public async setLauncherSheetHeight(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "setLauncherSheetHeight", argv);
  }

  public async setLauncherLightMaterial(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "setLauncherLightMaterial", argv);
  }

  public async setLauncherMemory(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "setLauncherMemory", argv);
  }

  public async scheduleTouchGuide(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "scheduleTouchGuide", argv);
  }

  public async prepareStorageChange(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "prepareStorageChange", argv);
  }

  public async listGraphicsBackends(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "listGraphicsBackends", argv);
  }

  public async selectGraphicsBackend(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "selectGraphicsBackend", argv);
  }

  public async getGlobalResolution(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getGlobalResolution", argv);
  }

  public async setGlobalResolution(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "setGlobalResolution", argv);
  }

  public async getGameLogRetention(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getGameLogRetention", argv);
  }

  public async setGameLogRetention(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "setGameLogRetention", argv);
  }

  public async bluetoothMidiAccess(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "bluetoothMidiAccess", argv);
  }

  public async getModMicrophone(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getModMicrophone", argv);
  }

  public async configureModMicrophone(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "configureModMicrophone", argv);
  }

  public async getDesktopInteraction(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getDesktopInteraction", argv);
  }

  public async setDesktopInteraction(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "setDesktopInteraction", argv);
  }

  public async openLauncherDiagnostic(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "openLauncherDiagnostic", argv);
  }

  public async readDiagnosticObservation(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readDiagnosticObservation", argv);
  }

  public async listJavaRuntimes(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "listJavaRuntimes", argv);
  }

  public async refreshJavaRuntimes(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "refreshJavaRuntimes", argv);
  }

  public async pickJavaRuntimeArchive(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "pickJavaRuntimeArchive", argv);
  }

  public async manageJavaRuntime(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "manageJavaRuntime", argv);
  }

  public async inspectNetwork(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "inspectNetwork", argv);
  }

  public async getLauncherUpdate(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getLauncherUpdate", argv);
  }

  public async checkLauncherUpdate(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "checkLauncherUpdate", argv);
  }

  public async selectLauncherUpdateChannel(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "selectLauncherUpdateChannel", argv);
  }

  public async openUpdateSource(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "openUpdateSource", argv);
  }

  public async installRecommendedUpdate(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "installRecommendedUpdate", argv);
  }

  public async updateAccountAccess(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "updateAccountAccess", argv);
  }

  public async getActiveLauncherUpdate(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getActiveLauncherUpdate", argv);
  }

  public async controlActiveLauncherUpdate(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "controlActiveLauncherUpdate", argv);
  }

  public async navigateLauncherSettings(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "navigateLauncherSettings", argv);
  }

  public async readSettingHandoff(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readSettingHandoff", argv);
  }

  public async copyLauncherDiagnostic(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "copyLauncherDiagnostic", argv);
  }

  public async getUpdateNotice(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getUpdateNotice", argv);
  }

  public async chooseRuntimeUpdateItem(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "chooseRuntimeUpdateItem", argv);
  }

  public async answerUpdateNotice(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "answerUpdateNotice", argv);
  }

  public async readJavaArchiveImport(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readJavaArchiveImport", argv);
  }

  public async getMobileInputMode(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getMobileInputMode", argv);
  }

  public async setMobileInputMode(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "setMobileInputMode", argv);
  }

  public async readUpdatePackageSelection(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readUpdatePackageSelection", argv);
  }

  public async getLauncherState(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getLauncherState", argv);
  }

  public async retryLauncherInitialization(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "retryLauncherInitialization", argv);
  }

  public async openLauncherLog(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "openLauncherLog", argv);
  }

  public async openRecentGameLog(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "openRecentGameLog", argv);
  }

  public async openPlayerSupport(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "openPlayerSupport", argv);
  }

  public async readMessages(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readMessages", argv);
  }

  public async openMessage(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "openMessage", argv);
  }

  public async markAllMessagesRead(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "markAllMessagesRead", argv);
  }

  public async requestClearMessages(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "requestClearMessages", argv);
  }

  public async readLauncherAbout(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readLauncherAbout", argv);
  }

  public async openStoreRunSettings(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "openStoreRunSettings", argv);
  }

  public async readReleaseNotes(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readReleaseNotes", argv);
  }

  public async openLatestRelease(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "openLatestRelease", argv);
  }

  public async readLocalPolicy(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readLocalPolicy", argv);
  }

  public async readSharedLogs(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readSharedLogs", argv);
  }

  public async viewSharedLog(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "viewSharedLog", argv);
  }

  public async requestRevokeSharedLog(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "requestRevokeSharedLog", argv);
  }

  public async readActivity(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readActivity", argv);
  }

  public async readActivityEvents(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readActivityEvents", argv);
  }

  public async setActivityRetention(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "setActivityRetention", argv);
  }

  public async requestActivityRemoval(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "requestActivityRemoval", argv);
  }

  public async exportActivityEvidence(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "exportActivityEvidence", argv);
  }

  public async reviewActivityShare(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "reviewActivityShare", argv);
  }

  public async readHistoricalAnalysis(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readHistoricalAnalysis", argv);
  }

  public async readActivityStorage(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readActivityStorage", argv);
  }

  public async setActivityAlert(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "setActivityAlert", argv);
  }

  public async readHomeNotification(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readHomeNotification", argv);
  }

  public async actOnHomeNotification(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "actOnHomeNotification", argv);
  }

  public async readSupportPage(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readSupportPage", argv);
  }

  public async retrySupportPage(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "retrySupportPage", argv);
  }

  public async viewSupportInBrowser(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "viewSupportInBrowser", argv);
  }

  public async copyActivityEvidence(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "copyActivityEvidence", argv);
  }

  public async copyActivityEvent(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "copyActivityEvent", argv);
  }

  public async readActivityFindings(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readActivityFindings", argv);
  }

  public async readLauncherDiagnostics(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readLauncherDiagnostics", argv);
  }

  public async readSystemBackupStatus(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "readSystemBackupStatus", argv);
  }

  public async getActivityShareOutcome(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getActivityShareOutcome", argv);
  }

  public async getActivityChoiceOutcome(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getActivityChoiceOutcome", argv);
  }

  public async getLauncherHandoff(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    await invokeSkill(info, "getLauncherHandoff", argv);
  }

}
