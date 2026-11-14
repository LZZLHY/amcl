/**
 * 完整电脑实例、MCBBS、旧 HMCL 和 MultiMC 的只读适配层。
 * 本层只确认精确游戏/加载器身份和包内用户内容根；不执行捆绑启动器、Java 或脚本，
 * 不把电脑 version.json 直接作为鸿蒙启动描述。执行和本地文件摘要校验仍由安装 owner 完成。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { ExportVersionResolver, ExportVersionSource, ExportResolvedVersion, ExportIssue } from 'feature_core';
import { ModpackPlan, ParsedModpack, ModpackLoader, ModpackFile, ModpackEnv,
  safeBaseName, safeRelPath } from './ModpackManifest';

/** 一个真实存在且可供 UI 固定选择的数据根；路径始终相对候选包根，点号表示共享根。 */
export interface ModpackDataRoot { path: string; title: string; }
/** 本地作者文件的预期摘要；异步 SHA-1 校验由安装器在应用覆盖前执行。 */
interface InstanceLocalFile { path: string; sha1: string; root?: string; }
/** 额外字段全为可序列化数据，随统一持久计划恢复，不保存文件句柄或页面对象。 */
interface InstancePlan extends ModpackPlan {
  contentOnly: boolean;
  instanceVersionId?: string;
  requiredLocalFiles: InstanceLocalFile[];
}
interface ComponentIdentity { game: string; loader: ModpackLoader; version: string; }

/** 读取普通、有限大小 JSON；BOM 只在文本入口去除，不改变清单语义。 */
function json(root: string, relative: string): Record<string, Object> {
  const path = checkedPath(root, relative);
  const stat = fs.lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 4 * 1024 * 1024) {
    throw new Error('实例元数据不是有限大小的普通文件：' + relative);
  }
  try {
    const value = JSON.parse(fs.readTextSync(path).replace(/^\uFEFF/, '')) as Object;
    if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Error('object required');
    return value as Record<string, Object>;
  } catch (_) { throw new Error('实例元数据 JSON 无效：' + relative); }
}
/** 动态来源仅接受真实字符串/对象，不能把 null 或数字隐式转为路径和版本。 */
function object(value: Object | undefined): Record<string, Object> {
  return value !== null && value !== undefined && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, Object> : {};
}
function string(value: Record<string, Object>, key: string): string {
  return typeof value[key] === 'string' ? value[key] as string : '';
}
/** 相对路径只能走包内普通目录链；唯一例外是内部定义的根哨兵，不放宽公共路径校验。 */
function checkedPath(root: string, relative: string): string {
  if (relative !== '.' && safeRelPath(relative) !== relative) throw new Error('实例来源路径不安全：' + relative);
  let path = root;
  const start = fs.lstatSync(path);
  if (!start.isDirectory() || start.isSymbolicLink()) throw new Error('实例包根不是普通目录');
  if (relative === '.') return path;
  for (const part of relative.split('/')) {
    path += '/' + part;
    if (fs.lstatSync(path).isSymbolicLink()) throw new Error('实例来源包含符号链接：' + relative);
  }
  return path;
}
/** 可选记录只用于发现；选中后的读取仍再次检查完整路径链和类型。 */
function file(root: string, rel: string): boolean {
  try { return fs.lstatSync(checkedPath(root, rel)).isFile(); } catch (_) { return false; }
}
function directory(root: string, rel: string): boolean {
  try { return fs.lstatSync(checkedPath(root, rel)).isDirectory(); } catch (_) { return false; }
}

/**
 * 电脑运行层和私有控制文件不属于待迁移的用户内容。允许未知模组数据目录，
 * 但不复制桌面本机二进制/脚本或账户。versionId 是来源 ID，可能与用户选择的新实例名不同。
 */
