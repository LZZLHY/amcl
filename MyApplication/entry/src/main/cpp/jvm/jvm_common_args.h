/**
 * jvm_common_args.h — AMCL 所有 JVM 消费者共享的 JVM 参数清单（Single Source of Truth）
 *
 * 背景（ROADMAP.md P0-2）：
 *   JVM 参数曾经分散在 3 个位置：
 *     1. jvm_launcher.cpp      —— 主进程 JVM（MC 主进程）
 *     2. fork_run_java.cpp     —— 子进程 JVM（Forge installer）
 *     3. LaunchProfileBuilder.ets —— 对 version.json 去重的黑名单
 *   三处字面量高度重复，改一处忘改另两处就会产生参数冲突 / 去重失效。
 *
 * 本文件是唯一权威清单。所有消费者通过 amcl::getCommonJvmArgs() 获取。
 * ArkTS 侧通过 NAPI 函数 `getCommonJvmArgs()` 获取同一份列表用于去重。
 * 列表保留旧包的UsePerfData/Attach保守默认，不等于每个运行包的最终effective参数：
 * jvmInit仅对实际只读libjvm合同支持的包省略这两条自动项，平台可用性仍以目标验证为准。
 * 清单/用户显式同名参数保持来源和末项覆盖顺序，不能因条件默认去重而被删除。
 *
 * 清单集中维护共享默认及明确的旧包兼容项；不直接装配以下运行时参数：
 *   - CF自动编译规避（jvmInit按真实release major决定，显式来源原样保留）
 *   - -Xmx / -Xms / -XX:TieredStopAtLevel    （主/子进程不同）
 *   - -Djava.home / -Dsun.boot.library.path  （运行时生成）
 *   - 与 classpath 相关的 -Xbootclasspath/a:... （共享清单不装配 Cacio 运行体）
 *   - AWT 工具包或字体的运行参数            （当前启动默认使用标准 headless 路径）
 *   - -Djava.system.class.loader=AmclClassLoader  （仅主进程）
 *   - -Dlog4j2.formatMsgNoLookups / -Dorg.lwjgl.glfw.checkThread0  （仅主进程）
 *   - -Dsun.java2d.fontpath                  （仅 installer 子进程）
 */
#pragma once

#include <string>
#include <vector>

namespace amcl {

/**
 * 获取共享的 JVM 参数列表（主进程 JVM + Forge installer 子进程 JVM 通用）。
 *
 * 返回值是静态 vector 的常量引用，调用者不需要释放。
 * 线程安全（C++11 及以上的 function-local static）。
 */
const std::vector<std::string>& getCommonJvmArgs();

} // namespace amcl
