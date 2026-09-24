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
 * ArkTS 侧通过 NAPI 函数 `getCommonJvmArgs()` 获取同一份列表。
 *
 * 清单只包含【和版本 / classpath / 用户设置无关】的"OHOS 兼容性修复参数"，不含：
 *   - -Xmx / -Xms / -XX:TieredStopAtLevel    （主/子进程不同）
 *   - -Djava.home / -Dsun.boot.library.path  （运行时生成）
 *   - -Xbootclasspath/a:.../cacio-*.jar      （运行时生成）
 *   - -Dcacio.font.* / -Dawt.toolkit         （主进程条件启用）
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