export function isInstanceContentPath(relative: string, versionId?: string): boolean {
  if (safeRelPath(relative) !== relative) return false;
  const lower = relative.toLowerCase();
  const parts = lower.split('/');
  const first = parts[0];
  if (['versions', 'libraries', 'assets', 'bin', 'runtime', 'runtimes', 'jre', 'jdk', 'java',
    'natives', '.natives', 'pcl', '.hmcl', '.amcl', '.amcl-runtime', 'accounts', '.secrets',
    'launcher_logs', 'logs', 'crash-reports'].indexOf(first) >= 0 || first.startsWith('lwjgl-ohos')) return false;
  // 只在游戏内容根排除可确认的版本化 Java 目录，不能误删 mods 内同名资源。
  if (/^(?:jre|jdk)[-_]?[0-9][a-z0-9._+\-]*$/.test(first)) return false;
  if (parts.some((part: string): boolean => part.startsWith('.amcl-'))) return false;
  const base = parts[parts.length - 1];
  // 包装层常见 HMCL/PCL 程序自身也是 JAR；只按根层已知名字识别，普通 mod JAR 保留。
  if (parts.length === 1 && (/^(?:hmcl|pcl(?:2|ce)?|launcher)(?:[-_. ][a-z0-9].*)?\.jar$/.test(base)
    || ['hmcl.json', 'hmcl_config.json', 'hmclconfig.json', 'pcl.json', 'launcher.json', 'launcher.cfg'].indexOf(base) >= 0)) return false;
  if (['launcher_accounts.json', 'launcher_profiles.json', 'accounts.json', 'authentication.json',
    'launcher_settings.json', 'usercache.json', 'usernamecache.json', 'session.lock', 'amcl.json',
    'amcl-export.json', 'modrinth.index.json', 'manifest.json', 'mcbbs.packmeta', 'mmc-pack.json',
    'modpack.json', 'instance.cfg', 'pack.json', 'user_jvm_args.txt', 'jvm_args.txt'].indexOf(base) >= 0) return false;
  if (versionId !== undefined && parts.length === 1
    && (base === versionId.toLowerCase() + '.json' || base === versionId.toLowerCase() + '.jar')) return false;
  return !/\.(?:exe|dll|dylib|so(?:\.[0-9]+)*|bat|cmd|ps1|vbs|sh|msi|lnk|part|download)$/i.test(base);
}

/** 只看一层是否存在用户内容，避免发现阶段递归扫描全部游戏资源。 */
function hasContent(root: string, rel: string, versionId: string): boolean {
  if (!directory(root, rel)) return false;
  return fs.listFileSync(checkedPath(root, rel)).some((name: string): boolean => isInstanceContentPath(name, versionId));
}
/** 解析已知 PCL 配置；忽略注释，只接受确有定义的隔离开关，不采用 Java/命令字段。 */
function pclRoot(root: string, isolated: string): string {
  const rel = isolated + '/PCL/Setup.ini';
  if (!file(root, rel)) return '';
  let modern = '', legacy = '';
  for (const raw of fs.readTextSync(checkedPath(root, rel)).split(/\r?\n/)) {
    const line = raw.trim();
    if (line.startsWith('#') || line.startsWith(';')) continue;
    const match = /^(VersionArgumentIndieV2|VersionArgumentIndie)\s*[:=]\s*(\S+)\s*$/i.exec(line);
    if (match === null) continue;
    if (match[1].toLowerCase() === 'versionargumentindiev2') modern = match[2].toLowerCase();
    else legacy = match[2];
  }
  if (modern === 'true') return isolated;
  if (modern === 'false') return '.';
  if (legacy === '1') return isolated;
  if (legacy === '2') return '.';
  return '';
}
/** 只消费 HMCL 明确覆盖的 runningDirectory；外部绝对路径和变量路径不能迁入应用沙箱。 */
function hmclRoot(root: string, isolated: string): string {
  const rel = isolated + '/.hmcl/config/instance-game-settings.json';
  if (!file(root, rel)) return '';
  const settings = json(root, rel);
  if (!Array.isArray(settings['overrideProperties'])
    || (settings['overrideProperties'] as Object[]).indexOf('runningDirectory') < 0) return '';
  if (typeof settings['runningDirectory'] !== 'string') throw new Error('HMCL 游戏目录配置类型无效');
  const value = string(settings, 'runningDirectory');
  if (value === '') return isolated;
  if (value !== '.' && safeRelPath(value) !== value) throw new Error('HMCL 指向包外或变量游戏目录，请选择包内数据根');
  return value;
}

