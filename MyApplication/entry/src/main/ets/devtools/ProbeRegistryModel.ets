/**
 * ProbeRegistryModel.ets — native 探针注册表的**纯模型层**（批次 D4）
 *
 * 文档：docs/refactor/测试自动化方案.md §三.4（D4）
 *       docs/guides/test-automation-contract.md §3.10（探针面大于 DevTools 工具列表）
 *                                               §8.3.1（判定逻辑必须能单独喂样本）
 *
 * 起因：`DevToolsPage.runTool` 的 switch 把"选哪个工具"与"怎么跑"混在一个函数里，
 * 于是"跑某个探针"这件事只有一个入口 —— 点那个页面上的按钮。
 *
 * 本文件**不 import `libentry.so`**：注册表的**数据与分派规则**在这里，
 * 真正的 NAPI 绑定在 `NativeProbeRegistry.ets`。这样分派规则才能在 Node 单测里
 * 直接喂样本（契约 §8.3.1）—— 否则它只能靠"点一遍页面"来验。
 *
 * ⚠️ **不为统一签名而包装**（D4 的硬约束）：把 `() => number` 的探针裹成
 * `() => string` 会改变它的行为语义，而那是自动化最不该做的事（契约 §2.2：
 * L3 禁止对被测行为的任何模拟）。⇒ 形状是**声明**出来的，由分派器分别处理。
 */

/**
 * 探针的实际调用形状。
 *
 * ⚠️ 这四个值是 2026-09-07 实读 `index.d.ts` 的结果，**不是设计出来的**。
 * D4 立项时只列了 `sync-text` / `async-promise` / `callback` 三种，实读后发现
 * 探针面里还有两种它们盖不住的：
 *   - `downloadEngineSelfTest: () => number`（返回码，不是文本）
 *   - `getNativeGlCapability: () => Promise<NativeGlCapability>`（对象，不是文本）
 * ⇒ 与其把它们裹成字符串，不如把形状说全。
 */
export enum ProbeShape {
  /** `(...) => string`：同步返回整段报告文本。绝大多数探针是这种。 */
  SYNC_TEXT = 'sync-text',
  /** `() => number`：同步返回一个状态码（0 = OK）。 */
  SYNC_CODE = 'sync-code',
  /** `() => Promise<object>`：异步返回结构化对象。 */
  ASYNC_JSON = 'async-json',
  /** `(done) => void`：异步，通过回调交付文本。 */
  CALLBACK_TEXT = 'callback-text',
}

/**
 * 一条探针的声明。
 *
 * 运行体按形状分成四个**可选**字段，而不是一个统一的 `run`：
 * 统一签名必然要求包装，而包装会改变返回语义（见文件头）。
 * `validateProbeDef` 强制"声明的形状"与"提供的运行体"一致。
 */
export interface NativeProbeDef {
  /** 稳定 id。自动化与 UI 都用它寻址，改名等于改契约。 */
  id: string;
  shape: ProbeShape;
  /** 人类可读标题。⚠️ 附加字段，机器一律用 `id`（契约 §2.3）。 */
  title: string;
  /**
   * 这条探针在 DevTools 页面上有没有按钮。
   *
   * ⭐ 契约 §3.10：NAPI 导出的探针**多于** DevTools 能触达的。
   * 把 `false` 的那批也纳入注册表，是 D4 的顺带收益 ——
   * 自动化因此能覆盖 UI 覆盖不到的部分，而不需要先给它们做界面。
   */
  hasUiEntry: boolean;
  /** 是否需要沙箱 filesDir（绑定时由宿主页面/桥注入，模型层不关心它从哪来）。 */
  needsFilesDir: boolean;
  runSyncText?: (filesDir: string) => string;
  runSyncCode?: () => number;
  runAsyncJson?: () => Promise<object>;
  runCallbackText?: (filesDir: string, done: (text: string) => void) => void;
}

/** 分派结果的统一外壳。**只有外壳统一，运行体不统一**。 */
export interface ProbeOutcome {
  id: string;
  ok: boolean;
  /** 文本形状给报告原文；code 形状给 `code=<n>`；json 形状给序列化结果。 */
  text: string;
  /** `SYNC_CODE` 专有；其余为 null。刻意不塞进 text 里让调用方去抠。 */
  code: number | null;
  error: string | null;
}

