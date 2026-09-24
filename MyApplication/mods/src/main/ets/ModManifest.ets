/** Package metadata and bidirectional constraints. Never infer compatibility from a filename. */
import { ModZipReader, modBytesText } from './ModZipReader';
import { compareManifestVersions, matchesModVersion } from './ModVersionRange';

export interface ModRequirement {
  id: string;
  ranges: string[];
  syntax: string;
  optional: boolean;
}

export interface ModDescriptor {
  id: string;
  name: string;
  version: string;
  loader: string;
  environment: string;
  provides: string[];
  depends: ModRequirement[];
  breaks: ModRequirement[];
  nested: boolean;
  file: string;
}

export interface ModEnvironment {
  gameVersion: string;
  loader: string;
  loaderVersion: string;
  javaVersion: string;
}

interface FabricNested { file: string; }
interface FabricMetadata {
  id: string;
  name?: string;
  version: string;
  environment?: string;
  provides?: string[];
  depends?: Record<string, string | string[]>;
  breaks?: Record<string, string | string[]>;
  jars?: FabricNested[];
}

interface QuiltDependency { id: string; versions?: string | string[]; optional?: boolean; }
interface QuiltProvided { id: string; version?: string; }
interface QuiltLoaderMetadata {
  id: string;
  version: string;
  metadata?: QuiltDisplay;
  depends?: QuiltDependency[];
  breaks?: QuiltDependency[];
  provides?: QuiltProvided[];
  jars?: string[];
}
interface QuiltDisplay { name?: string; }
interface QuiltMetadata { quilt_loader: QuiltLoaderMetadata; }
interface LegacyMetadata { modid: string; name?: string; version?: string; }
interface LegacyContainer { modList: LegacyMetadata[]; }
interface JarJarEntry { path: string; }
interface JarJarMetadata { jars: JarJarEntry[]; }

function descriptor(id: string, version: string, loader: string, file: string, nested: boolean): ModDescriptor {
  if (typeof id !== 'string' || id.length === 0 || typeof version !== 'string' || version.length === 0)
    throw new Error('模组标识或版本缺失：' + file);
  return { id: id, name: id, version: version, loader: loader, environment: '*', provides: [],
    depends: [], breaks: [], nested: nested, file: file };
}

function rangesOf(value: string | string[] | undefined): string[] {
  if (typeof value === 'string') return [value];
  if (Array.isArray(value) && value.every((v: string): boolean => typeof v === 'string')) return value;
  throw new Error('无法识别模组版本约束');
}

function fabricRequirements(value?: Record<string, string | string[]>): ModRequirement[] {
  const result: ModRequirement[] = [];
  if (value === undefined) return result;
  for (const id of Object.keys(value)) result.push({ id: id, ranges: rangesOf(value[id]), syntax: 'fabric', optional: false });
  return result;
}

export function parseFabricMod(text: string, file: string, nested: boolean = false): ModDescriptor {
  const raw = JSON.parse(text) as FabricMetadata;
  const d = descriptor(raw.id, raw.version, 'fabric', file, nested);
  d.name = raw.name ?? d.id;
  d.environment = raw.environment ?? '*';
  d.provides = raw.provides ?? [];
  d.depends = fabricRequirements(raw.depends);
  d.breaks = fabricRequirements(raw.breaks);
  return d;
}

function quiltRequirements(values?: QuiltDependency[]): ModRequirement[] {
  const result: ModRequirement[] = [];
  for (const value of values ?? []) {
    if (typeof value.id !== 'string') throw new Error('暂时无法解析 Quilt 复合依赖，请保留原文件');
    result.push({ id: value.id, ranges: value.versions === undefined ? ['*'] : rangesOf(value.versions),
      syntax: 'fabric', optional: value.optional === true });
  }
  return result;
}

/** TOML metadata only: quoted strings, booleans and array tables; unrelated keys are ignored. */
function tomlValue(text: string): string {
  const value = text.trim();
  if (value.startsWith('"')) {
    const match = new RegExp('^"(?:[^"\\\\]|\\\\.)*"').exec(value);
    if (match === null) throw new Error('模组 TOML 字符串未闭合');
    return JSON.parse(match[0]) as string;
  }
  if (value.startsWith("'")) {
    const end = value.indexOf("'", 1);
    if (end < 0) throw new Error('模组 TOML 字符串未闭合');
    return value.substring(1, end);
  }
  return value.split('#')[0].trim();
}

