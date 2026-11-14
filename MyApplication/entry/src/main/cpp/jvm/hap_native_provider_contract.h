#pragma once

#include <algorithm>
#include <string>
#include <utility>
#include <vector>

namespace amcl::jvm {
/**
 * 从当前 libentry 自身映像的位置取得 HAP 原生目录。生产调用者必须把 dladdr 的真实
 * dli_fname 交进来，不能传入游戏目录、JDK 目录或用户 JVM 参数。这里只识别平台已使用
 * 的三个 bundle 挂载位置；不按“哪个目录存在”猜测，也不回退到可写 filesDir 邻近目录。
 * 这是平台已装包的路径归属证明，不宣称字符串检查本身完成了签名或 ELF 身份验证。
 */
inline bool HapNativeDirectoryFromOwner(const std::string& owner,
    std::string& directory, std::string& error) {
    for (const char* candidate : {"/data/storage/el1/bundle/libs/arm64",
            "/data/storage/el1/bundle/libs/arm64-v8a", "/data/storage/el1/bundle/libs"}) {
        if (owner == std::string(candidate) + "/libentry.so") {
            directory = candidate;
            return true;
        }
    }
    error = "hap_native_owner_not_in_installed_bundle";
    return false;
}

/**
 * 完整产品随 HAP 提供的外部 C ABI 库。它们不是 Maven 平台 natives 的同一份字节，
 * 不应让 LWJGL 用上游 Linux SHA1 判断兼容；来源、ELF 和导出面由成品门验证。生成
 * JNI 模块不在此列，继续使用原有槽位、native hash 和 JNI surface 契约。
 */
inline const std::vector<std::string>& HapExternalProviderArtifacts() {
    static const std::vector<std::string> artifacts{
        "libglfw.so", "libopenal.so", "libSDL3.so", "libfreetype.so",
        "libshaderc.so", "libspirv-cross.so", "libamcl_vulkan_wsi.so"};
    return artifacts;
}

/**
 * 在 JVM/agent 创建前核目录内的实际普通文件；模板注入仅服务宿主回归，生产使用 stat。
 * 不 dlopen、不初始化 provider，不提前建立另一套图形/音频对象域。失败保留具名制品，
 * 由原启动失败路径结束本次会话，不用 JDK 中的同名库补足 HAP。
 */
template <typename IsRegularFile>
inline bool CheckHapExternalProviderFiles(const std::string& directory,
    IsRegularFile isRegularFile, std::string& error) {
    for (const auto& artifact : HapExternalProviderArtifacts()) {
        if (!isRegularFile(directory + "/" + artifact)) {
            error = "hap_native_provider_missing:" + artifact;
            return false;
        }
    }
    return true;
}

/** 一条由平台拥有的外部库路由及此前公开接受的库名；这些别名只映射同一个 HAP 文件。 */
struct HapProviderAlias {
    const char* key;
    const char* artifact;
    const char* oldValue;
};

inline const std::vector<HapProviderAlias>& HapOwnedProviderAliases() {
    static const std::vector<HapProviderAlias> aliases{
        {"org.lwjgl.glfw.libname", "libglfw.so", "libglfw.so"},
        {"org.lwjgl.sdl.libname", "libSDL3.so", "libSDL3.so"},
        {"org.lwjgl.freetype.libname", "libfreetype.so", "libfreetype.so"},
        {"org.lwjgl.vulkan.libname", "libamcl_vulkan_wsi.so", "libamcl_vulkan_wsi.so"},
        {"org.lwjgl.shaderc.libname", "libshaderc.so", "shaderc"},
        {"org.lwjgl.spvc.libname", "libspirv-cross.so", "spirv-cross"}};
    return aliases;
}

/** 提取显式系统属性；裸 -Dkey 与 -Dkey= 都保留为空串，不误当作没有用户选择。 */
inline bool ReadProviderArgument(const std::string& argument, const std::string& key,
    std::string& value) {
    const std::string prefix = "-D" + key;
    if (argument == prefix) { value.clear(); return true; }
    if (argument.compare(0, prefix.size() + 1, prefix + "=") != 0) return false;
    value = argument.substr(prefix.size() + 1);
    return true;
}

/**
 * 将旧的宿主等值别名规范为当前 HAP 绝对路径，然后交给既有 FreezeBootstrapProperties
 * 检查冲突。仅精确旧值可转换，别的绝对路径、空值或新库名不被悄悄替换。
 *
 * OpenAL 原本允许高级用户指定自定义库，保持 JVM 最后一个 -D 生效的语义：无显式选择
 * 或明确默认名使用 HAP 库，其他值（包括 none 和空串）保留且不计入宿主发行资格。
 * Shaderc 子入口默认复用 Shaderc::getLibrary，不新增四次库加载；只有显式子入口才要求
 * 与固定的主 provider 等值。所有检查通过后才提交两个向量，拒绝时没有半规范化状态。
 */
inline bool NormalizeHapProviderArguments(std::vector<std::string>& arguments,
    std::vector<std::pair<std::string, std::string>>& properties,
    const std::string& nativeDir, bool& customOpenAl, std::string& error) {
    auto nextArguments = arguments;
    auto nextProperties = properties;
    for (auto& argument : nextArguments) {
        for (const auto& alias : HapOwnedProviderAliases()) {
            std::string value;
            if (ReadProviderArgument(argument, alias.key, value) && value == alias.oldValue)
                argument = std::string("-D") + alias.key + "=" + nativeDir + "/" + alias.artifact;
        }
    }

    const std::string openAlKey = "org.lwjgl.openal.libname";
    const std::string openAlPath = nativeDir + "/libopenal.so";
    bool selected = false;
    std::string selectedValue;
    for (const auto& argument : arguments) {
        std::string value;
        if (ReadProviderArgument(argument, openAlKey, value)) { selected = true; selectedValue = value; }
    }
    const bool custom = selected && selectedValue != "libopenal.so" &&
        selectedValue != "openal" && selectedValue != openAlPath;
    if (custom) {
        nextProperties.erase(std::remove_if(nextProperties.begin(), nextProperties.end(),
            [&](const auto& item) { return item.first == openAlKey; }), nextProperties.end());
    } else {
        // 最后一次明确选择默认值时也清除前面的同键选择；保留 JVM 原来的最后值语义。
        nextArguments.erase(std::remove_if(nextArguments.begin(), nextArguments.end(),
            [&](const auto& arg) { std::string value; return ReadProviderArgument(arg, openAlKey, value); }), nextArguments.end());
    }

    for (const char* key : {"org.lwjgl.shaderc.glslang.libname",
            "org.lwjgl.shaderc.glslang_resource.libname", "org.lwjgl.shaderc.spirv_tools.libname",
            "org.lwjgl.shaderc.spirv_tools_optimizer.libname"}) {
        bool present = false;
        const std::string expected = nativeDir + "/libshaderc.so";
        for (auto& argument : nextArguments) {
            std::string value;
            if (!ReadProviderArgument(argument, key, value)) continue;
            if (value != "shaderc" && value != "libshaderc.so" && value != expected) {
                error = std::string("runtime_property_conflict:") + key;
                return false;
            }
            argument = std::string("-D") + key + "=" + expected;
            present = true;
        }
        if (present) {
            const auto existing = std::find_if(nextProperties.begin(), nextProperties.end(),
                [key](const auto& property) { return property.first == key; });
            if (existing == nextProperties.end()) nextProperties.emplace_back(key, expected);
            else if (existing->second != expected) {
                error = std::string("runtime_property_conflict:") + key;
                return false;
            }
        }
    }
    arguments.swap(nextArguments);
    properties.swap(nextProperties);
    customOpenAl = custom;
    return true;
}
}
