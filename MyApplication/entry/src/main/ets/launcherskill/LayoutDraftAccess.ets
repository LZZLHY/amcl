import { util } from '@kit.ArkTS';
import { SkillFields } from './LauncherSkillBus';

/** 布局草稿会混入人的手动编辑；每次写入前按真实快照核对本次编辑器及版本。 */
export class LayoutDraftAccess {
  /** 仅保留本进程最近结束的16个编辑结果；冷启动仅能从目录核实持久状态。 */
  private static outcomes: Map<string,SkillFields> = new Map();
  private ref: string = '';
  private signature: string = '';
  private revision: number = 0;

  open(): void {
    this.ref = util.generateRandomUUID();
    this.signature = ''; this.revision = 0;
  }

  snapshot(content: string): SkillFields {
    if (content !== this.signature) { this.signature = content; this.revision++; }
    return { 'draftRef': this.ref, 'draftRevision': this.revision };
  }

  complete(outcome: SkillFields): void {
    if (!this.ref) return;
    LayoutDraftAccess.outcomes.set(this.ref,outcome);
    if (LayoutDraftAccess.outcomes.size>16) {
      const keys:string[]=Array.from(LayoutDraftAccess.outcomes.keys());
      LayoutDraftAccess.outcomes.delete(keys[0]);
    }
  }

  static outcome(ref: string): SkillFields {
    return LayoutDraftAccess.outcomes.get(ref) ?? { 'state':'unknown','reason':'noConfirmedOutcome' };
  }

  permits(content: string, args: SkillFields): boolean {
    this.snapshot(content);
    return !!this.ref && args['draftRef'] === this.ref && args['draftRevision'] === this.revision;
  }
}

/** 只允许受限长度、去重的控件引用或键码列表。 */
export function layoutList(value: Object | undefined, limit: number): string[] | undefined {
  if (typeof value !== 'string' || value.length > 2048) return undefined;
  if (!value.trim()) return [];
  const parts = value.split(',').map((item: string): string => item.trim());
  if (parts.length > limit || parts.some((part: string): boolean => !part || part.length > 128) || new Set<string>(parts).size !== parts.length) return undefined;
  return parts;
}
