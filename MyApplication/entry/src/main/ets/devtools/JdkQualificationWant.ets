/**
 * default 调试包的固定平台验证入口。只接受明确的探针名和有界 nonce，
 * 通过同一注册表分派；不接收命令、URL 或待执行文件路径。
 */
import { common, Want } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { AppLogger, AtomicFileWriter, DiagnosticPolicy, LOG_DOMAIN_LAUNCH } from 'commons';
import { GameStorage } from 'feature_system';
import { nativeProbeRegistry } from './NativeProbeRegistry';
import { findProbe, runProbe, ProbeOutcome } from './ProbeRegistryModel';

let running: boolean = false;
let lastNonce: string = '';
interface JdkPlatformReport {
  nonce: string;
  startedAt: number;
  finishedAt: number;
  transportOk: boolean;
  text: string;
  error: string | null;
}

/** 固定四行协议只接受本应用上下文和GameStorage现有来源，不从Want读取任何路径。
 * 不使用resolveMcDir(EXTERNAL)，避免外部不可用时回落沙箱而形成假的外部测试通过。
 * nonce目录由资格候选预置；独占claim拒绝再次发布，原子写沿用公共短写/fsync合同。
 */
function preparePermissionRoots(context: common.UIAbilityContext, nonce: string): void {
  const directory: string = context.filesDir + '/jdk-runtime-qualification/' + nonce;
  const state = fs.lstatSync(directory);
  if (!state.isDirectory() || state.isSymbolicLink()) throw new Error('权限资格根必须是既有真实目录');
  const validPath = (value: string): boolean => value.length > 0 && value.length <= 1024 &&
    value.startsWith('/') && !/[\r\n\x00]/.test(value);
  if (!validPath(context.filesDir)) throw new Error('应用filesDir不满足权限资格记录边界');
  const source: string = GameStorage.isTabletSilent() ? 'environment' : 'phone-cache';
  const selected: string = GameStorage.externalAppDir();
  const external: string = validPath(selected) ? selected : '';
  const destination: string = directory + '/permission-roots.txt';
  // API没有O_EXCL选项；固定独占目录让同一nonce只能拥有一个发布者。失败现场保留，
  // 下一次使用新nonce，不覆盖已有输入或在异常后继续启动本轮Native测量。
  fs.mkdirSync(directory + '/permission-roots.claim');
  if (fs.accessSync(destination)) throw new Error('本nonce已存在权限根记录，拒绝覆盖');
  AtomicFileWriter.write(destination, 'AMCL-PERM-ROOTS-1\n' + context.filesDir + '\n' + external + '\n' + source + '\n');
}

/** 异步执行并保存完整原文；transportOk 只代表调用完成，不宣告每项平台能力通过。 */
export function runJdkQualificationWant(context: common.UIAbilityContext, want: Want): void {
  if (!DiagnosticPolicy.hasTestHooks() || running) return;
  const kind = want.parameters?.['amclJdkProbe'];
  if (kind !== 'platform' && kind !== 'java' && kind !== 'process') return;
  const nonce = want.parameters?.['amclJdkProbeNonce'];
  if (typeof nonce !== 'string' || !/^[a-z0-9-]{1,40}$/.test(nonce) || nonce === lastNonce) return;
  let major: string = '';
  let profile: string = 'basic';
  if (kind === 'java') {
    const requestedMajor = want.parameters?.['amclJdkMajor'];
    if (typeof requestedMajor !== 'string' || !['8', '17', '21', '25'].includes(requestedMajor)) return;
    major = requestedMajor;
    // shared仅允许basic/extended工具冷进程；没有NCP、pair或麦克风回退。Native另行检查Fresh/单次。
    // 资格模式是固定枚举；不会把Want中的字符串当作路径或JVM命令行。
    const requestedProfile = want.parameters?.['amclJdkProfile'];
    if (requestedProfile !== undefined) {
      if (typeof requestedProfile !== 'string' || !['basic', 'shared-basic', 'shared-extended', 'broad', 'c2-only', 'full',
        'extended', 'extended-fork', 'sound-software', 'sound-playback', 'font-defaults', 'process-java',
        'sound-capture-denied', 'sound-capture', 'sound-capture-diagnostic', 'sound-capture-native', 'sound-capture-layout',
        'sound-capture-startup', 'sound-capture-channels', 'native-temp', 'native-file-times', 'native-temp-vms', 'sound-timing', 'native-sound-devices'].includes(requestedProfile)) return;
      profile = requestedProfile;
    }
    if (major === '8' && profile === 'c2-only') return;
    // Native探针及双VM固定会合目录保持短小；不借Java通用nonce上限放大Unix socket路径。
    if ((profile === 'native-temp' || profile === 'native-temp-vms') && nonce.length > 32) return;
  }
  const probeId: string = kind === 'java' ? 'jdkJava' : kind === 'process' ? 'jdkProcess' : 'jdkPlatform';
  const probe = findProbe(nativeProbeRegistry(nonce, major, profile), probeId);
  if (probe === null) return;
  const path: string = context.filesDir + '/jdk-' + kind + '-' + nonce + '.json';
  // 每个 nonce 独占一个证据文件；重新请求不能改写已经完成的证据。
  if (fs.accessSync(path)) return;
  running = true;
  lastNonce = nonce;
  const startedAt: number = Date.now();
  if (kind === 'java') {
    try { preparePermissionRoots(context, nonce); }
    catch (error) {
      running = false;
      AppLogger.error('JdkQualification', '权限根记录失败，本轮Java资格未启动', error, LOG_DOMAIN_LAUNCH);
      return;
    }
  }
  runProbe(probe, context.filesDir).then((outcome: ProbeOutcome): void => {
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      const report: JdkPlatformReport = {
        nonce: nonce, startedAt: startedAt, finishedAt: Date.now(),
        transportOk: outcome.ok, text: outcome.text, error: outcome.error
      };
      fs.writeSync(file.fd, JSON.stringify(report));
    } finally { fs.closeSync(file); }
    AppLogger.info('JdkQualification', 'JDK资格报告已保存：' + nonce, LOG_DOMAIN_LAUNCH);
  }).catch((error: Error): void => {
    AppLogger.error('JdkQualification', '平台探针失败', error, LOG_DOMAIN_LAUNCH);
  }).finally((): void => { running = false; });
}
