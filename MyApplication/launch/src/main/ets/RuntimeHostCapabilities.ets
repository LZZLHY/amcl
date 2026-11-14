/** 由 config/runtime-host.json 生成；请使用 sync-product-profiles 更新，禁止远程扩大宿主能力。 */
export class RuntimeHostCapabilities {
  /** 返回本次源码实际支持的协议副本；未整合的候选能力不得加入。 */
  static supportedProtocols(): number[] { return [1, 2]; }
  /** 恢复读取协议独立于JDK装载ABI；2支持1MiB收据和耐久完成/续作，旧1仅兼容旧事务。 */
  static planProtocol(): number { return 2; }
  /** 目录读取能力独立于装载ABI/恢复协议；生产解析器与HAP元数据使用同一声明。 */
  static catalogProtocol(): number { return 2; }
  /** 本App正常工作流必需的JDK行为；不能由网络降低或由宿主ABI支持推断满足。 */
  static requiredCapabilities(): string[] { return ["zipfs-transaction-v1"]; }
  /** 发布前必须有兼容稳定推荐的Java槽位，实际发行门禁读取HAP中的同一声明。 */
  static requiredMajors(): number[] { return [8, 17, 21, 25]; }
}
