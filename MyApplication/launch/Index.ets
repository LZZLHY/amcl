/**
 * launch HAR 公共 API 入口（barrel）。
 * 三层架构 C 步：启动域。依赖 commons + feature_core + account + mods；native 经 LaunchNativeBridge 注入。
 */
export * from './src/main/ets/LaunchNativeBridge';
export * from './src/main/ets/LaunchCoordinator';
export * from './src/main/ets/LaunchProfileBuilder';
export * from './src/main/ets/PreLaunchValidator';
export * from './src/main/ets/JdkManager';
export * from './src/main/ets/JdkInstaller';
// 已装 JDK 与期望版本的关系判定（纯函数）。分级取舍与「harmfulTags 不许滥用」的理由写在文件开头；
// 判定钉子在 entry/src/test/JdkUpdatePolicy.test.ets。
export * from './src/main/ets/JdkUpdatePolicy';
// 从本地压缩包导入 JDK（离线 / 用户自带）。⚠️ 不变量：导入成功 ⇒ isInstalled 必须为真，
// 所以它的结构校验逐项复现 isInstalled 的 probe 列表（两处注释互相指名对方）。
export * from './src/main/ets/JdkImporter';
export * from './src/main/ets/JdkInstallTask';
export * from './src/main/ets/RuntimeDeployer';
export * from './src/main/ets/GameCompatibility';
export * from './src/main/ets/LwjglModernSlot';
// Old names are derived OpenGL compatibility views of the canonical graphics registry.
export { RENDERER_BACKENDS, RENDERER_BACKEND_DEFAULT_ID, RendererBackendSpec,
  rendererBackendById, userSelectableRendererBackends } from './src/main/ets/RendererBackendRegistry';
export * from './src/main/ets/RendererBackendResolver';
export * from './src/main/ets/GraphicsBackendPlan';
export * from './src/main/ets/GraphicsCapabilityContract';
export * from './src/main/ets/DeviceGraphicsFacts';
export * from './src/main/ets/GraphicsGameFacts';
// Minecraft 偏好和 API 参数只消费真实版本与 canonical 图形元数据。
export * from './src/main/ets/MinecraftGraphicsPreference';
export * from './src/main/ets/GraphicsProfileRegistry';
export * from './src/main/ets/GraphicsProfileResolver';
export { GraphicsHistoryHint } from './src/main/ets/GraphicsSelectionTypes';
// 加载器世代注册表（唯一事实源）。契约见 docs/refactor/启动世代契约规范.md。
// ⚠️ 只有数据与类型，判定规则在 LoaderGenerationResolver；静态门禁是
// scripts/check-launch-generation-contract.mjs。
export * from './src/main/ets/LoaderGenerationRegistry';
// 世代判定（纯函数，mainClass 精确匹配）。判定钉子在
// entry/src/test/LoaderGenerationContract.test.ets。
// ⚠️ 契约表就是全部策略 —— 改行为只改 LOADER_GENERATION_CONTRACTS，不要在调用点加特例。
export * from './src/main/ets/LoaderGenerationResolver';
// 启动契约校验（纯函数）。⚠️ 它是三层防线里的第 ② 层，看不到 java.class.path 的实际值；
// 唯一能否证实际值的是 AmclLauncher.verifyClasspathDelivery（第 ③ 层）。
export * from './src/main/ets/LaunchContractPreflight';
// C0 探针的 ArkTS 半边（纯函数）。**默认关**；开关是 -Damcl.agentProbe=1。
// 门禁 scripts/check-launch-agent-probe.mjs 断言默认值与两侧 marker 字面量一致。
export * from './src/main/ets/LaunchAgentProbe';
export * from './src/main/ets/RuntimeSlotGenerations';
export { verifyLwjglRuntimeSlot, verifyLwjglRuntimeSlotSync } from './src/main/ets/LwjglSlotIntegrity';
// ASM 版本 → 它能读到的最高 Java class file 版本（上游权威小表 + 纯查表）。
// ⚠️ 只有数据与查表，没有策略；"哪个 Forge 带哪个 ASM"**不在这里**，那是逐版本实读的。
export * from './src/main/ets/AsmJavaSupport';
// JDK 选择策略（纯函数）。⭐ **JDK 路由与 Phase 0 自检共用同一个 JdkRange** ——
// 区间内任何已装 JDK 都能启动，纪元理想只是推荐；把"推荐"当"唯一"会拦掉合法组合。
// 判定钉子在 entry/src/test/LaunchJdkPolicy.test.ets（含真机路线的等价矩阵）。
export * from './src/main/ets/LaunchJdkPolicy';
export * from './src/main/ets/McErrorClassifier';
export * from './src/main/ets/SessionMarker';
export * from './src/main/ets/SessionOutcomeResolver';
export * from './src/main/ets/JvmExitEvidence';
