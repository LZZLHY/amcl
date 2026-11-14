/** App 更新订阅的纯策略；与 JDK 通道和 sideload/store 分发渠道独立。 */
export class AppUpdatePolicy {
  /** 未保存选择的老安装默认稳定通道，未知持久值不扩大测试版订阅。 */
  static channel(value: string): string { return value === 'preview' ? 'preview' : 'stable'; }
  /** 新发行统一使用 pre1；历史 alpha/beta/rc/pre.N 继续可读，不重命名已发布资产。 */
  static prerelease(tag: string): boolean { return new RegExp('-(pre[1-9][0-9]*|dev[1-9][0-9]*|(alpha|beta|rc|pre)\\.[0-9]+)$').test(tag); }

  /** 发行类型来自真实版本名；开发者发行不是第三个订阅通道，非法版本不扩大权限。 */
  static releaseKind(value: string): string {
    if (typeof value !== 'string') return 'invalid';
    const name = value.startsWith('v') ? value.substring(1) : value;
    if (!AppUpdatePolicy.validVersion(name)) return 'invalid';
    if (new RegExp('-dev[1-9][0-9]*$').test(name)) return 'developer';
    return AppUpdatePolicy.prerelease(name) ? 'preview' : 'stable';
  }

  /** 开发者版保留原订阅，但暂停自动 App 检查与红点；JDK 通道由其自身策略决定。 */
  static automaticAllowed(installedName: string): boolean { return AppUpdatePolicy.releaseKind(installedName) !== 'developer'; }

  /** 版本名只解析发布格式；未知或溢出编号不参与同 code 覆盖决策。 */
  private static version(value: string): number[] | undefined {
    const match = new RegExp('^([0-9]+)\\.([0-9]+)\\.([0-9]+)(?:-(?:pre([1-9][0-9]*)|(alpha|beta|rc|pre)\\.([0-9]+)|dev([1-9][0-9]*)))?$').exec(value);
    if (match === null) return undefined;
    const stages: string[] = ['alpha', 'beta', 'rc', 'pre'];
    const rank = match[7] ? 4 : match[4] ? 3 : match[5] ? stages.indexOf(match[5]) : 9;
    const parts: number[] = [Number(match[1]), Number(match[2]), Number(match[3]), rank, Number(match[4] || match[6] || match[7] || 0)];
    return parts.every((part: number): boolean => Number.isSafeInteger(part) && part >= 0) ? parts : undefined;
  }

  /** 非法版本返回 false，供历史收据查询和同编号事务共同拒绝歧义输入。 */
  static validVersion(value: string): boolean { return AppUpdatePolicy.version(value) !== undefined; }

  /** 同一发行系列按数值比较 pre2/pre10；不使用字符串字典序或 GitHub 发布时间。 */
  static compare(left: string, right: string): number {
    const a = AppUpdatePolicy.version(left), b = AppUpdatePolicy.version(right);
    if (a === undefined || b === undefined) return 0;
    // dev/pre 之间没有发行先后关系；跨类型安装只接受下方明确的用户操作准入。
    if ((a[3] === 4 && b[3] < 4) || (b[3] === 4 && a[3] < 4)) return 0;
    for (let index = 0; index < a.length; index++) {
      if (a[index] !== b[index]) return a[index] > b[index] ? 1 : -1;
    }
    return 0;
  }

