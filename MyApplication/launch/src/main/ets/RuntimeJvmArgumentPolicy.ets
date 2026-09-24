/**
 * 启动期 JVM 参数来源策略。这里只处理可证明的清单默认值与用户覆盖次序，
 * 不选择图形 provider、不访问文件，也不代替 native 的最终属性冻结。
 * 清单模板和用户原文必须沿不同入口流转，避免把用户显式异值悄悄改成宿主默认值。
 */

/**
 * 把清单中两种官方 JNA 默认模板映射到宿主拥有的实例临时目录。
 *
 * 输入必须是从 version.json 解析出的单个原始参数，尚未替换占位符；仅精确接受
 * 旧版 `${natives_directory}` 与新版 `${natives_directory}/jna`。绝对路径、额外子目录、
 * 裸属性以及其他 key 原样返回，保留加载器自定义语义并让 native 对真实异值给出错误。
 * 调用方不能把用户参数送入这里，否则会把显式覆盖伪装成官方默认值。
 */
export function normalizeManifestJnaTmpdir(argument: string, gameDir: string): string {
  if (argument === '-Djna.tmpdir=${natives_directory}'
    || argument === '-Djna.tmpdir=${natives_directory}/jna') {
    return '-Djna.tmpdir=' + gameDir + '/natives/jna';
  }
  return argument;
}

/**
 * 返回具有末项覆盖语义的 JVM 参数键。普通 -D 属性（含裸键）与堆/栈大小选项
 * 可以按键覆盖；--add-opens、--add-exports、-javaagent 等可重复选项不返回键，
 * 以免不同模块开放或多个 agent 因相同前缀被丢弃。
 */
export function jvmArgumentOverrideKey(argument: string): string {
  if (argument.indexOf('-D') === 0) {
    const equalIndex: number = argument.indexOf('=');
    return equalIndex >= 0 ? argument.substring(0, equalIndex) : argument;
  }
  const memoryPrefixes: string[] = ['-Xmx', '-Xms', '-Xss', '-Xmn'];
  for (const prefix of memoryPrefixes) {
    if (argument.indexOf(prefix) === 0) return prefix;
  }
  return '';
}

/**
 * 对已经分词的用户参数保留每个覆盖键的最后一项，返回新数组且不修改输入。
 * 上游按“全局参数 + 单版本参数”拼接，故从后向前选择会自然保留单版本设置。
 * 结果恢复原相对次序；可重复模块参数和 agent 全部保留。保护属性也只留下用户
 * 真正生效的值，随后仍必须接受 builder/native 的严格检查，不能替换为合法默认值。
 */
export function retainLastJvmArgumentValues(argumentsList: string[]): string[] {
  const seenKeys: Set<string> = new Set<string>();
  const reversed: string[] = [];
  for (let index: number = argumentsList.length - 1; index >= 0; index--) {
    const argument: string = argumentsList[index];
    const key: string = jvmArgumentOverrideKey(argument);
    if (key.length > 0) {
      if (seenKeys.has(key)) continue;
      seenKeys.add(key);
    }
    reversed.push(argument);
  }
  return reversed.reverse();
}
