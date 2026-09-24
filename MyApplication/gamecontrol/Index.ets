/**
 * gamecontrol HAR 公共 API 入口（barrel）。
 *
 * 三层架构重构（C 步）：游戏控制域抽成独立 HAR。消费方统一 `import { X } from 'gamecontrol'`。
 * 依赖 commons；native 经 ControlNativeSink 注入解耦（由 entry 注入 testNapi 实现）。
 */

// 控制数据模型 / 常量
export * from './src/main/ets/ControlLayout';
export * from './src/main/ets/GlfwKeys';
export * from './src/main/ets/LayoutPresets';
export * from './src/main/ets/OhosKeyCodes';

// 输入映射 / 手柄 / 输入模式 / 指针
export * from './src/main/ets/KeyMap';
// Phase 3.3：实体键盘 held 的按设备追踪（与 native HeldId{deviceId,key} 同维度）
export * from './src/main/ets/PhysicalHeldKeyTracker';
// Phase 3.3：物理设备能力位 ABI 镜像 + 插拔事件模型
export * from './src/main/ets/InputDeviceAbi';
// Phase 3.3：进程监听幂等、插拔扇出与启动 inventory 的 remove-wins 门禁
export * from './src/main/ets/InputDeviceLifecycleCoordinator';
export * from './src/main/ets/InputSourceRegistry';
export * from './src/main/ets/JoystickSector';
// 提案 D1：物理键鼠端的**纯判定**部件。平台对象仍由 McGamePage 持有，这里只放能在
// 本机 ArkTS 单测里穷举的那部分（与 InputDeviceLifecycleCoordinator 同一种分工）。
export * from './src/main/ets/PhysicalKeyEdge';      // 一次键边沿 → 两个平面的动作码 + ESC 去抖判据
export * from './src/main/ets/WheelChannel';         // 两条滚轮通道的符号约定 + 分格累加 + Pan 入口闸门
export * from './src/main/ets/PhysicalMouseMotion';  // rawDelta 存在性的**唯一**判定（生产与探针共用）
export * from './src/main/ets/GamepadManager';
// ⚠️ `InputModeManager` 已删除（多输入端架构改进提案 D2）。它在 activeMode 被删之后名字
// 已名不副实，且捆着四件互不相关的事。拆成下面三个：
export * from './src/main/ets/InputDeviceMonitor';    // 设备能力 + 带 deviceId 的插拔扇出
export * from './src/main/ets/PhysicalPointerEcho';   // 菜单里区分鼠标镜像触点与真手指
export * from './src/main/ets/ImeActivationGate';     // 输入法激活时禁止 char 回灌
export * from './src/main/ets/PointerVisibilityCoordinator';
export * from './src/main/ets/ProductInputPolicy';
export * from './src/main/ets/ProductRuntimePolicy';
export * from './src/main/ets/InputSurfaceContext';
export * from './src/main/ets/TextInputSessionCoordinator';

// 布局持久化 + Pojav 导入（含 ControlNativeSink 注入接口）
export * from './src/main/ets/LayoutStore';
export * from './src/main/ets/LayoutMerge';
export * from './src/main/ets/PojavImporter';
