/**
 * VersionParser.ets — MC version.json 解析器
 *
 * 从 .minecraft/versions/<ver>/<ver>.json 中提取启动所需信息：
 *   - mainClass, arguments, libraries, assetIndex 等
 *   - 处理 library rules（os/arch 过滤）
 *   - 处理 LWJGL jar 替换（用 OHOS 编译的版本替换官方版本）
 *   - 支持 MC 1.13+ arguments 格式和 1.12- minecraftArguments 格式
 *
 * v2 变更（下载系统重组）：
 *   - 删除 inheritsFrom 继承链解析（改用 VersionJsonMerger 合并 JSON）
 *   - 所有版本的 version.json 都是完全自包含的
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { mavenToRelativePath } from '../modloader/MavenUtils';
import { formatError } from 'commons';

const TAG = 'VersionParser';

// ============================================================
//  version.json 数据结构
// ============================================================

interface ArgumentRuleOs {
  name?: string;
  arch?: string;
}

interface ArgumentRule {
  action: string;
  os?: ArgumentRuleOs;
  features?: Record<string, boolean>;
}

interface ArgumentEntry {
  value: string | string[];
  rules?: ArgumentRule[];
}

interface LibraryDownloadArtifact {
  path: string;
  url: string;
  sha1: string;
  size: number;
}

interface LibraryDownloads {
  artifact?: LibraryDownloadArtifact;
}

interface LibraryRuleOs {
  name?: string;
}

interface LibraryRule {
  action: string;
  os?: LibraryRuleOs;
}

interface LibraryEntry {
  name: string;
  downloads?: LibraryDownloads;
  rules?: LibraryRule[];
}

interface AssetIndexInfo {
  id: string;
  url: string;
  sha1: string;
  size: number;
  totalSize: number;
}

interface ClientDownloadInfo {
  sha1?: string;
}

interface VersionDownloads {
  client?: ClientDownloadInfo;
}

interface VersionArguments {
  game?: (string | ArgumentEntry)[];
  jvm?: (string | ArgumentEntry)[];
}

export interface MinecraftLoggingFile { id: string; url: string; sha1: string; size: number; }
export interface MinecraftLoggingClient { argument: string; file: MinecraftLoggingFile; type?: string; }
interface MinecraftLogging { client?: MinecraftLoggingClient; }

/** 官方或合并清单声明的 Java 运行要求；它表示下限，不表示唯一允许的 JDK。 */
interface MinecraftJavaVersion {
  majorVersion?: number;
}

interface VersionJsonData {
  id: string;
  type: string;
  mainClass: string;
  arguments?: VersionArguments;
  minecraftArguments?: string;
  libraries: LibraryEntry[];
  assetIndex?: AssetIndexInfo;
  assets?: string;
  inheritsFrom?: string;
  downloads?: VersionDownloads;
  logging?: MinecraftLogging;
  javaVersion?: MinecraftJavaVersion;
}

// ============================================================
//  解析结果
// ============================================================

export interface ParsedVersion {
  id: string;
  type: string;
  mainClass: string;
  gameArgs: string[];
  jvmArgs: string[];
  libraries: string[];
  assetIndex: string;
  inheritsFrom: string;
  clientSha1: string;
  loggingClient?: MinecraftLoggingClient;
  /** 清单明确声明的 Java 主版本下限；0 表示缺失或非法，调用方仍可按纪元回退。 */
  javaVersionMajor?: number;
}

// ============================================================
//  VersionParser
// ============================================================

export class VersionParser {
  private static readonly KNOWN_FEATURES: Record<string, boolean> = {
    'is_demo_user': false,
    'has_custom_resolution': false,
    'has_quick_plays_support': false,
    'is_quick_play_singleplayer': false,
    'is_quick_play_multiplayer': false,
    'is_quick_play_realms': false,
  }

