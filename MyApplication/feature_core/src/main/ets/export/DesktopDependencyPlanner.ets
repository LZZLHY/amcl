/**
 * 根据未经过 OHOS 过滤的原始元数据生成目标电脑版必需文件闭包。
 * 本类不查询本机 libraries、不下载、不执行 Forge 安装器；缺乏证据的依赖保持明确阻断。
 */
import { ExportDependency, ExportDependencyPlan, ExportForgelikeEvidence, ExportIssue, ExportPlatform, ExportResolvedVersion } from './ExportTypes';
import { ExportPath } from './ExportPath';
import { ExportVersionResolver as V } from './ExportVersionResolver';
import { ForgelikeExportPlanner } from './ForgelikeExportPlanner';

/** 仅计划生成时保留去重索引，返回前剥离；每个资产对象只需常数次路径查询。 */
interface ExportDependencyPlanState extends ExportDependencyPlan { paths: Map<string, ExportDependency>; }

export class DesktopDependencyPlanner {
  /**
   * assetIndexJson 必须由 I/O 层按 assetIndex.sha1 核验后传入；为空时返回具体缺失原因。
   * 标准整合包由目标启动器安装本体，因此不调用此方法，不会伪称已包含电脑版公共依赖。
   */
  static plan(version: ExportResolvedVersion, platform: ExportPlatform, assetIndexJson: string = '',
    forgelikeEvidence?: ExportForgelikeEvidence): ExportDependencyPlan {
    const out: ExportDependencyPlanState = { dependencies: [], issues: version.issues.slice(), paths: new Map<string, ExportDependency>() };
    if ((platform.os !== 'windows' && platform.os !== 'linux' && platform.os !== 'osx')
      || ['x64', 'arm64', 'x86'].indexOf(platform.arch) < 0) {
      DesktopDependencyPlanner.error(out, 'TARGET_PLATFORM', '目标电脑平台无效');
      return { dependencies: out.dependencies, issues: out.issues };
    }
    // 安装器整体摘要由 I/O 层建立，纯层还须完成发布身份/运行闭包绑定，才能借用其中的普通库身份。
    // 错版本、损坏 profile 或不受支持的形态仍发布原错误，不把这些证据中的 checksums 授予所选实例。
    let trustedEvidence: ExportForgelikeEvidence | undefined = undefined;
    if (version.loader.kind === 'forge' || version.loader.kind === 'neoforge') {
      // 先纳入安装器证明的隐式 runtime 闭包，普通 libraries 遇同路径生成件时不再拼不存在的 URL。
      const runtime = ForgelikeExportPlanner.plan(version, platform, forgelikeEvidence);
      out.issues.push(...runtime.issues);
      for (const dependency of runtime.dependencies) DesktopDependencyPlanner.add(out, dependency);
      if (!runtime.issues.some((issue: ExportIssue): boolean => issue.severity === 'error')) trustedEvidence = forgelikeEvidence;
    }
    const trustedLibraries = DesktopDependencyPlanner.installerLibraries(trustedEvidence, out);
    const client = V.object(V.object(version.json['downloads'])['client']);
    DesktopDependencyPlanner.artifact(out, client, 'versions/' + version.jarVersionId + '/' + version.jarVersionId + '.jar', 'client');
    const libraries = Array.isArray(version.json['libraries']) ? version.json['libraries'] as Object[] : [];
    for (const raw of libraries) {
      const lib = DesktopDependencyPlanner.enrichLibrary(V.object(raw), trustedLibraries, out);
      const name = V.string(lib, 'name');
      if (!DesktopDependencyPlanner.allowed(lib['rules'], platform, out)) continue;
      if (name.indexOf('ohos') >= 0 || name.indexOf('stub-objc-bridge') >= 0) {
        DesktopDependencyPlanner.error(out, 'OHOS_LIBRARY_METADATA', '版本描述包含鸿蒙专用库，不能替代电脑版原件');
        continue;
      }
      const downloads = V.object(lib['downloads']);
      const artifact = V.object(downloads['artifact']);
      const natives = V.object(lib['natives']);
      const nativeName = V.string(natives, platform.os);
      if (Object.keys(artifact).length > 0) {
        const path = 'libraries/' + V.string(artifact, 'path');
        const declared = out.paths.get(path.toLowerCase());
        if (declared !== undefined && declared.generated) {
          // 完整来源和角色已由同一已验 installer 绑定；本地身份由准备阶段完成，不能当普通远程库。
        } else if (forgelikeEvidence === undefined && ForgelikeExportPlanner.localArtifactPath(version, path, V.string(artifact, 'url'))) {
          // 预览尚未取得安装器时仅保留显式准备要求；执行必须重新调用含 evidence 的规划器。
        } else DesktopDependencyPlanner.artifact(out, artifact, path, 'library');
      } else if (Object.keys(natives).length === 0) {
        // 旧格式只有 Maven 坐标时，优先采用同一已验安装器声明的 primary 整件 SHA1 候选。
        // 这里只设定待核对的预期值，不表示本地/远端正文已通过；未知大小仍为 0，由 Native 严格验摘要。
        // 没有可信 primary 才继续沿既有 I/O 获取 sidecar，不能因 sidecar 404 就放过完整性检查。
        const path = ExportPath.maven(name);
        const base = V.string(lib, 'url') || 'https://libraries.minecraft.net/';
        const url = base + (base.endsWith('/') ? '' : '/') + path;
        const declared = out.paths.get(('libraries/' + path).toLowerCase());
        if (declared !== undefined && declared.generated) {
          // 传统 Forge 安装器内嵌件采用已绑定 installer-entry，不请求不存在的无 classifier Maven 件。
        } else if (forgelikeEvidence === undefined && ForgelikeExportPlanner.localArtifactPath(version, path, V.string(lib, 'url'))) {
          // 尚未准备 profile 的同类坐标由 FORGELIKE_PROFILE_PREPARATION 统一说明。
        } else if (path.length === 0 || !ExportPath.https(url)) DesktopDependencyPlanner.error(out, 'LEGACY_LIBRARY_PATH', '旧式库坐标或下载来源无效');
        else {
          const reference = trustedLibraries.get(name.replace(/@jar$/, ''));
          const expected = reference === undefined ? '' : DesktopDependencyPlanner.legacyPrimaryChecksum(reference, path, out);
          DesktopDependencyPlanner.add(out, { path: 'libraries/' + path, url: url, sha1: expected, size: 0, kind: 'library', generated: false });
        }
      }
      if (nativeName.length > 0) {
        const classifier = nativeName.replace(/\$\{arch\}/g, platform.arch === 'x86' ? '32' : '64');
        const selected = V.object(V.object(downloads['classifiers'])[classifier]);
        if (Object.keys(selected).length === 0) DesktopDependencyPlanner.error(out, 'NATIVE_CLASSIFIER', '目标平台 native 的 classifier 元数据缺失');
        else DesktopDependencyPlanner.artifact(out, selected, 'libraries/' + V.string(selected, 'path'), 'native');
      }
    }
    if (version.loader.kind === 'forge' || version.loader.kind === 'neoforge') {
      DesktopDependencyPlanner.verifyArgumentLibraries(out, version, platform);
    }
    const logging = V.object(V.object(V.object(version.json['logging'])['client'])['file']);
    if (Object.keys(logging).length > 0) {
      const id = V.string(logging, 'id');
      if (!ExportPath.segment(id)) DesktopDependencyPlanner.error(out, 'LOGGING_PATH', '日志配置文件名无效');
      else DesktopDependencyPlanner.artifact(out, logging, 'assets/log_configs/' + id, 'logging');
    }
    DesktopDependencyPlanner.assets(out, version, assetIndexJson);
    return { dependencies: out.dependencies, issues: out.issues };
  }