interface TomlSection { name: string; values: Record<string, string>; }

export function parseForgeMods(text: string, file: string, loader: string, jarVersion: string = '', nested: boolean = false): ModDescriptor[] {
  const sections: TomlSection[] = [];
  let current: TomlSection = { name: '', values: {} };
  sections.push(current);
  let multiline = '';
  for (const rawLine of text.split(new RegExp('\r?\n'))) {
    const line = rawLine.trim();
    if (multiline.length > 0) { if (line.indexOf(multiline) >= 0) multiline = ''; continue; }
    if (line.length === 0 || line.startsWith('#')) continue;
    const head = new RegExp('^\\[\\[(.+)\\]\\](?:\\s*#.*)?$').exec(line);
    if (head !== null) { current = { name: head[1].replace(new RegExp('["\']', 'g'), ''), values: {} }; sections.push(current); continue; }
    if (line.startsWith('[')) { current = { name: '', values: {} }; sections.push(current); continue; }
    const kv = new RegExp('^([A-Za-z0-9_.-]+)\\s*=\\s*(.*)$').exec(line);
    if (kv === null) continue;
    if (kv[2].startsWith('"""') || kv[2].startsWith("'''")) {
      const quote = kv[2].substring(0, 3);
      if (kv[2].substring(3).indexOf(quote) < 0) multiline = quote;
      continue;
    }
    if (['modId', 'version', 'displayName', 'mandatory', 'type', 'versionRange', 'side'].indexOf(kv[1]) >= 0)
      current.values[kv[1]] = tomlValue(kv[2]);
  }
  const result: ModDescriptor[] = [];
  for (const section of sections) {
    if (section.name !== 'mods') continue;
    let version = section.values['version'] ?? '';
    version = version.split('${file.jarVersion}').join(jarVersion);
    const d = descriptor(section.values['modId'] ?? '', version, loader, file, nested);
    d.name = section.values['displayName'] ?? d.id;
    result.push(d);
  }
  if (result.length === 0) throw new Error('模组 TOML 没有有效的 mods 声明：' + file);
  for (const section of sections) {
    if (!section.name.startsWith('dependencies.')) continue;
    const owner = result.find((d: ModDescriptor): boolean => d.id === section.name.substring(13));
    if (owner === undefined) throw new Error('模组依赖的所属 modId 不存在：' + section.name);
    const values = section.values;
    if (values['side'] === 'SERVER') continue;
    const type = values['type'] ?? (values['mandatory'] === 'false' ? 'optional' : 'required');
    const requirement: ModRequirement = { id: values['modId'] ?? '', ranges: [values['versionRange'] ?? '*'],
      syntax: 'maven', optional: type === 'optional' };
    if (requirement.id.length === 0) throw new Error('模组依赖 modId 缺失：' + file);
    if (type === 'incompatible') owner.breaks.push(requirement);
    else if (type !== 'discouraged') owner.depends.push(requirement);
  }
  return result;
}

