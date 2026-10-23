/**
 * 标准包清单生成器。对当前文件库存生成 MR/CF 清单，未知来源保留实际文件进入 overrides，
 * 不返还旧整合包、不查询最新版，也不会为本地文件伪造 project/file 或下载 URL。
 */
import { ExportInventoryFile, ExportIssue, ExportRequest, ExportResolvedVersion, ExportResourceSource } from './ExportTypes';
import { ExportPath } from './ExportPath';

export interface ExportStandardManifest {
  path: string;
  content: string;
  downloadPaths: string[];
  issues: ExportIssue[];
}

export class StandardPackWriter {
  /**
   * 精确来源只有与本次 SHA-1/大小及原路径完全一致时才可使用；禁用文件保留名字进入覆盖目录。
   * CF 对“下载到哪个文件名”表达有限，因此只提升 mods/ 根目录的已启用 JAR，其他内容覆盖。
   */
  static build(request: ExportRequest, version: ExportResolvedVersion, files: ExportInventoryFile[],
    sources: ExportResourceSource[] = []): ExportStandardManifest {
    const out: ExportStandardManifest = { path: request.format === 'modrinth' ? 'modrinth.index.json' : 'manifest.json',
      content: '', downloadPaths: [], issues: [] };
    if (request.launcher === 'pcl' && (version.loader.kind === 'neoforge' || version.loader.kind === 'quilt')) {
      out.issues.push({ code: 'STANDARD_LAUNCHER_LOADER', severity: 'error',
        message: '当前 PCL 兼容基线尚未确认此标准包加载器，请选择 HMCL', path: '' });
    }
    if (version.loader.kind === 'unknown' || (version.loader.kind !== 'vanilla' && version.loader.version.length === 0)) {
      out.issues.push({ code: 'STANDARD_LOADER_IDENTITY', severity: 'error', message: '不能生成缺少精确加载器身份的标准包', path: '' });
    }
    const entries: Object[] = [];
    const byPath = new Map<string, ExportResourceSource>();
    const ambiguous = new Set<string>();
    for (const source of sources) {
      if (byPath.has(source.path)) ambiguous.add(source.path);
      byPath.set(source.path, source);
    }
    for (const file of files) {
      if (file.directory) continue;
      // 重复来源不任选其一；保留实际文件进入覆盖目录，避免模糊身份变成外部下载。
      if (ambiguous.has(file.path)) continue;
      const source = byPath.get(file.path);
      if (source === undefined || source.disabled || source.size !== file.size
        || !/^[0-9a-fA-F]{40}$/.test(source.sha1) || source.sha1.toLowerCase() !== file.sha1.toLowerCase()) continue;
      if (request.format === 'modrinth') {
        if (!/^[0-9a-fA-F]{128}$/.test(source.sha512) || file.sha512 === undefined
          || source.sha512.toLowerCase() !== file.sha512.toLowerCase() || source.downloads.length === 0
          || !source.downloads.every((url: string): boolean => ExportPath.https(url))) continue;
        const hashes: Record<string, Object> = { 'sha1': file.sha1.toLowerCase(), 'sha512': source.sha512.toLowerCase() };
        const env: Record<string, Object> = { 'client': 'required', 'server': 'unsupported' };
        const entry: Record<string, Object> = { 'path': file.path, 'hashes': hashes, 'env': env,
          'downloads': source.downloads.slice(), 'fileSize': file.size };
        entries.push(entry);
        out.downloadPaths.push(file.path);
      } else if (/^mods\/[^/]+\.jar$/.test(file.path) && Number.isSafeInteger(source.curseforgeProjectId)
        && source.curseforgeProjectId > 0 && Number.isSafeInteger(source.curseforgeFileId) && source.curseforgeFileId > 0) {
        const entry: Record<string, Object> = { 'projectID': source.curseforgeProjectId, 'fileID': source.curseforgeFileId, 'required': true };
        entries.push(entry);
        out.downloadPaths.push(file.path);
      }
    }
    if (request.format === 'modrinth') {
      const deps: Record<string, Object> = { 'minecraft': version.vanillaVersion };
      const kind = version.loader.kind;
      const loaderKey = kind === 'fabric' ? 'fabric-loader' : kind === 'quilt' ? 'quilt-loader' : kind;
      if (kind !== 'vanilla' && kind !== 'unknown') deps[loaderKey] = version.loader.version;
      const manifest: Record<string, Object> = { 'formatVersion': 1, 'game': 'minecraft', 'versionId': request.exportId,
        'name': request.displayName, 'files': entries, 'dependencies': deps };
      out.content = JSON.stringify(manifest, null, 2);
    } else {
      const loaders: Object[] = [];
      if (version.loader.kind !== 'vanilla' && version.loader.kind !== 'unknown') {
        const loader: Record<string, Object> = { 'id': version.loader.kind + '-' + version.loader.version, 'primary': true };
        loaders.push(loader);
      }
      const minecraft: Record<string, Object> = { 'version': version.vanillaVersion, 'modLoaders': loaders };
      const manifest: Record<string, Object> = { 'minecraft': minecraft, 'manifestType': 'minecraftModpack',
        'manifestVersion': 1, 'name': request.displayName, 'version': request.exportId,
        'files': entries, 'overrides': 'overrides' };
      out.content = JSON.stringify(manifest, null, 2);
    }
    return out;
  }
}