  /**
   * 为安装后退化为 name/url 的旧库建立同版本可信元数据索引。只有同一个已验 installer 的
   * profile/version 声明进入此表；不会把安装器的全部工具依赖自动加入成品。
   */
  private static installerLibraries(evidence: ExportForgelikeEvidence | undefined, out: ExportDependencyPlan): Map<string, Record<string, Object>> {
    const result = new Map<string, Record<string, Object>>();
    if (evidence === undefined) return result;
    try {
      for (const text of [evidence.installerVersionJson, evidence.installerProfileJson]) {
        const json = V.object(JSON.parse(text) as Object);
        const libraries = Array.isArray(json['libraries']) ? json['libraries'] as Object[] : [];
        for (const raw of libraries) {
          const library = V.object(raw);
          const key = V.string(library, 'name').replace(/@jar$/, '');
          if (key.length === 0) continue;
          const artifact = V.object(V.object(library['downloads'])['artifact']);
          const existing = result.get(key);
          if (existing !== undefined) {
            const old = V.object(V.object(existing['downloads'])['artifact']);
            if (Object.keys(old).length > 0 && Object.keys(artifact).length > 0
              && (V.string(old, 'path') !== V.string(artifact, 'path') || V.string(old, 'sha1') !== V.string(artifact, 'sha1'))) {
              DesktopDependencyPlanner.error(out, 'FORGELIKE_LIBRARY_METADATA_COLLISION', '安装器对同一库声明了冲突的路径或摘要');
            }
            if (Object.keys(old).length > 0) continue;
            if (Object.keys(artifact).length === 0) {
              // profile/version 对同坐标的 legacy primary 也必须一致；不能由 JSON 遍历顺序选择另一个摘要。
              const path = ExportPath.maven(key);
              const oldExpected = DesktopDependencyPlanner.legacyPrimaryChecksum(existing, path, out);
              const newExpected = DesktopDependencyPlanner.legacyPrimaryChecksum(library, path, out);
              if (oldExpected.length > 0 && newExpected.length > 0 && oldExpected !== newExpected) {
                DesktopDependencyPlanner.error(out, 'FORGELIKE_LIBRARY_METADATA_COLLISION', '安装器对同一旧式库声明了冲突的首选摘要', 'libraries/' + path);
              }
              if (oldExpected.length > 0) continue;
            }
          }
          result.set(key, library);
        }
      }
    } catch (_) { DesktopDependencyPlanner.error(out, 'FORGELIKE_LIBRARY_METADATA_JSON', '无法读取已验安装器的普通库元数据'); }
    return result;
  }