/**
 * 给发现层返回实际可选择的数据根。已知启动器的明确配置优先；缺配置时两侧均有内容，
 * 返回两个候选，让 UI 固定选择后再调用 parse，而不是把共享/隔离的 mod 和配置混合。
 */
export function discoverInstanceDataRoots(root: string, versionId: string): ModpackDataRoot[] {
  if (safeBaseName(versionId) !== versionId) throw new Error('实例版本 ID 不安全');
  const isolated = 'versions/' + versionId;
  if (!directory(root, isolated)) throw new Error('所选客户端实例目录不存在');
  const pcl = pclRoot(root, isolated), hmcl = hmclRoot(root, isolated);
  if (pcl.length > 0 && hmcl.length > 0 && pcl !== hmcl) {
    if (!directory(root, pcl) || !directory(root, hmcl)) throw new Error('启动器指定的包内游戏目录不存在');
    return [{ path: pcl, title: 'PCL 指定的数据根（与 HMCL 冲突）' },
      { path: hmcl, title: 'HMCL 指定的数据根（与 PCL 冲突）' }];
  }
  const configured = pcl || hmcl;
  if (configured.length > 0) {
    if (!directory(root, configured)) throw new Error('启动器指定的包内游戏目录不存在');
    return [{ path: configured, title: configured === '.' ? '共享游戏目录' : '独立游戏目录' }];
  }
  const result: ModpackDataRoot[] = [];
  if (hasContent(root, '.', versionId)) result.push({ path: '.', title: '共享游戏目录' });
  if (hasContent(root, isolated, versionId)) result.push({ path: isolated, title: '独立游戏目录' });
  return result.length > 0 ? result : [{ path: isolated, title: '独立游戏目录（无附加用户内容）' }];
}

/** game/loader 身份只接受精确、安全且非冲突值；不从文件名或“最新”猜测。 */
function identity(entries: Record<string, Object>[], gameKey: string, uidKey: string): ComponentIdentity {
  const result: ComponentIdentity = { game: '', loader: ModpackLoader.NONE, version: '' };
  const seen: Map<string, string> = new Map<string, string>();
  for (const entry of entries) {
    const id = string(entry, uidKey), version = string(entry, 'version');
    if (id.length === 0 || version.length === 0 || safeBaseName(version) !== version) throw new Error('整合包组件缺少安全的精确版本');
    if (seen.has(id) && seen.get(id) !== version) throw new Error('整合包组件身份冲突：' + id);
    seen.set(id, version);
    if (id === gameKey) { result.game = version; continue; }
    // MMC 声明的电脑 LWJGL 由鸿蒙运行时替换，不构成第二个模组加载器。
    if (uidKey === 'uid' && (id === 'org.lwjgl' || id === 'org.lwjgl3')) continue;
    let loader = ModpackLoader.NONE;
    if (id === 'forge' || id === 'net.minecraftforge') loader = ModpackLoader.FORGE;
    else if (id === 'neoforge' || id === 'net.neoforged') loader = ModpackLoader.NEOFORGE;
    else if (id === 'fabric' || id === 'net.fabricmc.fabric-loader') loader = ModpackLoader.FABRIC;
    else if (id === 'quilt' || id === 'org.quiltmc.quilt-loader') loader = ModpackLoader.QUILT;
    else throw new Error('暂不支持整合包声明的组件：' + id);
    if (result.loader !== ModpackLoader.NONE && (result.loader !== loader || result.version !== version)) {
      throw new Error('整合包声明了多个互斥加载器');
    }
    result.loader = loader; result.version = version;
  }
  if (result.game.length === 0) throw new Error('整合包没有精确 Minecraft 版本');
  return result;
}
/** 建立统一计划；本机执行设置不进入计划，用户内容在 owner 中过滤并复制。 */
function parsed(kind: string, name: string, packVersion: string, ident: ComponentIdentity,
  roots: string[], versionId?: string): ParsedModpack {
  const plan: InstancePlan = { source: kind, name: name || '本地整合包', packVersion: packVersion,
    gameVersion: ident.game, loaderType: ident.loader, loaderVersion: ident.version, summary: '', files: [],
    overrideDirs: roots, problems: [], contentOnly: true, requiredLocalFiles: [], instanceVersionId: versionId };
  return { plan: plan, warnings: ['仅迁移用户内容；启动器程序、账户、捆绑 Java 和电脑原生运行库不导入，游戏运行层由鸿蒙重新建立。'] };
}