/**
 * 校验一条声明的自洽性。返回 issues（空 = 自洽）。
 *
 * 存在的理由：形状与运行体错配的失败形态是**运行时才炸**，而探针本来就是
 * "偶尔跑一次"的东西 —— 错配可能几个月都没人碰到。
 */
export function validateProbeDef(def: NativeProbeDef): string[] {
  const issues: string[] = [];
  const id: string = def.id !== undefined && def.id.length > 0 ? def.id : '<no id>';
  if (def.id === undefined || def.id.length === 0) issues.push('probe id must be a non-empty string');
  if (def.title === undefined || def.title.length === 0) issues.push(`${id}: title must be non-empty`);

  const provided: string[] = [];
  if (def.runSyncText !== undefined) provided.push(ProbeShape.SYNC_TEXT);
  if (def.runSyncCode !== undefined) provided.push(ProbeShape.SYNC_CODE);
  if (def.runAsyncJson !== undefined) provided.push(ProbeShape.ASYNC_JSON);
  if (def.runCallbackText !== undefined) provided.push(ProbeShape.CALLBACK_TEXT);

  if (provided.length === 0) {
    issues.push(`${id}: declares shape '${def.shape}' but provides no runner`);
  } else if (provided.length > 1) {
    // 两个运行体 = 两条真实通路，而声明只能指一条 ⇒ 另一条永远不会被跑到。
    issues.push(`${id}: provides ${provided.length} runners (${provided.join(', ')}); exactly one is allowed`);
  } else if (provided[0] !== def.shape) {
    issues.push(`${id}: declares shape '${def.shape}' but provides a '${provided[0]}' runner`);
  }
  return issues;
}

/** 校验整张表：逐条自洽 + id 唯一。 */
export function validateProbeRegistry(defs: NativeProbeDef[]): string[] {
  const issues: string[] = [];
  const seen: Set<string> = new Set<string>();
  for (const def of defs) {
    issues.push(...validateProbeDef(def));
    if (seen.has(def.id)) issues.push(`duplicate probe id '${def.id}'`);
    seen.add(def.id);
  }
  return issues;
}

/** 按 id 找一条；找不到返回 null（不抛、不猜）。 */
export function findProbe(defs: NativeProbeDef[], id: string): NativeProbeDef | null {
  for (const def of defs) {
    if (def.id === id) return def;
  }
  return null;
}

/** 没有 UI 入口的那批（契约 §3.10 的具体清单）。 */
export function probesWithoutUiEntry(defs: NativeProbeDef[]): string[] {
  const out: string[] = [];
  for (const def of defs) {
    if (!def.hasUiEntry) out.push(def.id);
  }
  return out;
}

/**
 * 纯分派：按声明的形状调用对应运行体，把结果整形成 `ProbeOutcome`。
 *
 * 注意它做的三件事与契约 §1.1 对 handler 的要求一致 ——
 * 参数编排、调用产品自己的实现、把结果整形。**不含任何业务判断**：
 * 探针输出里那句"PASS/FAIL"由探针自己给，这里不解释它。
 */
export async function runProbe(def: NativeProbeDef, filesDir: string): Promise<ProbeOutcome> {
  const issues: string[] = validateProbeDef(def);
  if (issues.length > 0) {
    return { id: def.id, ok: false, text: '', code: null, error: issues.join('; ') };
  }
  try {
    if (def.shape === ProbeShape.SYNC_TEXT) {
      return { id: def.id, ok: true, text: def.runSyncText!(filesDir), code: null, error: null };
    }
    if (def.shape === ProbeShape.SYNC_CODE) {
      const code: number = def.runSyncCode!();
      // code 单独成字段：塞进 text 会逼调用方去正则抠一个本来就是结构化的值。
      return { id: def.id, ok: code === 0, text: `code=${code}`, code, error: null };
    }
    if (def.shape === ProbeShape.ASYNC_JSON) {
      const value: object = await def.runAsyncJson!();
      return { id: def.id, ok: true, text: JSON.stringify(value), code: null, error: null };
    }
    const text: string = await new Promise<string>((resolve) => {
      def.runCallbackText!(filesDir, (t: string) => resolve(t));
    });
    return { id: def.id, ok: true, text, code: null, error: null };
  } catch (e) {
    const err = e as Error;
    const message: string = err !== undefined && err !== null && err.message !== undefined
      ? err.message : String(e);
    // 探针抛异常是**探针的结果**，不是分派器的失败 ⇒ ok=false 但仍返回结构，不再抛。
    return { id: def.id, ok: false, text: '', code: null, error: message };
  }
}