export async function readModDescriptors(path: string, loader: string, memory?: ArrayBuffer, depth: number = 0): Promise<ModDescriptor[]> {
  if (depth > 8) throw new Error('模组内嵌 JAR 层数过多：' + path);
  const zip = new ModZipReader(path, memory);
  zip.load();
  const result: ModDescriptor[] = [];
  let nestedNames: string[] = [];
  const fabric = await zip.entry('fabric.mod.json');
  const quilt = loader === 'quilt' ? await zip.entry('quilt.mod.json') : undefined;
  if (quilt !== undefined) {
    const q = (JSON.parse(modBytesText(quilt)) as QuiltMetadata).quilt_loader;
    const d = descriptor(q.id, q.version, 'quilt', path, depth > 0);
    d.name = q.metadata?.name ?? d.id;
    d.depends = quiltRequirements(q.depends);
    d.breaks = quiltRequirements(q.breaks);
    d.provides = (q.provides ?? []).map((p: QuiltProvided): string => p.id);
    nestedNames = q.jars ?? [];
    result.push(d);
  } else if (fabric !== undefined && (loader === 'fabric' || loader === 'quilt')) {
    const text = modBytesText(fabric);
    result.push(parseFabricMod(text, path, depth > 0));
    nestedNames = ((JSON.parse(text) as FabricMetadata).jars ?? []).map((j: FabricNested): string => j.file);
  } else if (loader === 'forge' || loader === 'neoforge') {
    const jarJar = await zip.entry('META-INF/jarjar/metadata.json');
    if (jarJar !== undefined) nestedNames = (JSON.parse(modBytesText(jarJar)) as JarJarMetadata).jars.map((j: JarJarEntry): string => j.path);
    let toml = loader === 'neoforge' ? await zip.entry('META-INF/neoforge.mods.toml') : undefined;
    if (toml === undefined) toml = await zip.entry('META-INF/mods.toml');
    if (toml !== undefined) {
      const mf = await zip.entry('META-INF/MANIFEST.MF');
      const manifestText = mf === undefined ? '' : modBytesText(mf).replace(new RegExp('\r?\n ', 'g'), '');
      const jarVersion = new RegExp('(?:^|\n)Implementation-Version:\\s*([^\r\n]+)').exec(manifestText);
      result.push(...parseForgeMods(modBytesText(toml), path, loader, jarVersion === null ? '' : jarVersion[1].trim(), depth > 0));
    } else {
      const legacy = await zip.entry('mcmod.info');
      if (legacy !== undefined) {
        const parsed = JSON.parse(modBytesText(legacy)) as LegacyContainer | LegacyMetadata[];
        const mods: LegacyMetadata[] = Array.isArray(parsed) ? parsed as LegacyMetadata[] : (parsed as LegacyContainer).modList;
        for (const m of mods) result.push(descriptor(m.modid, m.version || '0', loader, path, depth > 0));
      }
    }
  }
  if (result.length === 0 && depth === 0 && (loader === 'fabric' || loader === 'quilt'))
    throw new Error('JAR 中没有 ' + loader + ' 模组声明：' + path);
  if (result.length > 0 && result.every((d: ModDescriptor): boolean => d.environment === 'server')) return result;
  let nestedBytes = 0;
  for (const name of nestedNames) {
    const bytes = await zip.entry(name, 32 * 1024 * 1024);
    if (bytes === undefined) throw new Error('内嵌模组文件缺失：' + name);
    nestedBytes += bytes.byteLength;
    if (nestedBytes > 128 * 1024 * 1024) throw new Error('内嵌模组总大小超限');
    result.push(...await readModDescriptors(path + '!/' + name, loader, bytes, depth + 1));
  }
  return result;
}

function actualVersions(id: string, descriptors: ModDescriptor[], environment: ModEnvironment): string[] {
  if (id === 'minecraft') return [environment.gameVersion];
  if (id === 'java') return environment.javaVersion.length > 0 ? [environment.javaVersion] : [];
  if (((environment.loader === 'forge' || environment.loader === 'neoforge') && id === environment.loader)
    || (id === 'fabricloader' && environment.loader === 'fabric')
    || (id === 'quilt_loader' && environment.loader === 'quilt')) return [environment.loaderVersion];
  return descriptors.filter((d: ModDescriptor): boolean => d.id === id || d.provides.indexOf(id) >= 0)
    .map((d: ModDescriptor): string => d.version);
}

function checkDescriptors(descriptors: ModDescriptor[], environment: ModEnvironment, future: ModDescriptor[]): string[] {
  const errors: string[] = [];
  const owners = new Map<string, string>();
  for (const d of descriptors) {
    for (const id of [d.id, ...d.provides]) {
      const previous = owners.get(id);
      if (previous !== undefined && previous !== d.file) errors.push('重复模组标识 ' + id + '：' + previous + ' / ' + d.file);
      owners.set(id, d.file);
    }
    for (const req of d.depends) {
      if (req.id === 'java' && environment.javaVersion.length === 0) continue;
      const versions = actualVersions(req.id, descriptors, environment);
      if (versions.length === 0 && req.optional) continue;
      let accepted = false;
      let supported = true;
      for (const v of versions) {
        const check = matchesModVersion(v, req.ranges, req.syntax);
        supported = supported && check.supported;
        accepted = accepted || (check.supported && check.matches);
      }
      if (accepted) continue;
      const possible = future.some((candidate: ModDescriptor): boolean => {
        if (candidate.id !== req.id && candidate.provides.indexOf(req.id) < 0) return false;
        const check = matchesModVersion(candidate.version, req.ranges, req.syntax);
        return check.supported && check.matches;
      });
      if (possible) continue;
      if (versions.length === 0) errors.push(d.name + ' ' + d.version + ' 缺少前置 ' + req.id + ' ' + req.ranges.join(' 或 '));
      else errors.push(d.name + ' 需要 ' + req.id + ' ' + req.ranges.join(' 或 ') + '，实际为 ' + versions.join('/')
        + (supported ? '' : '（无法确认此版本约束）'));
    }
    for (const req of d.breaks) {
      for (const v of actualVersions(req.id, descriptors, environment)) {
        const check = matchesModVersion(v, req.ranges, req.syntax);
        if (!check.supported || check.matches) errors.push(d.name + ' ' + d.version + ' 与 ' + req.id + ' ' + v
          + ' 冲突（' + req.ranges.join(' 或 ') + '）');
      }
    }
  }
  return errors;
}

