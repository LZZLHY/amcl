/**
 * 只读版本身份与继承闭包解析。与运行解析器分开，避免其 Linux/OHOS 库过滤和修复副作用。
 * 输入为已读取的 JSON 文本；输出深拷贝，自定义目录名不被当作真实 Minecraft 版本。
 */
import { ExportIssue, ExportLoader, ExportResolvedVersion, ExportVersionSource } from './ExportTypes';
import { ExportPath } from './ExportPath';

export class ExportVersionResolver {
  /** 递归父版本最多 64 层，重复身份、缺父、非法 JSON 和环都使结果不能进入完整导出。 */
  static resolve(versionId: string, sources: ExportVersionSource[]): ExportResolvedVersion {
    const result: ExportResolvedVersion = { versionId: versionId, jarVersionId: versionId, vanillaVersion: '',
      loader: { kind: 'vanilla', version: '' }, json: {}, sourceIds: [], issues: [] };
    if (!ExportPath.segment(versionId)) {
      ExportVersionResolver.issue(result, 'VERSION_PATH', '版本目录名称不能安全用于导出');
      return result;
    }
    const byId = new Map<string, ExportVersionSource>();
    for (const source of sources) {
      if (byId.has(source.id)) ExportVersionResolver.issue(result, 'DUPLICATE_VERSION', '版本源身份重复');
      byId.set(source.id, source);
    }
    result.json = ExportVersionResolver.visit(versionId, byId, [], result);
    result.jarVersionId = ExportVersionResolver.jarOwner(versionId, byId, []);
    const jar = ExportVersionResolver.string(result.json, 'jar');
    if (jar.length > 0) {
      if (!ExportPath.segment(jar) || result.sourceIds.indexOf(jar) < 0) {
        ExportVersionResolver.issue(result, 'JAR_REFERENCE', '主 JAR 指向未核验的外部版本');
      } else result.jarVersionId = jar;
    }
    result.vanillaVersion = ExportVersionResolver.vanilla(result.json);
    result.loader = ExportVersionResolver.loader(result.json, result.vanillaVersion);
    if (result.vanillaVersion.length === 0) ExportVersionResolver.issue(result, 'VANILLA_IDENTITY', '不能从版本内容确认真实 Minecraft 版本');
    if (ExportVersionResolver.string(result.json, 'mainClass').length === 0) ExportVersionResolver.issue(result, 'MAIN_CLASS', '版本没有可用的 mainClass');
    if (!Array.isArray(result.json['libraries'])) ExportVersionResolver.issue(result, 'LIBRARIES_METADATA', '版本缺少完整 libraries 元数据');
    if (result.loader.kind === 'unknown') ExportVersionResolver.issue(result, 'LOADER_IDENTITY', '无法确认此版本的加载器类型与精确版本');
    return result;
  }

  /** 只接收普通 JSON 对象，null、数组及标量均不拥有版本字段语义。 */
  static object(value: Object | undefined): Record<string, Object> {
    return value !== null && value !== undefined && typeof value === 'object' && !Array.isArray(value)
      ? value as Record<string, Object> : {};
  }

  /** 动态 JSON 的字符串读取统一严格校验，避免隐式强转产生路径或虚假身份。 */
  static string(value: Record<string, Object>, key: string): string {
    return typeof value[key] === 'string' ? value[key] as string : '';
  }

  /**
   * 从清单声明的游戏参数读取精确值，兼容 --key value 与 --key=value；不读取 AMCL 实际启动命令。
   * 同一身份选项出现不同值时返回空值，让上层拒绝模糊身份，不能按第一个或最后一个猜版本。
   */
  static argumentValue(json: Record<string, Object>, flag: string): string {
    const args: string[] = [];
    const game = ExportVersionResolver.object(json['arguments'])['game'];
    if (Array.isArray(game)) for (const item of game as Object[]) if (typeof item === 'string') args.push(item as string);
    const legacy = ExportVersionResolver.string(json, 'minecraftArguments');
    if (legacy.length > 0) args.push(...legacy.split(/\s+/));
    let result = '';
    for (let i = 0; i < args.length; i++) {
      let value = '';
      if (args[i] === flag && i + 1 < args.length && !args[i + 1].startsWith('--')) value = args[i + 1];
      else if (args[i].startsWith(flag + '=')) value = args[i].substring(flag.length + 1);
      if (value.length === 0) continue;
      if (result.length > 0 && result !== value) return '';
      result = value;
    }
    return result;
  }

