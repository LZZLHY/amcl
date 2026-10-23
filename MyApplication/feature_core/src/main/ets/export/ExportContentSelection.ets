/**
 * 导出内容选择的纯规则。页面、盘点与文件计划共用同一包含/排除判断；本模块不访问
 * 文件、不猜测包内内容，不把发现错误算成空。更改选择返回独立请求，不改变在途owner。
 */
import { ExportContentGroup, ExportContentItem, ExportContentSelectionResult, ExportContentTree,
  ExportIssue, ExportRequest } from './ExportTypes';
import { ExportPath } from './ExportPath';

/** 相对路径分量边界匹配，避免mods/a误匹配mods/abc；不做realpath或大小写折叠。 */
function within(parent: string, path: string): boolean { return path === parent || path.startsWith(parent + '/'); }

/** 仅复制公共请求数据；调用方随后改数组不能回写旧草稿、preview或任务持有的请求。 */
function copy(request: ExportRequest): ExportRequest { return JSON.parse(JSON.stringify(request)) as ExportRequest; }

/** 查找有限父分量而非扫描所有选择项；数千单元的盘点/渲染不能退化为平方比较。 */
function coveredBy(roots: Set<string>, path: string, self: boolean = true): boolean {
  let candidate = self ? path : path.substring(0, path.lastIndexOf('/'));
  while (candidate.length > 0) {
    if (roots.has(candidate)) return true;
    candidate = candidate.substring(0, candidate.lastIndexOf('/'));
  }
  return false;
}

/** 一次纯选择求值的局部索引；owner按请求创建，不跨请求缓存，也不把源路径等价化。 */
export class ExportContentSelectionEvaluator {
  private readonly directories_: Set<string>;
  private readonly files_: Set<string>;
  private readonly worlds_: Set<string>;
  private readonly exclusions_: Set<string>;
  private readonly pendingWorldScope_: boolean;
  constructor(request: ExportRequest) {
    this.directories_ = new Set<string>(request.includeDirectories);
    this.files_ = new Set<string>(request.includeFiles);
    this.worlds_ = new Set<string>(request.selectedWorlds);
    this.exclusions_ = new Set<string>(Array.isArray(request.excludePaths) ? request.excludePaths : []);
    // 仅用于发现失败时保存saves范围身份，绝不据此选择具体世界；I/O层仍拒绝整树执行。
    this.pendingWorldScope_ = request.selectionVersion === 2 && this.directories_.has('saves');
  }
  /** 按分量执行排除优先，saves始终使用世界清单；不接收glob或绝对路径。 */
  isSelected(path: string): boolean {
    if (!ExportPath.relative(path) || ExportPath.excluded(path) || coveredBy(this.exclusions_, path)) return false;
    // saves根单元只表示发现失败的未决范围；已确认世界不能反过来重新选中该错误身份。
    if (path === 'saves') return this.pendingWorldScope_;
    if (path.startsWith('saves/')) return this.worlds_.has(path.split('/')[1]);
    return this.files_.has(path) || coveredBy(this.directories_, path);
  }
  /** 批量投影复用同一请求索引；关联设置必须和实际包同时被选中。 */
  isItemSelected(item: ExportContentItem): boolean {
    return this.isSelected(item.path) && (item.associatedPath === undefined || this.isSelected(item.associatedPath));
  }
}

/** 单元按来源path去重，分类的展开/排列不产生另一个有效文件选择。 */
function itemsIn(groups: ExportContentGroup[]): ExportContentItem[] {
  const found: Map<string, ExportContentItem> = new Map<string, ExportContentItem>();
  const visit = (group: ExportContentGroup): void => {
    for (const item of group.items) if (!found.has(item.path)) found.set(item.path, item);
    for (const child of group.children) visit(child);
  };
  for (const group of groups) visit(group);
  return Array.from(found.values());
}

/** 结构化问题均绑定相对路径，不能把绝对源位置写入可分享的报告。 */
function issue(code: string, message: string, path: string = '', warning: boolean = false): ExportIssue {
  return { code, message, path, severity: warning ? 'warning' : 'error' };
}

/** 世界和包是原子单元；深路径仍可用于config等普通资料，但不能拆半个世界/解压包。 */
function atomicPathValid(path: string, exclusion: boolean): boolean {
  const parts = path.split('/');
  if (parts[0] === 'saves') return path === 'saves' || (exclusion && parts.length === 2);
  if (['resourcepacks', 'texturepacks', 'shaderpacks'].indexOf(parts[0]) >= 0 && parts.length > 2) return false;
  return true;
}

