/**
 * 纯文件计划：把显式选择的实例内容映射到电脑隔离目录或标准 overrides，生成全新 PC 元数据。
 * 本类不会改源数据，不读取账户/JDK/启动命令；快照和写入层只消费这里的逐项计划。
 */
import { ExportDependency, ExportFilePlanResult, ExportInventoryFile, ExportPlannedFile, ExportRequest,
  ExportResolvedVersion, ExportResourceSource } from './ExportTypes';
import { ExportPath } from './ExportPath';
import { ExportVersionResolver as V } from './ExportVersionResolver';
import { StandardPackWriter } from './StandardPackWriter';
import { ExportContentSelectionEvaluator, validateExportSelection } from './ExportContentSelection';

/** 构建期路径索引只存活于同步计划，不暴露到返回值或持久记录，避免数万 assets 退化为平方扫描。 */
interface ExportFilePlanBuildState extends ExportFilePlanResult {
  paths: Map<string, ExportPlannedFile>;
  parents: Map<string, string>;
  entryLimit: boolean;
}

export class ExportFilePlan {
  /**
   * 生成新计划，不修改请求或库存。dependencies 只用于完整包；调用方还须合并依赖解析器的问题。
   * 旧式 Maven 无哈希项标记待补全，任务必须取得可信远端摘要并下载核验后才可冻结。
   */
  static build(request: ExportRequest, version: ExportResolvedVersion, dependencies: ExportDependency[],
    userFiles: ExportInventoryFile[], sources: ExportResourceSource[] = []): ExportFilePlanResult {
    const out: ExportFilePlanBuildState = { files: [], issues: version.issues.slice(), totalBytes: 0, paths: new Map<string, ExportPlannedFile>(), parents: new Map<string, string>(), entryLimit: false };
    out.issues.push(...validateExportSelection(request));
    if (!ExportPath.segment(request.exportId)) {
      ExportFilePlan.error(out, 'EXPORT_ID', '导出 ID 不是安全的电脑文件夹名');
      return { files: out.files, issues: out.issues, totalBytes: out.totalBytes };
    }
    if (request.displayName.length === 0 || /[\u0000-\u001f\u007f]/.test(request.displayName)) ExportFilePlan.error(out, 'EXPORT_DISPLAY_NAME', '导出名称为空或包含控制字符');
    for (const path of request.includeDirectories.concat(request.includeFiles)) {
      if (!ExportPath.relative(path)) ExportFilePlan.error(out, 'SELECTION_PATH', '选中的内容路径无效');
    }
    for (const world of request.selectedWorlds) if (!ExportPath.segment(world)) ExportFilePlan.error(out, 'WORLD_PATH', '选择的世界目录名称无效');
    if (request.sharedGameDir) out.issues.push({ code: 'SHARED_GAME_DIR', severity: 'warning',
      message: '来源使用共享游戏目录，所选文件可能同时属于其他版本，请确认实际内容清单', path: '' });
    const selected: ExportInventoryFile[] = [];
    const selection = new ExportContentSelectionEvaluator(request);
    for (const file of userFiles) {
      if (!selection.isSelected(file.path)) continue;
      if (!ExportPath.relative(file.path)) {
        ExportFilePlan.error(out, 'USER_PATH', '实例内容包含不安全或无法在目标平台保存的文件名');
        continue;
      }
      if (ExportPath.excluded(file.path)) continue;
      if (!file.directory && (!Number.isSafeInteger(file.size) || file.size < 0
        || !/^[0-9a-fA-F]{40}$/.test(file.sha1) || !/^[0-9a-fA-F]{64}$/.test(file.sha256))) {
        ExportFilePlan.error(out, 'USER_FILE_IDENTITY', '所选内容缺少实际大小或摘要', file.path);
        continue;
      }
      selected.push(file);
    }
    if (request.format === 'full') ExportFilePlan.full(out, request, version, dependencies, selected);
    else ExportFilePlan.standard(out, request, version, selected, sources);
    ExportFilePlan.generated(out, 'amcl-export.json', ExportFilePlan.report(request, version, out));
    ExportFilePlan.generated(out, '使用说明.txt', ExportFilePlan.instructions(request));
    return { files: out.files, issues: out.issues, totalBytes: out.totalBytes };
  }

