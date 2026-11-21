/**
 * 设置页的可见性与搜索目录。
 *
 * 目录只描述已经存在的产品能力，不读取 Preferences、不写配置，也不自行探测设备。
 * 宿主从原产品策略计算能力后传入，同一份结果同时约束侧栏、搜索结果与目标项导航。
 * 稳定的 item id 与 section id 不含展示文案，改名不会令搜索定位指向另一项设置。
 */

/** 由 SettingsTab 从现有渠道/设备策略计算；运行准入与安装产品能力分别保留。 */
export interface SettingsCapabilities {
  run: boolean;
  store: boolean;
  publisher: boolean;
  touch: boolean;
  chooseInteraction: boolean;
  tabletProcess: boolean;
  pc: boolean;
  developer: boolean;
}

/** 分区只承载导航信息；about 与 ledger 是既有独立页面，不建立第二套路由栈。 */
export interface SettingsSection {
  id: string;
  title: string;
  description: string;
}

/** 具体项的索引信息；id 同时用于渲染锚点，避免只匹配分区后让用户再次寻找。 */
export interface SettingsItem {
  id: string;
  section: string;
  title: string;
  description: string;
  keywords: string;
}

/** 单选草稿使用字符串身份；禁用项可以解释原因，但永远不能被确定操作提交。 */
export interface SettingsChoice {
  value: string;
  title: string;
  description: string;
  enabled: boolean;
}

/** 窗口宽度沿用原设置页的 840 vp 门槛；手机与窄分屏不保留分类侧栏。 */
export const SETTINGS_WIDE_WIDTH: number = 840;

/** 返回当前能实际打开的分区；管理态仍可调整主题、文件归属和下载，不暴露运行术语。 */
export function settingsSections(capability: SettingsCapabilities): SettingsSection[] {
  const sections: SettingsSection[] = [];
  if (capability.run) {
    sections.push({ id: 'performance', title: '游戏与性能', description: '内存、Java 与启动方式' });
    sections.push({ id: 'controls', title: '显示与操控', description: '图形、语言、触控与手柄' });
  } else {
    sections.push({ id: 'files', title: '文件归属', description: '版本隔离与文件归属' });
  }
  sections.push({ id: 'appearance', title: '外观与光感', description: '主题、导航材质与应用位置' });
  sections.push({ id: 'download', title: '下载与存储', description: '下载源与游戏数据位置' });
  sections.push({ id: 'logs', title: '日志与支持', description: '日志保留、网络检测与帮助' });
  return sections;
}

/**
 * 构造当前具体项库存。条件与真实渲染使用同一 capability，搜索不能绕过渠道或产品裁剪。
 * JDK 版本、图形后端等动态子选项仍由原目录服务提供，这里不复制其候选或可用性结论。
 */