  /** 后代覆盖父字段，libraries 按坐标身份替换，arguments 按父→子追加；原输入始终不改。 */
  private static visit(id: string, sources: Map<string, ExportVersionSource>, visiting: string[], result: ExportResolvedVersion): Record<string, Object> {
    if (visiting.indexOf(id) >= 0 || visiting.length >= 64) {
      ExportVersionResolver.issue(result, 'INHERITANCE_CYCLE', '版本继承存在环或超过安全深度');
      return {};
    }
    const source = sources.get(id);
    if (source === undefined) {
      ExportVersionResolver.issue(result, 'PARENT_MISSING', '所选版本或父版本描述缺失', id);
      return {};
    }
    let child: Record<string, Object> = {};
    try {
      const parsed = JSON.parse(source.jsonText) as Object;
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('invalid object');
      child = parsed as Record<string, Object>;
    } catch (_) {
      ExportVersionResolver.issue(result, 'VERSION_JSON', '版本 JSON 损坏或不是对象', id);
      return {};
    }
    const parentId = ExportVersionResolver.string(child, 'inheritsFrom');
    let parent: Record<string, Object> = {};
    if (child['inheritsFrom'] !== undefined && (parentId.length === 0 || !ExportPath.segment(parentId))) {
      ExportVersionResolver.issue(result, 'PARENT_PATH', '父版本名称非法', id);
    } else if (parentId.length > 0) {
      const stack = visiting.slice();
      stack.push(id);
      parent = ExportVersionResolver.visit(parentId, sources, stack, result);
    }
    const merged: Record<string, Object> = {};
    for (const key of Object.keys(parent)) merged[key] = parent[key];
    for (const key of Object.keys(child)) merged[key] = child[key];
    // 旧格式没有结构化参数身份，简单覆盖会丢父参数，直接拼接又可能改变成对选项的含义。
    // 尚未建立可靠合并规则前，对父子均声明不同非空参数的链明确阻断，避免生成貌似完整的坏包。
    const parentLegacy = ExportVersionResolver.string(parent, 'minecraftArguments');
    const childLegacy = ExportVersionResolver.string(child, 'minecraftArguments');
    if (parentLegacy.length > 0 && childLegacy.length > 0 && parentLegacy !== childLegacy) {
      ExportVersionResolver.issue(result, 'LEGACY_INHERITANCE_ARGUMENTS',
        '父子版本声明了不同的旧式启动参数，当前无法可靠合并，请先将版本整理为自包含描述', id);
    }
    // downloads 是命名产物集合；子版本只新增 server 等字段时仍须继承父 client 身份。
    const downloads: Record<string, Object> = {};
    const parentDownloads = ExportVersionResolver.object(parent['downloads']);
    const childDownloads = ExportVersionResolver.object(child['downloads']);
    for (const key of Object.keys(parentDownloads)) downloads[key] = parentDownloads[key];
    for (const key of Object.keys(childDownloads)) downloads[key] = childDownloads[key];
    if (Object.keys(downloads).length > 0) merged['downloads'] = downloads;
    const parentLibs = Array.isArray(parent['libraries']) ? parent['libraries'] as Object[] : [];
    const childLibs = Array.isArray(child['libraries']) ? child['libraries'] as Object[] : [];
    if (parent['libraries'] !== undefined || child['libraries'] !== undefined) {
      const libraries: Object[] = [];
      const childKeys = childLibs.map((lib: Object): string => ExportVersionResolver.libraryKey(ExportVersionResolver.object(lib)));
      for (const lib of childLibs) libraries.push(lib);
      for (const lib of parentLibs) if (childKeys.indexOf(ExportVersionResolver.libraryKey(ExportVersionResolver.object(lib))) < 0) libraries.push(lib);
      merged['libraries'] = libraries;
    }
    const pa = ExportVersionResolver.object(parent['arguments']);
    const ca = ExportVersionResolver.object(child['arguments']);
    const args: Record<string, Object> = {};
    for (const key of ['game', 'jvm']) {
      const par = Array.isArray(pa[key]) ? pa[key] as Object[] : [];
      const cur = Array.isArray(ca[key]) ? ca[key] as Object[] : [];
      if (par.length > 0 || cur.length > 0) args[key] = par.concat(cur);
    }
    if (Object.keys(args).length > 0) merged['arguments'] = args;
    // 本体真实 ID 必须在覆盖 id 之前保存；继承根本身就是原版时可作为可靠身份。
    if (ExportVersionResolver.string(merged, 'clientVersion').length === 0 && parentId.length > 0) {
      merged['clientVersion'] = ExportVersionResolver.string(parent, 'clientVersion') || ExportVersionResolver.string(parent, 'id');
    }
    result.sourceIds.push(id);
    return merged;
  }

  /**
   * 主 JAR 按所选版本向父追溯，最近的 downloads.client 优先；递归合并阶段不能提前改这个选择，
   * 否则“父有继承、子自带 client”的链会误用祖父本体。环和 JSON 错误已由 visit 结构化报告。
   */
  private static jarOwner(id: string, sources: Map<string, ExportVersionSource>, visiting: string[]): string {
    if (visiting.indexOf(id) >= 0 || visiting.length >= 64) return id;
    const source = sources.get(id);
    if (source === undefined) return id;
    try {
    const json = ExportVersionResolver.object(JSON.parse(source.jsonText) as Object);
      const jar = ExportVersionResolver.string(json, 'jar');
      if (jar.length > 0) return jar;
      if (ExportVersionResolver.object(json['downloads'])['client'] !== undefined) return id;
      const parent = ExportVersionResolver.string(json, 'inheritsFrom');
      if (parent.length > 0) {
        const stack = visiting.slice();
        stack.push(id);
        return ExportVersionResolver.jarOwner(parent, sources, stack);
      }
    } catch (_) { return id; }
    return id;
  }

