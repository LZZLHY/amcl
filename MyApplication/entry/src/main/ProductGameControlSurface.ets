import { GameControls } from './ets/components/GameControls'
import { DesktopGameControlSurface } from './ets/components/DesktopGameControlSurface'
import { ProductInputProfile } from 'entry/ProductInputProfile'

@Component
export struct ProductGameControlSurface {
  @Prop isGrabbed: boolean = false
  @Prop surfaceContextGeneration: number = 0
  @Prop pageActive: boolean = true
  build() {
    if (ProductInputProfile.current().acceptDirectTouchInGame) {
      GameControls({ isGrabbed: this.isGrabbed, surfaceContextGeneration: this.surfaceContextGeneration })
    } else {
      DesktopGameControlSurface({ isGrabbed: this.isGrabbed,
        surfaceContextGeneration: this.surfaceContextGeneration, pageActive: this.pageActive })
    }
  }
}
