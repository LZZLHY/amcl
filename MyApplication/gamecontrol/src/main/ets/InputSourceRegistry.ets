import { AppLogger } from 'commons';
/**
 * InputSourceRegistry.ets — 输入端注册表：ArkTS 侧的"端"一等概念
 *
 * ============================ 它补的是哪个洞 ============================
 *
 * native 侧早已把"端"提升成类型（cpp/platform/input_source.h：三端平级、端之间不仲裁、
 * 端内通道才仲裁）。ArkTS 侧**没有**对应物，后果是三端的代码归属层次完全不同：
 *
 *   触控虚拟按键端 : UI 组件（GameControls）+ C 层解释器，双层
 *   手柄端         : HAR 里的纯逻辑类（GamepadManager），输出靠 McGamePage 注入 emitter
 *   物理键鼠端     : 散在 McGamePage 的页面方法里 + native core
 *
 * 没有共同接口，直接导致两类结构性缺陷：
 *
 *   1. **复位漏端。** native 的 `cancelAllInput` 只能触达 native 状态；手柄端的按下集合
 *      是 McGamePage 的私有字段，两个 Ability 的 onBackground、GameAbility.onDestroy、
 *      surface 销毁、失焦、窗口重建这六个边界都只调 native cancel，于是 native ledger
 *      已归零而 ArkTS 仍认为按着，随后的抬起发出一个"已被释放过"的 RELEASE 并被静默丢弃。
 *   2. **"当前哪个端在用"没有真相源。** InputModeManager 曾有 `activeMode`，但
 *      `notify('touch')` 全仓没有调用点、唯一读取方 `GameControls.currentInputMode`
 *      又从不被读 —— 一条只写不读、且三端里缺一个生产者的空抽象。
 *
 * ============================ 本文件的契约 ============================
 *
 * · 每个端实现 `InputEnd`，在自己的生命周期起点 register、终点 unregister。
 * · 任何"后续抬起不保证到达"的边界调用 `releaseAllEnds(reason)`，它对**每个已注册的端**
 *   各说一次。端自己负责放掉自己的按下态，native cancel 退化成兜底而不是唯一手段。
 * · 端不做仲裁。三端可以同时产出，那是玩家真的同时在用两种设备（见 input_source.h）。
 *   本注册表只做"清点 + 广播复位"，**不**决定谁有权产出，也**不**记录"当前哪个端"
 *   （那个概念做过两次都是只写不读的空抽象，理由见文件末尾）。
 *
 * ============================ 顺序纪律 ============================
 *
 * 复位边界必须 **先 `releaseAllEnds()`，后 `cancelAllInput()`**。
 * 理由：端自己发出的 RELEASE 需要与它自己的 PRESS 配对才能被 native 接受；若先跑
 * native cancel，ledger 已被清空，随后这些 RELEASE 全部变成无配对边沿被丢弃 ——
 * 聚合结果虽然仍是零，但日志里会出现一批 ownerless 边沿，把真正的失步问题掩盖掉。
 */

import { hilog } from '@kit.PerformanceAnalysisKit'

const TAG = 'InputSourceRegistry'

/**
 * 输入端身份。**必须**与 cpp/platform/input_source.h 的 AmclInputSource 逐值对应：
 * 这些数值会作为 NAPI 参数直接过界，改一边不改另一边会静默错标而不是报错。
 */
export enum AmclInputSource {
  /**
   * 未申报 —— **这是一个告警值**。任何非零的 `untagged` 计数都意味着有调用点还没申报
   * 端身份，应当被追查。不要拿它当"其它"用。
   *
   * ⚠️ 它曾同时承担"平台手势"的含义，导致 `untagged` 分不清"有人漏改"与"用户按了
   * 返回键"，告警能力失效。平台手势现在有自己的 `PlatformGesture`。
   */
  None = 0,
  /** 触控虚拟按键端：屏幕摇杆 / 按钮 / 滚轮条 / 物品栏，手指驱动。 */
  TouchControls = 1,
  /** 手柄端：按钮 / 摇杆 / 扳机 / HAT。 */
  Gamepad = 2,
  /** 物理键鼠端：物理键盘 + 物理鼠标（含滚轮）。 */
  PhysicalKbm = 3,
  /**
   * 平台手势：系统返回键 / 返回手势合成的 ESC 等。
   *
   * **不是第四个"端"** —— 没有配置、没有量纲、不参与 look 漏斗、不参与按端复位遍历
   * （它产出的是 press/release 紧邻的瞬时 tap，不跨帧持有）。它存在的唯一目的是让
   * "这条边沿有正当来源"可表达，从而把 `None` 还原成纯告警值。
   */
  PlatformGesture = 4,
}