  /** 完整包仅从依赖清单取公共文件，绝不把全库和其他版本顺带加入。 */
  private static full(out: ExportFilePlanBuildState, request: ExportRequest, version: ExportResolvedVersion,
    dependencies: ExportDependency[], selected: ExportInventoryFile[]): void {
    if (request.platform.arch !== 'x64' || (request.platform.os !== 'windows' && request.platform.os !== 'linux')
      || (request.launcher === 'pcl' && request.platform.os !== 'windows')) {
      ExportFilePlan.error(out, 'FULL_TARGET_SUPPORT', '当前完整包支持 Windows x64；HMCL 另支持 Linux x64，其他组合待验证');
    }
    const instance = '.minecraft/versions/' + request.exportId + '/';
    let clients = 0;
    for (const dep of dependencies) {
      if (!ExportPath.relative(dep.path) || (dep.sourcePath !== undefined && !ExportPath.relative(dep.sourcePath))) {
        ExportFilePlan.error(out, 'DEPENDENCY_PATH', '必需依赖路径无效');
        continue;
      }
      if (dep.generated) {
        const identity = dep.generatedIdentity;
        const origin = dep.provenance;
        const expected = origin === undefined ? '' : origin.expectedSha1.toLowerCase();
        if (identity === undefined || origin === undefined || !/^[0-9a-fA-F]{40}$/.test(identity.sha1)
          || !/^[0-9a-fA-F]{64}$/.test(identity.sha256) || !Number.isSafeInteger(identity.size) || identity.size <= 0
          || !/^[0-9a-fA-F]{40}$/.test(origin.installerSha1) || !/^[0-9a-fA-F]{64}$/.test(origin.profileSha256)
          || (expected.length > 0 && (!/^[0-9a-f]{40}$/.test(expected) || identity.sha1.toLowerCase() !== expected))
          || (origin.validation === 'local-generated-jar' && expected.length === 0 && origin.preparation !== 'verified-processor-rebuild')
          || (origin.validation === 'installer-entry' && origin.preparation !== 'installer-entry')
          || (origin.expectedEntries.length === 0 && origin.expectedEntryPrefixes.length === 0)) {
          ExportFilePlan.error(out, 'GENERATED_ARTIFACT_IDENTITY', '加载器产物尚未完成可信安装器来源、完整 JAR 与实际摘要核验', dep.path);
          continue;
        }
      }
      if (!dep.generated && (!/^[0-9a-fA-F]{40}$/.test(dep.sha1) || dep.size <= 0)) {
        if (!ExportPath.https(dep.url)) ExportFilePlan.error(out, 'DEPENDENCY_IDENTITY', '必需依赖缺少可核验的来源', dep.path);
        else out.issues.push({ code: 'DEPENDENCY_PREPARATION', severity: 'warning', message: '此依赖需在导出副本中取得可信远端摘要并补全后重新校验', path: dep.path });
      }
      // map_to_resources 使用接收端实际 gameDir；目标已隔离，因此旧资源应位于版本根 resources。
      const target = dep.kind === 'client' ? instance + request.exportId + '.jar'
        : dep.path.startsWith('resources/') ? instance + dep.path : '.minecraft/' + dep.path;
      if (dep.kind === 'client') clients++;
      const file: ExportPlannedFile = { source: 'mcRoot', sourcePath: dep.sourcePath || dep.path, archivePath: target,
        size: dep.generatedIdentity?.size ?? dep.size, sha1: dep.generatedIdentity?.sha1 ?? dep.sha1,
        sha256: dep.generatedIdentity?.sha256 ?? '', content: '', directory: false, required: true };
      if (dep.provenance !== undefined) file.provenance = dep.provenance;
      ExportFilePlan.add(out, file);
    }
    if (clients !== 1) ExportFilePlan.error(out, 'CLIENT_REQUIRED', '完整游戏包必须且只能包含一个已解析的游戏本体 JAR');
    ExportFilePlan.generated(out, instance + request.exportId + '.json', ExportFilePlan.versionJson(out, request, version, dependencies));
    if (request.launcher === 'pcl') {
      ExportFilePlan.generated(out, instance + 'PCL/Setup.ini', 'VersionArgumentIndieV2:true\r\nVersionArgumentIndie:1\r\n');
    } else {
      // HMCL v3.16.4 新实例 schema；只覆盖运行目录，不继承本机路径、账户和 JVM 设置。
      const settings: Record<string, Object> = { '$schema': 'https://schemas.glavo.site/hmcl/instance-game-settings/1.0.0',
        'overrideProperties': ['runningDirectory'], 'runningDirectory': '' };
      ExportFilePlan.generated(out, instance + '.hmcl/config/instance-game-settings.json', JSON.stringify(settings, null, 2));
    }
    for (const file of selected) {
      // 旧map_to_resources与用户resources可能落同一个版本目录。只有实际字节身份与
      // 必需工件严格相同才复用已有目标；不同大小/摘要或大小写仍交统一碰撞检查阻断。
      const target = instance + file.path;
      const required = out.paths.get(target.toLowerCase());
      if (!file.directory && required !== undefined && required.required && required.archivePath === target
        && required.sha1.length > 0 && required.sha1.toLowerCase() === file.sha1.toLowerCase() && required.size === file.size
        && (required.sha256.length === 0 || required.sha256.toLowerCase() === file.sha256.toLowerCase())) continue;
      ExportFilePlan.user(out, instance, file);
    }
  }