/**
 * 只校验选择表达，不读取目标。v1保持首层数组与逐世界；v2是显式升级而非接受任意
 * 用户glob。私有/运行库排除继续由ExportPath及I/O控制路径政策执行，不允许子路径绕过。
 */
export function validateExportSelection(request: ExportRequest): ExportIssue[] {
  const issues: ExportIssue[] = [];
  const modern = request.selectionVersion === 2;
  if (request.selectionVersion !== undefined && !modern) issues.push(issue('SELECTION_VERSION', '内容选择版本不受支持，请重新选择'));
  if (request.excludePaths !== undefined && (!modern || !Array.isArray(request.excludePaths))) {
    issues.push(issue('SELECTION_EXCLUSIONS', '排除路径需要合法的v2内容选择'));
  }
  for (const path of request.includeDirectories.concat(request.includeFiles)) {
    if (typeof path !== 'string' || !ExportPath.relative(path) || (!modern && path.indexOf('/') >= 0)
      || (modern && !atomicPathValid(path, false))) issues.push(issue('SELECTION_PATH', '内容选择包含不安全或非原子路径'));
  }
  const directories = new Set<string>(request.includeDirectories);
  for (const path of request.includeFiles) if (directories.has(path)) issues.push(issue('SELECTION_KIND_CONFLICT', '同一路径不能同时作为文件和目录选择', path));
  if (modern && request.includeFiles.indexOf('saves') >= 0) issues.push(issue('WORLD_PATH', '世界范围只能使用目录身份'));
  for (const world of request.selectedWorlds) if (typeof world !== 'string' || !ExportPath.segment(world)) {
    issues.push(issue('WORLD_PATH', '世界选择必须是完整世界目录的名称'));
  }
  if (Array.isArray(request.excludePaths)) for (const path of request.excludePaths) {
    if (typeof path !== 'string' || !ExportPath.relative(path) || !atomicPathValid(path, true)) {
      issues.push(issue('SELECTION_EXCLUSION_PATH', '内容排除包含不安全路径或拆分了原子单元'));
    }
  }
  return issues;
}

/** 单一实际路径的有效选择；排除永远覆盖父包含，saves不接受整个目录代替逐世界清单。 */
export function isExportPathSelected(request: ExportRequest, path: string): boolean {
  return new ExportContentSelectionEvaluator(request).isSelected(path);
}

/** 返回false只表示单元未选，不能把available=false的读取错误当作无来源或空资料。 */
export function isExportContentItemSelected(request: ExportRequest, item: ExportContentItem): boolean {
  return new ExportContentSelectionEvaluator(request).isItemSelected(item);
}

/** 分类状态基于有效单元选择计算，包含有路径身份的错误项，使full漏读不能看似全选。 */
export function exportContentSelectionState(request: ExportRequest, group: ExportContentGroup): 'all' | 'some' | 'none' {
  const items = itemsIn([group]);
  const evaluator = new ExportContentSelectionEvaluator(request);
  const selected = items.filter((item: ExportContentItem): boolean => evaluator.isItemSelected(item)).length;
  return selected === 0 ? 'none' : selected === items.length ? 'all' : 'some';
}

/** 只有所有发现单元都选中才是完整资料预设；读取错误另由issues阻断，不能据此亮绿。 */
export function isExportContentAllSelected(request: ExportRequest, tree: ExportContentTree): boolean {
  if (Array.isArray(request.excludePaths) && request.excludePaths.length > 0) return false;
  const evaluator = new ExportContentSelectionEvaluator(request);
  return itemsIn(tree.groups).every((item: ExportContentItem): boolean => evaluator.isItemSelected(item));
}

/**
 * 从单元集合重新编译v2请求。通用config包含可以覆盖具体子项，所以未选子项仅在被
 * 选中父目录覆盖时生成排除；未选的祖先不能反过来阻断用户明确选中的子项。
 */
