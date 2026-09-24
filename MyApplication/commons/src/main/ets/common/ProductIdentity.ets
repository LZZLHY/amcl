/**
 * ProductIdentity.ets — 产品身份的结构化表示与格式化（批次 D8）
 *
 * 文档：docs/refactor/测试自动化方案.md §三.8（D8）
 *       docs/guides/test-automation-contract.md §2.3（机器可读优先）/ §10.2（产品身份不进日志）
 *
 * 起因（2026-09-07 真机探针 A7 判为不通过）：`onCreate` 第一行就调了
 * `DiagnosticPolicy.configure(ProductBuildProfile.developerDiagnostics, testNapi.getDiagnosticCapabilities())`
 * —— **解析发生了，结果没被记下来**。启动器日志全文没有任何一行能回答
 * "这个包是哪条产品轨、能力位实际是几"。⇒ agent 问"我在驱动哪个产品"今天无法回答，
 * 契约 §五 G1 的自检也无从反查（`AGENTS.md` §二.5：声明默认值与产品实际值是两个事实）。
 *
 * 本文件**只有纯函数与类型**：
 *   - 不 import `deviceInfo` / `libentry.so` / `ProductBuildProfile`，
 *     值一律由调用方传入 ⇒ 可以在 Node 下的单测里直接喂样本（契约 §8.3.1）；
 *   - 采集那一半在 `entry/src/main/ets/product/ProductIdentityCollector.ets`，
 *     它才知道去哪儿读这些值。
 *
 * ⚠️ 机器可读优先（契约 §2.3）：字段一律用稳定的英文 id 与布尔/数值，
 * **不放中文文案**。未来应用内 agent / MCP 会去匹配这些键，一改文案就断。
 */

/**
 * 一次运行的产品身份。字段分三组：构建期产品轨、运行期解析出的诊断能力位、设备。
 *
 * ⚠️ `capabilities` 是 **`DiagnosticPolicy` 解析之后**的值，不是 native 掩码原值 ——
 * 两者在非 default 产品上不同（policy 会强制清零）。要反查"出货包里开关实际是几"，
 * 唯一有意义的就是解析后的这个值。
 */
export interface ProductIdentity {
  // —— 构建期（generated ProductBuildProfile，五条产品轨各一份）
  product: string;
  family: string;
  storeChannel: boolean;
  publishable: boolean;
  developerDiagnostics: boolean;
  touchControls: boolean;
  runtimeRawMouse: boolean;
  // —— 运行期解析后的诊断能力位
  capabilities: number;
  developerBuild: boolean;
  testHooks: boolean;
  inputTrace: boolean;
  // —— 包与设备
  versionCode: number;
  versionName: string;
  deviceModel: string;
  deviceBrand: string;
  osFullName: string;
  apiVersion: number;
}

/**
 * banner 必须包含的字段，**顺序即输出顺序**。
 *
 * 门禁（`scripts/check-product-identity-banner.mjs`）拿它与 `ProductBuildProfile` 的
 * 静态字段集合对账：产品轨那七个字段少一个，banner 就回答不全"我在驱动哪个产品"，
 * 而少字段的失败形态是**报告看起来很正常**。
 */
export const PRODUCT_IDENTITY_FIELDS: string[] = [
  'product', 'family', 'storeChannel', 'publishable', 'developerDiagnostics',
  'touchControls', 'runtimeRawMouse',
  'capabilities', 'developerBuild', 'testHooks', 'inputTrace',
  'versionCode', 'versionName',
  'deviceModel', 'deviceBrand', 'osFullName', 'apiVersion',
];

/** banner 行的前缀。日志与门禁都认这个串，改它等于改契约。 */
export const PRODUCT_IDENTITY_BANNER_PREFIX: string = '[AMCL-PRODUCT-IDENTITY]';

function encodeValue(value: string | number | boolean): string {
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number') return String(value);
  // 值里出现空格会让 `key=value` 的切分失效；机型名（`MRDI-W10`）与
  // osFullName（`OpenHarmony-6.1.1.120`）实测无空格，但不能指望所有设备都如此。
  const text: string = String(value);
  return text.length === 0 ? '-' : text.split(' ').join('_');
}

function fieldValue(id: ProductIdentity, field: string): string | number | boolean {
  if (field === 'product') return id.product;
  if (field === 'family') return id.family;
  if (field === 'storeChannel') return id.storeChannel;
  if (field === 'publishable') return id.publishable;
  if (field === 'developerDiagnostics') return id.developerDiagnostics;
  if (field === 'touchControls') return id.touchControls;
  if (field === 'runtimeRawMouse') return id.runtimeRawMouse;
  if (field === 'capabilities') return id.capabilities;
  if (field === 'developerBuild') return id.developerBuild;
  if (field === 'testHooks') return id.testHooks;
  if (field === 'inputTrace') return id.inputTrace;
  if (field === 'versionCode') return id.versionCode;
  if (field === 'versionName') return id.versionName;
  if (field === 'deviceModel') return id.deviceModel;
  if (field === 'deviceBrand') return id.deviceBrand;
  if (field === 'osFullName') return id.osFullName;
  if (field === 'apiVersion') return id.apiVersion;
  return '';
}

/**
 * 格式化成一行结构化 banner：`[AMCL-PRODUCT-IDENTITY] key=value key=value …`
 *
 * ⚠️ 单行、且必须短：hilog 单条上限 4096 B（契约 §6.2）。当前字段集远小于此。
 */
export function formatProductIdentity(id: ProductIdentity): string {
  const parts: string[] = [];
  for (const field of PRODUCT_IDENTITY_FIELDS) {
    parts.push(`${field}=${encodeValue(fieldValue(id, field))}`);
  }
  return `${PRODUCT_IDENTITY_BANNER_PREFIX} ${parts.join(' ')}`;
}

/**
 * 反向解析 banner 行 → 键值对。给宿主编排器与未来的 `app.identity` 对账用。
 *
 * 存在的理由不是对称美感：**只有能被解析回来，banner 才算"机器可读"**。
 * 一个只能给人看的 banner 会让 agent 去正则抠字段，而那正是契约 §2.3 要防的形状。
 * 不是 banner 行时返回 null（不猜）。
 */
export function parseProductIdentityBanner(line: string): Map<string, string> | null {
  const text: string = typeof line === 'string' ? line : '';
  const at: number = text.indexOf(PRODUCT_IDENTITY_BANNER_PREFIX);
  if (at < 0) return null;
  const body: string = text.substring(at + PRODUCT_IDENTITY_BANNER_PREFIX.length).trim();
  if (body.length === 0) return null;
  const out: Map<string, string> = new Map<string, string>();
  for (const token of body.split(' ')) {
    if (token.length === 0) continue;
    const eq: number = token.indexOf('=');
    if (eq <= 0) continue;
    out.set(token.substring(0, eq), token.substring(eq + 1));
  }
  return out.size === 0 ? null : out;
}

/**
 * banner 是否字段齐全。门禁与自动化两处都用它，避免各写一份"齐全"的定义。
 * 返回缺失字段名（空数组 = 齐全）。
 */
export function missingIdentityFields(parsed: Map<string, string> | null): string[] {
  if (parsed === null) return PRODUCT_IDENTITY_FIELDS.slice();
  const missing: string[] = [];
  for (const field of PRODUCT_IDENTITY_FIELDS) {
    if (!parsed.has(field)) missing.push(field);
  }
  return missing;
}