  /** 清单文件只出现一种；已表达为精确下载项的路径不再加入覆盖目录。 */
  private static standard(out: ExportFilePlanBuildState, request: ExportRequest, version: ExportResolvedVersion,
    selected: ExportInventoryFile[], sources: ExportResourceSource[]): void {
    const manifest = StandardPackWriter.build(request, version, selected, sources);
    out.issues = out.issues.concat(manifest.issues);
    ExportFilePlan.generated(out, manifest.path, manifest.content);
    for (const file of selected) if (manifest.downloadPaths.indexOf(file.path) < 0) ExportFilePlan.user(out, 'overrides/', file);
    out.issues.push({ code: 'STANDARD_NETWORK', severity: 'warning',
      message: '标准包由接收启动器联网安装游戏与加载器，本包只携带清单及所选覆盖内容', path: '' });
  }

  /**
   * 重写只改变副本的 id 与已解析继承关系。保留原有标准占位符，不全局替换显示名或任意字符串，
   * 防止误改 Maven 坐标、MC 版本号和加载器参数。未知顶层私有扩展不导出。
   */
  private static versionJson(out: ExportFilePlanBuildState, request: ExportRequest, version: ExportResolvedVersion,
    dependencies: ExportDependency[]): string {
    const json: Record<string, Object> = {};
    const keys = ['type', 'time', 'releaseTime', 'mainClass', 'minimumLauncherVersion', 'complianceLevel',
      'javaVersion', 'assets', 'assetIndex', 'downloads', 'logging', 'libraries', 'arguments', 'minecraftArguments'];
    for (const key of keys) if (version.json[key] !== undefined) json[key] = version.json[key];
    json['id'] = request.exportId;
    json['clientVersion'] = version.vanillaVersion;
    // 本地生成件的 actual SHA 与上游预期分开记录。若原 JSON 直接声明了它，只在导出副本中
    // 写入已验证实际大小/摘要；不把设备原 JSON 改掉，也不为生成件伪造远程下载地址。
    if (Array.isArray(json['libraries'])) {
      const generated = new Map<string, ExportDependency>();
      for (const dependency of dependencies) if (dependency.generated && dependency.generatedIdentity !== undefined) generated.set(dependency.path, dependency);
      if (generated.size > 0) {
        const libraries = JSON.parse(JSON.stringify(json['libraries'])) as Object[];
        for (const raw of libraries) {
          const lib = V.object(raw);
          const artifact = V.object(V.object(lib['downloads'])['artifact']);
          const path = V.string(artifact, 'path') || ExportPath.maven(V.string(lib, 'name'));
          const dependency = generated.get('libraries/' + path);
          if (dependency === undefined || dependency.generatedIdentity === undefined || Object.keys(artifact).length === 0) continue;
          artifact['sha1'] = dependency.generatedIdentity.sha1;
          artifact['size'] = dependency.generatedIdentity.size;
          artifact['url'] = '';
        }
        json['libraries'] = libraries;
      }
    }
    const args = V.object(json['arguments']);
    const cleanArgs: Record<string, Object> = {};
    for (const kind of ['game', 'jvm']) {
      if (!Array.isArray(args[kind])) continue;
      cleanArgs[kind] = ExportFilePlan.cleanArguments(out, args[kind] as Object[]);
    }
    if (Object.keys(cleanArgs).length > 0) json['arguments'] = cleanArgs;
    const legacy = V.string(json, 'minecraftArguments');
    if (legacy.length > 0) json['minecraftArguments'] = (ExportFilePlan.cleanArguments(out, legacy.split(' ')) as string[]).join(' ');
    const text = JSON.stringify(json, null, 2);
    if (/\/data\/(?:storage|app)\/|file:\/\/|[A-Za-z]:\\\\|"\/(?!\/)|=[/\\]/.test(text)) ExportFilePlan.error(out, 'ABSOLUTE_PATH_METADATA', '版本描述含本机绝对路径，不能安全生成电脑版描述');
    if (ExportFilePlan.hasPrivateMetadata(json)) ExportFilePlan.error(out, 'PRIVATE_VERSION_METADATA', '版本描述包含私有认证字段，不能安全生成电脑版描述');
    return text;
  }

  /** 标准版本字段内部同样不能夹带私有扩展；只检查字段名，标准认证参数的占位符不受影响。 */
  private static hasPrivateMetadata(value: Object): boolean {
    if (value === null || typeof value !== 'object') return false;
    if (Array.isArray(value)) return (value as Object[]).some((item: Object): boolean => ExportFilePlan.hasPrivateMetadata(item));
    const object = value as Record<string, Object>;
    for (const key of Object.keys(object)) {
      if (/^(?:access_?token|refresh_?token|client_?secret|password|credentials?|private_?key|accounts?|authentication)$/i.test(key)
        || ExportFilePlan.hasPrivateMetadata(object[key])) return true;
    }
    return false;
  }

  /**
   * 删除明确的 AMCL 注入参数，并检查独立值和 --key=value 两种认证参数写法。
   * 认证选项只能携带该选项对应的标准占位符；缺值、字面值和跨对象拆分的未知值都阻断。
   * 阻断时同时从待生成正文移除这一组参数，避免调用方误用失败计划时仍带出账户数据。
   * rules.value 的数组递归使用同一规则；这里不展开规则或把未知对象猜成安全占位符。
   */
  private static cleanArguments(out: ExportFilePlanBuildState, args: Object[]): Object[] {
    const result: Object[] = [];
    for (let i = 0; i < args.length; i++) {
      const item = args[i];
      if (typeof item === 'string') {
        const text = item as string;
        if (/^(?:-Damcl\.|-Djava\.system\.class\.loader=|-javaagent:|-agentpath:|-agentlib:|--amcl)/i.test(text)) {
          out.issues.push({ code: 'RUNTIME_ARGUMENT_REMOVED', severity: 'warning', message: '已从电脑版描述移除鸿蒙启动注入参数', path: '' });
          continue;
        }
        const equals = text.indexOf('=');
        const option = equals < 0 ? text : text.substring(0, equals);
        const placeholder = ExportFilePlan.authenticationPlaceholder(option);
        if (placeholder.length > 0) {
          const separateValue = equals < 0;
          const value = separateValue ? (i + 1 < args.length && typeof args[i + 1] === 'string' ? args[i + 1] as string : '')
            : text.substring(equals + 1);
          if (value !== placeholder) {
            ExportFilePlan.error(out, 'LITERAL_AUTH_ARGUMENT', '版本认证参数缺值或含字面账户数据，请先恢复对应的标准占位符');
            // 独立值占据下一项；即使其类型错误也不把这一项重新当普通参数写入说明正文。
            // 下一项若明确是另一个 --选项，则视为缺值，保留它供下一轮独立检查。
            if (separateValue && i + 1 < args.length && (typeof args[i + 1] !== 'string'
              || !(args[i + 1] as string).startsWith('--'))) i++;
            continue;
          }
          result.push(text);
          if (separateValue) { result.push(value); i++; }
          continue;
        }
        result.push(text);
      } else {
        const entry = V.object(item);
        const value = entry['value'];
        const values: Object[] = typeof value === 'string' ? [value] : Array.isArray(value) ? value as Object[] : [];
        const clean = ExportFilePlan.cleanArguments(out, values);
        if (clean.length > 0) {
          const clone: Record<string, Object> = { 'value': typeof value === 'string' ? clean[0] : clean };
          if (entry['rules'] !== undefined) clone['rules'] = entry['rules'];
          result.push(clone);
        }
      }
    }
    return result;
  }

  /**
   * 认证选项与 Mojang 标准占位符一一对应，不能以任意 ${...} 掩盖字面身份或损坏模板。
   * --session 覆盖旧版 minecraftArguments；clientid/user_properties 保留上游实际命名。
   * 非认证选项返回空串，交回普通参数保留流程，不扩大为删除用户的全部启动参数。
   */
  private static authenticationPlaceholder(option: string): string {
    switch (option) {
      case '--accessToken': return '${auth_access_token}';
      case '--clientId': return '${clientid}';
      case '--xuid': return '${auth_xuid}';
      case '--username': return '${auth_player_name}';
      case '--uuid': return '${auth_uuid}';
      case '--userProperties': return '${user_properties}';
      case '--session': return '${auth_session}';
      default: return '';
    }
  }

  /** 普通用户文件和空目录保持实际内容，不将原实例目录套进目标实例根。 */
  private static user(out: ExportFilePlanBuildState, prefix: string, file: ExportInventoryFile): void {
    ExportFilePlan.add(out, { source: 'gameDir', sourcePath: file.path, archivePath: prefix + file.path,
      size: file.directory ? 0 : file.size, sha1: file.sha1, sha256: file.sha256, content: '',
      directory: file.directory, required: false });
  }

  /** UTF-8 字节数独立于系统编码；非 BMP 字符按代理对计 4 字节，与实际写入一致。 */
  static utf8Size(text: string): number {
    let bytes = 0;
    for (let i = 0; i < text.length; i++) {
      const code = text.charCodeAt(i);
      if (code < 0x80) bytes++;
      else if (code < 0x800) bytes += 2;
      else if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length && text.charCodeAt(i + 1) >= 0xdc00 && text.charCodeAt(i + 1) <= 0xdfff) { bytes += 4; i++; }
      else bytes += 3;
    }
    return bytes;
  }