  /**
   * 只补齐同坐标、同目标 path 的缺字段，保留用户库版本、rules、natives 与显式来源。
   * 若源声明和可信安装器已有 hash/size 冲突则报告，绝不能静默拿官方近似件覆盖用户选择。
   */
  private static enrichLibrary(library: Record<string, Object>, trusted: Map<string, Record<string, Object>>, out: ExportDependencyPlan): Record<string, Object> {
    const name = V.string(library, 'name');
    const reference = trusted.get(name.replace(/@jar$/, ''));
    if (reference === undefined) return library;
    const original = V.object(V.object(library['downloads'])['artifact']);
    const official = V.object(V.object(reference['downloads'])['artifact']);
    const path = V.string(original, 'path') || ExportPath.maven(name);
    const officialPath = V.string(official, 'path') || ExportPath.maven(V.string(reference, 'name'));
    if (path.length === 0 || path !== officialPath) return library;
    // 完整 modern artifact 的语义保持优先；只有没有 modern 声明时才读取传统 primary。
    // 原库没有 artifact 时交给旧式分支保留 size=0，避免伪造一个缺少可信大小的现代 artifact。
    const expected = Object.keys(official).length > 0 ? V.string(official, 'sha1')
      : DesktopDependencyPlanner.legacyPrimaryChecksum(reference, path, out);
    if (Object.keys(official).length === 0 && (Object.keys(original).length === 0 || expected.length === 0)) return library;
    const hash = V.string(original, 'sha1');
    const size = original['size'];
    if ((hash.length > 0 && expected.length > 0 && hash.toLowerCase() !== expected.toLowerCase())
      || (typeof size === 'number' && (size as number) > 0 && typeof official['size'] === 'number' && size !== official['size'])) {
      DesktopDependencyPlanner.error(out, 'FORGELIKE_LIBRARY_SOURCE_CONFLICT', '所选库声明与同版本安装器的可信字节身份冲突', 'libraries/' + path);
      return library;
    }
    const clone = JSON.parse(JSON.stringify(library)) as Record<string, Object>;
    const downloads = V.object(clone['downloads']);
    const artifact = V.object(downloads['artifact']);
    if (V.string(artifact, 'path').length === 0) artifact['path'] = path;
    if (V.string(artifact, 'sha1').length === 0 && expected.length > 0) artifact['sha1'] = expected;
    if (!(typeof artifact['size'] === 'number' && (artifact['size'] as number) > 0) && official['size'] !== undefined) artifact['size'] = official['size'];
    if (V.string(artifact, 'url').length === 0 && V.string(official, 'url').length > 0) artifact['url'] = official['url'];
    downloads['artifact'] = artifact; clone['downloads'] = downloads;
    return clone;
  }

