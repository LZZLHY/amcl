/**
 * entry 负责读取产品/系统/native 能力，结果写入 commons 的会话环境事实仓库。
 * 只在创建/准备当前启动时调用；历史分享只读取当时的快照，禁止用当前设备补历史空值。
 */
import { common, bundleManager } from '@kit.AbilityKit';
import deviceInfo from '@ohos.deviceInfo';
import { fileIo as fs } from '@kit.CoreFileKit';
import testNapi from 'libentry.so';
import { LedgerBeginMeta, SessionEnvironmentFact, sessionEnvironmentFact, updateSessionEnvironment } from 'commons';
import { LaunchProfile } from 'launch';
import { collectProductIdentity } from '../product/ProductIdentityCollector';

/** 已安装包版本是记录版本；读取失败显式未知，不使用开发常量冒充真实打包版本。 */
export function enrichSessionEnvironment(context: common.UIAbilityContext, activityId: number,
  meta: LedgerBeginMeta, profile?: LaunchProfile): LedgerBeginMeta {
  const identity = collectProductIdentity();
  let version: string = 'unknown';
  let versionCode: string = 'unknown';
  try {
    const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    version = info.versionName; versionCode = String(info.versionCode);
  } catch (e) { /* 真实安装信息不可得时保留明确未知。 */ }
  const facts: SessionEnvironmentFact[] = [
    sessionEnvironmentFact('launcher.name', 'AMCL', 'application'),
    sessionEnvironmentFact('launcher.version', version, 'bundleManager'),
    sessionEnvironmentFact('launcher.versionCode', versionCode, 'bundleManager'),
    sessionEnvironmentFact('launcher.product', identity.product, 'ProductBuildProfile'),
    sessionEnvironmentFact('launcher.channel', identity.storeChannel ? 'store' : 'sideload', 'ProductBuildProfile'),
    sessionEnvironmentFact('host.os', 'HarmonyOS', 'application.platform'),
    sessionEnvironmentFact('host.osVersion', identity.osFullName, 'deviceInfo.osFullName'),
    sessionEnvironmentFact('host.api', String(identity.apiVersion), 'deviceInfo.sdkApiVersion'),
    sessionEnvironmentFact('host.device', identity.deviceModel, 'deviceInfo.productModel'),
    sessionEnvironmentFact('host.brand', identity.deviceBrand, 'deviceInfo.brand'),
    sessionEnvironmentFact('host.abi', deviceInfo.abiList, 'deviceInfo.abiList'),
    sessionEnvironmentFact('game.instance', meta.gameVersionId ?? meta.title, 'launch.request'),
    sessionEnvironmentFact('gpu.model', '尚未取得运行线程的图形设备观测', 'graphics.runtime', 'unavailable'),
    sessionEnvironmentFact('gpu.vendor', '尚未初始化图形上下文', 'graphics.runtime', 'unavailable'),
    sessionEnvironmentFact('gpu.driver', '驱动信息未提供', 'graphics.runtime', 'unavailable'),
  ];
  try { facts.push(sessionEnvironmentFact('cpu.model', deviceInfo.chipType, 'deviceInfo.chipType')); }
  catch (e) { facts.push(sessionEnvironmentFact('cpu.model', '系统未提供芯片型号', 'deviceInfo.chipType', 'unavailable')); }
  try {
    const online: string = fs.readTextSync('/sys/devices/system/cpu/online').trim();
    let count: number = 0;
    for (const part of online.split(',')) {
      const range: string[] = part.split('-');
      count += range.length === 1 ? 1 : Number(range[1]) - Number(range[0]) + 1;
    }
    if (!(count > 0 && count <= 1024)) throw new Error('CPU 核心列表无效');
    facts.push(sessionEnvironmentFact('cpu.cores', String(count), 'sysfs.cpu.online'));
  } catch (e) { facts.push(sessionEnvironmentFact('cpu.cores', '系统未开放核心列表', 'sysfs.cpu.online', 'unavailable')); }
  try { facts.push(sessionEnvironmentFact('memory.physicalMb', String(testNapi.getDeviceMemoryMB()), 'native.sysconf')); }
  catch (e) { facts.push(sessionEnvironmentFact('memory.physicalMb', '读取失败', 'native.sysconf', 'unavailable')); }
  if (profile !== undefined) {
    facts.push(sessionEnvironmentFact('game.version', profile.baseGameVersion ?? profile.version, 'VersionParser'));
    facts.push(sessionEnvironmentFact('game.loader', profile.loaderType ?? 'unknown', 'VersionParser'));
    facts.push(sessionEnvironmentFact('game.loaderVersion', profile.loaderVersion ?? 'unknown', 'VersionParser'));
    facts.push(sessionEnvironmentFact('game.generation', profile.generation, 'LaunchProfile'));
    facts.push(sessionEnvironmentFact('java.major', profile.jdkVersion, 'LaunchProfile'));
    facts.push(sessionEnvironmentFact('java.arguments', profile.extraJvmArgs.join('\n'), 'LaunchProfile'));
    facts.push(sessionEnvironmentFact('memory.jvmMaxMb', String(profile.xmxMb), 'LaunchProfile'));
    if (profile.graphicsPlan !== undefined) {
      const plan = profile.graphicsPlan;
      facts.push(sessionEnvironmentFact('graphics.requestedProfile', plan.requestedProfile, 'LaunchProfile', 'planned'));
      facts.push(sessionEnvironmentFact('graphics.profile', plan.profile, 'LaunchProfile', 'planned'));
      facts.push(sessionEnvironmentFact('graphics.api', plan.apiFamily, 'LaunchProfile', 'planned'));
      facts.push(sessionEnvironmentFact('graphics.provider', plan.actualProvider, 'LaunchProfile', 'planned'));
      facts.push(sessionEnvironmentFact('graphics.windowProvider', plan.windowProvider, 'LaunchProfile', 'planned'));
    }
    meta.loaderType = profile.loaderType; meta.loaderVersion = profile.loaderVersion;
  }
  updateSessionEnvironment(context.filesDir, activityId, facts);
  meta.appVersion = version; meta.deviceModel = identity.deviceModel; meta.osVersion = identity.osFullName;
  return meta;
}