  /**
   * 从 version.json 内容判定【原版 MC 版本号】（对齐 PCL Meloong-Git/PCL 的
   * McVersion.Version）。
   *
   * 关键点：版本号【只来自 json 内容，与版本文件夹名无关】。这样用户把版本目录改名
   * （甚至全中文、无版本号）都不影响 JDK 纪元路由 —— 与 PCL / HMCL 行为一致。
   * AMCL 历史实现用 extractGameVersionFromId(文件夹名) 解析，纯中文目录会退化兜底，
   * 这里改为先读 json 内容。
   *
   * 优先级（同 PCL）：
   *   1. clientVersion                       PCL 下载/合并版本直接写明原版号
   *   2. patches[id=="game"].version         HMCL / MultiMC 格式
   *   3. arguments.game 里 --fml.mcVersion    Forge / NeoForge（取其后一项）
   *   4. inheritsFrom                        继承的原版 id
   *   5. id                                  自包含原版 json 的 id（下载时写入，
   *                                          比文件夹名更可靠——改名通常只改文件名不改内容）
   * 全部取不到 → null（调用方回退到目录名解析）。
   */
  static detectVanillaVersion(jsonPath: string): string | null {
    let obj: Record<string, Object>
    try {
      let content = fs.readTextSync(jsonPath)
      obj = JSON.parse(content) as Record<string, Object>
    } catch (e) {
      hilog.warn(0x0000, TAG, 'detectVanillaVersion: read/parse failed %{public}s: %{public}s',
        jsonPath, formatError(e))
      return null
    }

    // 1. clientVersion
    let cv = obj['clientVersion']
    if (typeof cv === 'string' && cv.length > 0) return cv

    // 2. patches[id=="game"].version
    let patches = obj['patches']
    if (Array.isArray(patches)) {
      let arr = patches as Object[]
      for (let p of arr) {
        let po = p as Record<string, Object>
        if ((po['id'] as string) === 'game') {
          let v = po['version']
          if (typeof v === 'string' && v.length > 0) return v
        }
      }
    }

    // 3. arguments.game 里 --fml.mcVersion 的下一项
    let args = obj['arguments'] as Record<string, Object>
    if (args) {
      let game = args['game']
      if (Array.isArray(game)) {
        let garr = game as Object[]
        let mark = false
        for (let a of garr) {
          if (mark && typeof a === 'string' && (a as string).length > 0) return a as string
          if (a === '--fml.mcVersion') mark = true
        }
      }
    }

    // 4. inheritsFrom
    let inh = obj['inheritsFrom']
    if (typeof inh === 'string' && inh.length > 0) return inh

    // 5. id（json 内容里的 id，下载时写入；改文件夹名一般不改 json 内容）
    let id = obj['id']
    if (typeof id === 'string' && id.length > 0) return id

    return null
  }

  /**
   * 解析 version.json 文件（不处理 inheritsFrom）
   */
  static parse(jsonPath: string): ParsedVersion | null {
    try {
      let content = fs.readTextSync(jsonPath)
      let data: VersionJsonData = JSON.parse(content) as VersionJsonData
      return VersionParser.parseData(data)
    } catch (e) {
      hilog.error(0x0000, TAG, 'Failed to parse %{public}s: %{public}s', jsonPath, formatError(e))
      return null
    }
  }

  /**
   * 解析 version.json 数据对象
   */
  static parseData(data: VersionJsonData): ParsedVersion {
    let result: ParsedVersion = {
      id: data.id,
      type: data.type || 'release',
      mainClass: data.mainClass,
      gameArgs: [],
      jvmArgs: [],
      libraries: [],
      assetIndex: '',
      inheritsFrom: data.inheritsFrom || '',
      clientSha1: data.downloads && data.downloads.client && data.downloads.client.sha1
        ? data.downloads.client.sha1 : '',
      javaVersionMajor: VersionParser.javaMajorFromMetadata(data.javaVersion),
    }

    // asset index
    if (data.assetIndex) {
      result.assetIndex = data.assetIndex.id
    } else if (data.assets) {
      result.assetIndex = data.assets
    }

    // arguments（MC 1.13+ 格式）
    if (data.arguments) {
      if (data.arguments.game) {
        result.gameArgs = VersionParser.resolveArguments(data.arguments.game)
      }
      if (data.arguments.jvm) {
        result.jvmArgs = VersionParser.resolveArguments(data.arguments.jvm)
      }
    }
    // minecraftArguments（MC 1.12 及以下格式）
    else if (data.minecraftArguments) {
      result.gameArgs = data.minecraftArguments.split(' ')
    }

    // libraries
    for (let lib of data.libraries) {
      if (!VersionParser.checkLibraryRules(lib.rules)) continue
      if (lib.downloads && lib.downloads.artifact && lib.downloads.artifact.path) {
        result.libraries.push(lib.downloads.artifact.path)
      } else {
        // Maven 格式 name → path 转换（用于无 downloads 的 library）
        // Phase 9 收尾（D9-3）：调用统一的 mavenToRelativePath，不再于本文件重复实现
        let path = mavenToRelativePath(lib.name)
        if (path) result.libraries.push(path)
      }
    }

    result.loggingClient = data.logging?.client;
    return result
  }