export function inputSourceName(source: AmclInputSource): string {
  if (source === AmclInputSource.TouchControls) return 'touchControls'
  if (source === AmclInputSource.Gamepad) return 'gamepad'
  if (source === AmclInputSource.PhysicalKbm) return 'physicalKbm'
  if (source === AmclInputSource.PlatformGesture) return 'platformGesture'
  return 'none'
}

/**
 * 一个输入端。三端各自实现它，注册表只认这个接口。
 *
 * 刻意只有一个动作（releaseAll）：注册表的职责是清点与广播复位，不是代理端的业务。
 * 端内部怎么维护按下集合、经哪条 NAPI 下沉，注册表一概不关心 —— 这样
 * GamepadManager 能继续保持"零 ArkUI 依赖、零 NAPI 依赖"的纯逻辑形态。
 */
export interface InputEnd {
  /** 端身份。同一个 source 允许注册多个实例（例如多个手柄），注册表不去重。 */
  readonly inputSource: AmclInputSource
  /** 日志用的稳定短名，便于在一行里看出是哪个实例漏了复位。 */
  readonly endName: string

  /**
   * **ArkTS 先归零**：放掉本端当前所有按下态，发出的 RELEASE 必须与本端自己的 PRESS 配对。
   * 这是面向用户的完整复位，允许有 UI 副作用（收起抽屉、关闭输入条等）。
   *
   * 用于"ArkTS 侧知道即将失去后续抬起"的边界：页面隐藏/销毁、Ability 切后台/销毁。
   * 必须幂等：同一个边界可能被重复触发（页面隐藏 + Ability 后台会叠加）。
   * @param reason 仅用于日志，不参与判断。
   */
  releaseAllInputs(reason: string): void

  /**
   * **native 先归零**：本端只丢弃自己的按下缓存，不发任何边沿。
   *
   * 与 `releaseAllInputs` 的区别不是"要不要发边沿"这种细节，而是**谁先归零、谁负责发边沿**：
   *   · native 先归零 ⇒ 边沿已经由 native 发完，本端再发就是无配对的空转；
   *   · **本方法必须没有任何面向用户的副作用**。它由 reset-epoch 对账驱动，而对账挂在
   *     每个物理按键事件上 —— 一旦它会收起抽屉/关闭聊天输入条，用户"按一下键盘就
   *     莫名关掉输入框"。这正是本方法被拆出来的直接原因（曾用 releaseAllInputs
   *     顶替它，导致页面创建后第一次按键就清掉 UI 状态）。
   *
   * ⚠️ **"native 已经把 ledger 清空了"这句前提，本接口自己不保证。**
   * 驱动对账的 reset epoch 有两个语义各异的推进点，其中"typed core 观测到自己的 RESET"
   * 那一路**不**清 native 的 external held 与 ledger（详见
   * `dropAllEndStateAfterNativeReset` 上方那段）。所以前提由**注册表**在广播完本方法之后
   * 调按端释放来强制成立，不是由各端假设成立。各端实现**不要**自己去调 native 释放 ——
   * 那会让端级复位计数翻倍，并且把 `GamepadManager` 的零 NAPI 依赖打破。
   *
   * 实现要求：只清"我认为哪些键还按着"这类缓存；不发 GLFW 边沿、不动可见性、
   * 不动 IME/抽屉/toggle 之类用户可见状态。
   * @param reason 仅用于日志，不参与判断。
   */
  dropHeldStateAfterNativeReset(reason: string): void
}

/**
 * 把一个回调包装成 `InputEnd` 的适配器。
 *
 * 为什么需要它而不是直接写对象字面量：ArkTS 的 `arkts-no-untyped-obj-literals` 不允许用
 * 对象字面量去实现**带方法**的接口（属性式函数字段可以，方法不行）。而把
 * `releaseAllInputs` 改成属性式函数又会让 `GamepadManager implements InputEnd` 变得别扭
 * （它本来就是一个方法）。所以接口保持方法形态，需要临时适配的地方用这个类。
 *
 * 典型用法是"某个端的状态住在页面/组件的字段里"，例如物理键鼠端的 held 缓存与触控端
 * 的 ArkTS 兼容态：它们没有独立的类可以 implements，用本适配器把清理动作交进来即可。
 */
export class CallbackInputEnd implements InputEnd {
  readonly inputSource: AmclInputSource
  readonly endName: string
  private onRelease: (reason: string) => void
  private onDropCache: (reason: string) => void

