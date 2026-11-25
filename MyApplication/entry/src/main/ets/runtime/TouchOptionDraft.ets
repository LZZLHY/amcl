import { TouchConfiguration, normalizeTouchPreferences, TOUCH_ACTION_NAMES } from 'gamecontrol';

/** 共用触控草稿构造器。两种入口均由宿主持有撤销与保存。 */
export function touchFlagDraft(current: TouchConfiguration, name: string, enabled: boolean): TouchConfiguration | undefined {
    const next: TouchConfiguration = normalizeTouchPreferences(current) ?? new TouchConfiguration()
    switch (name) {
      case 'scroll': next.menuTwoFingerScroll=enabled; break
      case 'sprint': next.joystickSprint=enabled; break
      case 'bindings': next.followGameBindings=enabled; break
      case 'swap': next.hotbarSwapDoubleTap=enabled; break
      case 'drop': next.hotbarDropHold=enabled; break
      case 'gyroX': next.gyroscopeInvertX=enabled; break
      case 'gyroY': next.gyroscopeInvertY=enabled; break
      default: return undefined
    }
    return next
}

export function touchNumberDraft(current: TouchConfiguration, name: string, value: number): TouchConfiguration | undefined {
    const next: TouchConfiguration = normalizeTouchPreferences(current) ?? new TouchConfiguration()
    if (name === 'menuSpeed') next.menuSensitivity=value/100
    else if (name === 'menuHold') next.menuHoldMs=value
    else if (name === 'sprint') next.joystickSprintThreshold=value/100
    else if (name === 'hold') next.holdMs=value
    else if (name === 'gyro') next.gyroscopeSensitivity=value/100
    else return undefined
    return next
}

export function touchBindingDraft(current: TouchConfiguration, index: number, unbind: boolean): TouchConfiguration | undefined {
    const next: TouchConfiguration = normalizeTouchPreferences(current) ?? new TouchConfiguration()
    const overrides: Record<string,number> = {}
    for (const name of Object.keys(next.actionOverrides)) {
      if (name !== TOUCH_ACTION_NAMES[index]) overrides[name] = next.actionOverrides[name]
    }
    if (unbind) overrides[TOUCH_ACTION_NAMES[index]] = 0
    next.actionOverrides = overrides
    return next
}

export function touchChoiceDraft(current: TouchConfiguration, name: string,value: string): TouchConfiguration | undefined {
    const next: TouchConfiguration=normalizeTouchPreferences(current) ?? new TouchConfiguration()
    if(name==='menu') next.menuMode=value==='direct' ? 'direct' : 'touchpad'
    else if(name==='joystick') next.joystickCenter=value==='fixed' ? 'fixed' : 'floating'
    else if(name==='gyro') next.gyroscopeMode=value==='aim' ? 'aim' : value==='always' ? 'always' : 'off'
    else return undefined
    return next
}