  /** 自有说明仅含可公开身份和归档路径，不把源 mcRoot/gameDir 或认证数据写进包。 */
  private static report(request: ExportRequest, version: ExportResolvedVersion, out: ExportFilePlanBuildState): string {
    const files: Object[] = out.files.map((file: ExportPlannedFile): Object => {
      const entry: Record<string, Object> = { 'path': file.archivePath, 'size': file.size, 'sha1': file.sha1, 'sha256': file.sha256, 'directory': file.directory };
      if (file.provenance !== undefined) entry['provenance'] = file.provenance;
      return entry;
    });
    const report: Record<string, Object> = { 'schemaVersion': 1, 'exportId': request.exportId, 'name': request.displayName,
      'format': request.format, 'launcher': request.launcher, 'minecraft': version.vanillaVersion,
      'loader': version.loader.kind, 'loaderVersion': version.loader.version, 'files': files,
      'requiresNetworkInstall': request.format !== 'full' };
    if (request.format === 'full') report['platform'] = request.platform.os + '-' + request.platform.arch;
    return JSON.stringify(report, null, 2);
  }

  /** 使用说明明确隔离和运行前提；源码适配依据不冒充目标发行版的设备往返验收。 */
  private static instructions(request: ExportRequest): string {
    return request.format === 'full'
      ? 'AMCL 完整游戏包\n\n请解压到新的空目录，再使用 ' + (request.launcher === 'pcl' ? 'PCL' : 'HMCL')
        + ' 添加或导入其中的 .minecraft 游戏目录。\n所选用户内容位于 versions/' + request.exportId
        + '/，已生成接收启动器的最小隔离设置；首次启动前请确认实际游戏目录为该版本目录。\n'
        + '目标电脑仍需自行安装启动器、适用的 Java，并使用自己的账户登录。\n本包不包含账户、鸿蒙运行时或启动器程序。\n'
      : 'AMCL 标准整合包\n\n请使用 ' + (request.launcher === 'pcl' ? 'PCL' : 'HMCL')
        + ' 的整合包导入功能安装本包。接收启动器需要联网下载 Minecraft、加载器及清单列出的资源。\n'
        + 'overrides 中保存本次选中的实际实例内容，包括没有可靠下载来源的本地资源。\n安装后请确认实例隔离目录、加载器版本与所选世界。\n';
  }

