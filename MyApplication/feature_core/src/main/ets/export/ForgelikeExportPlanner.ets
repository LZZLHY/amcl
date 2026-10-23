/**
 * Forge/NeoForge 电脑版运行闭包的纯规划器。
 *
 * version.json 的 libraries 不是这两种加载器的完整运行清单：FML 会按命令行身份从 libraryDirectory
 * 发现 universal、patched client，以及经典管线的 srg/extra。这里绑定精确安装器 profile/data，
 * 区分真正远程库、安装器内嵌件和本地 processor 生成件；既不执行安装器，也不改原实例。
 */
import { ExportArtifactProvenance, ExportDependency, ExportForgelikeEvidence, ExportForgelikeInstaller,
  ExportForgelikePlan, ExportIssue, ExportPlatform, ExportResolvedVersion } from './ExportTypes';
import { ExportPath } from './ExportPath';
import { ExportVersionResolver as V } from './ExportVersionResolver';

interface ForgelikePlanState extends ExportForgelikePlan { paths: Map<string, ExportDependency>; }

export class ForgelikeExportPlanner {
  /**
   * 精确安装器 Maven 身份来自实际加载器坐标或 FML 产品参数；NeoForge 的 FML 模块版本不参与。
   * 返回相对工作区路径，调用方只能在导出专用目录下载并核验，不能覆盖游戏根的历史 installer。
   */
  static describe(version: ExportResolvedVersion): ExportForgelikeInstaller {
    const kind = version.loader.kind === 'neoforge' ? 'neoforge' : 'forge';
    let coordinate = version.loader.coordinate || '';
    if (coordinate.length === 0) coordinate = kind === 'neoforge'
      ? 'net.neoforged:neoforge:' + version.loader.version
      : 'net.minecraftforge:forge:' + version.vanillaVersion + '-' + version.loader.version;
    const parts = coordinate.split(':');
    const artifactVersion = parts.length === 3 ? parts[2] : '';
    const group = kind === 'neoforge' && parts[1] === 'forge' ? 'net.neoforged' : kind === 'neoforge' ? 'net.neoforged' : 'net.minecraftforge';
    const artifact = kind === 'neoforge' && parts[1] !== 'forge' ? 'neoforge' : 'forge';
    const productCoordinate = group + ':' + artifact + ':' + artifactVersion;
    const installerCoordinate = productCoordinate + ':installer';
    const path = ExportPath.maven(installerCoordinate);
    const base = kind === 'neoforge' ? 'https://maven.neoforged.net/releases/' : 'https://maven.minecraftforge.net/';
    return { coordinate: installerCoordinate, path: path, url: base + path, sha1Url: base + path + '.sha1',
      loaderKind: kind, loaderVersion: version.loader.version, minecraftVersion: version.vanillaVersion };
  }

