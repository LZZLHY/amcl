/** Configured once by the HAP from its generated product identity and native mask. */
export class DiagnosticPolicy {
  private static initialized: boolean = false;
  private static capabilities: number = 0;

  static configure(developerProduct: boolean, nativeCapabilities: number): void {
    if (DiagnosticPolicy.initialized) return;
    DiagnosticPolicy.initialized = true;
    DiagnosticPolicy.capabilities = developerProduct ? nativeCapabilities : 0;
  }

  static isDeveloperBuild(): boolean { return (DiagnosticPolicy.capabilities & 1) !== 0; }
  static hasTestHooks(): boolean { return (DiagnosticPolicy.capabilities & 3) === 3; }
  static inputTraceEnabled(): boolean { return (DiagnosticPolicy.capabilities & 5) === 5; }

  /**
   * 解析**之后**的能力位原值（批次 D8）。
   *
   * 与 `testNapi.getDiagnosticCapabilities()` 的区别是承重的：那是 native 掩码，
   * 而这里是 `configure()` 按产品身份裁剪后的结果（非 developer 产品恒为 0）。
   * 要回答"出货包里开关实际是几"，只有这个值有意义 —— `AGENTS.md` §二.5：
   * 声明默认值与产品实际值是两个事实。
   *
   * 只读，不改变任何状态；加它是为了让产品身份 banner 与未来的 `app.identity`
   * 读**同一个**事实源，而不是各自再算一遍。
   */
  static resolvedCapabilities(): number { return DiagnosticPolicy.capabilities; }
}
