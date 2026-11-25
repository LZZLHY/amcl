import { util } from '@kit.ArkTS';
import { LauncherSkillBus, SkillFields } from './LauncherSkillBus';

interface EvidenceChoice {
  ref: string;
  activity: number;
  operation: string;
  outcome?: SkillFields;
}

/** 前台选择器或产品对话框独占本次操作；页面离开后仍能按原引用读回结果。进程重启则报告未知。 */
export class EvidenceChoiceResult {
  private static recent: EvidenceChoice[] = [];

  static begin(activity: number, operation: string, action: () => Promise<SkillFields>): SkillFields {
    const pending = EvidenceChoiceResult.recent.find((e: EvidenceChoice): boolean => e.activity === activity && !e.outcome);
    if (pending) return { 'state':'busy', 'reason':'existingChoice', 'operationRef':pending.ref, 'activityId':activity, 'operation':pending.operation };
    if (EvidenceChoiceResult.recent.length >= 32) {
      const completed = EvidenceChoiceResult.recent.findIndex((e: EvidenceChoice): boolean => e.outcome !== undefined);
      if (completed < 0) return { 'state':'busy', 'reason':'pendingChoices' };
      EvidenceChoiceResult.recent.splice(completed,1);
    }
    const entry: EvidenceChoice = { ref:util.generateRandomUUID(), activity:activity, operation:operation };
    EvidenceChoiceResult.recent.push(entry);
    try {
      const decision = action().then((result: SkillFields): void => { entry.outcome = result; }, (): void => {
        entry.outcome = { 'state':'unknown', 'reason':'choiceOutcomeUnknown' };
      });
      LauncherSkillBus.followUserDecision(operation, decision);
    } catch (_) { entry.outcome = { 'state':'unknown', 'reason':'choiceOutcomeUnknown' }; }
    return { 'state':'needsUser', 'reason':'evidenceChoice', 'operationRef':entry.ref, 'activityId':activity, 'operation':operation };
  }

  static read(args: SkillFields): SkillFields {
    const entry = EvidenceChoiceResult.recent.find((e: EvidenceChoice): boolean =>
      e.ref === args['operationRef'] && e.activity === args['activityId']);
    if (!entry) return { 'state':'unknown', 'reason':'originalChoiceUnavailable' };
    // 不同操作的终态字段不同；始终回传原操作和活动，便于按其类别核对是否写入/移除。
    const result: SkillFields = { 'state':'needsUser', 'operation':entry.operation, 'activityId':entry.activity, 'operationRef':entry.ref };
    if (entry.outcome) {
      for (const key of Object.keys(entry.outcome)) result[key] = entry.outcome[key];
    }
    return result;
  }
}
