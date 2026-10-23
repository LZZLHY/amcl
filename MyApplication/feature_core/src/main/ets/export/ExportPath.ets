/** 导出计划专用的纯路径边界；不访问磁盘，不修复带歧义的输入。 */
export class ExportPath {
  /** 拒绝穿越、反斜杠、控制字符、Windows 保留名称和会被接收端折叠的尾点/空格。 */
  static relative(path: string): boolean {
    if (path.length === 0 || path.length > 4096 || path.startsWith('/') || path.indexOf('\\') >= 0) return false;
    for (const part of path.split('/')) if (!ExportPath.segment(part)) return false;
    return true;
  }

  /** 所有出口均遵循 Windows 文件名交集，使标准包在默认电脑目标上不会出现同名覆盖。 */
  static segment(part: string): boolean {
    return part.length > 0 && part.length <= 255 && part !== '.' && part !== '..'
      && !/[\\/:*?"<>|\u0000-\u001f\u007f]/.test(part) && !/[. ]$/.test(part)
      && !/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(part);
  }

  /**
   * 用户数据采用明确拒绝列表，未知模组数据继续保留。账户、会话和本机控制记录不会进入覆盖目录。
   * 仅按已知名字判定，不把普通 config 或包含 token 字样的模组配置一概删除。
   */
  static excluded(path: string): boolean {
    const parts = path.toLowerCase().split('/');
    const root = parts[0];
    const denied = ['.amcl-runtime', '.amcl', '.hmcl', 'pcl', 'launcher_logs',
      'versions', 'libraries', 'assets', 'runtime', 'runtimes', 'natives', '.natives', 'jdk', 'accounts', '.secrets'];
    if (denied.indexOf(root) >= 0 || root.startsWith('lwjgl-ohos')) return true;
    for (const part of parts) {
      if (part === 'stub-objc-bridge.jar' || part.startsWith('.amcl-') || part.startsWith('amcl-runtime')
        || part.endsWith('.part') || part.endsWith('.part.meta') || part.endsWith('.download')
        || part === 'session.lock' || part === 'amcl.json' || part === 'amcl-launch.log') return true;
    }
    return ['launcher_accounts.json', 'launcher_profiles.json', 'usercache.json', 'usernamecache.json',
      'accounts.json', 'authentication.json', 'launcher_settings.json', 'optionsof.txt.orig',
      'amcl-version.json', 'amcl-install.json', '.amcl-install-pending.json'].indexOf(path.toLowerCase()) >= 0;
  }

  /**
   * Maven 坐标纯转换与工程 MavenUtils 的语法保持一致；此模块不能导入其中的网络/Kit 依赖。
   * 不猜下载 classifier：旧 native-only 条目的调用方必须先选择元数据声明的分类符。
   */
  static maven(name: string): string {
    const at = name.split('@');
    if (at.length > 2) return '';
    const extension = at.length === 2 ? at[1] : 'jar';
    const parts = at[0].split(':');
    if (parts.length < 3 || parts.length > 4 || !ExportPath.segment(extension)) return '';
    for (const part of parts) if (!ExportPath.segment(part)) return '';
    const group = parts[0].split('.');
    for (const part of group) if (!ExportPath.segment(part)) return '';
    const file = parts[1] + '-' + parts[2] + (parts.length === 4 ? '-' + parts[3] : '') + '.' + extension;
    const result = group.join('/') + '/' + parts[1] + '/' + parts[2] + '/' + file;
    return ExportPath.relative(result) ? result : '';
  }

  /** 清单下载只允许无认证信息的 HTTPS 地址；不输出带密码的 URL 或本地沙箱地址。 */
  static https(url: string): boolean {
    return /^https:\/\/[^\s\/@?#]+(?::[0-9]+)?(?:\/[^\s]*)?$/.test(url)
      && !/[\u0000-\u001f\u007f]/.test(url);
  }
}