  /**
   * @param onRelease   面向用户的完整释放（可有 UI 副作用）
   * @param onDropCache native 已归零后的纯缓存丢弃（**不得**有 UI 副作用）。
   *                    两者必须分开传入：把同一个函数传两次就会重新引入本类要避免的缺陷。
   */
  constructor(source: AmclInputSource, name: string,
              onRelease: (reason: string) => void,
              onDropCache: (reason: string) => void) {
    this.inputSource = source
    this.endName = name
    this.onRelease = onRelease
    this.onDropCache = onDropCache
  }

  releaseAllInputs(reason: string): void {
    this.onRelease(reason)
  }

  dropHeldStateAfterNativeReset(reason: string): void {
    this.onDropCache(reason)
  }
}

/**
 * native 侧的按端接口。由宿主（entry 模块）注入 —— gamecontrol 是 HAR，
 * 不能直接依赖 entry 的 libentry NAPI，否则这个 HAR 就无法独立于宿主构建。
 *
 * 两个方法都允许缺省：注入方拿不到 native 时传 undefined，注册表退化成纯 ArkTS 广播，
 * 不会因为 native 不可用而让端复位整体失效。
 */
export interface NativeInputSourceSink {
  /** 只释放该端在 native external 表里持有的输出。对应 NAPI releaseSourceHeld。 */
  releaseSourceHeld?: (source: number) => void
  /** 记一笔该端已复位，让端级复位日志三栏都有生产者。对应 NAPI noteSourceReset。 */
  noteSourceReset?: (source: number) => void
}

/**
 * ⚠️ **单例作用域的硬约束（官方文档 A 级证据）**
 *
 * 本文件所在的 `gamecontrol` 是一个 **HAR**。华为官方 FAQ 明确回答过同样的问题：
 * 多个模块使用同一个 HAR 时**会存在多份** —— 每个使用方都会把 HAR 拷贝一份到自己模块，
 * 所以**不能靠 HAR 里的模块级变量在多个模块之间共享实例**，官方给的替代方案是改用 HSP。
 *
 * 当前拓扑下这条约束**没有被触发**：`entry/oh-package.json5` 是唯一声明依赖 gamecontrol
 * 的模块，注册表的全部使用方（McGamePage / GameControls / GameAbility / EntryAbility /
 * GamepadManager）都在 entry 里，因此只有一份拷贝、一个单例。
 *
 * **一旦有第二个模块（feature_core / launch / 任何 HSP）import 本文件，注册表会分裂成
 * 多份**：那个模块注册的端对 entry 里的复位边界不可见，表现为"切后台后某个端卡键"，
 * 而且极难定位。届时必须把承载它的模块改成 HSP（同进程、同包名、编译后只保留一份），
 * 不能靠"反正同进程"来救 —— 同进程只保证共享地址空间，不保证 HAR 模块实例被共享。
 *
 * 同一约束也适用于本 HAR 里其它模块级单例：`getInputDeviceMonitor()`、
 * `getPhysicalPointerEcho()`、`getImeActivationGate()`、`getLayoutStore()`。
 */
class InputSourceRegistryImpl {
  private ends: InputEnd[] = []
  private nativeSink: NativeInputSourceSink | undefined = undefined

  /**
   * 注入 native 接缝。宿主在页面初始化时调一次；重复调用以最后一次为准
   * （页面重建时 NAPI 对象不变，但重新注入是幂等的）。
   */
  setNativeSink(sink: NativeInputSourceSink | undefined): void {
    this.nativeSink = sink
  }

  register(end: InputEnd): void {
    if (this.ends.indexOf(end) >= 0) return
    this.ends.push(end)
    hilog.info(0x0000, TAG, 'end registered source=%{public}s name=%{public}s total=%{public}d',
      inputSourceName(end.inputSource), end.endName, this.ends.length)
  }

  unregister(end: InputEnd): void {
    const idx = this.ends.indexOf(end)
    if (idx < 0) return
    this.ends.splice(idx, 1)
    hilog.info(0x0000, TAG, 'end unregistered source=%{public}s name=%{public}s total=%{public}d',
      inputSourceName(end.inputSource), end.endName, this.ends.length)
  }

  /** 当前注册了几个端。仅诊断用（用来发现"某个端根本没注册上"）。 */
  registeredCount(): number {
    return this.ends.length
  }