interface NestedModChoices { id: string; choices: ModDescriptor[]; }

function nestedParentsPresent(selected: ModDescriptor[], all: ModDescriptor[]): boolean {
  for (const d of selected) {
    const split = d.file.lastIndexOf('!/');
    if (!d.nested || split < 0) continue;
    const parent = d.file.substring(0, split);
    if (all.some((p: ModDescriptor): boolean => p.file === parent)
      && !selected.some((p: ModDescriptor): boolean => p.file === parent)) return false;
  }
  return true;
}

/** Bounded search for nested candidates. Top-level user mods are always forced. */
class NestedModSearch {
  private groups_: NestedModChoices[];
  private environment_: ModEnvironment;
  private all_: ModDescriptor[];
  private visits_: number = 0;
  private exhausted_: boolean = false;
  constructor(groups: NestedModChoices[], environment: ModEnvironment, all: ModDescriptor[]) {
    this.groups_ = groups; this.environment_ = environment; this.all_ = all;
  }
  exhausted(): boolean { return this.exhausted_; }
  solve(selected: ModDescriptor[], index: number = 0): boolean {
    if (++this.visits_ > 8192) { this.exhausted_ = true; return false; }
    const future: ModDescriptor[] = [];
    for (let i = index; i < this.groups_.length; i++) future.push(...this.groups_[i].choices);
    if (checkDescriptors(selected, this.environment_, future).length > 0) return false;
    if (index >= this.groups_.length) return nestedParentsPresent(selected, this.all_);
    for (const candidate of this.groups_[index].choices) {
      selected.push(candidate);
      if (this.solve(selected, index + 1)) return true;
      selected.pop();
      if (this.exhausted_) return false;
    }
    // Nested JARs are optional candidates until required by a selected mod.
    return this.solve(selected, index + 1);
  }
}

/** An empty list proves that some nested selection satisfies every active root constraint. */
export function validateModSet(input: ModDescriptor[], environment: ModEnvironment): string[] {
  const roots: ModDescriptor[] = [];
  const groups = new Map<string, NestedModChoices>();
  for (const d of input) {
    if (d.environment === 'server') continue;
    if (!d.nested) roots.push(d);
    else {
      let group = groups.get(d.id);
      if (group === undefined) { group = { id: d.id, choices: [] }; groups.set(d.id, group); }
      if (!group.choices.some((old: ModDescriptor): boolean => old.file === d.file)) group.choices.push(d);
    }
  }
  const choices: NestedModChoices[] = [];
  groups.forEach((group: NestedModChoices): void => {
    if (roots.some((root: ModDescriptor): boolean => root.id === group.id)) return;
    group.choices.sort((a: ModDescriptor, b: ModDescriptor): number => -(compareManifestVersions(a.version, b.version) ?? 0));
    choices.push(group);
  });
  if (choices.length > 256) return ['内嵌模组候选过多，无法完整确认组合；原文件将被保留'];
  const preferred = roots.slice();
  for (const group of choices) if (group.choices.length > 0) preferred.push(group.choices[0]);
  const initialErrors = checkDescriptors(preferred, environment, []);
  if (initialErrors.length === 0 && nestedParentsPresent(preferred, input)) return [];
  if (initialErrors.length === 0) initialErrors.push('内嵌前置需要对应的来源模组版本');
  const search = new NestedModSearch(choices, environment, input);
  if (search.solve(roots.slice())) return [];
  if (search.exhausted()) initialErrors.push('内嵌模组版本组合未能在检查预算内收敛');
  return initialErrors;
}