  /**
   * 没有安装器证据时只返回可见的准备要求；取得同一已验 installer 内的 profile/version 后再生成闭包。
   * 有证据也不授予本地生成件“已验证”身份，generatedIdentity 只能由完整 JAR 校验的 I/O 层补齐。
   */
  static plan(version: ExportResolvedVersion, platform: ExportPlatform,
    evidence?: ExportForgelikeEvidence): ExportForgelikePlan {
    const installer = ForgelikeExportPlanner.describe(version);
    const out: ForgelikePlanState = { installer: installer, dependencies: [], issues: [], runtimePaths: [],
      profileRequired: evidence === undefined, paths: new Map<string, ExportDependency>() };
    if (['windows', 'linux', 'osx'].indexOf(platform.os) < 0 || ['x64', 'x86', 'arm64'].indexOf(platform.arch) < 0) {
      ForgelikeExportPlanner.issue(out, 'FORGELIKE_TARGET', '加载器导出的目标平台无效');
    } else if (version.loader.kind !== 'forge' && version.loader.kind !== 'neoforge') {
      ForgelikeExportPlanner.issue(out, 'FORGELIKE_IDENTITY', '当前版本不是可确认的 Forge/NeoForge');
    } else if (installer.path.length === 0 || !ExportPath.https(installer.url)) {
      ForgelikeExportPlanner.issue(out, 'FORGELIKE_INSTALLER_IDENTITY', '无法从加载器精确身份解析安全的安装器坐标');
    } else if (evidence === undefined) {
      ForgelikeExportPlanner.issue(out, 'FORGELIKE_PROFILE_PREPARATION', '需要在导出副本中取得并校验精确安装器，再核对加载器运行产物', true);
    } else if (!/^[0-9a-fA-F]{40}$/.test(evidence.installerSha1) || !/^[0-9a-fA-F]{64}$/.test(evidence.profileSha256)) {
      ForgelikeExportPlanner.issue(out, 'FORGELIKE_INSTALLER_EVIDENCE', '安装器或 profile 缺少已核验的来源摘要');
    } else {
      let profile: Record<string, Object> = {};
      let metadata: Record<string, Object> = {};
      try {
        const rawProfile = JSON.parse(evidence.installerProfileJson) as Object;
        const rawVersion = JSON.parse(evidence.installerVersionJson) as Object;
        profile = V.object(rawProfile);
        metadata = V.object(rawVersion);
        if (Object.keys(profile).length === 0 || !Array.isArray(metadata['libraries'])) throw new Error('invalid installer metadata');
      } catch (_) { ForgelikeExportPlanner.issue(out, 'FORGELIKE_PROFILE_JSON', '安装器 profile/version JSON 损坏或不完整'); }
      if (out.issues.length === 0 && ForgelikeExportPlanner.matches(out, version, profile, metadata)) {
        const spec = profile['spec'];
        const processors = Array.isArray(profile['processors']) ? profile['processors'] as Object[] : [];
        if (profile['install'] !== undefined || spec === 0 || processors.length === 0) {
          ForgelikeExportPlanner.legacy(out, version, profile, metadata, evidence);
        } else if (spec === 1) {
          ForgelikeExportPlanner.modern(out, version, profile, metadata, evidence);
        } else ForgelikeExportPlanner.issue(out, 'FORGELIKE_PROFILE_SPEC', '当前安装器 profile 版本未建立运行闭包规则');
        ForgelikeExportPlanner.argumentLibraries(out, version, profile, metadata, evidence, platform);
      }
    }
    return { installer: out.installer, dependencies: out.dependencies, issues: out.issues,
      runtimePaths: out.runtimePaths, profileRequired: out.profileRequired };
  }

  /**
   * 识别只可能由安装器提供的已知坐标；用于准备前跳过不存在的 Maven 下载，不能据此宣布文件完整。
   * 安装器证据到位后必须由同一路径的具体 provenance 取代，否则最终闭包仍不能冻结。
   */
  static localArtifactPath(version: ExportResolvedVersion, path: string, url: string): boolean {
    if (version.loader.kind !== 'forge' && version.loader.kind !== 'neoforge') return false;
    const p = path.startsWith('libraries/') ? path.substring(10) : path;
    if (/^net\/minecraft\/client\/[^/]+\/[^/]+-(?:srg|extra|slim|unpacked)\.jar$/.test(p)) return true;
    if (/^net\/(?:minecraftforge\/forge|neoforged\/neoforge)\/[^/]+\/[^/]+-client\.jar$/.test(p)
      || /^net\/neoforged\/minecraft-client-patched\/[^/]+\/[^/]+\.jar$/.test(p)) return true;
    // 传统 Forge 的普通无 classifier JAR 可仅内嵌于 installer；空 URL 是声明，不能自造远程 URL。
    return url.length === 0 && /^net\/(?:minecraftforge|neoforged)\/forge\/[^/]+\/[^/]+\.jar$/.test(p);
  }

  /** profile 的 MC、发布坐标及独立 version.json 身份必须与选中版本一致，防止拿邻近版本补运行件。 */
  private static matches(out: ForgelikePlanState, version: ExportResolvedVersion, profile: Record<string, Object>, metadata: Record<string, Object>): boolean {
    const minecraft = V.string(profile, 'minecraft') || V.string(V.object(profile['install']), 'minecraft');
    const parent = V.string(metadata, 'inheritsFrom');
    if ((minecraft.length > 0 && minecraft !== version.vanillaVersion) || (parent.length > 0 && parent !== version.vanillaVersion)) {
      ForgelikeExportPlanner.issue(out, 'FORGELIKE_PROFILE_MINECRAFT', '安装器 Minecraft 身份与所选实例不一致');
    }
    const neo = V.argumentValue(metadata, '--fml.neoForgeVersion');
    const forge = V.argumentValue(metadata, '--fml.forgeVersion');
    if ((neo.length > 0 && (version.loader.kind !== 'neoforge' || neo !== version.loader.version))
      || (forge.length > 0 && forge !== version.loader.version)) {
      ForgelikeExportPlanner.issue(out, 'FORGELIKE_PROFILE_LOADER', '安装器加载器版本与所选实例不一致');
    }
    const expected = out.installer.coordinate.substring(0, out.installer.coordinate.lastIndexOf(':'));
    const path = V.string(profile, 'path') || V.string(V.object(profile['install']), 'path');
    if (path.length > 0 && path !== expected) ForgelikeExportPlanner.issue(out, 'FORGELIKE_PROFILE_COORDINATE', '安装器内嵌产品坐标与选中的发布身份不一致');
    if (neo.length === 0 && forge.length === 0 && path.length === 0) {
      const profileVersion = V.string(profile, 'version');
      if (profileVersion !== version.vanillaVersion + '-forge-' + version.loader.version
        && profileVersion !== 'neoforge-' + version.loader.version) {
        ForgelikeExportPlanner.issue(out, 'FORGELIKE_PROFILE_IDENTITY', '安装器没有可绑定的产品发布身份');
      }
    }
    return out.issues.length === 0;
  }