  /**
   * 对**每个**已注册端广播复位，再让 native 按端释放各自残留的持有记录。
   *
   * 单端抛异常不得中断其余端 —— 一个端的 bug 不能变成"其它端全部漏放"。
   * 这一条是刻意的：复位路径上"尽量多放"总比"整条链断在第一个异常"安全。
   */
  releaseAllEnds(reason: string): void {
    for (let i = 0; i < this.ends.length; i++) {
      const end = this.ends[i]
      try {
        end.releaseAllInputs(reason)
      } catch (e) {
        AppLogger.error(TAG, `end releaseAll threw source=${inputSourceName(end.inputSource)} name=${end.endName} err=${(e as Error).message}`)
      }
    }
    // native 释放**按端遍历，而不是按已注册实例遍历**。两个理由：
    //   · 某个端此刻没有 ArkTS 实例时，native 的 external 表里仍可能有它的残留记录
    //     （页面已销毁而 NAPI 边沿刚好在途）—— 按实例遍历就漏掉了它；
    //   · 同一个 source 注册了两个实例时（将来的双手柄），按实例遍历会把该端的
    //     复位计数记两次，正是"计数器不可信比没有计数器更糟"要避免的。
    this.notifyNativeResetForAllSources()
    hilog.info(0x0000, TAG, 'releaseAllEnds reason=%{public}s ends=%{public}d',
      reason, this.ends.length)
  }

  /**
   * native 已归零之后，让每个端丢弃自己的按下缓存，**然后把 native 侧可能残留的按端持有
   * 记录也清掉**。仍然**不得有 UI 副作用**。与 `releaseAllEnds` 是两个方向，不能互相顶替。
   *
   * **为什么这里必须补一次 native 按端释放**（完整因果与真机证据见 `输入架构规范.md` §3.3）：
   * 驱动本方法的 reset epoch 有**两个语义** —— (i) typed core 只清自己的 held owner；
   * (ii) 完整 `ohos_cancel_all_input` 清全部平面。而 surface 几何变化只产生 (i)、**没有**
   * cancel 配对（2026-08-21 平板实测：两次 `Surface changed:` 各跟一次本方法，全程零
   * `Input cancelAll`）。所以"native 已经归零了"是**假前提**，代价是一个用户可感知的卡键
   * （键在 MC 侧恒为按下且此后按它无反应）。本方法**强制**该前提成立，而不是假设它成立。
   *
   * 三条安全性依据，缺一条就不能放在这条禁止副作用的路径上（都是 A 级，§3.3 有论证）：
   * **幂等**（(ii) 下 `DrainSource` 返回空 ⇒ no-op，不产生 ownerless 边沿）、
   * **无 UI 副作用**（只到 ledger → `sendEvent`，触达不到任何 ArkTS 状态）、
   * **不越端不跨 owner 域**（grabbed 下的 schema owner 直接进 ledger、不经 external 表）。
   *
   * 频率不是问题：只在 epoch **变化时**才广播，一次会话个位数 —— 所以走按端释放原语，
   * 而不是各端的 `releaseAll()`（后者才是 `GamepadManager` 那句注释担心的东西）。
   */
  dropAllEndStateAfterNativeReset(reason: string): void {
    for (let i = 0; i < this.ends.length; i++) {
      const end = this.ends[i]
      try {
        end.dropHeldStateAfterNativeReset(reason)
      } catch (e) {
        AppLogger.error(TAG, `end dropState threw source=${inputSourceName(end.inputSource)} name=${end.endName} err=${(e as Error).message}`)
      }
    }
    // 按端遍历而不是按已注册实例遍历，理由与 releaseAllEnds 里那段相同。
    this.releaseNativeHeldForAllSources()
    hilog.info(0x0000, TAG, 'dropAllEndState reason=%{public}s ends=%{public}d',
      reason, this.ends.length)
  }

  /**
   * 只复位一个端。设备插拔用它：拔掉一个手柄不应该连带放掉屏幕虚拟按键的按下态
   * （旧实现只有全局 releaseAll，那正是"拔键盘也会误放手柄"的根因）。
   */
  releaseEndsOfSource(source: AmclInputSource, reason: string): void {
    let touched = 0
    for (let i = 0; i < this.ends.length; i++) {
      const end = this.ends[i]
      if (end.inputSource !== source) continue
      touched++
      try {
        end.releaseAllInputs(reason)
      } catch (e) {
        AppLogger.error(TAG, `end releaseAll threw source=${inputSourceName(source)} name=${end.endName} err=${(e as Error).message}`)
      }
    }
    this.notifyNativeReset(source)
    hilog.info(0x0000, TAG, 'releaseEndsOfSource source=%{public}s reason=%{public}s ends=%{public}d',
      inputSourceName(source), reason, touched)
  }

