/**
 * JdkImporter.ets — 从本地压缩包导入 JDK（离线可用 / 用户自带）
 *
 * 为什么要有这条路（2026-08-29）：
 *   1. **离线**：用户在别处下好了 JDK 包，设备没网也能装上；
 *   2. **用户自己修好的包**：IPv6 那次就有用户自己改出了可用的 `libnet.so`。我们不采纳
 *      第三方**二进制**进出货链（理由见 docs/adaptation/JDK_IPV6_ADAPTATION_PLAN.md §七），
 *      但没有理由禁止用户在**自己的设备上**用自己的包 —— 那是他的机器。
 *   3. 官方通道全挂（GitHub/Gitee 都不通）时的兜底。
 *
 * ⚠️ 与官方安装的**三条**刻意差异：
 *   - **不校验 SHA-256**（没有期望值可比）。所以导入是一个"用户明确授权"的动作，
 *     文案里必须说清"来源由你负责"，不能让它看起来和官方下载一样安全。
 *   - 戳写成 `imported:<zip 的 sha256 前 12 位>`，让它成为一个**可识别的状态**
 *     （`JdkTagState.user-import`）：既不会被当成"过期"强制覆盖，也不会被当成
 *     "来源未知的旧装"。那 12 位是用户报问题时唯一能把这个包认回来的线索。
 *   - **永不参与更新检查**（`shouldOfferUpdate` 对 user-import 返回 false）。
 *     对用户自己塞的包提示"更新"＝提示覆盖掉它，那是数据破坏。
 *
 * 安全面完全复用既有设施，没有自己写一套：
 *   - 解压走 `feature_core` 的 `decompressFile`，它带 containment / symlink 拒绝 /
 *     条目数 / 累计字节 / 目录深度 全套扫描（见 ForgeInstallerUtils）；
 *   - 落地走与官方安装**同一段** staging → rename + backup + 回滚。
 *
 * ⭐ 一条不变量（也是最容易做错的地方）：**导入成功 ⇒ `JdkManager.isInstalled()` 必须为真**。
 * 所以这里的结构校验不是"随便查个文件"，而是**逐项复现 isInstalled 的 probe 列表**。
 * 否则会出现"导入提示成功，回到首页却说未安装"这种自相矛盾的状态。
 *
 * 创建日期：2026-08-29
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { removeDirRecursive } from 'commons';
import { ensureDirSync } from 'commons';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_LAUNCH } from 'commons';
import { decompressFile, VersionFileVerifier } from 'feature_core';
import { IMPORTED_TAG_PREFIX } from './JdkUpdatePolicy';

const TAG = 'JdkImporter';

/** 导入结果。`cancelled` 与 `ok=false` 分开 —— 用户取消不是错误。 */
export interface JdkImportResult {
  ok: boolean;
  /** 失败/成功的人话说明，直接可以进 toast。 */
  message: string;
  /** 成功时写进 `.amcl_release_tag` 的戳（`imported:<sha12>`）。 */
  stamp: string;
}

/** 进度回调。`percent` 只在有意义的阶段给（解压没有进度可报，给 -1）。 */
export type JdkImportProgress = (phase: string, percent: number, message: string) => void;

/**
 * 导入用的结构校验：**必须与 `JdkManager.isInstalled()` 的 probe 列表一致**。
 *
 * 这里刻意重复一遍而不是去调 `isInstalled` —— `isInstalled` 查的是**已发布的目标目录**，
 * 而这里查的是**还在 staging 里的候选目录**。共用一个函数会把"发布前校验"和"发布后自检"
 * 耦合成一件事，将来任一侧改了另一侧会跟着漂。重复的代价是两处要一起改，
 * 所以两边的注释互相指名对方。
 *
 * @returns 空串 = 通过；非空 = 失败原因（人话）
 */
