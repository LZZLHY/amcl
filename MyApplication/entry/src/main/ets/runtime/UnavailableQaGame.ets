import { StartObservedGame } from './LaunchAttemptObserver'
import { common, Want } from '@kit.AbilityKit'
import { GameSessionHost } from './GameSessionHost'

/** 非诊断产品不接收游戏测试动作，也不加载设备会话和证据适配器。 */
export class ProductQaGame {
  /** 发行版本不创建、查询或写入进程间观测材料。 */
  static armPrivate(_context: common.UIAbilityContext, _want: Want, _activity: number,
    _version: string): (() => void) | undefined { return undefined }
  static pulsePrivate(_host: GameSessionHost): void {}
  static async handle(_filesDir: string, _action: string, _args: string, _requestId: string,
    _start: StartObservedGame): Promise<string> {
    return ''
  }
}