  /** 同 group:artifact[:classifier] 的后代声明覆盖父项，保持安装器的显式选择。 */
  private static libraryKey(lib: Record<string, Object>): string {
    const name = ExportVersionResolver.string(lib, 'name');
    const parts = name.split(':');
    return parts.length >= 3 ? parts[0] + ':' + parts[1] + (parts.length > 3 ? ':' + parts[3] : '') : name;
  }

  /** 身份优先使用明确 clientVersion，再取 FML 参数，最后只接受形似官方版本号的 id。 */
  private static vanilla(json: Record<string, Object>): string {
    const explicit = ExportVersionResolver.string(json, 'clientVersion');
    if (explicit.length > 0 && ExportPath.segment(explicit)) return explicit;
    const fmlVersion = ExportVersionResolver.argumentValue(json, '--fml.mcVersion');
    if (fmlVersion.length > 0 && ExportPath.segment(fmlVersion)) return fmlVersion;
    const id = ExportVersionResolver.string(json, 'id');
    return /^(?:[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:[-_ ].*)?|[0-9]{2}w[0-9]{2}[a-z]|[ab][0-9].*)$/.test(id) ? id : '';
  }

  /** 只认精确 loader 坐标，不从用户目录名、下载历史或“最新版本”猜测。 */
  private static loader(json: Record<string, Object>, vanilla: string): ExportLoader {
    // 新 Forge 的 version.json 只有 fmlloader；NeoForge 26.x 只有 fancymodloader 模块。
    // FML 参数中的产品版本才是安装器/运行产物身份，不能把 loader 模块版本当作 NeoForge 版本。
    const neoVersion = ExportVersionResolver.argumentValue(json, '--fml.neoForgeVersion');
    if (neoVersion.length > 0 && ExportPath.segment(neoVersion)) return { kind: 'neoforge', version: neoVersion,
      coordinate: 'net.neoforged:neoforge:' + neoVersion };
    const forgeVersion = ExportVersionResolver.argumentValue(json, '--fml.forgeVersion');
    const forgeGroup = ExportVersionResolver.argumentValue(json, '--fml.forgeGroup');
    if (forgeVersion.length > 0 && ExportPath.segment(forgeVersion)
      && (forgeGroup.length === 0 || forgeGroup === 'net.minecraftforge' || forgeGroup === 'net.neoforged')) {
      return { kind: forgeGroup === 'net.neoforged' ? 'neoforge' : 'forge', version: forgeVersion,
        coordinate: (forgeGroup || 'net.minecraftforge') + ':forge:' + vanilla + '-' + forgeVersion };
    }
    const libs = Array.isArray(json['libraries']) ? json['libraries'] as Object[] : [];
    for (const item of libs) {
      const name = ExportVersionResolver.string(ExportVersionResolver.object(item), 'name');
      const p = name.split(':');
      if (p.length < 3) continue;
      if (p[0] === 'net.fabricmc' && p[1] === 'fabric-loader') return { kind: 'fabric', version: p[2] };
      if (p[0] === 'org.quiltmc' && p[1] === 'quilt-loader') return { kind: 'quilt', version: p[2] };
      if (p[0] === 'net.neoforged' && (p[1] === 'neoforge' || p[1] === 'forge')) return { kind: 'neoforge', version: p[2].startsWith(vanilla + '-') ? p[2].substring(vanilla.length + 1) : p[2], coordinate: p.slice(0, 3).join(':').split('@')[0] };
      if (p[0] === 'net.minecraftforge' && p[1] === 'forge') return { kind: 'forge', version: p[2].startsWith(vanilla + '-') ? p[2].substring(vanilla.length + 1) : p[2], coordinate: p.slice(0, 3).join(':').split('@')[0] };
    }
    const main = ExportVersionResolver.string(json, 'mainClass');
    return main === 'net.minecraft.client.main.Main' || main === 'net.minecraft.launchwrapper.Launch'
      && ExportVersionResolver.string(json, 'minecraftArguments').indexOf('--tweakClass') < 0
      || main === 'net.minecraft.client.Minecraft' ? { kind: 'vanilla', version: '' } : { kind: 'unknown', version: '' };
  }

  /** 所有失败保持结构化，读取层和页面可展示同一原因，避免把空结果当作完整版本。 */
  private static issue(result: ExportResolvedVersion, code: string, message: string, path: string = ''): void {
    const issue: ExportIssue = { code: code, severity: 'error', message: message, path: path };
    result.issues.push(issue);
  }
}
