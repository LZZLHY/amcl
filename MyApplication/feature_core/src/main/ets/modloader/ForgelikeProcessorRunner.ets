/**
 * ForgelikeProcessorRunner.ets — Forge/NeoForge 新版安装器「processors」自实现执行器（FCL/HMCL 思路）
 *
 * 背景与动机：
 *   新版 Forge(≥1.13)/NeoForge 安装器的核心是一串 **processors**（installertools / jarsplitter /
 *   AutoRenamingTool / binarypatcher 等构建工具），桌面端由安装器**逐个 fork 独立 `java` 子进程**
 *   执行，每个子进程 classpath 干净（只含该 processor 声明的依赖）。
 *
 *   手机端无 `java` 可执行文件，先前用 bangbang93 的 forge-install-bootstrapper 让所有 processors
 *   **同进程**跑——但 bootstrapper 给 processor 建的 URLClassLoader 以系统类加载器为父，会把
 *   installer.jar 里 **shaded 的第三方库**（joptsimple/gson 等）经父优先委派泄漏进 processor，
 *   与 processor 真正依赖的版本冲突（如 jopt-simple 5.0.4 的 OptionParser.accepts 签名不同）→
 *   NoSuchMethodError → 级联失败。前置真实 jar 只能缓解单个冲突，不彻底。
 *
 *   本执行器抛开 bootstrapper，**完整复刻桌面/FCL 的做法**：自己解析 install_profile.json，
 *   逐个 processor 用 `runJavaProcessor`（fork + JNI_CreateJavaVM/jvmInit，**干净 classpath = 只含该
 *   processor 声明的 jar**）执行。彻底消除 installer.jar 的 shaded 类泄漏，无任何类加载冲突。
 *
 * install_profile.json（spec=1）关键结构：
 *   - data: { TOKEN: { client, server } }  值形如 [maven坐标] / 'literal' / /installer内路径
 *   - processors: [ { sides?, jar(maven), classpath[](maven), args[], outputs? } ]
 *   - 内置 token：{SIDE} {MINECRAFT_JAR} {ROOT} {INSTALLER} {LIBRARY_DIR} {MINECRAFT_VERSION}
 *
 * 仅做 **client** 安装：跳过 sides 明确为 server-only 的 processor。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { mavenToRelativePath } from './MavenUtils';
import { decompressFile } from './ForgeInstallerUtils';
import { ModLoaderInstallProgress, ModLoaderInstallCallback } from './ModLoaderTypes';
import { forgeNative } from './ForgelikeNative';
import { removeDirRecursive, fileExistsAndNonEmpty } from 'commons';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_MODLOADER } from 'commons';

const TAG = 'ForgelikeProcRunner';

/** 单个 processor 的解析结果（已 token 替换后的可执行形态）。 */
interface ResolvedProcessor {
  mainClass: string;
  classpath: string;   // 冒号分隔的绝对路径
  args: string[];
  jarCoord: string;    // 仅用于日志
}

export class ForgelikeProcessorResult {
  success: boolean = false;
  error: string = '';
  ranCount: number = 0;
  // install_profile 的 data.PATCHED（client 侧）解析出的 patched MC client jar 绝对路径。
  // 各版本/品牌坐标不同（26.x=minecraft-client-patched / 1.21.x=neoforge:client / Forge=forge:client），
  // 故由 runner 据 install_profile 权威解析后回传，供安装期校验"运行时必需 patched client"是否产出。
  patchedClientPath: string = '';
  constructor(success: boolean, error: string, ranCount: number, patchedClientPath: string = '') {
    this.success = success;
    this.error = error;
    this.ranCount = ranCount;
    this.patchedClientPath = patchedClientPath;
  }
}

