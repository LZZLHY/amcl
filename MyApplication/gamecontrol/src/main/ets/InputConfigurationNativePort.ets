/**
 * 输入配置的进程平台端口注册。entry 持有 Native 实现，HAR 只借用其已注册端口。
 * 注册不会应用配置；只有活跃游戏会话的 InputConfigurationRuntime 可以发起应用。
 * 此处仍保留原全来源 look 原子调用，尚未把历史用户参数迁移为独立来源政策。
 */
import { LookConfiguration } from './InputConfiguration'
import { LookPolicySource } from './LookPreferences'

/** 平台一次接受完整 look 参数；false 表示未应用，不得用多个 void 调用伪装成原子成功。 */
export interface ControlNativeSink {
  applyLookConfiguration(config: LookConfiguration): boolean
  /** 仅支持显式来源政策的端口提供；缺席保持该域待应用，不能回退全来源写入。 */
  applySourceLookConfiguration?(source: LookPolicySource, config: LookConfiguration): boolean
}

/** 一个进程端口绑定快照；generation 只标识端口注册变化，不代替会话、Surface 或配置修订。 */
export class InputConfigurationNativeBinding {
  readonly generation: number
  readonly sink: ControlNativeSink | null
  constructor(generation: number, sink: ControlNativeSink | null) {
    this.generation = generation; this.sink = sink
  }
}

/** 会话依赖受限的端口读取能力；测试可注入同等合同，不需加载 libentry.so。 */
export interface InputConfigurationNativePort {
  binding(): InputConfigurationNativeBinding
}

let registeredSink: ControlNativeSink | null = null
let registeredGeneration: number = 0

/** entry 在进程准备时安装/卸载端口；每次注册使旧应用回执失效，但不推进任何输入输出。 */
export function setControlNativeSink(sink: ControlNativeSink | null): void {
  registeredSink = sink
  registeredGeneration++
}

/** 默认进程端口读适配器；各会话的运行对象保留自己的应用与失败状态。 */
export class RegisteredInputConfigurationNativePort implements InputConfigurationNativePort {
  binding(): InputConfigurationNativeBinding {
    return new InputConfigurationNativeBinding(registeredGeneration, registeredSink)
  }
}
