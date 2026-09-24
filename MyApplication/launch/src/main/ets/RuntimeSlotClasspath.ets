/**
 * LWJGL 三个现役槽位的 classpath 输入。
 *
 * 本模块是无文件读写的纯选择器：三个槽统一消费 LwjglRuntimeSlots 的交付描述符，
 * 与部署、预检使用同一 JAR 集合，不把目录枚举结果当成依赖许可。
 * 文件存在性、摘要与 ZIP 校验仍由部署/预检负责。本函数即使遇到缺文件也返回
 * 全部必需路径，使调用方能够准确报告缺失，不能悄悄生成不完整的 classpath。
 */
import { LwjglRuntimeSlot, lwjglRuntimeSlot } from './LwjglRuntimeSlots';

/**
 * 返回选定目录的固定 JAR 名单。目录必须精确匹配现役槽位，不接受相似前缀目录。
 * 返回新数组，调用方排序或追加元素不会污染下一次启动。322 的 jemalloc 是既有
 * 兼容模块；modern 则继续依照其清单省略 jemalloc，保留已验证的 StdlibAllocator 回退。
 */
export function lwjglSlotJarNames(slotDirectory: string): string[] {
  const slot: LwjglRuntimeSlot = lwjglRuntimeSlot(slotDirectory);
  const names: string[] = [];
  for (const jar of slot.jars) {
    names.push(jar.name);
  }
  return names;
}

/**
 * 将已知槽位名单展开为绝对路径；不扫描目录，不加载任何 Java/native 类，也不
 * 复制、恢复或删除 libraries 下的共享 Maven 文件。升级残留、诊断 JAR 和临时
 * 文件因不在名单内自然不会进入游戏类加载器；缺文件保留给 classpath 预检发现。
 */
export function lwjglSlotClasspath(slotDirectory: string): string[] {
  const paths: string[] = [];
  for (const name of lwjglSlotJarNames(slotDirectory)) {
    paths.push(slotDirectory + '/' + name);
  }
  return paths;
}