/** Record 的逐键构造避免把异构动态对象字面量交给 ArkTS 推断。 */
function component(id: string, version: string): Record<string, Object> {
  const value: Record<string, Object> = {};
  value['id'] = id; value['version'] = version;
  return value;
}

/**
 * 按参数协议收集某一身份开关的所有值，包括 --key=value、旧字符串和 rules.value。
 * 不读取启动器保存的实际命令；条件参数只作为声明证据，出现不同身份仍须停止猜选。
 */
function argumentValues(value: Record<string, Object>, flag: string): string[] {
  const args: string[] = [];
  const append = (items: Object[], depth: number): void => {
    if (depth > 32) throw new Error('版本参数嵌套过深');
    for (const item of items) {
      if (typeof item === 'string') args.push(item as string);
      else {
        const nested = object(item)['value'];
        if (typeof nested === 'string') args.push(nested as string);
        else if (Array.isArray(nested)) append(nested as Object[], depth + 1);
      }
    }
  };
  const game = object(value['arguments'])['game'];
  if (Array.isArray(game)) append(game as Object[], 0);
  const legacy = string(value, 'minecraftArguments');
  if (legacy.length > 0) args.push(...legacy.split(/\s+/));
  const result: string[] = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === flag && i + 1 < args.length && !args[i + 1].startsWith('--')) result.push(args[i + 1]);
    else if (args[i].startsWith(flag + '=')) result.push(args[i].substring(flag.length + 1));
  }
  return result;
}

/**
 * loader 库不能把服务端 mainClass 变成客户端资格；Forge 共用 bootstrap 主类时再核查
 * 明确的 server launchTarget。这里只拒绝确有服务端语义的声明，不通过目录名猜测。
 */
function verifyClient(resolved: ExportResolvedVersion): void {
  const main = string(resolved.json, 'mainClass').toLowerCase();
  if (main === 'net.minecraft.server.main' || main.indexOf('.server.') >= 0
    || /\.(?:knotserver|servermain|serverlaunchwrapper|fabricserverlauncher|quiltserverlauncher)$/.test(main)
    || argumentValues(resolved.json, '--launchTarget').some((target: string): boolean =>
      ['forgeserver', 'neoforgeserver', 'fmlserver', 'server'].indexOf(target.toLowerCase()) >= 0)) {
    throw new Error('所选版本明确声明服务端入口，不能作为客户端实例安装');
  }
}

/**
 * 比对已解析父闭包中的所有真实 Minecraft 身份来源，禁止优先级掩盖矛盾。
 * 自定义目录名和显示名不计入证据；只在无显式 clientVersion 的原版根使用官方形态 ID，
 * 与 ExportVersionResolver 的 fallback 保持一致。Forge Maven 的 MC 前缀同样是身份声明。
 */