function compile(request: ExportRequest, tree: ExportContentTree, selected: Set<string>, preserveIntent: boolean = false): ExportRequest {
  const result = copy(request);
  result.selectionVersion = 2;
  result.includeDirectories = []; result.includeFiles = []; result.selectedWorlds = []; result.excludePaths = [];
  const items = itemsIn(tree.groups);
  const knownPaths = new Set<string>();
  const selectedPaths = new Set<string>();
  for (const item of items) {
    knownPaths.add(item.path);
    if (selected.has(item.id)) selectedPaths.add(item.path);
  }
  const includedDirectories = new Set<string>();
  const includedFiles = new Set<string>();
  const selectedWorlds = new Set<string>();
  const exclusions = new Set<string>();
  for (const item of items) if (selected.has(item.id) && (item.associatedPath === undefined
    || selectedPaths.has(item.associatedPath))) {
    if (item.kind === 'world') selectedWorlds.add(item.path.substring('saves/'.length));
    else if (item.kind === 'directory') includedDirectories.add(item.path);
    else includedFiles.add(item.path);
  }
  // 全资料和父类全选保留“整个来源目录”的意图，而不是把当时文件名展开成白名单。
  // 后来新增子文件仍会进入同一inventory比较，不能在预览/冻结之间悄悄消失。
  // 具体叶子子集保持精确路径；已有宽目录在取消一部分子项后仍保留，再用明确排除裁剪。
  const currentDirectories = new Set<string>(tree.directories);
  const previousDirectories = new Set<string>(request.includeDirectories);
  const descendants = new Map<string, number>();
  const selectedDescendants = new Map<string, number>();
  // 每个单元只沿自身祖先聚合一次；不能为每个首层root重扫所有单元。
  for (const item of items) {
    let parent = item.path;
    while (parent.length > 0) {
      if (currentDirectories.has(parent)) {
        descendants.set(parent, (descendants.get(parent) ?? 0) + 1);
        if (selected.has(item.id)) selectedDescendants.set(parent, (selectedDescendants.get(parent) ?? 0) + 1);
      }
      parent = parent.substring(0, parent.lastIndexOf('/'));
    }
  }
  for (const root of currentDirectories) {
    if (root === 'saves') continue;
    // 某个root自身也是显式单元（尤其部分发现失败的根错误项）且用户已取消时，不能
    // 借旧宽目录意图重新选中它。保留已确认的具体子项，避免排除整个root连正常包也丢掉。
    if (knownPaths.has(root) && !selectedPaths.has(root)) continue;
    const count = descendants.get(root) ?? 0;
    const selectedCount = selectedDescendants.get(root) ?? 0;
    const all = count > 0 && selectedCount === count;
    const kept = preserveIntent && previousDirectories.has(root) && selectedCount > 0;
    if (all || kept) includedDirectories.add(root);
  }
  if (preserveIntent) {
    // 当前未发现的旧选择不能因用户改了另一个分类而静默删除；继续留给严格检查或显式重置。
    const currentFiles = new Set<string>(tree.files);
    const currentWorlds = new Set<string>(tree.worlds);
    for (const path of request.includeFiles) if (!knownPaths.has(path) && !currentFiles.has(path)) includedFiles.add(path);
    for (const path of request.includeDirectories) if (!knownPaths.has(path) && !currentDirectories.has(path)) includedDirectories.add(path);
    for (const world of request.selectedWorlds) if (!knownPaths.has('saves/' + world) && !currentWorlds.has(world)) selectedWorlds.add(world);
  }
  for (const item of items) if (!selected.has(item.id) && coveredBy(includedDirectories, item.path, false)) {
    exclusions.add(item.path);
  }
  if (preserveIntent && Array.isArray(request.excludePaths)) for (const path of request.excludePaths) {
    if (!knownPaths.has(path) && coveredBy(includedDirectories, path)) exclusions.add(path);
  }
  result.includeDirectories = Array.from(includedDirectories).sort();
  result.includeFiles = Array.from(includedFiles).sort();
  result.selectedWorlds = Array.from(selectedWorlds).sort();
  result.excludePaths = Array.from(exclusions).sort();
  return result;
}

/** 新full包含错误范围等待用户处理；标准包只用各单元默认，不套用PCL个人资料默认到full。 */
export function defaultExportContentSelection(request: ExportRequest, tree: ExportContentTree): ExportRequest {
  const selected = new Set<string>();
  for (const item of itemsIn(tree.groups)) if (request.format === 'full' || item.defaultSelected) selected.add(item.id);
  return compile(request, tree, selected);
}

/**
 * group与leaf共用稳定id；all→取消、some/none→全选由UI传入selected明确决定。
 * 所有已发现单元重新编译，因此config宽选不能盖掉JEI/地图的明确取消。错误项可明确取消。
 */