  /**
   * 传统 Forge 分为 profile.install.filePath 与 maven/ 两种内嵌方式。沿安装器声明的目标坐标导出，
   * 不把普通 forge-<ver>.jar 改名成网上未发布的 universal，也不要求虚假的 HTTP 来源。
   */
  private static legacy(out: ForgelikePlanState, version: ExportResolvedVersion, profile: Record<string, Object>, metadata: Record<string, Object>, evidence: ExportForgelikeEvidence): void {
    if (version.loader.kind !== 'forge' && !out.installer.coordinate.startsWith('net.neoforged:forge:')) {
      ForgelikeExportPlanner.issue(out, 'FORGELIKE_LEGACY_SHAPE', '此加载器的无 processor 安装器形态尚未建立运行规则');
      return;
    }
    const install = V.object(profile['install']);
    const coordinate = V.string(install, 'path') || V.string(profile, 'path');
    const relative = ExportPath.maven(coordinate);
    const entry = V.string(install, 'filePath').replace(/^\//, '') || 'maven/' + relative;
    if (relative.length === 0 || !ExportPath.relative(entry)) {
      ForgelikeExportPlanner.issue(out, 'FORGELIKE_LEGACY_ENTRY', '传统 Forge 安装器没有安全的内嵌产物来源');
      return;
    }
    const artifact = ForgelikeExportPlanner.findArtifact([metadata, profile], relative);
    const sha1 = V.string(artifact, 'sha1').toLowerCase();
    const size = typeof artifact['size'] === 'number' ? artifact['size'] as number : 0;
    const provenance = ForgelikeExportPlanner.provenance(out, evidence, 'LEGACY_LOADER', 'installer-entry', sha1);
    provenance.entryPath = entry;
    provenance.expectedEntries = ['net/minecraftforge/common/MinecraftForge.class'];
    ForgelikeExportPlanner.add(out, { path: 'libraries/' + relative, url: '', sha1: /^[0-9a-f]{40}$/.test(sha1) ? sha1 : '',
      size: Number.isSafeInteger(size) && size > 0 ? size : 0, kind: 'generated', generated: true, provenance: provenance });
  }

  /**
   * FML 运行发现契约：经典管线需要 srg、extra、patched-client；新 minecraft-client-patched 管线
   * 只需要该完整客户端。两者都还需 universal。MC_SLIM/映射/processor 工具不属于运行闭包。
   */
  private static modern(out: ForgelikePlanState, version: ExportResolvedVersion, profile: Record<string, Object>, metadata: Record<string, Object>, evidence: ExportForgelikeEvidence): void {
    const data = V.object(profile['data']);
    const patched = ForgelikeExportPlanner.dataPath(data, 'PATCHED');
    if (patched.length === 0) {
      ForgelikeExportPlanner.issue(out, 'FORGELIKE_PATCHED_METADATA', '安装器未声明可解析的客户端 PATCHED 产物');
      return;
    }
    const yearly = patched.startsWith('libraries/net/neoforged/minecraft-client-patched/');
    for (const role of yearly ? ['PATCHED'] : ['MC_SRG', 'MC_EXTRA', 'PATCHED']) {
      const path = ForgelikeExportPlanner.dataPath(data, role);
      if (path.length === 0) {
        ForgelikeExportPlanner.issue(out, 'FORGELIKE_RUNTIME_TOKEN', '经典加载器缺少必需运行产物声明：' + role);
        continue;
      }
      const hash = ForgelikeExportPlanner.outputHash(out, profile, data, role, path);
      const provenance = ForgelikeExportPlanner.provenance(out, evidence, role,
        hash.length > 0 ? 'installer-output-sha1' : 'local-generated-jar', hash);
      if (role === 'MC_SRG' || yearly) provenance.expectedEntries = ['net/minecraft/client/Minecraft.class'];
      else if (role === 'MC_EXTRA') provenance.expectedEntryPrefixes = ['assets/minecraft/'];
      else provenance.expectedEntryPrefixes = ['net/minecraft/'];
      ForgelikeExportPlanner.add(out, { path: path, url: '', sha1: hash, size: 0, kind: 'generated', generated: true, provenance: provenance });
    }
    const product = out.installer.coordinate.substring(0, out.installer.coordinate.lastIndexOf(':'));
    const universalPath = ExportPath.maven(product + ':universal');
    ForgelikeExportPlanner.remote(out, profile, metadata, evidence, universalPath, 'UNIVERSAL');
    // Forge 的 language/fmlcore 模块由运行 discovery 按产品版本发现，不全在 version.json 内。
    if (version.loader.kind === 'forge') {
      const parts = product.split(':');
      for (const artifact of ['fmlcore', 'javafmllanguage', 'lowcodelanguage', 'mclanguage']) {
        const path = ExportPath.maven(parts[0] + ':' + artifact + ':' + parts[2]);
        // 不把旧安装器没有的模块强行套到所有纪元；有声明才加入，未知主形态由运行引用校验阻断。
        if (Object.keys(ForgelikeExportPlanner.findArtifact([metadata, profile], path)).length > 0) {
          ForgelikeExportPlanner.remote(out, profile, metadata, evidence, path, 'FML_MODULE');
        }
      }
    }
  }

  /**
   * 解析 JVM 中显式 library_directory/modulepath 引用，补入不在普通 libraries 列表中的必要项。
   * 未知 argsfile 或缺乏来源的路径必须阻断，不能把字符串留给电脑端在导出成功后再碰运气下载。
   */
  private static argumentLibraries(out: ForgelikePlanState, version: ExportResolvedVersion, profile: Record<string, Object>, metadata: Record<string, Object>, evidence: ExportForgelikeEvidence, platform: ExportPlatform): void {
    const args = V.object(version.json['arguments']);
    const strings: string[] = [];
    for (const key of ['jvm', 'game']) if (Array.isArray(args[key])) ForgelikeExportPlanner.argumentStrings(args[key] as Object[], strings, platform);
    const known = new Set<string>();
    for (const source of [version.json]) {
      const libs = Array.isArray(source['libraries']) ? source['libraries'] as Object[] : [];
      for (const raw of libs) {
        const lib = V.object(raw);
        const artifact = V.object(V.object(lib['downloads'])['artifact']);
        const path = V.string(artifact, 'path') || ExportPath.maven(V.string(lib, 'name'));
        if (path.length > 0) known.add(path);
      }
    }
    for (const text of strings) {
      if (text.startsWith('@') && text.indexOf('${') < 0) {
        ForgelikeExportPlanner.issue(out, 'FORGELIKE_ARGUMENT_FILE', '运行描述引用尚未解析的外部参数文件，不能保证完整包闭包');
        continue;
      }
      const pattern = /\$\{library_directory\}\/([^$;\s]+?\.jar)(?=\$|;|\s|$)/g;
      let match = pattern.exec(text);
      while (match !== null) {
        const relative = match[1];
        if (!ExportPath.relative(relative)) ForgelikeExportPlanner.issue(out, 'FORGELIKE_ARGUMENT_PATH', '加载器参数包含不安全的库路径');
        else if (!out.paths.has(('libraries/' + relative).toLowerCase()) && !known.has(relative)) {
          ForgelikeExportPlanner.remote(out, profile, metadata, evidence, relative, 'ARGUMENT_LIBRARY');
        }
        match = pattern.exec(text);
      }
    }
  }

  /** 规则对象只提取 value 文本；实际目标系统筛选仍由 DesktopDependencyPlanner 统一处理。 */
  private static argumentStrings(items: Object[], result: string[], platform: ExportPlatform): void {
    for (const item of items) {
      if (typeof item === 'string') result.push(item as string);
      else {
        const entry = V.object(item);
        if (!ForgelikeExportPlanner.argumentAllowed(entry['rules'], platform)) continue;
        const value = entry['value'];
        if (typeof value === 'string') result.push(value as string);
        else if (Array.isArray(value)) ForgelikeExportPlanner.argumentStrings(value as Object[], result, platform);
      }
    }
  }

  /**
   * 参数对象的目标筛选与 Mojang 最后匹配规则语义一致；这里仅决定是否查找额外引用。
   * 规则语法和未知目标版本的结构化错误仍由 DesktopDependencyPlanner 最终闭包核验报告。
   */
  private static argumentAllowed(raw: Object | undefined, platform: ExportPlatform): boolean {
    if (raw === undefined) return true;
    if (!Array.isArray(raw)) return false;
    const rules = raw as Object[];
    if (rules.length === 0) return true;
    let allowed = false;
    for (const item of rules) {
      const rule = V.object(item);
      const os = V.object(rule['os']);
      const name = V.string(os, 'name');
      if (name.length > 0 && name !== platform.os) continue;
      const arch = V.string(os, 'arch');
      const aliases = platform.arch === 'x64' ? ['x86_64', 'amd64', 'x64'] : platform.arch === 'arm64' ? ['aarch64', 'arm64'] : ['x86', 'i386', 'i686'];
      const osVersion = V.string(os, 'version');
      try {
        if (arch.length > 0 && !aliases.some((alias: string): boolean => new RegExp('^(?:' + arch + ')$').test(alias))) continue;
        if (osVersion.length > 0 && (platform.version.length === 0 || !new RegExp(osVersion).test(platform.version))) continue;
      } catch (_) { continue; }
      const features = V.object(rule['features']);
      if (Object.keys(features).some((key: string): boolean => features[key] !== false)) continue;
      allowed = V.string(rule, 'action') === 'allow';
    }
    return allowed;
  }

  /** profile data 只把完整 [Maven] 或安全 libraries 相对形式解释为路径，不展开任意本机绝对路径。 */
  private static dataPath(data: Record<string, Object>, role: string): string {
    const raw = V.string(V.object(data[role]), 'client');
    const value = ForgelikeExportPlanner.expand(raw, data, []);
    if (value.startsWith('[') && value.endsWith(']')) {
      const relative = ExportPath.maven(value.substring(1, value.length - 1));
      return relative.length > 0 ? 'libraries/' + relative : '';
    }
    const relative = value.replace(/^\{ROOT\}\//, '').replace(/^\{LIBRARY_DIR\}\//, 'libraries/');
    return relative.startsWith('libraries/') && relative.endsWith('.jar') && ExportPath.relative(relative) ? relative : '';
  }

  /** token 替换有环/深度保护，只从 profile.client 值取数据；HASH literal 的单引号按安装器语义去掉。 */
  private static expand(raw: string, data: Record<string, Object>, stack: string[]): string {
    let value = raw;
    const refs = raw.match(/\{[A-Z0-9_]+\}/g) || [];
    for (const ref of refs) {
      const key = ref.substring(1, ref.length - 1);
      if (key === 'ROOT' || key === 'LIBRARY_DIR') continue;
      if (stack.indexOf(key) >= 0 || stack.length >= 32) return '';
      const replacement = V.string(V.object(data[key]), 'client');
      if (replacement.length === 0) return '';
      const next = stack.slice(); next.push(key);
      value = value.split(ref).join(ForgelikeExportPlanner.expand(replacement, data, next));
    }
    return value.length >= 2 && value.startsWith("'") && value.endsWith("'") ? value.substring(1, value.length - 1) : value;
  }

  /** data.ROLE_SHA 与 processor.outputs 的可信 SHA1 同时存在时必须一致；缺值不能编造。 */
  private static outputHash(out: ForgelikePlanState, profile: Record<string, Object>, data: Record<string, Object>, role: string, path: string): string {
    let result = ForgelikeExportPlanner.expand(V.string(V.object(data[role + '_SHA']), 'client'), data, []).toLowerCase();
    if (result.length > 0 && !/^[0-9a-f]{40}$/.test(result)) {
      ForgelikeExportPlanner.issue(out, 'FORGELIKE_OUTPUT_HASH', '安装器运行产物摘要声明无效：' + role);
      result = '';
    }
    const processors = Array.isArray(profile['processors']) ? profile['processors'] as Object[] : [];
    for (const raw of processors) {
      const processor = V.object(raw);
      const sides = processor['sides'];
      if (Array.isArray(sides) && (sides as Object[]).indexOf('client') < 0) continue;
      const outputs = V.object(processor['outputs']);
      for (const key of Object.keys(outputs)) {
        const temporary: Record<string, Object> = { 'client': key };
        const extended: Record<string, Object> = {};
        for (const name of Object.keys(data)) extended[name] = data[name];
        extended['EXPORT_OUTPUT'] = temporary;
        if (ForgelikeExportPlanner.dataPath(extended, 'EXPORT_OUTPUT') !== path) continue;
        const hash = ForgelikeExportPlanner.expand(V.string(outputs, key), data, []).toLowerCase();
        if (!/^[0-9a-f]{40}$/.test(hash) || (result.length > 0 && result !== hash)) {
          ForgelikeExportPlanner.issue(out, 'FORGELIKE_OUTPUT_HASH', '安装器运行产物摘要声明冲突或无效：' + role);
        } else result = hash;
      }
    }
    return result;
  }

  /** 按真实 artifact.path 查询，兼容下载地址与坐标存储名不同的 Forge 迁移库。 */
  private static findArtifact(sources: Record<string, Object>[], relative: string): Record<string, Object> {
    for (const source of sources) {
      const libs = Array.isArray(source['libraries']) ? source['libraries'] as Object[] : [];
      for (const raw of libs) {
        const lib = V.object(raw);
        const artifact = V.object(V.object(lib['downloads'])['artifact']);
        const path = V.string(artifact, 'path') || ExportPath.maven(V.string(lib, 'name'));
        if (path === relative) return artifact;
      }
    }
    return {};
  }

  /** 远程运行件必须有安装器声明的完整可信身份；不能把生成产物拼成不存在的 Maven URL。 */
  private static remote(out: ForgelikePlanState, profile: Record<string, Object>, metadata: Record<string, Object>, evidence: ExportForgelikeEvidence, relative: string, role: string): void {
    const artifact = ForgelikeExportPlanner.findArtifact([metadata, profile], relative);
    const url = V.string(artifact, 'url');
    const sha1 = V.string(artifact, 'sha1').toLowerCase();
    const size = artifact['size'];
    if (!ExportPath.relative(relative) || !ExportPath.https(url) || !/^[0-9a-f]{40}$/.test(sha1)
      || typeof size !== 'number' || !Number.isSafeInteger(size) || (size as number) <= 0) {
      ForgelikeExportPlanner.issue(out, 'FORGELIKE_RUNTIME_LIBRARY', '安装器缺少必需运行库的可信下载声明：' + role, false, 'libraries/' + relative);
      return;
    }
    ForgelikeExportPlanner.add(out, { path: 'libraries/' + relative, url: url, sha1: sha1, size: size as number,
      kind: 'library', generated: false, provenance: ForgelikeExportPlanner.provenance(out, evidence, role, 'upstream-sha1', sha1) });
  }

  /** 每个角色绑定安装器整体及 profile 身份，不保存原沙箱路径或安装命令。 */
  private static provenance(out: ForgelikePlanState, evidence: ExportForgelikeEvidence, role: string,
    validation: 'installer-output-sha1' | 'local-generated-jar' | 'installer-entry' | 'upstream-sha1', hash: string): ExportArtifactProvenance {
    return { installerCoordinate: out.installer.coordinate, installerSha1: evidence.installerSha1.toLowerCase(),
      profileSha256: evidence.profileSha256.toLowerCase(), role: role, validation: validation, expectedSha1: hash,
      entryPath: '', expectedEntries: [], expectedEntryPrefixes: [] };
  }

  /** 不同角色复用同一路径时必须具有同一可信字节身份，不能由追加顺序决定结果。 */
  private static add(out: ForgelikePlanState, dependency: ExportDependency): void {
    const key = dependency.path.toLowerCase();
    const existing = out.paths.get(key);
    if (existing !== undefined) {
      if (existing.path !== dependency.path || existing.sha1 !== dependency.sha1 || existing.generated !== dependency.generated) {
        ForgelikeExportPlanner.issue(out, 'FORGELIKE_RUNTIME_COLLISION', '加载器运行产物存在路径或身份冲突', false, dependency.path);
      }
      return;
    }
    out.dependencies.push(dependency); out.runtimePaths.push(dependency.path); out.paths.set(key, dependency);
  }

  /** 全部未知形态使用具体问题说明；准备要求为 warning，真正缺闭包/冲突为 error。 */
  private static issue(out: ForgelikePlanState, code: string, message: string, warning: boolean = false, path: string = ''): void {
    const issue: ExportIssue = { code: code, severity: warning ? 'warning' : 'error', message: message, path: path };
    out.issues.push(issue);
  }
}
