/**
 * 当前分支实际宿主能力。协议2实现已整合，任何远端清单、产品版本号或偏好都不能扩大集合。
 * 后续宿主实现与产物审计同时通过后才更新集合；返回副本避免调用者污染进程内信任边界。
 */
import { RuntimeHostCapabilities } from './RuntimeHostCapabilities';
export function runtimeHostProtocols(): number[] { return RuntimeHostCapabilities.supportedProtocols(); }
/** App对JDK的最低行为要求单独读取，不能把支持旧ABI当作旧JDK所有工作流仍可用。 */
export function runtimeRequiredCapabilities(): string[] { return RuntimeHostCapabilities.requiredCapabilities(); }
