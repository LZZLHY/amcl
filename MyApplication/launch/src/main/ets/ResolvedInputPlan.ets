/**
 * 输入启动子契约：复用已经解析的运行库事实，独立冻结真实输入 ABI 和制品槽。
 * 本模块只做无副作用的计划决议与组合校验，不创建游戏类、DSO 或 consumer。
 * 因此计划通过仅表示能够准备，实际 READY 仍由各后端实例自己的注册入口证明。
 */
import { GraphicsGameFacts } from './GraphicsGameFacts';

/** 这是实际游戏输入接口；LWJGL2 即使使用 GLFW 窗口，也保留自己的读取消费者。 */
export enum InputAbi { GLFW = 'GLFW', LWJGL2 = 'LWJGL2', SDL3 = 'SDL3' }
export const INPUT_PLAN_SCHEMA: string = 'v1';
export const INPUT_PLAN_ARG_KEY: string = '-Damcl.input.plan=';

/**
 * 计划字段为创建 JVM 前的不可变事实。javaSlotDirectory 指向已核验的派生运行库目录，
 * nativeBinding 是 HAP 内实际输入出口；二者仍由既有运行库/产物完整性门核验内容身份。
 * compatibilityPolicy 仅记录当前 ABI 必须保留的交付政策，不代表新的统一算法已经实施。
 * 原生手柄能力未由平台启动结果推定；必须等待实际 ABI 的完整出口证据再改变来源政策。
 */
export interface ResolvedInputPlan {
  schemaVersion: string;
  abi: InputAbi;
  lwjglSlot: string;
  windowProvider: string;
  javaSlotDirectory: string;
  nativeBinding: string;
  compatibilityPolicy: string;
}

/**
 * 使用 Builder 同一次版本解析的事实和最终选定目录生成输入计划。
 * 不读取图形 profile/API，也不再次解析 version.json 或 classpath；输入与图形共同
 * 引用该运行库选择，之后各自执行。非法 SDL+LWJGL2/322 组合在 JVM 之前直接拒绝。
 */
export function resolveInputPlan(facts: GraphicsGameFacts, javaSlotDirectory: string): ResolvedInputPlan {
  const slot: string = facts.lwjglVersion === 2 ? 'LWJGL2'
    : (facts.needsLwjgl322Slot ? 'LWJGL322' : 'LWJGL3');
  if (javaSlotDirectory.length === 0 || (facts.usesSdl3 && slot !== 'LWJGL3')) {
    throw new Error('输入运行库槽与实际 ABI 不兼容');
  }
  const abi: InputAbi = slot === 'LWJGL2' ? InputAbi.LWJGL2
    : (facts.usesSdl3 ? InputAbi.SDL3 : InputAbi.GLFW);
  return {
    schemaVersion: INPUT_PLAN_SCHEMA, abi: abi, lwjglSlot: slot,
    windowProvider: facts.usesSdl3 ? 'SDL3' : 'GLFW', javaSlotDirectory: javaSlotDirectory,
    nativeBinding: abi === InputAbi.LWJGL2 ? 'liblwjgl_v2.so'
      : (abi === InputAbi.SDL3 ? 'libSDL3.so' : 'libglfw.so'),
    compatibilityPolicy: abi === InputAbi.LWJGL2 ? 'l2-pull'
      : (abi === InputAbi.SDL3 ? 'sdl-present-1' : 'glfw-present-2'),
  };
}

/**
 * 核验两个子契约共享同一个运行库/窗口组合。调用者只能拒绝冲突，不能用图形值重写输入。
 * 此处不要求实际窗口或 consumer 已经存在，避免准备阶段与游戏合法初始化形成循环。
 */
export function inputPlanMatchesRuntime(plan: ResolvedInputPlan, slot: string, windowProvider: string): boolean {
  return plan.schemaVersion === INPUT_PLAN_SCHEMA && plan.lwjglSlot === slot
    && plan.windowProvider === windowProvider;
}

/**
 * 私有 JVM 参数中的定长字段契约；完整目录保留在 LaunchProfile 并由现有槽租约保护。
 * 所有序列化值都是本模块生成的封闭枚举，不允许用户注入路径或任意自定义政策。
 */
export function serializeInputPlan(plan: ResolvedInputPlan): string {
  return 'v=' + plan.schemaVersion + ';abi=' + plan.abi + ';slot=' + plan.lwjglSlot
    + ';window=' + plan.windowProvider + ';binding=' + plan.nativeBinding
    + ';policy=' + plan.compatibilityPolicy;
}

/**
 * 宿主及私有快照对账只解析纯文本，不触碰游戏资源。固定字段顺序也使未知字段、重复字段、
 * 非法 ABI/槽/制品/政策组合无法悄悄被忽略。返回 undefined 表示 InvalidPayload，
 * 不能把失败重新解释为 legacy；缺失旧参数的兼容选择仅允许在 Native 旧入口完成。
 * javaSlotDirectory 不在该紧凑线协议里，因此由持有真实 Profile 的调用者另行绑定。
 */
export function parseInputPlan(wire: string): ResolvedInputPlan | undefined {
  if (wire.length === 0 || wire.length > 256) return undefined;
  const parts: string[] = wire.split(';');
  const keys: string[] = ['v=', 'abi=', 'slot=', 'window=', 'binding=', 'policy='];
  if (parts.length !== keys.length) return undefined;
  const values: string[] = [];
  for (let index: number = 0; index < keys.length; index++) {
    if (!parts[index].startsWith(keys[index])) return undefined;
    values.push(parts[index].substring(keys[index].length));
  }
  if (values[0] !== INPUT_PLAN_SCHEMA) return undefined;
  const abi: InputAbi | undefined = values[1] === InputAbi.GLFW ? InputAbi.GLFW
    : (values[1] === InputAbi.LWJGL2 ? InputAbi.LWJGL2
      : (values[1] === InputAbi.SDL3 ? InputAbi.SDL3 : undefined));
  if (abi === undefined) return undefined;
  const isL2: boolean = abi === InputAbi.LWJGL2 && values[2] === 'LWJGL2'
    && values[3] === 'GLFW' && values[4] === 'liblwjgl_v2.so' && values[5] === 'l2-pull';
  const isGlfw: boolean = abi === InputAbi.GLFW && (values[2] === 'LWJGL3' || values[2] === 'LWJGL322')
    && values[3] === 'GLFW' && values[4] === 'libglfw.so' && values[5] === 'glfw-present-2';
  const isSdl: boolean = abi === InputAbi.SDL3 && values[2] === 'LWJGL3'
    && values[3] === 'SDL3' && values[4] === 'libSDL3.so' && values[5] === 'sdl-present-1';
  if (!isL2 && !isGlfw && !isSdl) return undefined;
  return { schemaVersion: values[0], abi: abi, lwjglSlot: values[2], windowProvider: values[3],
    javaSlotDirectory: '', nativeBinding: values[4], compatibilityPolicy: values[5] };
}
