/**
 * 校准陀螺仪的纯积分器。平台角速度为rad/s，时间戳为开机后的ns；不使用UI回调次数估算运动。
 * 首样本、转屏和长间隔只重建基线，不能把后台积累或旧方向的差分注入新相机。
 * 输出是虚拟位移，之后只应用一次公共灵敏度；不承诺在不同Minecraft灵敏度下物理角度1:1。
 */
export class TouchGyroscopeDelta {
  dx: number = 0
  dy: number = 0
  timeNs: number = 0
}

export class TouchGyroscopeIntegrator {
  private lastNs: number = 0
  private lastX: number = 0
  private lastY: number = 0
  private rotation: number = -1

  /** 传感器订阅退休/配置变更时清基线，不保留待输出尾量。 */
  reset(): void {
    this.lastNs=0; this.lastX=0; this.lastY=0; this.rotation=-1
  }

  /**
   * 梯形积分减少不同合法采样周期下的差异；无效/逆序样本不推进时间。
   * rotation采用显示系统0..3四个方向，灵敏度为用户明确配置的倍率。
   */
  sample(x: number, y: number, timeNs: number, rotation: number, sensitivity: number,
    invertX: boolean, invertY: boolean): TouchGyroscopeDelta | undefined {
    if (!Number.isFinite(x) || !Number.isFinite(y) || Math.abs(x)>64 || Math.abs(y)>64
      || !Number.isFinite(timeNs) || timeNs<=0 || timeNs>=9223372036854775808
      || !Number.isInteger(rotation) || rotation<0 || rotation>3
      || !Number.isFinite(sensitivity) || sensitivity<0.1 || sensitivity>3) return undefined
    if (this.lastNs>0 && timeNs<=this.lastNs) return undefined
    const elapsed: number = (timeNs-this.lastNs)/1000000000
    const reset: boolean = this.lastNs===0 || rotation!==this.rotation || elapsed>0.1
    const pitch: number = (x+this.lastX)*0.5*elapsed
    const yaw: number = (y+this.lastY)*0.5*elapsed
    this.lastNs=timeNs; this.lastX=x; this.lastY=y; this.rotation=rotation
    if (reset) return undefined
    let horizontal: number = -yaw
    let vertical: number = -pitch
    if (rotation===1) { horizontal=-pitch; vertical=yaw }
    else if (rotation===2) { horizontal=yaw; vertical=pitch }
    else if (rotation===3) { horizontal=pitch; vertical=-yaw }
    const result = new TouchGyroscopeDelta()
    // 360 virtual units/rad是独立的交互增益基准；游戏自身设置及公共灵敏度仍会影响最终视角。
    result.dx=horizontal*360*sensitivity*(invertX ? -1 : 1)
    result.dy=vertical*360*sensitivity*(invertY ? -1 : 1)
    result.timeNs=timeNs
    return result
  }
}
