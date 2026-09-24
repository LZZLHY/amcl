import { common } from '@kit.AbilityKit'
import { ProductInputProfile } from 'entry/ProductInputProfile'
import { MobileGameWindowCoordinator } from './ets/window/MobileGameWindowCoordinator'
import { DesktopGameWindowCoordinator } from './ets/window/DesktopGameWindowCoordinator'
import { GameWindowSnapshot } from './ets/window/GameWindowSnapshot'
export { GameWindowSnapshot as ProductGameWindowSnapshot } from './ets/window/GameWindowSnapshot'

export class ProductGameWindowCoordinator {
  private coordinator: MobileGameWindowCoordinator | DesktopGameWindowCoordinator =
    ProductInputProfile.selection().desktopWindow
      ? new DesktopGameWindowCoordinator() : new MobileGameWindowCoordinator()
  enter(context: common.UIAbilityContext): Promise<GameWindowSnapshot> { return this.coordinator.enter(context) }
  restore(): Promise<void> { return this.coordinator.restore() }
  snapshot(): GameWindowSnapshot { return this.coordinator.snapshot() }
}
