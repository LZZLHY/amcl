/**
 * VersionJsonMerger.ets — PCL2 风格 version.json 合并器
 *
 * 参考 PCL2 MergeJson 函数，将原版 JSON 和模组加载器 JSON 合并为
 * 完全自包含的 version.json（无 inheritsFrom）。
 *
 * 合并规则：
 *   1. 以原版 JSON 为基础
 *   2. mainClass: 加载器优先
 *   3. libraries: 加载器的追加到原版之前（优先加载）
 *   4. arguments.game: 原版 + 加载器追加
 *   5. arguments.jvm: 原版 + 加载器追加
 *   6. minecraftArguments: 合并去重（1.12 及以下格式）
 *   7. 删除 inheritsFrom / jar 字段
 *   8. 设置 id = outputName
 *   9. 复制原版 jar 到输出目录
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { writeTextFile } from 'commons';
import { parseMavenName, compareMavenVersions } from '../modloader/MavenUtils';
import { VersionParser } from './VersionParser';

const TAG = 'VersionJsonMerger';

export class VersionJsonMerger {

  /**
   * 合并原版 JSON 和模组加载器 JSON，生成完全自包含的 version.json。
   *
   * @param minecraftJsonPath 原版 version.json 路径
   * @param loaderJsonPath    模组加载器 version.json 路径（null 表示无加载器）
   * @param outputName        输出版本名称（用户自定义）
   * @param outputDir         输出目录（不含尾部斜杠）
   * @param mcJarPath         原版 jar 路径（将复制到输出目录）
   */
  static merge(
    minecraftJsonPath: string,
    loaderJsonPath: string | null,
    outputName: string,
    outputDir: string,
    mcJarPath: string
  ): void {
    hilog.info(0x0000, TAG, 'MergeJson: mc=%{public}s loader=%{public}s output=%{public}s',
      minecraftJsonPath, loaderJsonPath || '(none)', outputName)

    // 读取原版 JSON
    let mcContent = VersionJsonMerger.readTextFile(minecraftJsonPath)
    if (mcContent.length === 0) {
      throw new Error('原版 version.json 为空或不存在: ' + minecraftJsonPath)
    }
    let mcJson: Record<string, Object> = JSON.parse(mcContent) as Record<string, Object>

    // 读取加载器 JSON（如果有）
    let loaderJson: Record<string, Object> | null = null
    if (loaderJsonPath) {
      let loaderContent = VersionJsonMerger.readTextFile(loaderJsonPath)
      if (loaderContent.length === 0) {
        throw new Error('加载器 version.json 为空或不存在: ' + loaderJsonPath)
      }
      loaderJson = JSON.parse(loaderContent) as Record<string, Object>
    }

    // 合并
    let outputJson = VersionJsonMerger.mergeJsonObjects(mcJson, loaderJson, outputName)

    // 确保输出目录存在
    try { fs.mkdirSync(outputDir, true) } catch (e) { /* exists */ }

    // 写入合并后的 JSON
    let outputJsonPath = outputDir + '/' + outputName + '.json'
    let jsonStr = JSON.stringify(outputJson, null, 2)
    writeTextFile(outputJsonPath, jsonStr)
    hilog.info(0x0000, TAG, 'Written merged JSON: %{public}s (%{public}d bytes)',
      outputJsonPath, jsonStr.length)

    // 复制 jar
    let outputJarPath = outputDir + '/' + outputName + '.jar'
    if (mcJarPath !== outputJarPath) {
      try { fs.unlinkSync(outputJarPath) } catch (e) { /* not exists */ }
      // 2026-05-23 ArkTS 严格模式：fs.copyFileSync 会报 'Function may throw'。
      // 包 try-catch + hilog + rethrow 保留原行为（合并失败让上层中止），
      // 但日志里能看到目标路径。详见 docs/guides/api-migration-2026-05.md。
      try {
        fs.copyFileSync(mcJarPath, outputJarPath)
      } catch (e) {
        hilog.error(0x0000, TAG, 'copyFileSync %{public}s -> %{public}s failed: %{public}s',
          mcJarPath, outputJarPath, (e as Error).message)
        throw e as Error
      }
      let jarSize = VersionJsonMerger.fileSize(outputJarPath)
      hilog.info(0x0000, TAG, 'Copied jar: %{public}s -> %{public}s (%{public}d bytes)',
        mcJarPath, outputJarPath, jarSize)
    }
  }

  /**
   * 合并两个 JSON 对象，返回合并后的结果。
   * 参考 PCL2 MergeJson 的合并逻辑。
   *
   * 2026-05-06：Phase 7 解锁 public 用于纯函数单元测试（零 IO / 零 NAPI 依赖）。
   */
  static mergeJsonObjects(
    mcJson: Record<string, Object>,
    loaderJson: Record<string, Object> | null,
    outputName: string
  ): Record<string, Object> {
    // 以原版为基础
    let output: Record<string, Object> = mcJson

    // 记录真实原版 MC 版本：合并后 id 会被改成自定义名（整合包名/重命名），
    // detectVanillaVersion 会退化到读 id → 拿到自定义名而非真实版本。写 clientVersion
    // 作为内容判定的权威字段（PCL2 同款），使 JDK 纪元路由 / 渲染器判定对整合包 +
    // 重命名版本都能从内容拿到正确 MC 版本。
    let vanillaVersion = ''
    let rawVanillaId = mcJson['id']
    if (typeof rawVanillaId === 'string') vanillaVersion = rawVanillaId as string
    let existingClientVer = mcJson['clientVersion']
    if (typeof existingClientVer === 'string' && (existingClientVer as string).length > 0) {
      vanillaVersion = existingClientVer as string
    }

    if (loaderJson) {
      // Java 下限取两个有效声明的较高者；加载器可以提高要求，不能降低原版要求。
      // 其余 javaVersion 字段保留原版值，避免合并时顺手丢掉 component 等来源信息。
      VersionJsonMerger.mergeJavaVersionMetadata(output, loaderJson);
      // 加载器显式 logging.client 优先；其余字段继续继承官方元数据。
      const loaderLogging = loaderJson['logging'] as Record<string, Object> | undefined;
      if (loaderLogging !== undefined && loaderLogging['client'] !== undefined) {
        const logging = output['logging'] as Record<string, Object> | undefined;
        const mergedLogging: Record<string, Object> = {};
        if (logging !== undefined) for (const key of Object.keys(logging)) mergedLogging[key] = logging[key];
        mergedLogging['client'] = loaderLogging['client'];
        output['logging'] = mergedLogging;
      }
      // mainClass: 加载器优先
      if (loaderJson['mainClass']) {
        output['mainClass'] = loaderJson['mainClass']
      }

      // libraries: 加载器的放前面（优先加载），原版的在后
      //
      // 关键：拼接后必须按 groupId:artifactId 去重并保留最高版本（对齐 HMCL
      // MaintainTask.unique / PCL2 MergeJson）。否则当原版与加载器各自声明同一库的
      // 不同版本时（如 vanilla 1.21.6 自带 org.ow2.asm:asm:9.6 + Fabric 带 asm:9.9），
      // 两个版本都会进 classpath，Fabric loader 的 LoaderUtil.verifyClasspath 检测到
      // 重复 ASM 类直接抛 IllegalStateException 拒绝启动。加载器在前 → 高版本通常来自
      // 加载器，去重后即"用加载器版本替换/升级原版版本"。
      let mcLibs = output['libraries'] as Object[]
      let loaderLibs = loaderJson['libraries'] as Object[]
      if (loaderLibs && loaderLibs.length > 0) {
        if (mcLibs && mcLibs.length > 0) {
          output['libraries'] = VersionJsonMerger.uniqueLibraries((loaderLibs as Object[]).concat(mcLibs))
        } else {
          output['libraries'] = VersionJsonMerger.uniqueLibraries(loaderLibs)
        }
      }

      // arguments（MC 1.13+ 格式）
      let mcArgs = output['arguments'] as Record<string, Object> | undefined
      let loaderArgs = loaderJson['arguments'] as Record<string, Object> | undefined
      if (loaderArgs) {
        if (!mcArgs) {
          mcArgs = {} as Record<string, Object>
          output['arguments'] = mcArgs
        }
        // game args: 原版 + 加载器追加
        if (loaderArgs['game']) {
          let mcGame = (mcArgs['game'] || []) as Object[]
          let loaderGame = loaderArgs['game'] as Object[]
          mcArgs['game'] = mcGame.concat(loaderGame)
        }
        // jvm args: 原版 + 加载器追加
        if (loaderArgs['jvm']) {
          let mcJvm = (mcArgs['jvm'] || []) as Object[]
          let loaderJvm = loaderArgs['jvm'] as Object[]
          mcArgs['jvm'] = mcJvm.concat(loaderJvm)
        }
      }

      // minecraftArguments（MC 1.12 及以下格式）: 合并去重
      let mcMinecraftArgs = output['minecraftArguments'] as string | undefined
      let loaderMinecraftArgs = loaderJson['minecraftArguments'] as string | undefined
      if (loaderMinecraftArgs && loaderMinecraftArgs.length > 0) {
        let allArgs = ((mcMinecraftArgs || '') + ' ' + loaderMinecraftArgs).trim()
        let parts = allArgs.split(' ').filter((s: string) => s.length > 0)
        let unique = VersionJsonMerger.dedupeStringArray(parts)
        output['minecraftArguments'] = unique.join(' ')
      }

      // type: 加载器有则用加载器的
      if (loaderJson['type']) {
        output['type'] = loaderJson['type']
      }

      // releaseTime / time: 保留原版的（PCL2 行为：删除加载器的 releaseTime/time）
      // 不需要额外操作，因为我们以原版为基础
    }

    // 构建输出 JSON：排除 inheritsFrom / jar / _comment_ 字段（PCL2 核心操作）
    // ArkTS 不支持 delete，所以构建新对象时跳过这些字段
    let cleanOutput: Record<string, Object> = {};
    let keys = Object.keys(output);
    for (let key of keys) {
      if (key === 'inheritsFrom' || key === 'jar' || key === '_comment_') continue;
      cleanOutput[key] = output[key];
    }

    // 设置 id 为用户自定义名称
    cleanOutput['id'] = outputName;

    // 写入真实原版 MC 版本（detectVanillaVersion 第 1 优先字段），保证改名/整合包后仍可内容判定
    if (vanillaVersion.length > 0) {
      cleanOutput['clientVersion'] = vanillaVersion;
    }

    return cleanOutput;
  }

  /**
   * 合并 Java 运行要求。仅在加载器给出了有效且更高的下限时创建新元数据对象，
   * 不修改原版 javaVersion 对象内部字段；原版没有对象时继承加载器其余字段。
   * 双方均没有有效声明时保持原状，交由解析器的纪元回退处理，绝不臆造最低版本。
   */
  private static mergeJavaVersionMetadata(output: Record<string, Object>, loader: Record<string, Object>): void {
    const original: Object | undefined = output['javaVersion'];
    const added: Object | undefined = loader['javaVersion'];
    const originalMajor: number = VersionParser.javaMajorFromMetadata(original);
    const addedMajor: number = VersionParser.javaMajorFromMetadata(added);
    if (addedMajor <= originalMajor) return;
    const hasOriginalObject: boolean = original !== undefined && original !== null
      && typeof original === 'object' && !Array.isArray(original);
    const fields: Record<string, Object> = (hasOriginalObject ? original : added) as Record<string, Object>;
    const merged: Record<string, Object> = {};
    for (const key of Object.keys(fields)) merged[key] = fields[key];
    merged['majorVersion'] = addedMajor;
    output['javaVersion'] = merged;
  }

  /**
   * 按 groupId:artifactId(:classifier) 去重 libraries，版本不同时保留最高版本。
   *
   * 移植自 HMCL `MaintainTask.unique(Version)`（HMCLCore/.../download/MaintainTask.java）：
   *   - key = groupId:artifactId(:classifier)（classifier 让 natives 与主 jar 分开，不被误删）
   *   - 同 key 再次出现时比较版本号，`compareMavenVersions > 0` 就用高版本替换已记录的低版本
   *   - 无法解析坐标（name 缺失 / 非法）的条目原样保留，不参与去重
   *
   * 保序：首次出现某 GA 的位置固定（加载器库在前，所以高版本通常落在加载器位置）。
   *
   * 2026-06-04：Phase 7 风格解锁 public 便于纯函数单元测试。
   */
  static uniqueLibraries(libs: Object[]): Object[] {
    let out: Object[] = []
    let keyToIndex = new Map<string, number>()
    let dropped = 0
    for (let lib of libs) {
      let libObj = lib as Record<string, Object>
      let rawName = libObj['name']
      let name = (typeof rawName === 'string') ? rawName as string : ''
      let coord = name.length > 0 ? parseMavenName(name) : null
      if (!coord) {
        // 无法识别坐标，无法安全去重 —— 原样保留
        out.push(lib)
        continue
      }
      let key = coord.groupId + ':' + coord.artifactId
        + (coord.classifier ? ':' + coord.classifier : '')
      let existingIdx = keyToIndex.get(key)
      if (existingIdx === undefined) {
        keyToIndex.set(key, out.length)
        out.push(lib)
      } else {
        // 已有同 GA：保留高版本
        let existing = out[existingIdx] as Record<string, Object>
        let existingName = (typeof existing['name'] === 'string') ? existing['name'] as string : ''
        let existingCoord = existingName.length > 0 ? parseMavenName(existingName) : null
        let existingVer = existingCoord ? existingCoord.version : '0'
        if (compareMavenVersions(coord.version, existingVer) > 0) {
          out[existingIdx] = lib
          hilog.info(0x0000, TAG, 'uniqueLibraries: %{public}s upgraded %{public}s -> %{public}s',
            key, existingVer, coord.version)
        }
        dropped++
      }
    }
    if (dropped > 0) {
      hilog.info(0x0000, TAG,
        'uniqueLibraries: removed %{public}d duplicate libs (kept highest version per groupId:artifactId)',
        dropped)
    }
    return out
  }

  // ============================================================
  //  工具方法
  // ============================================================

  /** 2026-05-06：Phase 7 解锁 public 用于纯函数单元测试。 */
  static dedupeStringArray(arr: string[]): string[] {
    let seen = new Set<string>()
    let result: string[] = []
    for (let item of arr) {
      if (!seen.has(item)) {
        seen.add(item)
        result.push(item)
      }
    }
    return result
  }

  private static readTextFile(path: string): string {
    try {
      return fs.readTextSync(path)
    } catch (e) {
      return ''
    }
  }

  private static fileSize(path: string): number {
    try {
      return fs.statSync(path).size
    } catch (e) {
      return -1
    }
  }
}