  /**
   * 从不可信 JSON 元数据读取 Java 主版本。解析与合并共用这一处有效性规则，
   * 只接受有限正整数，不把字符串、分数或 null 强转成能阻断启动的版本约束。
   * 返回 0 代表“未获得声明”，不是“任意 JDK 已被验证兼容”。
   */
  static javaMajorFromMetadata(metadata: Object | undefined): number {
    if (metadata === undefined || metadata === null || typeof metadata !== 'object'
      || Array.isArray(metadata)) return 0;
    const javaVersion: MinecraftJavaVersion = metadata as MinecraftJavaVersion;
    const major: number | undefined = javaVersion.majorVersion;
    return typeof major === 'number' && Number.isFinite(major) && major > 0
      && Math.floor(major) === major ? major : 0;
  }

  /**
   * 解析 arguments 数组（MC 1.13+ 格式）
   * 支持普通字符串和带 rules 的对象
   */
  private static resolveArguments(args: (string | ArgumentEntry)[]): string[] {
    let result: string[] = []
    for (let arg of args) {
      if (typeof arg === 'string') {
        result.push(arg)
      } else {
        let entry = arg as ArgumentEntry
        // 检查 rules
        if (entry.rules && !VersionParser.checkArgumentRules(entry.rules)) continue
        // 添加值
        if (typeof entry.value === 'string') {
          result.push(entry.value)
        } else if (Array.isArray(entry.value)) {
          for (let v of entry.value) {
            result.push(v)
          }
        }
      }
    }
    return result
  }

  /**
   * 检查 library rules（os 过滤）
   * 返回 true 表示此 library 应该被包含
   */
  static checkLibraryRules(rules: LibraryRule[] | undefined): boolean {
    if (!rules || rules.length === 0) return true

    let dominated = false
    let dominated_by_allow = false

    for (let rule of rules) {
      if (rule.os && rule.os.name) {
        // 有 os 限定
        let osMatch = (rule.os.name === 'linux') // HarmonyOS 伪装为 Linux
        if (rule.action === 'allow') {
          if (osMatch) dominated_by_allow = true
          dominated = true
        } else if (rule.action === 'disallow') {
          if (osMatch) return false
        }
      } else {
        // 无 os 限定
        if (rule.action === 'allow') dominated_by_allow = true
        dominated = true
      }
    }

    if (dominated) return dominated_by_allow
    return true
  }

  /**
   * 检查 argument rules
   */
  private static checkArgumentRules(rules: ArgumentRule[]): boolean {
    if (!rules || rules.length === 0) return true

    // Mojang arguments 规则：按顺序应用“匹配当前环境”的规则，
    // 最终状态由最后一条匹配规则决定；有 rules 时默认不包含。
    let allowed = false
    for (let rule of rules) {
      if (!VersionParser.isArgumentRuleMatched(rule)) continue
      allowed = (rule.action === 'allow')
    }
    return allowed
  }

  private static isArgumentRuleMatched(rule: ArgumentRule): boolean {
    if (!VersionParser.isRuleOsMatched(rule.os)) return false
    if (!VersionParser.isRuleFeaturesMatched(rule.features)) return false
    return true
  }

  private static isRuleOsMatched(os: ArgumentRuleOs | undefined): boolean {
    if (!os) return true
    if (os.name && os.name !== 'linux') return false
    if (os.arch) {
      let targetArch = VersionParser.normalizeArch(os.arch)
      if (targetArch !== VersionParser.currentArch()) return false
    }
    return true
  }

  private static normalizeArch(raw: string): string {
    let lower = raw.toLowerCase()
    if (lower === 'aarch64' || lower === 'arm64' || lower === 'arm64-v8a') {
      return 'aarch64'
    }
    if (lower === 'amd64' || lower === 'x86_64') {
      return 'x86_64'
    }
    return lower
  }

  private static currentArch(): string {
    // HarmonyOS NEXT ARM64 设备统一映射为 aarch64。
    return 'aarch64'
  }

  private static isRuleFeaturesMatched(features: Record<string, boolean> | undefined): boolean {
    if (!features) return true
    let keys = Object.keys(features)
    for (let i = 0; i < keys.length; i++) {
      let key = keys[i]
      let expected = features[key]
      let actual = VersionParser.getFeatureValue(key)
      if (actual !== expected) return false
    }
    return true
  }

  private static getFeatureValue(name: string): boolean {
    let knownKeys = Object.keys(VersionParser.KNOWN_FEATURES)
    if (knownKeys.indexOf(name) >= 0) {
      return VersionParser.KNOWN_FEATURES[name]
    }
    // 未识别 feature 默认 false，避免误放行条件参数。
    return false
  }
}