export function validateJdkTree(root: string): string {
  // 布局判定与 isInstalled 同口径：先看经典布局的标志文件
  let classic = false;
  try {
    fs.statSync(root + '/jre/lib/aarch64/server/libjvm.so');
    classic = true;
  } catch (e) { /* modular */ }

  const probes: string[] = classic
    ? ['jre/lib/aarch64/server/libjvm.so', 'jre/lib/rt.jar']
    : ['lib/server/libjvm.so', 'lib/libjli.so', 'lib/modules'];
  const marker = classic ? 'jre/lib/rt.jar' : 'release';

  try {
    fs.statSync(root + '/' + marker);
  } catch (e) {
    return '缺少安装标记 ' + marker + '（这看起来不是一个完整的 JDK 目录）';
  }
  for (const p of probes) {
    try {
      fs.statSync(root + '/' + p);
    } catch (e) {
      return '缺少关键文件 ' + p;
    }
  }
  // boot artifact 的体积下界与官方安装同口径（1 MB）：拦住"文件在但是 0 字节/被截断"
  const bootRel = classic ? 'jre/lib/rt.jar' : 'lib/modules';
  try {
    const st = fs.statSync(root + '/' + bootRel);
    if (st.size < 1000000) {
      return bootRel + ' 只有 ' + st.size + ' 字节，明显不完整';
    }
  } catch (e) {
    return '无法读取 ' + bootRel;
  }
  return '';
}

/**
 * 在解压结果里定位真正的 JDK 根目录。
 *
 * 用户手里的包有两种形状，都得吃下来（这条经验来自 GameArchiveIO 的存档导入）：
 *   a) 顶层就是内容：`lib/`、`release` 直接在解压根下；
 *   b) 顶层是一个单独的文件夹：`jdk-25.0.4+3/lib/...`（绝大多数官方分发包是这种）。
 *
 * ⚠️ 只在"顶层恰好只有一个目录"时才下钻一层，且**只下钻一层**。多层嵌套或顶层混着文件时
 * 不猜 —— 猜错的后果是把一个不是 JDK 的目录发布成 JDK。
 *
 * @returns 定位到的根目录；定位不出返回空串
 */
export function locateJdkRoot(extractRoot: string): string {
  if (validateJdkTree(extractRoot).length === 0) return extractRoot;
  let names: string[] = [];
  try {
    names = fs.listFileSync(extractRoot);
  } catch (e) {
    return '';
  }
  if (names.length !== 1) return '';
  const only = extractRoot + '/' + names[0];
  try {
    if (!fs.statSync(only).isDirectory()) return '';
  } catch (e) {
    return '';
  }
  return validateJdkTree(only).length === 0 ? only : '';
}

