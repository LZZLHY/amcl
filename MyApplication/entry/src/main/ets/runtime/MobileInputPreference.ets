import { fileIo as fs } from '@kit.CoreFileKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { AppLogger, AtomicFileWriter, LOG_DOMAIN_LAUNCH } from 'commons'
import { ProductInputProfile } from 'entry/ProductInputProfile'

const FILE_NAME: string = 'mobile-input-mode'
const IN_MOVED_TO: number = 0x80
const RETRY_READ_MS: number = 120
type ModeListener = (mode: string) => void

/** 首次使用或升级时缺少文件即为自动；损坏和无权限必须反馈给调用者。 */
function readMode(directory: string): string {
  let value: string
  try { value = fs.readTextSync(directory + '/' + FILE_NAME) }
  catch (error) {
    if ((error as BusinessError).code === 13900002) return 'auto'
    throw error as Error
  }
  if (!MobileInputPreference.valid(value)) throw new Error('已保存的输入方式无效')
  return value
}

/** 同进程多个设置界面和游戏表面共用一个目录监听。每次原子替换后重读文件，以最新已发布值为准。 */
class ModeObservation {
  readonly listeners: Set<ModeListener> = new Set<ModeListener>()
  watcher?: fs.Watcher
  last?: string
  private retryTimer: number = -1

  publish(mode: string): void {
    this.last = mode
    Array.from(this.listeners).forEach((listener: ModeListener): void => {
      if (this.last !== mode || !this.listeners.has(listener)) return
      try { listener(mode) } catch (error) {
        AppLogger.warn('MobileInput', '界面未能接收输入偏好变化', error, LOG_DOMAIN_LAUNCH)
      }
    })
  }

  cancelRetry(): void {
    if (this.retryTimer < 0) return
    clearTimeout(this.retryTimer)
    this.retryTimer = -1
  }

  /** 文件事件或返回前台时先立即读。瞬时失败合并为一次补读，持续失败等下一次明确事件。 */
  refresh(directory: string, allowRetry: boolean = true): void {
    try {
      const mode: string = readMode(directory)
      this.cancelRetry()
      if (this.last !== mode) this.publish(mode)
    } catch (error) {
      AppLogger.warn('MobileInput', '输入偏好暂不可读，保留上次显示', error, LOG_DOMAIN_LAUNCH)
      if (!allowRetry || this.retryTimer >= 0 || this.listeners.size === 0) return
      const timer: number = setTimeout((): void => {
        if (this.retryTimer !== timer || observations.get(directory) !== this) return
        this.retryTimer = -1
        this.refresh(directory, false)
      }, RETRY_READ_MS)
      this.retryTimer = timer
    }
  }
}

const observations: Map<string, ModeObservation> = new Map<string, ModeObservation>()

/** 启动器和独立游戏进程共用这一个私有单值文件。每次完整替换，最后发布的选择生效。 */
export class MobileInputPreference {
  static available(): boolean { return ProductInputProfile.canChooseMobileInput() }

  static valid(value: string): boolean { return value === 'auto' || value === 'gamepad' || value === 'kbm' }

  /** 查询持久值，不使用独立进程的启动偏好快照。 */
  static read(context: Context): string {
    if (!MobileInputPreference.available()) throw new Error('当前设备不支持移动端输入方式')
    return readMode(context.filesDir)
  }

  /** 可见性恢复时只刷新已挂接的界面，不创建新的观察者或轮询。 */
  static reconcile(context: Context): void {
    observations.get(context.filesDir)?.refresh(context.filesDir)
  }

  /** 与启动快照分开保存，独立游戏进程也可写入。只通知原子文件保存后的实际选择。 */
  static save(context: Context, mode: string): void {
    if (!MobileInputPreference.available() || !MobileInputPreference.valid(mode)) throw new Error('不支持的输入方式')
    AtomicFileWriter.write(context.filesDir + '/' + FILE_NAME, mode)
    MobileInputPreference.reconcile(context)
  }

  /** 先监听目录再读初值，覆盖首次创建、原子替换和注册中的并发写；最后一个界面离开即停止监听。 */
  static subscribe(context: Context, listener: ModeListener): () => void {
    if (!MobileInputPreference.available()) throw new Error('当前设备不支持移动端输入方式')
    const directory: string = context.filesDir
    let observation: ModeObservation | undefined = observations.get(directory)
    if (!observation) {
      const created: ModeObservation = new ModeObservation()
      const watcher: fs.Watcher = fs.createWatcher(directory, IN_MOVED_TO, (event): void => {
        if (event.fileName === directory + '/' + FILE_NAME && observations.get(directory) === created) created.refresh(directory)
      })
      try { watcher.start() } catch (error) {
        try { watcher.stop() } catch (_) { /* start未完成时可能没有已启动的监听。 */ }
        throw error as Error
      }
      created.watcher = watcher
      observations.set(directory, created)
      observation = created
    }
    const session: ModeObservation = observation
    // 各次订阅相互独立，即使调用者复用同一个回调也能分别解除。
    const callback: ModeListener = (mode: string): void => listener(mode)
    const unsubscribe = (): void => {
      if (!session.listeners.delete(callback) || session.listeners.size !== 0) return
      observations.delete(directory)
      session.cancelRetry()
      try { session.watcher?.stop() } catch (error) {
        AppLogger.warn('MobileInput', '文件变化监听未确认停止', error, LOG_DOMAIN_LAUNCH)
      }
    }
    session.listeners.add(callback)
    try {
      const mode: string = MobileInputPreference.read(context)
      if (session.last === mode) callback(mode)
      else session.publish(mode)
    } catch (error) {
      unsubscribe()
      throw error as Error
    }
    return unsubscribe
  }
}