export class ForgelikeProcessorRunner {
  /**
   * 执行 install_profile.json 里的全部 client-side processors。
   * @param profilePath        install_profile.json 路径
   * @param installerTempDir   已解压的 installer 目录（/data/... 内路径与 version.json 取自此）
   * @param mcDir              .minecraft 根（= {ROOT}）
   * @param libDir             mcDir/libraries（= {LIBRARY_DIR}，processor 依赖与产物都在此树）
   * @param filesDir           app filesDir（JDK / fonts 定位）
   * @param gameVersion        干净 MC 版本（= {MINECRAFT_VERSION}，定位 vanilla client jar）
   * @param installerJdk       跑 processor 用的 JDK 大版本（"17"）
   * @param xmxMb              每个 processor JVM 的 -Xmx
   * @param loaderName         "Forge" / "NeoForge"（仅用于进度文案）
   */
  static async run(
    profilePath: string, installerTempDir: string,
    mcDir: string, libDir: string, filesDir: string,
    gameVersion: string, installerJdk: string, xmxMb: number,
    loaderName: string, callback?: ModLoaderInstallCallback
  ): Promise<ForgelikeProcessorResult> {
    let profile: Record<string, Object> | null = null;
    try {
      profile = JSON.parse(fs.readTextSync(profilePath)) as Record<string, Object>;
    } catch (e) {
      return new ForgelikeProcessorResult(false, 'install_profile.json 解析失败: ' + (e as Error).message, 0);
    }
    if (!profile) return new ForgelikeProcessorResult(false, 'install_profile.json 为空', 0);

    // ---- 1) 构建 token → 值 映射（数据项 + 内置项）----
    let tokens = new Map<string, string>();
    // 内置 token
    let minecraftJar = mcDir + '/versions/' + gameVersion + '/' + gameVersion + '.jar';
    tokens.set('SIDE', 'client');
    tokens.set('ROOT', mcDir);
    tokens.set('MINECRAFT_JAR', minecraftJar);
    tokens.set('LIBRARY_DIR', libDir);
    tokens.set('MINECRAFT_VERSION', gameVersion);
    // {INSTALLER}：仅 server-only 的 EXTRACT_FILES processor 用到，client 安装从不引用。
    // 给一个解压目录内的占位路径即可（client 流程不会真正读它）。
    tokens.set('INSTALLER', installerTempDir);

    // data 项（取 client 变体）
    let dataObj = profile['data'] as Record<string, Object> | undefined;
    if (dataObj) {
      let keys = Object.keys(dataObj);
      for (let k of keys) {
        let entry = dataObj[k] as Record<string, string> | undefined;
        if (!entry) continue;
        let raw = entry['client'];
        if (raw === undefined || raw === null) continue;
        tokens.set(k, ForgelikeProcessorRunner.resolveDataValue(raw, installerTempDir, libDir));
      }
    }

    // PATCHED token（client 侧）= 运行时必需的 patched MC client jar 绝对路径（已 [maven]→路径 解析）。
    //   26.x = .../minecraft-client-patched/<ver>/minecraft-client-patched-<ver>.jar
    //   1.21.x/Forge = .../<loader>/<ver>/<loader>-<ver>-client.jar
    // 回传供安装期校验（processor 不声明 outputs，故 runner 不会自动校验它，由 installer 兜底）。
    let patchedClientPath = tokens.has('PATCHED') ? (tokens.get('PATCHED') as string) : '';

    // ---- 2) 解析并执行 processors ----
    let processors = profile['processors'] as Array<Record<string, Object>> | undefined;
    if (!processors || processors.length === 0) {
      return new ForgelikeProcessorResult(false, 'install_profile.json 无 processors', 0);
    }

    // 先筛出 client 要跑的 processor（用于进度分母）
    let clientProcessors: Array<Record<string, Object>> = [];
    for (let p of processors) {
      if (ForgelikeProcessorRunner.shouldRunForClient(p)) clientProcessors.push(p);
    }
    AppLogger.info(TAG, `processors total=${processors.length} client-run=${clientProcessors.length}`, LOG_DOMAIN_MODLOADER);

    let mainClassCache = new Map<string, string>();
    let procTmpBase = mcDir + '/forge-proc-tmp';
    try { removeDirRecursive(procTmpBase); } catch (e) { /* */ }

    let ran = 0;
    for (let i = 0; i < clientProcessors.length; i++) {
      let p = clientProcessors[i];
      let resolved: ResolvedProcessor | null = null;
      try {
        resolved = await ForgelikeProcessorRunner.resolveProcessor(p, tokens, libDir, procTmpBase, mainClassCache);
      } catch (e) {
        return new ForgelikeProcessorResult(false, 'processor 解析失败: ' + (e as Error).message, ran);
      }
      if (!resolved) {
        return new ForgelikeProcessorResult(false, 'processor 解析失败（缺 jar/Main-Class）', ran);
      }

      let stepMsg = '运行 ' + loaderName + ' 安装步骤 ' + (i + 1) + '/' + clientProcessors.length
        + '（' + ForgelikeProcessorRunner.shortMain(resolved.mainClass) + '）...';
      ForgelikeProcessorRunner.report(callback, 'installing', 5 + (i / clientProcessors.length), 8, stepMsg);
      AppLogger.info(TAG,
        `run processor #${i} main=${resolved.mainClass} jar=${resolved.jarCoord} args=[${resolved.args.join(' ')}]`,
        LOG_DOMAIN_MODLOADER);

      let logFile = mcDir + '/forge-installer.log'; // 追加式日志（runJavaProcessor 内 O_TRUNC，每步覆盖）
      let rc = -1;
      try {
        rc = await forgeNative().runJavaProcessor(
          filesDir, installerJdk, xmxMb,
          resolved.classpath, resolved.mainClass, resolved.args, mcDir, logFile);
      } catch (e) {
        return new ForgelikeProcessorResult(false,
          loaderName + ' 安装步骤 ' + (i + 1) + ' 执行异常: ' + (e as Error).message, ran);
      }
      AppLogger.info(TAG, `processor #${i} returned rc=${rc}`, LOG_DOMAIN_MODLOADER);
      if (rc !== 0) {
        let detail = ForgelikeProcessorRunner.tailLog(logFile);
        return new ForgelikeProcessorResult(false,
          loaderName + ' 安装步骤 ' + (i + 1) + '/' + clientProcessors.length
          + '（' + ForgelikeProcessorRunner.shortMain(resolved.mainClass) + '）失败 (rc=' + rc + ')'
          + (detail.length > 0 ? '\n' + detail : ''), ran);
      }
      // 校验 outputs（若声明）——产物缺失即判失败，避免"静默坏安装"
      let outMissing = ForgelikeProcessorRunner.checkOutputs(p, tokens, libDir);
      if (outMissing.length > 0) {
        return new ForgelikeProcessorResult(false,
          loaderName + ' 安装步骤 ' + (i + 1) + ' 未产出预期文件: ' + outMissing, ran);
      }
      ran++;
    }

    try { removeDirRecursive(procTmpBase); } catch (e) { /* */ }
    return new ForgelikeProcessorResult(true, '', ran, patchedClientPath);
  }

