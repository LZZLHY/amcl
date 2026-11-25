import { DownloadTaskRegistry, UnifiedTaskState, UnifiedTaskView } from 'feature_core';
import { qaTaskId, qaTaskRef } from './QaTaskIdentity';

interface CommandState { taskId: string; activityId: number; command: string; outcome: string; }
function reply(status: string, reason: string, data: Record<string, Object> = {}): string {
  return JSON.stringify({ status:status, reason:reason, data:data });
}

/** 控制 TaskCard 的同一个 adapter。异步恢复可能执行至任务结束，受理和自然完成分别回读。 */
export class QaTaskControl {
  private static directory: string = '';
  private static commands: Map<string, CommandState> = new Map<string, CommandState>();

  static run(registry: DownloadTaskRegistry, session: string, action: string, args: Record<string, Object>,
    id: string): string {
    if (QaTaskControl.directory !== session) {
      QaTaskControl.directory = session;
      QaTaskControl.commands.clear();
    }
    if (action === 'tasks.controlState') {
      const operation = args['operationId'];
      if (Object.keys(args).length !== 1 || typeof operation !== 'string') return reply('rejected','INVALID_ARGUMENTS');
      const old = QaTaskControl.commands.get(operation);
      return old ? reply('ok','',{ 'operationId':operation,'taskId':old.taskId,'activityId':old.activityId,
        'command':old.command,'outcome':old.outcome }) : reply('unknown','COMMAND_OWNER_LOST');
    }
    const key = args['taskId'];
    const activity = args['activityId'];
    const command = args['command'];
    if (Object.keys(args).some((k: string): boolean => !['taskId','activityId','command','taskRef'].includes(k)) || typeof key !== 'string' || typeof activity !== 'number' ||
      !Number.isSafeInteger(activity) || activity < 0 || typeof command !== 'string') return reply('rejected','INVALID_ARGUMENTS');
    const view = registry.listAll().find((v: UnifiedTaskView): boolean => v.startedAtMs === activity && qaTaskId(session,v) === key);
    if (!view || registry.get(view.id) !== view) return reply('rejected','TASK_REPLACED');
    if ((args['taskRef'] !== undefined && (!args['taskRef'] || args['taskRef'] !== qaTaskRef(session,view))) ||
      (activity === 0 && (args['taskRef'] !== qaTaskRef(session,view) || view.state !== UnifiedTaskState.WAITING || command !== 'cancel'))) {
      return reply('rejected','STALE_OR_UNSTARTED_TASK');
    }
    const active = view.state === UnifiedTaskState.PREPARING || view.state === UnifiedTaskState.DOWNLOADING ||
      view.state === UnifiedTaskState.EXTRACTING || view.state === UnifiedTaskState.VERIFYING;
    const allowed = (command === 'pause' && active && view.canPause) || (command === 'resume' && view.canResume && !view.requiresConfirmation) ||
      (command === 'retry' && view.canRetry && !view.canRecoverExternally) || (command === 'cancel' && view.canCancel);
    if (!allowed) return reply('rejected','OPERATION_UNAVAILABLE');
    const state: CommandState = {taskId:key,activityId:activity,command:command,outcome:'pending'};
    QaTaskControl.commands.set(id,state);
    let work: Promise<void>;
    try {
      if (command === 'pause') work = registry.pause(view.id);
      else if (command === 'resume') work = registry.resume(view.id);
      else if (command === 'retry') work = registry.retry(view.id);
      else work = registry.cancel(view.id, false);
    } catch (_) {
      state.outcome = 'failed';
      return reply('rejected','CONTROL_NOT_DISPATCHED');
    }
    work.then((): void => { state.outcome='returned'; }).catch((): void => { state.outcome='failed'; });
    return reply('accepted','',{ 'operationId':id,'taskId':key,'activityId':activity,'command':command });
  }
}
