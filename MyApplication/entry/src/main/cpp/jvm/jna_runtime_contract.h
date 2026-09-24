#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace amcl::jvm {
/**
 * 本次 JNA 早读属性。默认交回 JNA 自带 native，不把“未发现/未能证明”解释为协议 7。
 * selected 表示从真实 Version.class 证明且包内制品存在；deferred 不等于已验证 OHOS 兼容。
 */
struct JnaBootstrap {
    bool ok = true;
    std::string bootLibraryName = "jnidispatch";
    std::string bootLibraryPath;
    std::string protocol;
    std::string mode = "deferred";
    std::string reason = "jna_not_identified";
    std::string sourceJar;
    std::string requiredArtifact;
};

/** 从有界 class 字节读取声明的 String 常量，不执行类；失败保留具体 reason。 */
bool ReadJnaNativeVersion(const std::vector<uint8_t>& bytes, std::string& version, std::string& reason);
/** 只读一个 ZIP 中的唯一 Version.class，验证头、范围、CRC；不提取任何磁盘条目。 */
bool ReadJnaVersionFromJar(const std::string& path, std::string& version, std::string& reason);
/** 根据已经证明的 native 协议选 ABI 槽；未知 major/minor 返回 deferred，不猜 Java 包版本。 */
JnaBootstrap SelectJnaBootstrap(const std::string& protocol, const std::string& nativeDir);
/**
 * 消费 ArkTS 已合并/去重的最终游戏 classpath。只考虑明确 JNA 文件名；重复候选保守
 * deferred，避免预测第三方 ClassLoader 的阴影规则。没有模组扫描、类加载或文件写入。
 */
JnaBootstrap ResolveJnaBootstrap(const std::string& classpath, const std::string& nativeDir);
}
