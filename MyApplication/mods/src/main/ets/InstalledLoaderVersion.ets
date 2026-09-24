/**
 * 已安装加载器的版本解析。
 * 同一版本可能以 FML 启动参数或 Maven 坐标声明 loader 版本，不能只认其中一种。
 * 本模块读取实际元数据并沿安全的继承链回退；目录名只用于定位文件，不用于猜版本。
 * 返回空串表示证据缺失，由安装入口在开始网络传输前给出可理解的环境错误。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { safeBaseName } from 'feature_core';
import { readModpackSnapshot } from './ModpackSnapshot';

/** 只读取版本判定所需字段；带规则的参数不在这里擅自判为当前生效。 */
interface LoaderArgument { value: string | string[]; rules?: Object[]; }
interface LoaderArguments { game?: (string | LoaderArgument)[]; }
interface LoaderLibrary { name: string; }
export interface LoaderVersionMetadata {
  arguments?: LoaderArguments;
  minecraftArguments?: string;
  libraries?: LoaderLibrary[];
  inheritsFrom?: string;
}

/** 从明确的参数序列读取值，兼容 --flag value 和 --flag=value，拒绝占位符及下一个开关。 */
function loaderArgumentValue(tokens: string[], flag: string): string {
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    let value = '';
    if (token === flag && i + 1 < tokens.length) value = tokens[i + 1];
    else if (token.startsWith(flag + '=')) value = token.substring(flag.length + 1);
    value = value.trim();
    if (value.length > 0 && !value.startsWith('--') && value.indexOf('${') < 0) return value;
  }
  return '';
}

/**
 * 单份 JSON 的纯解析入口，供实际安装和宿主回归共用。
 * 启动参数优先于库坐标，防止现代 NeoForge 没有主坐标、或辅助 FML 库版本被误认。
 * 无条件参数对象可展开；条件参数只充当分隔符，避免把不同参数段拼成伪 flag/value。
 */
export function loaderVersionFromMetadata(metadata: LoaderVersionMetadata, loader: string, game: string): string {
  const tokens: string[] = [];
  for (const arg of metadata.arguments?.game ?? []) {
    if (typeof arg === 'string') tokens.push(arg);
    else if (arg.rules === undefined || arg.rules.length === 0) {
      if (typeof arg.value === 'string') tokens.push(arg.value);
      else tokens.push(...arg.value);
    } else tokens.push('--');
  }
  // 旧版参数字符串只做词法拆分，不执行变量替换或 shell 求值。
  if (metadata.minecraftArguments !== undefined) {
    const matcher = new RegExp('"([^"\\r\\n]*)"|[^\\s"]+', 'g');
    let match = matcher.exec(metadata.minecraftArguments);
    while (match !== null) {
      tokens.push(match[1] !== undefined ? match[1] : match[0]);
      match = matcher.exec(metadata.minecraftArguments);
    }
  }
  if (loader === 'neoforge' || loader === 'forge') {
    const flag = loader === 'neoforge' ? '--fml.neoForgeVersion' : '--fml.forgeVersion';
    const argument = loaderArgumentValue(tokens, flag);
    if (argument.length > 0) return argument;
  }
  for (const library of metadata.libraries ?? []) {
    const parts = library.name.split(':');
    if (parts.length < 3) continue;
    const group = parts[0];
    const artifact = parts[1];
    const version = parts[2];
    if ((loader === 'fabric' && group === 'net.fabricmc' && artifact === 'fabric-loader')
      || (loader === 'quilt' && group === 'org.quiltmc' && artifact === 'quilt-loader')
      || (loader === 'neoforge' && group === 'net.neoforged' && artifact === 'neoforge')) return version;
    if ((loader === 'forge' && group === 'net.minecraftforge' && (artifact === 'forge' || artifact === 'fmlloader'))
      || (loader === 'neoforge' && group === 'net.neoforged' && artifact === 'forge')) {
      return game.length > 0 && version.startsWith(game + '-') ? version.substring(game.length + 1) : version;
    }
  }
  return '';
}

/**
 * 最多读取 16 层继承，循环或非法目录项停止；不存在的父版本不会越界读取。
 * 实际 JSON 无版本证据时才读取对应 loader 的整合包快照；不缓存以免更新后沿用旧值。
 */
export function resolveInstalledLoaderVersion(mcDir: string, versionId: string, loader: string, game: string): string {
  const visited = new Set<string>();
  let current = versionId;
  for (let depth = 0; depth < 16 && current.length > 0; depth++) {
    if (safeBaseName(current).length === 0 || visited.has(current)) break;
    visited.add(current);
    let metadata: LoaderVersionMetadata;
    try {
      metadata = JSON.parse(fs.readTextSync(mcDir + '/versions/' + current + '/' + current + '.json')) as LoaderVersionMetadata;
    } catch (e) { break; }
    const found = loaderVersionFromMetadata(metadata, loader, game);
    if (found.length > 0) return found;
    current = metadata.inheritsFrom ?? '';
  }
  if (safeBaseName(versionId).length === 0) return '';
  const snapshot = readModpackSnapshot(mcDir + '/versions/' + versionId);
  if (snapshot !== null && snapshot.loaderType === loader) return snapshot.loaderVersion?.trim() ?? '';
  return '';
}