  /**
   * 传统 Forge checksums 的有限兼容：仅把已绑定 installer 中的第一个合法值作为整件 SHA1 预期。
   * 数组其余项也必须是 40 位十六进制，防止损坏声明被局部接受；未知形状/空数组/超限均报错。
   * 这里只授予“必须匹配”的候选值，不授予字节已验身份，也不接收源实例自己的 checksums。
   * 尚不支持 HMCL 的候选集合或 JAR 内 checksums.sha1 清单协议；若 primary 实际属于该清单，
   * Native 的整件 SHA1 必须失败，不能改用实际本地 hash、第二项或单纯 ZIP CRC 放行。
   */
  private static legacyPrimaryChecksum(reference: Record<string, Object>, path: string, out: ExportDependencyPlan): string {
    const artifact = V.object(V.object(reference['downloads'])['artifact']);
    if (Object.keys(artifact).length > 0 || path.length === 0 || ExportPath.maven(V.string(reference, 'name')) !== path) return '';
    const raw = reference['checksums'];
    if (raw === undefined) return '';
    if (!Array.isArray(raw) || (raw as Object[]).length === 0 || (raw as Object[]).length > 64) {
      DesktopDependencyPlanner.error(out, 'FORGELIKE_LEGACY_CHECKSUMS', '已验安装器的旧式库摘要必须是 1–64 项 SHA1 数组', 'libraries/' + path);
      return '';
    }
    const values = raw as Object[];
    for (const value of values) {
      if (typeof value !== 'string' || !/^[0-9a-fA-F]{40}$/.test(value as string)) {
        DesktopDependencyPlanner.error(out, 'FORGELIKE_LEGACY_CHECKSUMS', '已验安装器的旧式库摘要含有非 SHA1 项', 'libraries/' + path);
        return '';
      }
    }
    return (values[0] as string).toLowerCase();
  }

  /**
   * 在目标 rules 过滤和普通库合并之后核对显式 modulepath/classpath，避免库升级去重后仍引用旧路径，
   * 或条件库被目标规则排除而留下悬空启动参数。带规则的参数只检查当前目标实际生效的 value。
   */
  private static verifyArgumentLibraries(out: ExportDependencyPlanState, version: ExportResolvedVersion, platform: ExportPlatform): void {
    const args = V.object(version.json['arguments']);
    for (const key of ['jvm', 'game']) if (Array.isArray(args[key])) DesktopDependencyPlanner.verifyArgumentValues(out, args[key] as Object[], platform);
  }

  /** 参数中不含 library_directory 的普通 UI/认证/内存选项不参与此闭包检查。 */
  private static verifyArgumentValues(out: ExportDependencyPlanState, values: Object[], platform: ExportPlatform): void {
    for (const value of values) {
      if (typeof value !== 'string') {
        const entry = V.object(value);
        const raw = entry['value'];
        const nested: Object[] = typeof raw === 'string' ? [raw] : Array.isArray(raw) ? raw as Object[] : [];
        if (JSON.stringify(nested).indexOf('${library_directory}') >= 0 && DesktopDependencyPlanner.allowed(entry['rules'], platform, out)) {
          DesktopDependencyPlanner.verifyArgumentValues(out, nested, platform);
        }
        continue;
      }
      const pattern = /\$\{library_directory\}\/([^$;\s]+?\.jar)(?=\$|;|\s|$)/g;
      let match = pattern.exec(value as string);
      while (match !== null) {
        const path = 'libraries/' + match[1];
        if (!ExportPath.relative(path) || !out.paths.has(path.toLowerCase())) {
          DesktopDependencyPlanner.error(out, 'FORGELIKE_ARGUMENT_LIBRARY_MISSING', '目标启动参数引用的精确库未纳入完整包', ExportPath.relative(path) ? path : '');
        }
        match = pattern.exec(value as string);
      }
    }
  }