  /** 生成文件只指向工作副本；摘要由写入层按实际 UTF-8 字节补齐。 */
  private static generated(out: ExportFilePlanBuildState, path: string, content: string): void {
    ExportFilePlan.add(out, { source: 'generated', sourcePath: '', archivePath: path, size: ExportFilePlan.utf8Size(content),
      sha1: '', sha256: '', content: content, directory: false, required: true });
  }

  /** 所有条目统一检查大小写与文件/目录前缀冲突，禁止先写后覆盖及目录被文件占用。 */
  private static add(out: ExportFilePlanBuildState, file: ExportPlannedFile): void {
    if (out.entryLimit) return;
    if (out.files.length >= 200000) {
      out.entryLimit = true;
      ExportFilePlan.error(out, 'ARCHIVE_ENTRY_LIMIT', '归档条目超过当前 200000 项限制，请减少所选内容');
      return;
    }
    if (!ExportPath.relative(file.archivePath)) {
      ExportFilePlan.error(out, 'ARCHIVE_PATH', '归档路径非法');
      return;
    }
    const lower = file.archivePath.toLowerCase();
    const previous = out.paths.get(lower);
    const parentSpelling = out.parents.get(lower);
    if (previous !== undefined || (!file.directory && parentSpelling !== undefined)
      || (parentSpelling !== undefined && parentSpelling !== file.archivePath)) {
      ExportFilePlan.error(out, 'ARCHIVE_COLLISION', '归档内容存在同名、大小写或文件目录冲突', file.archivePath);
      return;
    }
    const parts = file.archivePath.split('/');
    const parents: string[] = [];
    let prefix = '';
    for (let i = 0; i < parts.length - 1; i++) {
      prefix += (i === 0 ? '' : '/') + parts[i];
      const key = prefix.toLowerCase();
      const ancestor = out.paths.get(key);
      const spelling = out.parents.get(key);
      if ((ancestor !== undefined && (!ancestor.directory || ancestor.archivePath !== prefix))
        || (spelling !== undefined && spelling !== prefix)) {
        ExportFilePlan.error(out, 'ARCHIVE_COLLISION', '归档内容存在同名、大小写或文件目录冲突', file.archivePath);
        return;
      }
      parents.push(prefix);
    }
    out.files.push(file);
    out.paths.set(lower, file);
    for (const parent of parents) out.parents.set(parent.toLowerCase(), parent);
    out.totalBytes += file.size;
  }

  /** 所有安全与完整性失败保留为结构化问题，不通过丢掉条目让计划表面成功。 */
  private static error(out: ExportFilePlanBuildState, code: string, message: string, path: string = ''): void {
    out.issues.push({ code: code, severity: 'error', message: message, path: path });
  }
}