  /**
   * 安装编号不得降低。同 code 时仅允许预览序列前进，或用户所选稳定通道返回正式版。
   * 这是候选准入，不是安装成功证明；哈希、实际包版本、签名及执行权仍须独立核验。
   */
  static canInstall(currentCode: number, currentName: string, targetCode: number, targetName: string, channel: string,
    manualDeveloper: boolean = false): boolean {
    const targetKind = AppUpdatePolicy.releaseKind(targetName), currentKind = AppUpdatePolicy.releaseKind(currentName);
    // 开发者包只由已经核对官网精确原件的文件选择器意图授予此位；推荐解析永不传 true。
    if (targetKind === 'developer' && !manualDeveloper) return false;
    if (targetCode > currentCode) return true;
    if (targetCode !== currentCode || !AppUpdatePolicy.validVersion(currentName) || !AppUpdatePolicy.validVersion(targetName)) return false;
    const order = AppUpdatePolicy.compare(targetName, currentName);
    if (targetKind === 'developer') {
      if (currentKind !== 'developer') {
        const a = AppUpdatePolicy.version(targetName)!, b = AppUpdatePolicy.version(currentName)!;
        for (let index = 0; index < 3; index++) if (a[index] !== b[index]) return a[index] > b[index];
        return currentKind === 'preview';
      }
      return order > 0;
    }
    if (currentKind === 'developer') {
      if (channel === 'stable') return targetKind === 'stable';
      // 明确“转入预览版”允许同系列跨类型；不把早期系列的旧预览当成返回目标。
      const a = AppUpdatePolicy.version(targetName)!, b = AppUpdatePolicy.version(currentName)!;
      for (let index = 0; index < 3; index++) if (a[index] !== b[index]) return channel === 'preview' && a[index] > b[index];
      return channel === 'preview' && targetKind === 'preview';
    }
    if (order === 0) return false;
    const currentPre = AppUpdatePolicy.prerelease(currentName), targetPre = AppUpdatePolicy.prerelease(targetName);
    if (channel === 'stable') return currentPre && !targetPre;
    return channel === 'preview' && order > 0 && (currentPre || targetPre);
  }

  /** 旧清单只供稳定正式版兼容；测试通道必须得到明确声明，不能跨源切换订阅。 */
  static accepts(tag: string, declaredChannel: string | undefined, prerelease: boolean | undefined, expected: string): boolean {
    if (AppUpdatePolicy.releaseKind(tag) === 'developer') return false;
    const stage = AppUpdatePolicy.prerelease(tag);
    if (prerelease !== undefined && prerelease !== stage) return false;
    if (declaredChannel !== undefined && declaredChannel !== expected) return false;
    if (expected === 'preview') return declaredChannel === 'preview';
    return expected === 'stable' && !stage;
  }

  /** 预览/开发原件必须沿用其明确正式基线的 code；基线本身必须是较早的正式发行。 */
  static validBaseline(name: string, code: number, baseName: string, baseCode: number): boolean {
    if (!Number.isSafeInteger(code) || code < 1 || code !== baseCode || AppUpdatePolicy.releaseKind(baseName) !== 'stable') return false;
    if (AppUpdatePolicy.releaseKind(name) !== 'preview' && AppUpdatePolicy.releaseKind(name) !== 'developer') return false;
    const target = AppUpdatePolicy.version(name), base = AppUpdatePolicy.version(baseName);
    if (target === undefined || base === undefined) return false;
    for (let index = 0; index < 3; index++) if (target[index] !== base[index]) return target[index] > base[index];
    return false;
  }

  /** 每产品静态回退清单；官网当前头的优先级由调用方安排，preview 不追加旧 update.json。 */
  static urls(product: string, channel: string): string[] {
    const name = product === 'desktop' ? 'desktop' : 'sideload';
    const file = 'updates/' + name + '/' + AppUpdatePolicy.channel(channel) + '.json';
    return ['https://raw.githubusercontent.com/LZZLHY/amcl/main/' + file, 'https://lzzlhy.github.io/amcl/' + file];
  }
  /** 偏好隔离键包含产品和通道；目标延后由调用方再绑定实际 tag/code/hash。 */
  static preferenceKey(product: string, channel: string, field: string): string {
    return 'appUpdate.' + (product === 'desktop' ? 'desktop' : 'sideload') + '.' + AppUpdatePolicy.channel(channel) + '.' + field;
  }
}