  /** Mojang 规则按顺序执行，有 rules 时默认拒绝，最后一条匹配项决定是否包含。 */
  static allowed(raw: Object | undefined, platform: ExportPlatform, out: ExportDependencyPlan): boolean {
    if (raw === undefined) return true;
    if (!Array.isArray(raw)) {
      DesktopDependencyPlanner.error(out, 'LIBRARY_RULES', '库的 rules 不是数组');
      return false;
    }
    const rules = raw as Object[];
    if (rules.length === 0) return true;
    let allowed = false;
    for (const item of rules) {
      const rule = V.object(item);
      const action = V.string(rule, 'action');
      if (action !== 'allow' && action !== 'disallow') {
        DesktopDependencyPlanner.error(out, 'LIBRARY_RULE_ACTION', '库规则包含未知 action');
        continue;
      }
      const os = V.object(rule['os']);
      const osName = V.string(os, 'name');
      if (osName.length > 0 && osName !== platform.os) continue;
      const arch = V.string(os, 'arch');
      if (arch.length > 0 && !DesktopDependencyPlanner.archMatches(arch, platform.arch, out)) continue;
      const osVersion = V.string(os, 'version');
      if (osVersion.length > 0) {
        if (platform.version.length === 0) {
          DesktopDependencyPlanner.error(out, 'TARGET_OS_VERSION', '库规则要求目标系统版本，请明确版本后重新检查');
          continue;
        }
        try { if (!new RegExp(osVersion).test(platform.version)) continue; } catch (_) {
          DesktopDependencyPlanner.error(out, 'OS_VERSION_REGEX', '库规则中的系统版本正则无效');
          continue;
        }
      }
      const features = V.object(rule['features']);
      let matched = true;
      for (const key of Object.keys(features)) {
        if (typeof features[key] !== 'boolean') {
          DesktopDependencyPlanner.error(out, 'RULE_FEATURE', '库规则包含无效 feature 条件');
          matched = false;
        } else if (features[key] === true) matched = false;
      }
      if (matched) allowed = action === 'allow';
    }
    return allowed;
  }

  /** 架构名归一化后匹配；正则与别名都只作用于目标架构，绝不使用设备自身 ARM64。 */
  private static archMatches(pattern: string, arch: string, out: ExportDependencyPlan): boolean {
    const aliases = arch === 'x64' ? ['x86_64', 'amd64', 'x64'] : arch === 'arm64' ? ['aarch64', 'arm64'] : ['x86', 'i386', 'i686'];
    try {
      const regex = new RegExp('^(?:' + pattern + ')$');
      return aliases.some((alias: string): boolean => regex.test(alias));
    } catch (_) {
      DesktopDependencyPlanner.error(out, 'OS_ARCH_REGEX', '库规则中的目标架构正则无效');
      return false;
    }
  }

  /** 校验元数据自带 path/url/hash/size；不把下载 URL 的文件名反推为可信本地路径。 */
  private static artifact(out: ExportDependencyPlanState, data: Record<string, Object>, path: string,
    kind: 'client' | 'library' | 'native' | 'assetIndex' | 'logging'): void {
    const url = V.string(data, 'url');
    const sha1 = V.string(data, 'sha1').toLowerCase();
    const size = typeof data['size'] === 'number' ? data['size'] as number : 0;
    if (!ExportPath.relative(path) || !ExportPath.https(url) || !/^[0-9a-f]{40}$/.test(sha1)
      || !Number.isSafeInteger(size) || size <= 0) {
      DesktopDependencyPlanner.error(out, 'DEPENDENCY_METADATA', '必需依赖缺少可信路径、HTTPS 来源、大小或 SHA-1', ExportPath.relative(path) ? path : '');
      return;
    }
    DesktopDependencyPlanner.add(out, { path: path, url: url, sha1: sha1, size: size, kind: kind, generated: false });
  }

