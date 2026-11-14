/** Native分辨率状态的只读投影。协议异常返回不可用，不能从请求百分比推造actual尺寸。 */
export interface GameResolutionState {
  phase: string;
  requestId: string;
  generation: string;
  requestedPercent: number;
  configuredPercent: number;
  displayWidth: number;
  displayHeight: number;
  logicalWidth: number;
  logicalHeight: number;
  actualWidth: number;
  actualHeight: number;
  actualSource: number;
  /** 只证明本局请求通道和初始drawable已就绪，不代替目标比例的实际确认或设备资格。 */
  canRequest: boolean;
  virtualWindowManaged: boolean;
  reason: string;
}

export function unavailableGameResolution(): GameResolutionState {
  return { phase: 'unavailable', requestId: '0', generation: '0', requestedPercent: 100,
    configuredPercent: 100, displayWidth: 0, displayHeight: 0, logicalWidth: 0, logicalHeight: 0,
    actualWidth: 0, actualHeight: 0, actualSource: 0, canRequest: false, virtualWindowManaged: false, reason: '' };
}

/** 有限非负整数用于像素/来源编号，未知值不钳位成一个看似成功的实际尺寸。 */
function validDimension(value: Object | undefined): boolean {
  return typeof value === 'number' && Number.isFinite(value as number) && (value as number) >= 0
    && (value as number) <= 2147483647 && Math.floor(value as number) === value;
}

export function parseGameResolutionState(json: string): GameResolutionState {
  try {
    const data = JSON.parse(json) as Record<string, Object>;
    const phases: string[] = ['idle', 'pending', 'awaiting-drawable', 'confirmed', 'rejected', 'restoring', 'restart-required', 'suspended'];
    if (data['schema'] !== 1 || typeof data['phase'] !== 'string' || !phases.includes(data['phase'] as string)
      || typeof data['requestId'] !== 'string' || !/^\d+$/.test(data['requestId'] as string)
      || typeof data['generation'] !== 'string' || !/^\d+$/.test(data['generation'] as string)
      || typeof data['canRequest'] !== 'boolean' || typeof data['virtualWindowManaged'] !== 'boolean'
      || typeof data['reason'] !== 'string') return unavailableGameResolution();
    for (const key of ['displayWidth', 'displayHeight', 'logicalWidth', 'logicalHeight', 'actualWidth', 'actualHeight', 'actualSource']) {
      if (!validDimension(data[key])) return unavailableGameResolution();
    }
    for (const key of ['requestedPercent', 'configuredPercent']) {
      if (typeof data[key] !== 'number' || !Number.isFinite(data[key] as number)
        || (data[key] as number) < 50 || (data[key] as number) > 100) return unavailableGameResolution();
    }
    if (![0, 1, 2].includes(data['actualSource'] as number)) return unavailableGameResolution();
    if (data['phase'] === 'confirmed' && (data['actualSource'] === 0 || data['generation'] === '0'
      || (data['actualWidth'] as number) <= 0 || (data['actualHeight'] as number) <= 0
      || data['actualWidth'] !== data['logicalWidth'] || data['actualHeight'] !== data['logicalHeight'])) return unavailableGameResolution();
    return { phase: data['phase'] as string, requestId: data['requestId'] as string, generation: data['generation'] as string,
      requestedPercent: data['requestedPercent'] as number, configuredPercent: data['configuredPercent'] as number,
      displayWidth: data['displayWidth'] as number, displayHeight: data['displayHeight'] as number,
      logicalWidth: data['logicalWidth'] as number, logicalHeight: data['logicalHeight'] as number,
      actualWidth: data['actualWidth'] as number, actualHeight: data['actualHeight'] as number,
      actualSource: data['actualSource'] as number, canRequest: data['canRequest'] as boolean,
      virtualWindowManaged: data['virtualWindowManaged'] as boolean, reason: data['reason'] as string };
  } catch (_) { return unavailableGameResolution(); }
}

/** 用户文案按状态表达，具体失败码保留给日志；未确认时不使用“已生效”。 */
export function gameResolutionMessage(state: GameResolutionState): string {
  if (state.phase === 'confirmed') return '已生效：' + state.actualWidth + ' × ' + state.actualHeight;
  if (state.phase === 'pending' || state.phase === 'awaiting-drawable') return '正在应用，等待画面确认…';
  if (state.phase === 'restoring') return '未能采用目标尺寸，正在恢复…';
  if (state.phase === 'rejected') return state.actualWidth > 0
    ? '目标未生效，当前使用 ' + state.actualWidth + ' × ' + state.actualHeight : '目标未生效，请重新启动游戏';
  if (state.phase === 'restart-required') return '画面尺寸未能确认，请返回启动器后重新启动游戏';
  if (state.phase === 'suspended') return '游戏画面暂不可见，恢复后重新确认';
  return '当前窗口尚未具备游戏中调整条件，可在启动器设置下次启动的比例';
}