export function setExportContentSelection(request: ExportRequest, tree: ExportContentTree,
  nodeId: string, selected: boolean): ExportRequest {
  const all = itemsIn(tree.groups);
  const evaluator = new ExportContentSelectionEvaluator(request);
  const selectedIds = new Set<string>();
  const byPath = new Map<string, ExportContentItem>();
  for (const item of all) {
    byPath.set(item.path, item);
    if (evaluator.isItemSelected(item)) selectedIds.add(item.id);
  }
  const target = new Set<string>();
  const visit = (group: ExportContentGroup): void => {
    if (group.id === nodeId) for (const item of itemsIn([group])) target.add(item.id);
    for (const child of group.children) visit(child);
  };
  for (const group of tree.groups) visit(group);
  for (const item of all) if (item.id === nodeId) target.add(item.id);
  for (const id of target) { if (selected) selectedIds.add(id); else selectedIds.delete(id); }
  for (const item of all) if (target.has(item.id) && selected && item.associatedPath !== undefined) {
    const pack = byPath.get(item.associatedPath);
    if (pack !== undefined) selectedIds.add(pack.id);
  }
  const targetPaths = new Set<string>();
  for (const item of all) if (target.has(item.id)) targetPaths.add(item.path);
  if (!selected) for (const item of all) if (item.associatedPath !== undefined && targetPaths.has(item.associatedPath)) selectedIds.delete(item.id);
  return target.size === 0 ? copy(request) : compile(request, tree, selectedIds, true);
}

/** 固定分类顺序属于内容契约，UI只负责投影；没有文件时也返回真实empty分类。 */
export function createExportContentTree(): ExportContentTree {
  const group = (id: string, label: string, description: string = '', children: ExportContentGroup[] = []): ExportContentGroup =>
    ({ id: 'group:' + id, label, description, children, items: [], availability: 'empty', reason: '' });
  const groups: ExportContentGroup[] = [
    group('settings', '游戏设置', '', [group('settings-general', '游戏选项'), group('settings-personal', '游戏个人记录')]),
    group('mods', '模组与配置', '', [group('mods-enabled', '模组'), group('mods-disabled', '已禁用模组'),
      group('mod-config', '模组配置'), group('mod-data', '脚本与整合包资料'), group('mod-personal', '模组个人记录')]),
    group('resourcepacks', '资源包与材质包'),
    group('shaders', '光影包', '', [group('shader-packs', '光影包'), group('shader-settings', '光影设置')]),
    group('maps', '地图与投影', '', [group('map-data', '地图记录与路标'), group('schematics', '投影与结构')]),
    group('media', '录像与截图', '', [group('screenshots', '截图'), group('replays', '录像回放')]),
    group('worlds', '单人存档', '每个世界作为完整目录选择'), group('servers', '多人服务器'),
    group('other', '其它实例资料', '保留未归类的普通资料，不包含账户、运行时和安装控制文件'),
  ];
  return { groups, issues: [], directories: [], files: [], worlds: [] };
}

/** 比通用config更具体的子类先归属；不按任意map/token关键字猜路径。 */
export function exportContentGroupForPath(path: string): string {
  const lower = path.toLowerCase();
  const root = lower.split('/')[0];
  if (within('config/jei/world', lower) || ['emi.json', 'patchouli_data.json'].indexOf(lower) >= 0) return 'mod-personal';
  if (within('config/tacz/custom', lower)) return 'mod-data';
  if (within('journeymap/config', lower) || within('journeymap/server', lower)) return 'mod-config';
  if (within('journeymap/data', lower) || ['xaero', 'xaerowaypoints', 'xaeroworldmap'].indexOf(root) >= 0) return 'map-data';
  if (root === 'mods' || root === 'coremods' || root === 'lib') return /\.(disabled|old)$/i.test(path) ? 'mods-disabled' : 'mods-enabled';
  if (['options.txt', 'optionsof.txt', 'optionsshaders.txt', 'configureddefaults'].indexOf(root) >= 0) return 'settings-general';
  if (['hotbar.nbt', 'command_history.txt'].indexOf(lower) >= 0) return 'settings-personal';
  if (root === 'config' || root === 'defaultconfigs') return 'mod-config';
  if (root === 'resourcepacks' || root === 'texturepacks') return 'resourcepacks';
  if (root === 'shaderpacks') return lower.endsWith('.txt') ? 'shader-settings' : 'shader-packs';
  if (root === 'schematics') return 'schematics';
  if (root === 'screenshots') return 'screenshots';
  if (root === 'replay_recordings' || root === 'replay_videos') return 'replays';
  if (root === 'saves') return 'worlds';
  if (lower === 'servers.dat') return 'servers';
  if (['hotai', 'bansoukou', 'addons', 'multiblocked', 'global_packs', 'global_resource_packs', 'global_data_packs',
    'optional_data_packs', 'moonlight-global-datapacks', 'maps', 'mods-resourcepacks', 'matmos', 'resource_assorts',
    'resource_assorts.json', 'patchouli_books', 'datapacks', 'openloader', 'worldshape', 'resources', 'scripts',
    'structures', 'fontfiles', 'oresources', 'packmenu', 'craftpresence', 'pointblanks', 'tacz', 'immersive_paintings'].indexOf(root) >= 0
    || root.startsWith('kubejs') || root.startsWith('template')) return 'mod-data';
  return 'other';
}