  /**
   * 精确枚举电脑对象树和旧 virtual/resources 目标映射，并独立记录实际源布局候选。
   * AMCL 的旧资源只落 assets/virtual/legacy，不能要求源目录先有电脑端 objects 副本；
   * 外部导入实例也可能保留标准 objects 或按索引命名的 virtual 树，因此由 I/O 用同一
   * 上游 hash/size 核验候选并冻结实际来源。本类不访问磁盘，不替调用方选择未核验候选。
   */
  private static assets(out: ExportDependencyPlanState, version: ExportResolvedVersion, text: string): void {
    const index = V.object(version.json['assetIndex']);
    const id = V.string(index, 'id');
    if (!ExportPath.segment(id)) {
      DesktopDependencyPlanner.error(out, 'ASSET_INDEX_METADATA', '此版本没有可核验的 assetIndex 元数据');
      return;
    }
    DesktopDependencyPlanner.artifact(out, index, 'assets/indexes/' + id + '.json', 'assetIndex');
    if (text.length === 0) {
      DesktopDependencyPlanner.error(out, 'ASSET_INDEX_REQUIRED', '需要先取得并校验资源索引，才能枚举全部对象');
      return;
    }
    let parsed: Record<string, Object> = {};
    try { parsed = V.object(JSON.parse(text) as Object); } catch (_) {
      DesktopDependencyPlanner.error(out, 'ASSET_INDEX_JSON', '资源索引 JSON 损坏');
      return;
    }
    if (parsed['objects'] === undefined || typeof parsed['objects'] !== 'object'
      || Array.isArray(parsed['objects']) || parsed['objects'] === null) {
      DesktopDependencyPlanner.error(out, 'ASSET_OBJECTS', '资源索引缺少 objects 对象');
      return;
    }
    const objects = V.object(parsed['objects']);
    for (const name of Object.keys(objects)) {
      const object = V.object(objects[name]);
      const hash = V.string(object, 'hash').toLowerCase();
      const size = object['size'] as number;
      if (!/^[0-9a-f]{40}$/.test(hash) || typeof size !== 'number' || !Number.isSafeInteger(size) || size < 0 || !ExportPath.relative(name)) {
        DesktopDependencyPlanner.error(out, 'ASSET_OBJECT_METADATA', '资源对象路径、大小或摘要无效');
        continue;
      }
      const path = 'assets/objects/' + hash.substring(0, 2) + '/' + hash;
      const url = 'https://resources.download.minecraft.net/' + hash.substring(0, 2) + '/' + hash;
      const legacy = parsed['virtual'] === true || parsed['map_to_resources'] === true;
      const sourcePath = legacy ? 'assets/virtual/legacy/' + name : path;
      const candidates: string[] = [sourcePath];
      if (parsed['virtual'] === true && id !== 'legacy') candidates.push('assets/virtual/' + id + '/' + name);
      if (legacy) candidates.push(path);
      const objectDependency: ExportDependency = { path: path, url: url, sha1: hash, size: size, kind: 'asset', generated: false };
      if (legacy) { objectDependency.sourcePath = sourcePath; objectDependency.sourceCandidates = candidates.slice(); }
      DesktopDependencyPlanner.add(out, objectDependency);
      // 同一源字节可以生成多个电脑目标；每个映射项都保留独立候选数组，避免任务改选时串改别项。
      if (parsed['virtual'] === true) DesktopDependencyPlanner.add(out, { path: 'assets/virtual/' + id + '/' + name, sourcePath: sourcePath,
        sourceCandidates: candidates.slice(), url: url, sha1: hash, size: size, kind: 'asset', generated: false });
      if (parsed['map_to_resources'] === true) DesktopDependencyPlanner.add(out, { path: 'resources/' + name, sourcePath: sourcePath,
        sourceCandidates: candidates.slice(), url: url, sha1: hash, size: size, kind: 'asset', generated: false });
    }
  }

  /** 同一路径只允许同一字节身份；冲突和大小写折叠冲突均在写入前拒绝。 */
  private static add(out: ExportDependencyPlanState, dependency: ExportDependency): void {
    const old = out.paths.get(dependency.path.toLowerCase());
    if (old !== undefined) {
      if (old.path !== dependency.path || old.sha1 !== dependency.sha1 || old.size !== dependency.size) {
        DesktopDependencyPlanner.error(out, 'DEPENDENCY_COLLISION', '必需依赖的目标路径发生冲突', dependency.path);
      } else if (old.sourceCandidates !== undefined && dependency.sourceCandidates !== undefined) {
        // 多个资源名可以共享同一对象 hash；保留全部可信候选，不能因对象目标去重而丢掉可用源。
        for (const candidate of dependency.sourceCandidates) {
          if (old.sourceCandidates.indexOf(candidate) < 0) old.sourceCandidates.push(candidate);
        }
      }
      return;
    }
    out.dependencies.push(dependency);
    out.paths.set(dependency.path.toLowerCase(), dependency);
  }

  /** 结构化阻断始终附在计划上，由任务在执行前再次验证。 */
  private static error(out: ExportDependencyPlan, code: string, message: string, path: string = ''): void {
    const issue: ExportIssue = { code: code, severity: 'error', message: message, path: path };
    out.issues.push(issue);
  }
}