  /** sides 缺失/空 → 两端都跑；否则仅当含 'client' 才跑。 */
  private static shouldRunForClient(p: Record<string, Object>): boolean {
    let sides = p['sides'] as Array<string> | undefined;
    if (!sides || sides.length === 0) return true;
    for (let s of sides) { if (s === 'client') return true; }
    return false;
  }

  /** data 项值解析：[maven]→libraries 绝对路径 / 'literal'→去引号 / /path→installer 内解压路径 / 其它原样。 */
  private static resolveDataValue(raw: string, installerTempDir: string, libDir: string): string {
    if (raw.length === 0) return raw;
    if (raw.charAt(0) === '[' && raw.charAt(raw.length - 1) === ']') {
      let coord = raw.substring(1, raw.length - 1);
      let rel = mavenToRelativePath(coord);
      return rel.length > 0 ? (libDir + '/' + rel) : raw;
    }
    if (raw.charAt(0) === '\'' && raw.charAt(raw.length - 1) === '\'') {
      return raw.substring(1, raw.length - 1);
    }
    if (raw.charAt(0) === '/') {
      return installerTempDir + raw; // installer 内文件（已解压到 installerTempDir）
    }
    return raw;
  }

  /** 把单个 arg 做 token 替换：先替换所有 {KEY}，再处理整体 [maven] / 'literal'。 */
  private static resolveArg(arg: string, tokens: Map<string, string>, libDir: string): string {
    let out = arg;
    // 替换所有 {KEY}（可嵌在中间，如 {ROOT}/run.sh）
    if (out.indexOf('{') >= 0) {
      tokens.forEach((v: string, k: string) => {
        let needle = '{' + k + '}';
        if (out.indexOf(needle) >= 0) {
          out = out.split(needle).join(v);
        }
      });
    }
    // 整体 [maven] → 绝对路径
    if (out.length >= 2 && out.charAt(0) === '[' && out.charAt(out.length - 1) === ']') {
      let coord = out.substring(1, out.length - 1);
      let rel = mavenToRelativePath(coord);
      if (rel.length > 0) return libDir + '/' + rel;
    }
    // 整体 'literal' → 去引号
    if (out.length >= 2 && out.charAt(0) === '\'' && out.charAt(out.length - 1) === '\'') {
      return out.substring(1, out.length - 1);
    }
    return out;
  }