/** 常规标准包预设；full由默认编译器选所有范围，不借此列表漏掉世界或未知普通资料。 */
export function exportContentStandardDefault(path: string): boolean {
  const group = exportContentGroupForPath(path);
  return ['settings-general', 'mods-enabled', 'mod-config', 'mod-data', 'resourcepacks', 'shader-packs', 'shader-settings'].indexOf(group) >= 0
    || /^LICEN/i.test(path);
}

/** 发现器以自己的Set保证path唯一；这里仅作固定分类路由，避免逐项重扫整棵树退化为平方成本。 */
export function addExportContentItem(tree: ExportContentTree, item: ExportContentItem): void {
  const target = 'group:' + exportContentGroupForPath(item.path);
  const visit = (group: ExportContentGroup): boolean => {
    if (group.id === target) { group.items.push(item); return true; }
    return group.children.some((child: ExportContentGroup): boolean => visit(child));
  };
  tree.groups.some((group: ExportContentGroup): boolean => visit(group));
}

/** 状态由实际发现单元汇总，读取失败优先于empty；目录容量不作猜测。 */
export function finalizeExportContentTree(tree: ExportContentTree): ExportContentTree {
  const visit = (group: ExportContentGroup): void => {
    for (const child of group.children) visit(child);
    const items = itemsIn([group]);
    group.availability = items.some((item: ExportContentItem): boolean => !item.available) ? 'error'
      : items.length > 0 ? 'available' : 'empty';
    group.reason = items.filter((item: ExportContentItem): boolean => !item.available).map((item: ExportContentItem): string => item.reason).join('；');
  };
  for (const group of tree.groups) visit(group);
  return tree;
}

/** 发现期仅警告；当前确已选中的错误范围升级为阻断，未选标准包范围不会拖累合法内容。 */
export function exportContentSelectionIssues(request: ExportRequest, tree: ExportContentTree): ExportIssue[] {
  const issues = validateExportSelection(request);
  const evaluator = new ExportContentSelectionEvaluator(request);
  for (const item of itemsIn(tree.groups)) {
    if (!item.available && item.reason.length > 0 && evaluator.isSelected(item.path)) {
      issues.push(issue('CONTENT_SELECTION_UNREADABLE', '所选资料未能完成发现，请重试或明确排除：' + item.reason, item.path));
    }
    if (item.associatedPath !== undefined && evaluator.isSelected(item.path) && !evaluator.isSelected(item.associatedPath)) {
      issues.push(issue('CONTENT_SETTING_WITHOUT_PACK', '光影设置必须与对应光影包一起选择', item.path));
    }
  }
  return issues;
}

/** 用于owner准入；不以group空/非空替代选中错误范围的检查。 */
export function hasUnresolvedSelectedErrors(request: ExportRequest, tree: ExportContentTree): boolean {
  return exportContentSelectionIssues(request, tree).some((entry: ExportIssue): boolean => entry.severity === 'error');
}

/**
 * 旧草稿/记录保守恢复：不套新默认、不按首层库存交集丢掉v2子路径，合法旧数组原样保留。
 * 无法在当前发现中证明仍存在的选择给出提示；最终真实inventory仍失败关闭，不静默丢资料。
 */
export function reconcileExportContentSelection(request: ExportRequest, tree: ExportContentTree): ExportContentSelectionResult {
  const result = copy(request);
  const issues = exportContentSelectionIssues(result, tree);
  const known = itemsIn(tree.groups);
  const knownPaths = new Set<string>(known.map((item: ExportContentItem): string => item.path));
  const knownDirectories = new Set<string>(known.filter((item: ExportContentItem): boolean => item.kind === 'directory')
    .map((item: ExportContentItem): string => item.path));
  const currentDirectories = new Set<string>(tree.directories);
  const currentFiles = new Set<string>(tree.files);
  for (const path of result.includeDirectories.concat(result.includeFiles)
    .concat(result.selectedWorlds.map((world: string): string => 'saves/' + world))) {
    if (path === 'saves' || currentDirectories.has(path) || currentFiles.has(path)
      || knownPaths.has(path) || coveredBy(knownDirectories, path)) continue;
    issues.push(issue('CONTENT_SELECTION_CHANGED', '以前选择的范围当前未发现，检查时将重新核对', path, true));
  }
  return { request: result, issues };
}