export function settingsItems(c: SettingsCapabilities): SettingsItem[] {
  const items: SettingsItem[] = [
    { id: 'theme', section: 'appearance', title: '主题与外观', description: '明暗模式与玫晶、原生蓝、松石青、鸢尾紫', keywords: '外观 显示 自动 白天 夜间 主题色 配色 颜色 玫晶 原生蓝 松石青 鸢尾紫' },
    { id: 'phone-sheet-height', section: 'appearance', title: '手机 Sheet 高度', description: '默认展开高度，自动保存选择', keywords: '手机 面板 弹窗 底部 半模态 高度 sheet 百分比' },
    { id: 'immersive', section: 'appearance', title: '沉浸光感', description: '导航材质、底部栏与圆形图标按钮', keywords: '精美 轻柔 流畅 自动 返回 关闭 效果' },
    { id: 'mc-source', section: 'download', title: '游戏下载源', description: '自动、镜像优先或官方优先', keywords: 'minecraft mc mojang bmclapi 来源' },
    { id: 'mod-source', section: 'download', title: '模组数据源', description: '自动、镜像或官方', keywords: 'mod mcim modrinth curseforge 搜索 来源' },
    { id: 'remote-cache', section: 'download', title: '缓存远程元数据', description: '缓存项目详情与版本列表', keywords: '缓存 请求 网络 元数据' },
    { id: 'download-concurrency', section: 'download', title: '并发下载数', description: '由下载引擎自动管理', keywords: '线程 同时 数量 自动 并行' },
    { id: 'storage', section: 'download', title: '游戏数据位置', description: '应用私有或外部存储', keywords: '沙箱 路径 文件 迁移 复制 存档 卸载 download' },
    { id: 'retention', section: 'logs', title: '游戏日志保留', description: '每个版本保留的完整游戏日志数量', keywords: '保留 日志 占用 空间 清理 局数' },
    { id: 'launcher-log', section: 'logs', title: '启动器运行日志', description: '查看启动器运行记录', keywords: '日志 错误 诊断' },
    { id: 'diagnostics', section: 'logs', title: '应用诊断摘要', description: '复制脱敏的诊断摘要', keywords: '日志 复制 导出 剪贴板 脱敏' },
    { id: 'game-log', section: 'logs', title: '最近游戏的完整日志', description: '查看最近一次游戏记录', keywords: '游戏 日志 完整' },
    { id: 'network', section: 'logs', title: '网络检测', description: '检查网络环境与下载源可达性', keywords: '网络 下载 搜索 失败 超时 检测' },
    { id: 'ledger', section: 'ledger', title: '活动账本', description: '游戏、下载与文件管理记录', keywords: '活动 历史 记录 日志 ai 分析' },
    { id: 'about', section: 'about', title: '关于 AMCL', description: '版本信息、联系方式与更新日志', keywords: '关于 版本 联系 邮箱 qq 更新 许可 隐私 调试' },
    { id: 'software-update', section: 'software-update', title: '软件更新', description: c.store ? '应用版本与应用市场更新' : '更新通道、华为开发者账号与本地安装', keywords: c.store ? '软件 更新 市场 版本' : '软件 更新 华为 开发者 账号 登录 状态 授权 稳定 预览 本地 安装' },
  ];
  items.push({ id: 'isolation', section: c.run ? 'performance' : 'files', title: '版本隔离',
    description: '每个版本独立保存存档、模组与资源包', keywords: '隔离 文件 归属 存档 资源包' });
  if (c.run) {
    items.push({ id: 'game-keep-screen-on', section: 'performance', title: '游戏中保持屏幕常亮',
      description: '游戏在前台时防止自动息屏', keywords: '常亮 息屏 熄屏 亮屏 休眠 锁屏 显示 挂机' });
    items.push({ id: 'memory', section: 'performance', title: 'JVM 最大内存', description: '游戏内存、快捷档位与精确输入', keywords: '内存 堆 xmx mb gb 性能' });
    items.push({ id: 'virtual-memory', section: 'performance', title: '虚拟内存（堆文件）', description: '把 Java 堆放到存储上', keywords: '内存 堆文件 低内存 大型整合包' });
    items.push({ id: 'java', section: 'performance', title: 'Java 版本', description: '按游戏版本自动匹配或固定 JDK', keywords: 'java jdk 运行环境 版本' });
    items.push({ id: 'jvm', section: 'performance', title: '自定义 JVM 参数', description: '编辑全局启动参数', keywords: 'jvm java 参数 启动 自定义' });
    items.push({ id: 'mod-audio', section: 'performance', title: '模组麦克风', description: '前台语音聊天与 AI 交互', keywords: '麦克风 录音 语音 verity ai voice' });
    items.push({ id: 'frame-rate', section: 'controls', title: '系统调度帧率', description: '固定屏幕刷新率或交回系统自动调节', keywords: '显示 帧率 刷新 屏幕 hz fps 自动 固定 ltpo 档位' });
    items.push({ id: 'language', section: 'controls', title: '游戏语言', description: 'Minecraft 界面的默认语言', keywords: '语言 中文 english lang' });
    items.push({ id: 'graphics', section: 'controls', title: '图形后端', description: '按设备、游戏与运行库检查可用性', keywords: '渲染 mobilegl mobileglues vulkan opengl gl4es zink' });
    // 与分辨率组件使用同一运行能力门；管理态不暴露游戏缩放入口，搜索只导航不写设置。
    items.push({ id: 'resolution', section: 'controls', title: '游戏分辨率', description: '未单独设置版本的默认渲染比例，保持全屏', keywords: '分辨率 全局 默认 比例 缩放 像素 画质 性能 50 75 100' });
    items.push({ id: 'jdk-source', section: 'download', title: 'JDK 下载源', description: '自动、源站、Gitee 或镜像', keywords: 'java jdk github gitee 镜像 来源' });
    items.push({ id: 'jdk-update', section: 'download', title: 'JDK 更新', description: '手动检查、自动检查与更新通道', keywords: 'java jdk 检查 更新 稳定 预览 通道 服务器' });
    if (c.tabletProcess) items.push({ id: 'process', section: 'performance', title: '独立游戏进程', description: '平板游戏运行方式，重启启动器后生效', keywords: '平板 进程 兼容模式 重启' });
    if (c.touch) {
      items.push({ id: 'input', section: 'controls', title: '手感与输入', description: '视角、触觉反馈与手柄映射', keywords: '触控 输入 灵敏度 视角 手柄 死区 陀螺仪' });
      items.push({ id: 'layouts', section: 'controls', title: '操控方案', description: '管理布局、触控、视角与手柄设置', keywords: '触控 布局 按键 摇杆 编辑' });
      items.push({ id: 'touch-help', section: 'controls', title: '触控操作帮助', description: '进入游戏世界后学习真实控件', keywords: '触控 帮助 教学 引导 操作' });
    }
    if (c.chooseInteraction) items.push({ id: 'interaction', section: 'controls', title: '电脑游戏交互', description: '自动、触屏或键鼠', keywords: '电脑 交互 鼠标 键盘 触屏 重启' });
    if (c.pc) items.push({ id: 'gamepad', section: 'controls', title: '由游戏处理手柄', description: '游戏控制器模组与启动器映射', keywords: '电脑 手柄 控制器 模组 映射' });
    if (!c.tabletProcess) items.push({ id: 'window', section: 'controls', title: '游戏窗口', description: '当前设备的实际游戏窗口模式', keywords: '窗口 桌面 独立 全屏' });
    if (c.developer) items.push({ id: 'developer', section: 'controls', title: '开发者工具', description: '当前诊断构建提供的工具', keywords: '开发 调试 诊断 测试' });
  }
  if (c.publisher) items.push({ id: 'acceleration', section: 'download', title: '加速下载', description: '官方源中转与直连回退状态', keywords: '加速 官方源 网关 中转 服务器' });
  if (!c.store) {
    items.push({ id: 'install-help', section: 'logs', title: '怎么安装', description: 'HoKit 侧载安装教程', keywords: '安装 侧载 hokit 帮助' });
    items.push({ id: 'jit-help', section: 'logs', title: 'JIT 的解决办法', description: '提示 JIT 不可用时的帮助', keywords: 'jit 不可用 权限 帮助' });
    items.push({ id: 'feedback', section: 'logs', title: '问题反馈', description: '反馈问题与建议，可附截图', keywords: '反馈 bug 问题 建议' });
    items.push({ id: 'sponsor', section: 'logs', title: '支持作者', description: '赞助登记与支持方式', keywords: '支持 赞助 作者' });
  }
  return items;
}

/** 只搜索传入的可见库存；空白输入返回空结果，由宿主继续显示正常分区内容。 */
export function searchSettings(items: SettingsItem[], query: string): SettingsItem[] {
  const needle: string = query.trim().toLowerCase();
  if (needle.length === 0) return [];
  return items.filter((item: SettingsItem): boolean =>
    (item.title + ' ' + item.description + ' ' + item.keywords).toLowerCase().indexOf(needle) >= 0);
}