function verifyGameIdentity(resolved: ExportResolvedVersion, sources: ExportVersionSource[]): void {
  const expected = resolved.vanillaVersion;
  const check = (value: string): void => {
    if (value.length > 0 && value !== expected) throw new Error('客户端声明了冲突的 Minecraft 版本：' + expected + ' / ' + value);
  };
  for (const source of sources) {
    const raw = object(JSON.parse(source.jsonText) as Object);
    const explicit = string(raw, 'clientVersion');
    check(explicit);
    for (const value of argumentValues(raw, '--fml.mcVersion')) check(value);
    if (explicit.length === 0 && string(raw, 'inheritsFrom').length === 0) {
      const id = string(raw, 'id');
      if (/^(?:[0-9]+\.[0-9]+(?:\.[0-9]+)?|[0-9]{2}w[0-9]{2}[a-z]|[ab][0-9].*)$/.test(id)) check(id);
    }
    const libraries = Array.isArray(raw['libraries']) ? raw['libraries'] as Object[] : [];
    for (const entry of libraries) {
      const parts = string(object(entry), 'name').split(':');
      if (parts.length < 3 || parts[1] !== 'forge' || ['net.minecraftforge', 'net.neoforged'].indexOf(parts[0]) < 0) continue;
      const match = /^([0-9]+\.[0-9]+(?:\.[0-9]+)?)-/.exec(parts[2]);
      if (match !== null) check(match[1]);
    }
  }
}

/** 从完整版本的声明核验 loader 冲突，弥补通用导出解析器“首个识别坐标”不能用于导入冲突裁决的问题。 */
function verifyLoader(resolved: ExportResolvedVersion): void {
  const libs = Array.isArray(resolved.json['libraries']) ? resolved.json['libraries'] as Object[] : [];
  const declarations: Record<string, Object>[] = [];
  declarations.push(component('game', resolved.vanillaVersion));
  for (const raw of libs) {
    const parts = string(object(raw), 'name').split(':');
    if (parts.length < 3) continue;
    let id = '';
    if (parts[0] === 'net.fabricmc' && parts[1] === 'fabric-loader') id = 'fabric';
    else if (parts[0] === 'org.quiltmc' && parts[1] === 'quilt-loader') id = 'quilt';
    else if (parts[0] === 'net.minecraftforge' && parts[1] === 'forge') id = 'forge';
    else if (parts[0] === 'net.neoforged' && (parts[1] === 'forge' || parts[1] === 'neoforge')) id = 'neoforge';
    if (id.length > 0) declarations.push(component(id, parts[2].startsWith(resolved.vanillaVersion + '-')
      ? parts[2].substring(resolved.vanillaVersion.length + 1) : parts[2]));
  }
  if (resolved.loader.kind !== 'vanilla') declarations.push(component(resolved.loader.kind, resolved.loader.version));
  identity(declarations, 'game', 'id');
}
/** 统一调用导出域的继承解析，并把身份不全/继承环/缺父/未知 loader 在写实例前报告。 */
function resolvedIdentity(id: string, sources: ExportVersionSource[]): ExportResolvedVersion {
  const result = ExportVersionResolver.resolve(id, sources);
  const issue = result.issues.find((entry: ExportIssue): boolean => entry.severity === 'error');
  if (issue !== undefined) throw new Error('客户端实例无法重建：' + issue.message);
  verifyClient(result);
  verifyGameIdentity(result, sources);
  verifyLoader(result);
  return result;
}

/**
 * 完整 PC 包的候选根即 mcRoot。只读取版本描述闭包，不采用原启动命令；
 * gameDir 来自发现层/UI 的固定相对选择，缺省时必须只有一个可确定数据根。
 */