  /** 解析单个 processor：jar/classpath→绝对路径，Main-Class（读 MANIFEST），args→token 替换。 */
  private static async resolveProcessor(
    p: Record<string, Object>, tokens: Map<string, string>, libDir: string,
    procTmpBase: string, mainClassCache: Map<string, string>
  ): Promise<ResolvedProcessor | null> {
    let jarCoord = p['jar'] as string | undefined;
    if (!jarCoord || jarCoord.length === 0) return null;
    let jarRel = mavenToRelativePath(jarCoord);
    if (jarRel.length === 0) return null;
    let jarPath = libDir + '/' + jarRel;
    if (!fileExistsAndNonEmpty(jarPath)) {
      AppLogger.error(TAG, `processor jar missing: ${jarPath}`, null, LOG_DOMAIN_MODLOADER);
      return null;
    }

    // classpath = 各 classpath 坐标的绝对路径 + jar 本身（jar 放最后，避免遮蔽依赖）
    let cpPaths: string[] = [];
    let cpCoords = p['classpath'] as Array<string> | undefined;
    if (cpCoords) {
      for (let c of cpCoords) {
        let rel = mavenToRelativePath(c);
        if (rel.length === 0) continue;
        let abs = libDir + '/' + rel;
        if (cpPaths.indexOf(abs) < 0) cpPaths.push(abs);
      }
    }
    if (cpPaths.indexOf(jarPath) < 0) cpPaths.push(jarPath);
    let classpath = cpPaths.join(':');

    // Main-Class（读 jar 的 MANIFEST.MF，带缓存）
    let mainClass = mainClassCache.get(jarPath) || '';
    if (mainClass.length === 0) {
      mainClass = await ForgelikeProcessorRunner.readJarMainClass(jarPath, procTmpBase);
      if (mainClass.length === 0) {
        AppLogger.error(TAG, `cannot read Main-Class from ${jarPath}`, null, LOG_DOMAIN_MODLOADER);
        return null;
      }
      mainClassCache.set(jarPath, mainClass);
    }

    // args token 替换
    let rawArgs = p['args'] as Array<string> | undefined;
    let args: string[] = [];
    if (rawArgs) {
      for (let a of rawArgs) args.push(ForgelikeProcessorRunner.resolveArg(a, tokens, libDir));
    }

    return { mainClass, classpath, args, jarCoord };
  }

  /** 解压 jar 读取 META-INF/MANIFEST.MF 的 Main-Class。procTmpBase 下按 jar 名建子目录（缓存复用）。 */
  private static async readJarMainClass(jarPath: string, procTmpBase: string): Promise<string> {
    let name = jarPath.substring(jarPath.lastIndexOf('/') + 1).replace(/[^A-Za-z0-9._-]/g, '_');
    let outDir = procTmpBase + '/mf_' + name;
    let manifestPath = outDir + '/META-INF/MANIFEST.MF';
    if (!fileExistsAndNonEmpty(manifestPath)) {
      try { fs.mkdirSync(outDir, true); } catch (e) { /* */ }
      try {
        await decompressFile(jarPath, outDir);
      } catch (e) {
        AppLogger.warn(TAG, `decompress for manifest failed ${jarPath}: ${(e as Error).message}`, null, LOG_DOMAIN_MODLOADER);
        return '';
      }
    }
    let text = '';
    try { text = fs.readTextSync(manifestPath); } catch (e) { return ''; }
    return ForgelikeProcessorRunner.parseManifestMainClass(text);
  }

  /** 解析 MANIFEST.MF 的 Main-Class（处理 72 列折行：续行以单个空格开头）。 */
  private static parseManifestMainClass(text: string): string {
    let lines = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      let line = lines[i].replace(/\r$/, '');
      if (line.indexOf('Main-Class:') === 0) {
        let val = line.substring('Main-Class:'.length).trim();
        // 续行拼接
        let j = i + 1;
        while (j < lines.length && lines[j].length > 0 && lines[j].charAt(0) === ' ') {
          val += lines[j].replace(/\r$/, '').substring(1);
          j++;
        }
        return val.trim();
      }
    }
    return '';
  }

  /** 检查 processor 的 outputs（key 为 {TOKEN} 或 [maven]，已 token 替换后应是绝对路径文件）。返回缺失项串（空=都在）。 */
  private static checkOutputs(p: Record<string, Object>, tokens: Map<string, string>, libDir: string): string {
    let outputs = p['outputs'] as Record<string, Object> | undefined;
    if (!outputs) return '';
    let missing: string[] = [];
    let keys = Object.keys(outputs);
    for (let key of keys) {
      let path = ForgelikeProcessorRunner.resolveArg(key, tokens, libDir);
      if (!fileExistsAndNonEmpty(path)) missing.push(path);
    }
    return missing.join(', ');
  }

  private static shortMain(mainClass: string): string {
    let idx = mainClass.lastIndexOf('.');
    return idx >= 0 ? mainClass.substring(idx + 1) : mainClass;
  }

  private static tailLog(logFile: string): string {
    try {
      let text = fs.readTextSync(logFile);
      let lines = text.split('\n');
      let pick: string[] = [];
      for (let i = lines.length - 1; i >= 0 && pick.length < 6; i--) {
        let t = lines[i].trim();
        if (t.length === 0) continue;
        pick.unshift(t.length > 200 ? t.substring(0, 200) + '...' : t);
      }
      return pick.join('\n');
    } catch (e) { return ''; }
  }

  private static report(cb: ModLoaderInstallCallback | undefined,
    phase: string, current: number, total: number, message: string): void {
    if (cb) {
      let pr: ModLoaderInstallProgress = { phase, current, total, message };
      cb(pr);
    }
  }
}
