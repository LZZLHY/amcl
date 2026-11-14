/** 宿主字体配置独立于用户 JDK 载荷；冷启动/processor 都可按同一内容身份准备。 */
#pragma once
#include <string>
namespace amcl::jdk {
/** 返回完整内容地址路径。既存同名字节不匹配立即失败，绝不截断活跃进程正在读取的文件。
 * 失败原因通过 error 返回；函数不改变 JAVA_HOME、FONTCONFIG_FILE 或其他进程全局状态。 */
bool PrepareFontResources(const std::string &filesDir, std::string &fontsConf, std::string &jdk8Properties,
                          std::string &error);
} // namespace amcl::jdk