function parseComplete(root: string, versionId?: string, gameDir?: string): ParsedModpack {
  if (!directory(root, 'versions')) throw new Error('完整包未包含 versions 客户端目录');
  const ids = fs.listFileSync(checkedPath(root, 'versions')).filter((id: string): boolean =>
    safeBaseName(id) === id && file(root, 'versions/' + id + '/' + id + '.json'));
  const selected = versionId ?? (ids.length === 1 ? ids[0] : '');
  if (selected.length === 0) throw new Error('完整包含多个版本，请先选择客户端实例');
  if (ids.indexOf(selected) < 0) throw new Error('所选完整包客户端版本不存在');
  // 只读取所选实例的父闭包；其他实例的坏 JSON 不应阻断已明确选择的完整包。
  const sources: ExportVersionSource[] = [];
  let next = selected;
  while (next.length > 0 && sources.length <= 64 && !sources.some((source: ExportVersionSource): boolean => source.id === next)) {
    if (safeBaseName(next) !== next) throw new Error('父版本名称不安全');
    if (ids.indexOf(next) < 0) break; // 交给统一解析器报告明确的缺父错误。
    const value = json(root, 'versions/' + next + '/' + next + '.json');
    if (string(value, 'id') !== next) throw new Error('版本目录与 JSON 身份不一致：' + next);
    sources.push({ id: next, jsonText: JSON.stringify(value) });
    next = string(value, 'inheritsFrom');
  }
  const resolved = resolvedIdentity(selected, sources);
  // 版本 JSON 可以由父版本提供 JAR；重建不要求包中带本体，但存在的 JAR 必须仍是普通文件。
  const jar = 'versions/' + resolved.jarVersionId + '/' + resolved.jarVersionId + '.jar';
  if (directory(root, jar)) throw new Error('客户端主 JAR 不是普通文件');
  const choices = discoverInstanceDataRoots(root, selected);
  const data = gameDir ?? (choices.length === 1 ? choices[0].path : '');
  if (data.length === 0) throw new Error('共享与隔离目录均有内容，请先选择游戏数据根');
  // 显式选择也只能使用包内已经发现的数据根，防止后续调用者构造任意目录作为覆盖源。
  if (!choices.some((choice: ModpackDataRoot): boolean => choice.path === data)) throw new Error('游戏数据根不属于当前实例候选');
  const ident: ComponentIdentity = { game: resolved.vanillaVersion, loader: resolved.loader.kind === 'vanilla'
    ? ModpackLoader.NONE : resolved.loader.kind as ModpackLoader, version: resolved.loader.version };
  return parsed('instance', selected, '', ident, [data], selected);
}

/** MCBBS 的 addons 是权威组件信息，即使旁边存在兼容 CF 清单也不丢弃其 loader。 */
function parseMcbbs(root: string): ParsedModpack {
  const raw = json(root, file(root, 'mcbbs.packmeta') ? 'mcbbs.packmeta' : 'manifest.json');
  if (string(raw, 'manifestType') !== 'minecraftModpack' || !Array.isArray(raw['addons']) || !Array.isArray(raw['files'])) {
    throw new Error('MCBBS 清单缺少 addons/files 或格式身份不符');
  }
  if (raw['manifestVersion'] !== 1 && raw['manifestVersion'] !== 2) throw new Error('不支持的 MCBBS 清单版本');
  if (Array.isArray(raw['libraries']) && (raw['libraries'] as Object[]).length > 0) throw new Error('MCBBS 自定义 libraries 尚不能确认鸿蒙安装身份');
  const ident = identity((raw['addons'] as Object[]).map((entry: Object): Record<string, Object> => object(entry)), 'game', 'id');
  const result = parsed('mcbbs', string(raw, 'name'), string(raw, 'version'), ident, directory(root, 'overrides') ? ['overrides'] : []);
  const plan = result.plan as InstancePlan;
  for (const entry of raw['files'] as Object[]) {
    const item = object(entry), type = string(item, 'type');
    if (type === 'addon') {
      const path = string(item, 'path'), sha1 = string(item, 'hash').toLowerCase();
      if (safeRelPath(path) !== path || !/^[a-f0-9]{40}$/.test(sha1)) throw new Error('MCBBS 本地文件路径或 SHA-1 无效');
      if (!isInstanceContentPath(path)) throw new Error('MCBBS 声明了不能迁移的执行或私有文件：' + path);
      if (!file(root, 'overrides/' + path)) throw new Error('MCBBS 声明的本地文件缺失：' + path);
      plan.requiredLocalFiles.push({ path: path, sha1: sha1, root: 'overrides' });
    } else if (type === 'curse') {
      const pid = item['projectID'], fid = item['fileID'];
      if (typeof pid !== 'number' || typeof fid !== 'number' || !Number.isSafeInteger(pid as number)
        || !Number.isSafeInteger(fid as number) || (pid as number) <= 0 || (fid as number) <= 0) throw new Error('MCBBS CurseForge 文件身份无效');
      const download: ModpackFile = { path: '', urls: [], size: 0, env: ModpackEnv.REQUIRED,
        cfProjectId: pid as number, cfFileId: fid as number, fileNameHint: string(item, 'fileName') || 'CF 文件 ' + pid + '/' + fid };
      plan.files.push(download);
    } else throw new Error('不支持的 MCBBS 文件类型：' + type);
  }
  return result;
}

