/**
 * 三个现役 LWJGL 槽的交付身份，不重新决定游戏世代或渲染路线。
 *
 * 现代槽直接引用既有生成契约，桥 JAR 升级后本模块自动消费新摘要；两个兼容槽的
 * 最终字节以 prebuilt/lwjgl3/legacy-slots.manifest.json 为权威，专属测试核对镜像、
 * rawfile 和 3.2.3 的 prebuilt。这里的摘要不是 deps.lock 中 Maven 原包摘要。
 */
import { LwjglModernJar, LWJGL_MODERN_MARKER,
  LWJGL_MODERN_VERSION } from './LwjglModernSlot';
import { LwjglViewJar, LWJGL_JDK_VIEWS } from './LwjglJdkViews';

/** 槽描述仅包含交付事实；目录映射不拥有文件、ClassLoader 或 native 库。 */
export interface LwjglRuntimeSlot {
  id: string;
  version: string;
  deploymentDirectory: string;
  resourceDirectory: string;
  marker: string;
  /** modern 必须记录实际 Java feature；旧槽使用 0，保持原始独立制品。 */
  javaFeature: number;
  jars: LwjglViewJar[];
}

const LWJGL_322_JARS: LwjglModernJar[] = [
  { name: 'lwjgl-glfw.jar', size: 112841, sha256: '3b3fef190cbc3b848800b5dfcb8c04ae52d3ea8afef9fdc3602773ae89670630' },
  { name: 'lwjgl-jemalloc.jar', size: 34130, sha256: '6f790dbe775eb56be638e9d97b355313c0caf374f13545996670756a15cbfe6f' },
  { name: 'lwjgl-openal.jar', size: 79432, sha256: '9b1bfdf60a3fe7ba6c48976411d311575fb2b7a7e7457e5589d1588719820fb0' },
  { name: 'lwjgl-opengl.jar', size: 938214, sha256: '5c473f23fd290385e33322426cbd9234bc505c27a1721e381fc43d59903a8046' },
  { name: 'lwjgl-stb.jar', size: 104146, sha256: 'bf416a52a841fa18508a40864544d7ef976a57733f2a13efbf5eb56f2a14ca96' },
  { name: 'lwjgl-tinyfd.jar', size: 6391, sha256: '12b857110f4659adf56f33ddc3fdb4285b01edf755be8fab1d74cc3eab8007cd' },
  { name: 'lwjgl.jar', size: 553506, sha256: '72a1b0b2816b21eaf6835739be7e23e1f6e96c118b648a44dcf9af9ff47a7f1b' }
];
const LWJGL_2_JARS: LwjglModernJar[] = [
  { name: 'lwjgl.jar', size: 1913154, sha256: 'ce1295ec22b109fb66735f62a65e50f74d7569e0e3eed9d3c392706c8ffd92e7' }
];

/** 返回完整副本，防止 classpath 调用方排序或改写摘要污染下一次启动。 */
function copyJars(jars: LwjglModernJar[], resourceDirectory: string): LwjglViewJar[] {
  const copied: LwjglViewJar[] = [];
  for (const jar of jars) {
    copied.push({ name: jar.name, size: jar.size, sha256: jar.sha256,
      resourcePath: resourceDirectory + '/' + jar.name });
  }
  return copied;
}

/**
 * 精确匹配启动构建器已经选定的槽目录；不接受相似前缀，不按 Minecraft 名称推断。
 * 调用方可由合并清单的 GraphicsGameFacts 取得与 builder 相同的槽，再只验证该槽。
 * 旧槽 marker 包含版本与最终 JAR 清单摘要；历史固定字符串 installed 不再放行。
 */
export function lwjglRuntimeSlot(slotDirectory: string, javaFeature: number = 0): LwjglRuntimeSlot {
  const directory: string = slotDirectory.substring(slotDirectory.lastIndexOf('/') + 1);
  if (directory === 'lwjgl-ohos') {
    // 同一纯选择器供部署、预检、classpath 与租约内校验消费。缺少实际 feature 时
    // 明确失败，不能回退到包含未来类的完整源包，也不能从路径猜测另一个 JDK。
    for (const view of LWJGL_JDK_VIEWS) {
      if (view.javaFeature !== javaFeature) continue;
      if (LWJGL_MODERN_MARKER.indexOf('manifest=' + view.sourceSlotIdentity + '\n') < 0) {
        throw new Error('LWJGL JDK 视图来源与现代槽不一致');
      }
      const jars: LwjglViewJar[] = [];
      for (const jar of view.jars) {
        jars.push({ name: jar.name, size: jar.size, sha256: jar.sha256, resourcePath: jar.resourcePath });
      }
      return { id: 'modern-jdk' + javaFeature.toString(), version: LWJGL_MODERN_VERSION,
        deploymentDirectory: directory, resourceDirectory: 'lwjgl', javaFeature: javaFeature,
        marker: view.marker, jars: jars };
    }
    throw new Error('该 JDK 的启动器 LWJGL 运行库视图未交付：' + javaFeature.toString());
  }
  if (directory === 'lwjgl-ohos-322') {
    return { id: 'legacy322', version: '3.2.3', deploymentDirectory: directory,
      resourceDirectory: 'lwjgl-3.2.3', javaFeature: 0,
      marker: 'amcl.lwjgl.legacy-slot\nversion=3.2.3\nmanifest=5612e0dbd31991da8b6ccb89cd46b3ebaf60e4123849073dc4235b9a7666c67a\n',
      jars: copyJars(LWJGL_322_JARS, 'lwjgl-3.2.3') };
  }
  if (directory === 'lwjgl-ohos-2') {
    return { id: 'legacy2', version: '2.9.4', deploymentDirectory: directory,
      resourceDirectory: 'lwjgl2', javaFeature: 0,
      marker: 'amcl.lwjgl.legacy-slot\nversion=2.9.4\nmanifest=6cf4e4af464a4d26ddd8f839991850112775e724e20c626258f0991df2a01aad\n',
      jars: copyJars(LWJGL_2_JARS, 'lwjgl2') };
  }
  throw new Error('未知 LWJGL 运行槽目录：' + slotDirectory);
}
