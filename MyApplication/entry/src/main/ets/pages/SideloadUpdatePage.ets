/** 旧路由的兼容容器；正常立即更新在原弹窗内完成，此处复用相同内容与业务。 */
import { SideloadUpdateContent } from '../components/SideloadUpdateContent';
import { SideloadUpdatePageParams } from '../sideload/SideloadUpdateViewModel';
import { resolveUpdateDialogLayout, UpdateDialogLayout } from '../components/UpdateDialogLayout';

@Entry
@Component
struct SideloadUpdatePage {
  @State params: SideloadUpdatePageParams = {};
  /** 与正常弹窗共用窗口事实和几何，旧链接进入时也不能退回随内容伸缩的容器。 */
  @StorageProp('screenWidthVp') private windowWidth: number = 360;
  @StorageProp('screenHeightVp') private windowHeight: number = 780;
  @StorageProp('topRectHeight') private topSafe: number = 0;
  @StorageProp('bottomRectHeight') private bottomSafe: number = 0;
  private exitUpdate: () => boolean = (): boolean => true;
  /** 普通方法随视口/避让区重算；避免SDK丢弃struct getter，授权和进度仍不改变外框。 */
  private frame(): UpdateDialogLayout {
    return resolveUpdateDialogLayout(this.windowWidth, this.windowHeight, this.topSafe, this.bottomSafe);
  }
  /** 系统Back是明确退出，先撤销当前Attempt；已派发阶段由内容层拦截。 */
  onBackPress(): boolean { return !this.exitUpdate(); }
  aboutToAppear(): void {
    this.params = (this.getUIContext().getRouter().getParams() as SideloadUpdatePageParams) ?? {};
  }
  build() {
    Column() {
      SideloadUpdateContent({ params: this.params, compact: this.frame().compact,
        onDismiss: (): void => { this.getUIContext().getRouter().back(); },
        onExitGuardReady: (exit: () => boolean): void => { this.exitUpdate = exit; } })
        .width(this.frame().width).height(this.frame().height).borderRadius(20).clip(true)
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
  }
}