/** 旧 HMCL 包以 modpack.json + minecraft/pack.json 描述组件，minecraft 是用户数据根。 */
function parseHmcl(root: string): ParsedModpack {
  const meta = json(root, 'modpack.json'), original = json(root, 'minecraft/pack.json');
  const jar = original['jar'];
  // 复制允许的结构时排除旧 jar 引用；ArkTS 不使用 delete 动态删键。
  const game: Record<string, Object> = {};
  for (const key of Object.keys(original)) if (key !== 'jar') game[key] = original[key];
  const jarId = typeof jar === 'string' ? jar as string : string(object(jar), 'id');
  const declared = string(meta, 'gameVersion');
  if (declared.length > 0 && jarId.length > 0 && declared !== jarId) throw new Error('HMCL 包声明了冲突的 Minecraft 版本');
  if (jarId.length > 0) game['clientVersion'] = jarId;
  else if (declared.length > 0) game['clientVersion'] = declared;
  // jar 在旧 HMCL 表示原版来源 ID；改由已确认 clientVersion重建，不视为包外版本目录引用。
  const originalId = string(game, 'id') || 'pack';
  game['id'] = originalId;
  const resolved = resolvedIdentity(originalId, [{ id: originalId, jsonText: JSON.stringify(game) }]);
  const ident: ComponentIdentity = { game: resolved.vanillaVersion, loader: resolved.loader.kind === 'vanilla'
    ? ModpackLoader.NONE : resolved.loader.kind as ModpackLoader, version: resolved.loader.version };
  return parsed('hmcl', string(meta, 'name'), string(meta, 'version'), ident, ['minecraft'], 'pack');
}

/** MMC/Prism 只从 components确认精确版本，instance.cfg只用于标题，不执行其中的前置命令或 JVM 参数。 */
function parseMultimc(root: string, gameDir?: string): ParsedModpack {
  const raw = json(root, 'mmc-pack.json');
  if (raw['formatVersion'] !== 1 || !Array.isArray(raw['components'])) throw new Error('MultiMC 清单缺少受支持的组件格式');
  const ident = identity((raw['components'] as Object[]).map((entry: Object): Record<string, Object> => object(entry)), 'net.minecraft', 'uid');
  const roots = ['minecraft', '.minecraft'].filter((rel: string): boolean => directory(root, rel));
  const data = gameDir ?? (roots.length === 1 ? roots[0] : '');
  if (data.length === 0 || roots.indexOf(data) < 0) throw new Error('MultiMC 游戏目录缺失或存在多个目录，请先选择数据根');
  let name = 'MultiMC 整合包';
  if (file(root, 'instance.cfg')) {
    for (const line of fs.readTextSync(checkedPath(root, 'instance.cfg')).split(/\r?\n/)) {
      if (line.startsWith('name=')) { name = line.substring(5).trim() || name; break; }
    }
  }
  return parsed('multimc', name, '', ident, [data]);
}

/**
 * 安装器在包布局选择后调用的唯一入口。所有读取都局限 candidate root，
 * 不创建文件、不调用网络、不修改来源；身份或目录有歧义时在实例落盘前失败。
 */
export function parseInstancePackage(root: string, kind: string, versionId?: string, gameDir?: string): ParsedModpack {
  checkedPath(root, '.');
  if (kind === 'instance') return parseComplete(root, versionId, gameDir);
  if (kind === 'mcbbs') return parseMcbbs(root);
  if (kind === 'hmcl') return parseHmcl(root);
  if (kind === 'multimc') return parseMultimc(root, gameDir);
  throw new Error('不支持的实例包适配格式：' + kind);
}
