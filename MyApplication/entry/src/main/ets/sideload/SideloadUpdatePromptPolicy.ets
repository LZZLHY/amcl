import { UpdateManifest } from 'update';

/** 更新页的正式路由参数，候选路径只可由产品选择器令牌解析。 */
export interface SideloadUpdatePageParams {
  manifest?: UpdateManifest; autoStart?: boolean;
  /** Coordinator 核验后的不透明令牌；路由不能提供任意安装路径。 */
  importToken?: string;
  /** 从明确JDK依赖动作带来的兼容约束；只会缩小候选范围，不授予安装或切通道权限。 */
  requiredHostProtocol?: number;
  requiredHostProtocols?: number[];
  /** 私有JDK续作代次；只有记账后明确进入此流程的页面携带，不能由普通更新推断。 */
  runtimeIntentId?: string;
}

/** 首页更新提示的独立清单快照。手动检查可以在启动过游戏后继续显示。 */
export interface SideloadUpdatePromptCandidate {
  readonly manifest: UpdateManifest;
  readonly manual: boolean;
}

/** 开屏、恢复或其他对话框占位时，只保留最新候选，并隔离调用方对清单的修改。 */
export class SideloadUpdatePromptPolicy {
  static candidate(manifest: UpdateManifest, manual: boolean): SideloadUpdatePromptCandidate | null {
    try {
      return { manifest: JSON.parse(JSON.stringify(manifest)) as UpdateManifest, manual: manual };
    } catch (_) { return null; }
  }

  static queue(previous: SideloadUpdatePromptCandidate | null,
    next: SideloadUpdatePromptCandidate): SideloadUpdatePromptCandidate | null {
    return SideloadUpdatePromptPolicy.candidate(next.manifest, next.manual || previous?.manual === true);
  }

  static select(candidate: SideloadUpdatePromptCandidate | null,
    gameLaunchedThisSession: boolean): SideloadUpdatePromptCandidate | null {
    if (candidate === null || (!candidate.manual && gameLaunchedThisSession)) return null;
    return SideloadUpdatePromptPolicy.candidate(candidate.manifest, candidate.manual);
  }
}