export class JdkImporter {
  /**
   * 把一个本地 zip 导入成 `filesDir/jdk/<version>/`。
   *
   * @param context   用来取 filesDir（安装根）
   * @param version   要占用的槽位（'8' | '17' | '21' | '25'）——由调用方让用户选，
   *                  因为 zip 里的版本号不可信也不好解析
   * @param zipPath   已经在沙箱里的 zip 绝对路径（由 GameArchiveIO.importResourceFile 拷进来）
   * @param onProgress 可选进度
   */
  static async importFromZip(
    context: Context, version: string, zipPath: string, onProgress?: JdkImportProgress
  ): Promise<JdkImportResult> {
    const report = (phase: string, percent: number, msg: string): void => {
      if (onProgress) onProgress(phase, percent, msg);
    };

    const installRoot = context.filesDir + '/jdk';
    const targetDir = installRoot + '/' + version;
    const token = 'import-' + version + '-' + Date.now().toString() + '-'
      + Math.floor(Math.random() * 1000000000).toString();
    // ⚠️ staging 必须与 targetDir 同文件系统，rename 才是 O(1) 且原子的 —— 所以放在
    //    installRoot 下，不是 cacheDir（那是另一个挂载点）。与官方安装同一约定。
    const extractRoot = installRoot + '/.staging-' + token;

    let backupDir = '';
    let backupCreated = false;

    try {
      ensureDirSync(installRoot);
      try { removeDirRecursive(extractRoot) } catch (e) { /* 不存在很正常 */ }
      ensureDirSync(extractRoot);

      // ---- 1) 先算 zip 的 sha256（也顺便证明这个文件读得动）----
      report('verifying', -1, '正在计算校验值…');
      let sha = '';
      try {
        sha = (await VersionFileVerifier.sha256File(zipPath)).toLowerCase();
      } catch (e) {
        return { ok: false, message: '读取压缩包失败，文件可能已被移动或损坏', stamp: '' };
      }
      const stamp = IMPORTED_TAG_PREFIX + sha.substring(0, 12);

      // ---- 2) 安全解压（containment / symlink / 数量 / 体积 全套扫描在 decompressFile 里）----
      report('extracting', -1, '正在解压（大包可能需要几分钟，请勿关闭）…');
      try {
        await decompressFile(zipPath, extractRoot, 300000);
      } catch (e) {
        const err = e as Error;
        AppLogger.warn(TAG, `import decompress failed: ${err.message}`, e as Object, LOG_DOMAIN_LAUNCH);
        return { ok: false, message: '解压失败：' + err.message, stamp: '' };
      }

      // ---- 3) 定位 + 结构校验 ----
      report('verifying', -1, '正在校验目录结构…');
      const root = locateJdkRoot(extractRoot);
      if (root.length === 0) {
        // 把**具体缺什么**说出来，而不是笼统一句"不是有效的 JDK"——
        // 用户拿这句话才知道自己是不是选错了文件（比如选了 MC 整合包）。
        const why = validateJdkTree(extractRoot);
        return {
          ok: false,
          stamp: '',
          message: '这个压缩包不像一个可用的 JDK：' + (why.length > 0 ? why : '目录结构无法识别'),
        };
      }

      // ---- 4) 写戳（随目录一起发布，不是发布后再补写）----
      try {
        const sf = fs.openSync(root + '/.amcl_release_tag',
          fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        try { fs.writeSync(sf.fd, stamp) } finally { fs.closeSync(sf) }
      } catch (e) {
        // 与官方安装同口径：写戳失败不致命。但导入这条路上它会退化成 `unstamped`，
        // 于是这个包会被当成"来源未知的旧装"而不是"用户导入" —— 记一条 WARN 让日志能解释。
        AppLogger.warn(TAG, 'import stamp write failed (non-fatal; will look unstamped)',
          e as Object, LOG_DOMAIN_LAUNCH);
      }

      // ---- 5) 原子发布：旧目录先改名保底，失败能回滚 ----
      report('extracting', 100, '正在安装…');
      backupDir = targetDir + '.backup-' + Date.now().toString() + '-'
        + Math.floor(Math.random() * 1000000).toString();
      let targetExisted = false;
      try { fs.statSync(targetDir); targetExisted = true } catch (e) { /* 首次安装 */ }
      try {
        if (targetExisted) {
          fs.renameSync(targetDir, backupDir);
          backupCreated = true;
        }
        fs.renameSync(root, targetDir);
      } catch (e) {
        AppLogger.error(TAG, 'import publish failed', e as Object, LOG_DOMAIN_LAUNCH);
        if (backupCreated) {
          try {
            fs.renameSync(backupDir, targetDir);
            backupCreated = false;
          } catch (e2) {
            AppLogger.error(TAG, 'import rollback failed; backup retained at ' + backupDir,
              e2 as Object, LOG_DOMAIN_LAUNCH);
          }
        }
        return { ok: false, message: '安装失败（已尽力恢复原有 JDK）', stamp: '' };
      }
      if (backupCreated) {
        try { removeDirRecursive(backupDir) } catch (e) {
          AppLogger.warn(TAG, 'import backup cleanup failed: ' + backupDir, e as Object, LOG_DOMAIN_LAUNCH);
        }
        backupCreated = false;
      }

      AppLogger.info(TAG, `JDK ${version} imported from local zip, stamp=${stamp}`, LOG_DOMAIN_LAUNCH);
      report('verifying', 100, '导入完成');
      return { ok: true, message: 'JDK ' + version + ' 已从本地包导入（' + stamp + '）', stamp };
    } catch (e) {
      const err = e as Error;
      AppLogger.error(TAG, 'import failed', e as Object, LOG_DOMAIN_LAUNCH);
      return { ok: false, message: '导入失败：' + err.message, stamp: '' };
    } finally {
      // staging 一律清掉；发布成功时 root 已被 rename 走，这里删的是残留的外层目录。
      try { removeDirRecursive(extractRoot) } catch (e) { /* ignore */ }
    }
  }
}
