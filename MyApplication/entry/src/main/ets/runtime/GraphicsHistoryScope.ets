/** 从只读HAP字节、设备/驱动事实与真实游戏清单构造历史作用域，不缓存本局窗口准入。 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import deviceInfo from '@ohos.deviceInfo';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { evidenceFileDigestSync, evidenceTextDigest, evidenceHex, AppLogger } from 'commons';
import { GraphicsProfileInput } from 'launch';
import { PreferenceManager } from 'feature_system';
import { GraphicsHistoryStore } from './GraphicsHistoryStore';

let cachedArtifactScope: string = '';
let cachedBundle: string = '';
/** HAP库在当前进程只读，进程重启后重新取字节；不能仅用产品名或注册表版本代替制品身份。 */
function artifactScope(context: common.UIAbilityContext): string {
  if (cachedArtifactScope.length > 0 && cachedBundle === context.bundleCodeDir) return cachedArtifactScope;
  const parts: string[] = [];
  for (const name of ['libentry.so', 'libamcl_graphics_runtime.so', 'libamcl_gl_host.so', 'libmobilegl.so',
    'libgl4es.so', 'libglfw.so', 'libSDL3.so', 'liblwjgl.so']) {
    parts.push(name + ':' + evidenceFileDigestSync(context.bundleCodeDir + '/libs/arm64/' + name));
  }
  const javaBytes = context.resourceManager.getRawFileContentSync('amcl-launcher.jar');
  const digest = cryptoFramework.createMd('SHA256'); digest.updateSync({ data: javaBytes });
  parts.push('launcher:' + evidenceHex(digest.digestSync().data));
  cachedArtifactScope = evidenceTextDigest(parts.join('\n')); cachedBundle = context.bundleCodeDir;
  return cachedArtifactScope;
}
/** 任何可选历史IO/身份缺失均只关闭历史；现有静态选择和真实native准入继续执行。 */
export function attachGraphicsHistory(context: common.UIAbilityContext, input: GraphicsProfileInput, manifestPath: string,
  versionId: string): void {
  if (input.availabilityOnly || (input.graphicsProfileExplicit === true && input.graphicsProfilePreference !== 'auto')) return;
  try {
    let driver: string = '';
    for (const result of input.capabilityResults ?? []) if (result.evidenceProfileId === 'mobilegl') driver = result.driverIdentity ?? '';
    if (!new RegExp('^[0-9]+:[0-9]+:[0-9]+:[0-9a-f]{32}$').test(driver) || deviceInfo.osFullName.length === 0
      || input.realMcVersion.length === 0 || fs.statSync(manifestPath).size > 2097152) return;
    const parts: string[] = ['graphics-history-scope-v1', deviceInfo.productModel, deviceInfo.osFullName,
      String(deviceInfo.sdkApiVersion), driver, artifactScope(context), input.realMcVersion,
      input.usesSdl3 ? 'SDL3' : 'GLFW', String(input.gameApi), evidenceTextDigest(fs.readTextSync(manifestPath)),
      evidenceTextDigest(JSON.stringify(new PreferenceManager(context).resolveLaunch(versionId)))];
    input.graphicsHistoryScope = evidenceTextDigest(parts.join('\n'));
    input.graphicsHistory = GraphicsHistoryStore.hints(context.filesDir, input.graphicsHistoryScope, Date.now());
  } catch (error) { AppLogger.warn('GraphicsHistory', 'Optional graphics history scope unavailable', error); }
}