  /**
   * 对三个真实端各释放一次 native 持有记录。
   *
   * 刻意**不**包含 `PlatformGesture`（瞬时 tap，press/release 紧邻发出、不跨帧持有）
   * 与 `None`（告警值，不该有正常生产者；真的出现残留记录时由全局 cancel 兜底）。
   * 把它们卷进全端复位只会让复位计数失真，而复位计数是判断"哪个端漏了复位"的唯一依据。
   */
  private notifyNativeResetForAllSources(): void {
    this.notifyNativeReset(AmclInputSource.TouchControls)
    this.notifyNativeReset(AmclInputSource.Gamepad)
    this.notifyNativeReset(AmclInputSource.PhysicalKbm)
  }

  /**
   * 只做**按端释放**，刻意**不记复位账**。给 `dropAllEndStateAfterNativeReset` 用。
   *
   * 与 `notifyNativeResetForAllSources` 的唯一差别就是少了 `noteSourceReset`，而这个差别
   * 是承重的：端级复位计数（`AMCL_INSRC` 的 `resets` 三栏）的语义是"这个端被复位过几次"，
   * 而本路径是 native 已经复位之后的**对账**，不是一次新的复位。两处都记会让计数翻倍，
   * 那正是 `ohos_release_input_source_held` 自己注释里警告的事（它也刻意不 note）——
   * 一个数值不可信的计数器比没有计数器更糟。
   *
   * 端身份集合与 `notifyNativeResetForAllSources` 保持一致（三个真实端，不含
   * `PlatformGesture` 与 `None`），理由见那个方法上方的说明。
   */
  private releaseNativeHeldForAllSources(): void {
    this.releaseNativeHeld(AmclInputSource.TouchControls)
    this.releaseNativeHeld(AmclInputSource.Gamepad)
    this.releaseNativeHeld(AmclInputSource.PhysicalKbm)
  }

  /**
   * native 侧的按端释放 + 记账。
   *
   * 即使该端在 ArkTS 侧没有注册实例也要调 releaseSourceHeld：native external 表里
   * 可能仍有该端的残留持有记录（例如页面已销毁但 NAPI 边沿刚好在途）。
   */
  private notifyNativeReset(source: AmclInputSource): void {
    this.releaseNativeHeld(source)
    const sink = this.nativeSink
    if (!sink) return
    const note = sink.noteSourceReset
    if (note) {
      try { note(source as number) } catch (e) { /* 记账失败不影响复位本身 */ }
    }
  }

  /**
   * 按端释放 native 持有记录。两条复位方向共用的原语。
   *
   * native 不可用（老版本 .so / NAPI 未注入）时静默降级为纯 ArkTS 行为 —— 这条降级的
   * 代价是本轮修复失效、卡键缺陷回到修复前的状态，不会引入新的失效模式。
   */
  private releaseNativeHeld(source: AmclInputSource): void {
    const sink = this.nativeSink
    if (!sink) return
    const release = sink.releaseSourceHeld
    if (!release) return
    try { release(source as number) } catch (e) { /* native 不可用时保持纯 ArkTS 行为 */ }
  }

  // ⚠️ 这里曾有 `noteActivity` / `lastActiveSource` / `lastActivityAtMs` /
  // `addActivityListener` / `removeActivityListener` 一组"最近活跃的是哪个端"。
  // **已删除，且不要再加回来，除非同时提交它的消费者。**
  //
  // 它是在删掉 InputModeManager.activeMode（一条只写不读的链路）的同一轮里加进来的，
  // 而它自己**同样没有任何读取方** —— 12 个写入点（含 onMouse Move 热路径上的
  // `Date.now()`），0 个读取点。也就是说那一轮只是把同一个空抽象换了个位置，
  // 还顺带在每个鼠标样本上加了一次时间戳开销。
  //
  // 判据写在这里，供将来真的要做"输入源小图标"时参考：**先有消费者，再有生产者。**
  // 需要它的时候，注册表确实是正确的落点（三端都在这里注册），但那时应当一次性提交
  // 读取方；只加生产者的版本已经失败过两次。
}

let registry: InputSourceRegistryImpl | undefined = undefined

/** 进程内单例。三端与所有复位边界都经它。 */
export function getInputSourceRegistry(): InputSourceRegistryImpl {
  if (!registry) registry = new InputSourceRegistryImpl()
  return registry
}

export type InputSourceRegistryType = InputSourceRegistryImpl
