/**
 * 三个现役 LWJGL 槽的交付身份，不重新决定游戏世代或渲染路线。
 *
 * 现代槽直接引用既有生成契约，桥 JAR 升级后本模块自动消费新摘要；两个兼容槽的
 * 最终字节以 prebuilt/lwjgl3/legacy-slots.manifest.json 为权威，专属测试核对镜像、
 * rawfile 和 3.2.3 的 prebuilt。这里的摘要不是 deps.lock 中 Maven 原包摘要。
 */
import { LwjglModernJar, LWJGL_MODERN_JARS, LWJGL_MODERN_MARKER,
  LWJGL_MODERN_VERSION } from './LwjglModernSlot';

/** 槽描述仅包含交付事实；目录映射不拥有文件、ClassLoader 或 native 库。 */
export interface LwjglRuntimeSlot {
  id: string;
  version: string;
  deploymentDirectory: string;
  resourceDirectory: string;
  marker: string;
  jars: LwjglModernJar[];
}

const LWJGL_322_JARS: LwjglModernJar[] = [
  { name: 'lwjgl-glfw.jar', size: 112856, sha256: '99853e19ed3a0319db233900561368d523921ea738d0f9f6f8ab0dd85a03f549' },
  { name: 'lwjgl-jemalloc.jar', size: 34130, sha256: '6f790dbe775eb56be638e9d97b355313c0caf374f13545996670756a15cbfe6f' },
  { name: 'lwjgl-openal.jar', size: 79432, sha256: '9b1bfdf60a3fe7ba6c48976411d311575fb2b7a7e7457e5589d1588719820fb0' },
  { name: 'lwjgl-opengl.jar', size: 938214, sha256: '5c473f23fd290385e33322426cbd9234bc505c27a1721e381fc43d59903a8046' },
  { name: 'lwjgl-stb.jar', size: 104146, sha256: 'bf416a52a841fa18508a40864544d7ef976a57733f2a13efbf5eb56f2a14ca96' },
  { name: 'lwjgl-tinyfd.jar', size: 6391, sha256: '12b857110f4659adf56f33ddc3fdb4285b01edf755be8fab1d74cc3eab8007cd' },
  { name: 'lwjgl.jar', size: 553506, sha256: '72a1b0b2816b21eaf6835739be7e23e1f6e96c118b648a44dcf9af9ff47a7f1b' }
];
const LWJGL_2_JARS: LwjglModernJar[] = [
  { name: 'lwjgl.jar', size: 1924101, sha256: '30d9773d4917c5eb6a2cc5f4c35136eb87b21c92168c1c91bb284cace9a842ff' }
];

/** 返回完整副本，防止 classpath 调用方排序或改写摘要污染下一次启动。 */
function copyJars(jars: LwjglModernJar[]): LwjglModernJar[] {
  const copied: LwjglModernJar[] = [];
  for (const jar of jars) {
    copied.push({ name: jar.name, size: jar.size, sha256: jar.sha256 });
  }
  return copied;
}

/**
 * 精确匹配启动构建器已经选定的槽目录；不接受相似前缀，不按 Minecraft 名称推断。
 * 调用方可由合并清单的 GraphicsGameFacts 取得与 builder 相同的槽，再只验证该槽。
 * 旧槽 marker 包含版本与最终 JAR 清单摘要；历史固定字符串 installed 不再放行。
 */
export function lwjglRuntimeSlot(slotDirectory: string): LwjglRuntimeSlot {
  const directory: string = slotDirectory.substring(slotDirectory.lastIndexOf('/') + 1);
  if (directory === 'lwjgl-ohos') {
    return { id: 'modern', version: LWJGL_MODERN_VERSION, deploymentDirectory: directory,
      resourceDirectory: 'lwjgl', marker: LWJGL_MODERN_MARKER, jars: copyJars(LWJGL_MODERN_JARS) };
  }
  if (directory === 'lwjgl-ohos-322') {
    return { id: 'legacy322', version: '3.2.3', deploymentDirectory: directory,
      resourceDirectory: 'lwjgl-3.2.3',
      marker: 'amcl.lwjgl.legacy-slot\nversion=3.2.3\nmanifest=01301a0cc9a1e78b36d5b0d10d690761a78e7084067a4e34c808f3f021a541ef\n',
      jars: copyJars(LWJGL_322_JARS) };
  }
  if (directory === 'lwjgl-ohos-2') {
    return { id: 'legacy2', version: '2.9.4', deploymentDirectory: directory,
      resourceDirectory: 'lwjgl2',
      marker: 'amcl.lwjgl.legacy-slot\nversion=2.9.4\nmanifest=98f9c2f40656718e3237d7846ce6a99107d69e535b8c6efe3ed5666d6a174e30\n',
      jars: copyJars(LWJGL_2_JARS) };
  }
  throw new Error('未知 LWJGL 运行槽目录：' + slotDirectory);
}
