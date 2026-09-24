/**
 * JdkUpdatePolicy.ets — 已装 JDK 与期望版本之间的关系判定（纯函数，不碰 fs / Context）
 *
 * ⭐ 这个文件存在的原因，是一条付过学费的取舍：
 *
 * 旧行为（`JdkManager.isInstalled()` 里那段 release-tag 戳校验）把**任何** tag 不一致
 * 都判成「未安装」，于是启动前自检直接 fail、拒绝开游戏，用户必须重下整包（17/21/25 约
 * 110 MB）才能玩。那个设计当初是对的 —— `v8u452-ohos-2` 的 codegen 有缺陷、会崩，
 * 那种旧包**必须**强制换掉。
 *
 * 但把这条规则推广到所有 tag 变更，代价是：
 *   1. **发布顺序被绑死**。只要新 HAP 先于 JDK Release 发出去，所有已装用户立刻变成
 *      「JDK 未安装」+ 下载 404 —— 他们磁盘上那份能用的 JDK 还在，却被判成没装而玩不了。
 *   2. 一个只换了 68 KB 文件的修复，要收 110 MB 的过路费，且时机由我们而不是用户决定。
 *
 * ⇒ 分级：默认 `advisory`（旧包仍可用，只在 JDK 管理里提示「有更新」），
 *   只有显式列进 `harmfulTags` 的旧包才 `blocking`（保留强制重下）。
 *
 * ⚠️ 反过来的纪律也要写下来：**`harmfulTags` 是给"旧包已知有害"用的，不是给"我想让大家升级"用的。**
 * 往里加一个 tag 就等于对所有装着它的用户强制收一次整包流量并在升级完成前禁止开游戏。
 *
 * 判定与磁盘/网络无关，故抽成纯函数并配 `entry/src/test/JdkUpdatePolicy.test.ets`。
 * 之所以值得单独测：这条判定失效时**不会抛异常**，只会静默变成"永远提示更新"或
 * "永远不提示"，两种都要等用户反馈才发现。
 *
 * 创建日期：2026-08-29
 */

/**
 * 已装 JDK 相对「当前 HAP 期望的版本」的状态。
 *
 * ⚠️ 顺序不代表严重程度，别拿它做大小比较；每个值的处置方式见下方注释。
 */
export type JdkTagState =
  /** 没有戳。戳机制（2026-06-13）之前装的，来源未知 —— 容忍为可用，但可以提示一次修复。 */
  | 'unstamped'
  /** 戳与期望 tag 一致。 */
  | 'current'
  /** 戳与期望 tag 不同，且旧 tag **不在** harmfulTags 里 ⇒ 仍可用，提示「有更新」。 */
  | 'stale-advisory'
  /** 戳与期望 tag 不同，且旧 tag **在** harmfulTags 里 ⇒ 判不可用，强制重下。 */
  | 'stale-blocking'
  /** 用户自己导入的 JDK（戳以 IMPORTED_TAG_PREFIX 开头）⇒ 永不判过期，也永不提示更新。 */
  | 'user-import';

/**
 * 用户导入的 JDK 的戳前缀。
 *
 * 为什么导入的包也要写戳、而不是干脆不写：不写戳会落到 `unstamped`，而 `unstamped`
 * 的语义是"来源未知的旧装"，将来若要对它做什么（比如提示修复）就会误伤用户自己的包。
 * 写一个**可识别**的戳，让「用户导入」成为一个显式状态。
 *
 * 戳的完整形状是 `imported:<sha256 前 12 位>`，那 12 位是导入时那个 zip 的摘要 ——
 * 用户报"我导入的包有问题"时，这是唯一能把它认回来的线索。
 */
export const IMPORTED_TAG_PREFIX = 'imported:';

/** 判定入参。全部是值，没有句柄，方便测试直接造。 */
export interface JdkTagInput {
  /** `<jdkDir>/.amcl_release_tag` 的内容（已 trim）。读不到 / 不存在传 `''`。 */
  installedTag: string;
  /** 当前 HAP 里 `JdkVersionConfig.tag` 的值。 */
  expectedTag: string;
  /** 已知有害、必须强制换掉的旧 tag 列表。缺省视为空。 */
  harmfulTags: string[];
}

/**
 * 判定已装 JDK 与期望版本的关系。
 *
 * ⚠️ `expectedTag` 为空时一律返回 `current`：那说明配置本身没给期望值，
 * 此时"提示更新"或"判过期"都是在拿一个缺失的事实当结论。宁可什么都不做。
 */
export function classifyJdkTag(input: JdkTagInput): JdkTagState {
  const installed = input.installedTag.trim();
  const expected = input.expectedTag.trim();

  if (installed.length > 0 && installed.startsWith(IMPORTED_TAG_PREFIX)) {
    return 'user-import';
  }
  if (installed.length === 0) return 'unstamped';
  if (expected.length === 0) return 'current';
  if (installed === expected) return 'current';

  for (let i = 0; i < input.harmfulTags.length; i++) {
    if (input.harmfulTags[i] === installed) return 'stale-blocking';
  }
  return 'stale-advisory';
}

/**
 * 这个状态下，已装的 JDK 还能不能用来启动游戏。
 *
 * 只有 `stale-blocking` 是 false —— 那是"旧包已知有害"这一种情形。
 * 其余（含 `stale-advisory`）都可用：**有更新不等于不能用**，把这两件事分开正是本文件的目的。
 */
export function isUsableState(state: JdkTagState): boolean {
  return state !== 'stale-blocking';
}

/** 这个状态下要不要在 JDK 管理里显示「更新」。 */
export function shouldOfferUpdate(state: JdkTagState): boolean {
  return state === 'stale-advisory' || state === 'stale-blocking';
}

/**
 * 给用户看的一行状态说明。
 *
 * 刻意把**两个 tag 都写出来**：用户报问题时截这一行图就够定位，不必再问"你装的哪版"。
 * 这条经验来自 J-b（旧行为把过期显示成"未安装"，用户与我们都不知道真实原因）。
 */
export function describeJdkTagState(state: JdkTagState, input: JdkTagInput): string {
  if (state === 'current') return '已是最新';
  if (state === 'user-import') return '本地导入（不参与更新检查）';
  if (state === 'unstamped') return '来源未知（旧版安装，可重新下载以确认）';
  const from = input.installedTag.length > 0 ? input.installedTag : '(无戳)';
  if (state === 'stale-blocking') {
    return '已装 ' + from + ' 存在已知问题，需更新到 ' + input.expectedTag;
  }
  return '有新版本：' + from + ' → ' + input.expectedTag;
}
