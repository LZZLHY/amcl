#include "jdk_font_resources.h"
#include "jdk_install_io.h"
#include <cstdlib>

namespace amcl::jdk {
namespace {
#include "jdk_font_resources.inc"
/** Fontconfig的cachedir不支持按配置文件解析relative前缀，必须嵌入已验证宿主目录的
 * 绝对路径。这里转义的是XML文本节点：中文UTF-8保持原字节，实体和换行不可改变路径。
 * 文件系统允许但XML 1.0无法表达的控制字符明确拒绝，不能发布无法解析的配置。
 */
std::string XmlPath(const std::string &path) {
    std::string escaped;
    escaped.reserve(path.size());
    for (unsigned char value : path) {
        switch (value) {
        case '&': escaped += "&amp;"; break;
        case '<': escaped += "&lt;"; break;
        case '>': escaped += "&gt;"; break;
        case '"': escaped += "&quot;"; break;
        case '\'': escaped += "&apos;"; break;
        case '\t': escaped += "&#x9;"; break;
        case '\n': escaped += "&#xA;"; break;
        case '\r': escaped += "&#xD;"; break;
        default:
            io::Require(value >= 0x20, "宿主字体缓存路径包含XML无法表达的控制字符");
            escaped.push_back(static_cast<char>(value));
        }
    }
    return escaped;
}

/** 模板只能有一个明确替换点；实际文件身份由展开后的完整正文决定，不能沿用模板SHA。
 * 所有调用者都走同一Native接口，未展开的rawfile模板不会直接作为FONTCONFIG_FILE发布。
 */
std::string ExpandFontsConf(const std::string &cachePath) {
    std::string text(reinterpret_cast<const char *>(kFontsConf), sizeof(kFontsConf));
    const std::string token(kFontsConfCacheToken);
    const auto at = text.find(token);
    io::Require(at != std::string::npos && text.find(token, at + token.size()) == std::string::npos,
                "宿主字体配置模板必须包含唯一缓存目录占位符");
    text.replace(at, token.size(), XmlPath(cachePath));
    return text;
}
/** 持有 runtime-fonts 目录 flock 时的原子发布：同 hash 文件供独立进程复用。
 * 临时文件和目标在同一目录，真实设备禁止 hardlink，因此使用 renameat；所有
 * 合作发布者均由调用者的排他锁串行化，已存在目标必须验明原文，不能覆盖损坏。
 */
std::string Put(const std::string &directory, int root, const char *hash, const char *extension,
                const unsigned char *bytes, size_t size) {
    using namespace io;
    const std::string name = std::string(hash) + extension;
    auto verify = [&] {
        const auto actual = SmallFile(root, name, 1024 * 1024);
        Require(actual.size() == size && Digest(actual) == hash, "宿主字体配置已被修改：" + name);
    };
    if (Exists(root, name)) {
        verify();
        return directory + "/" + name;
    }
    std::string temporary = directory + "/.font-XXXXXX";
    Fd file(mkstemp(temporary.data()));
    if (file.get() < 0)
        Error("无法建立字体配置暂存");
    try {
        if (fcntl(file.get(), F_SETFD, FD_CLOEXEC))
            Error("无法设置字体配置 fd 继承属性");
        Write(file.get(), bytes, size);
        if (fchmod(file.get(), 0444))
            Error("无法保护宿主字体配置权限");
        Sync(file.get());
        if (renameat(root, Leaf(temporary).c_str(), root, name.c_str()))
            Error("无法发布宿主字体配置");
        // rename 成功后临时名称已经消失；同步目录后再核对正式文件的内容与单链接身份。
        Sync(root);
        verify();
        return directory + "/" + name;
    } catch (...) {
        unlinkat(root, Leaf(temporary).c_str(), 0);
        throw;
    }
}
} // namespace
bool PrepareFontResources(const std::string &filesDir, std::string &fontsConf, std::string &jdk8Properties,
                          std::string &error) {
    try {
        io::Require(!filesDir.empty() && filesDir.front() == '/' && filesDir.find('\0') == std::string::npos,
                    "宿主字体资源要求真实绝对filesDir");
        auto files = io::Directory(filesDir);
        auto root = io::ChildDirectory(files.get(), "runtime-fonts", true);
        // 小型宿主配置首次发布串行化，使“确认目标不存在→rename 发布”成为合作
        // 进程间的完整事务；不依赖设备文件系统可能禁止的硬链接能力。
        // 锁只保护这两个小文件，不持有 JDK writer/use，不参与游戏的热路径。
        int locked;
        do {
            locked = flock(root.get(), LOCK_EX);
        } while (locked != 0 && errno == EINTR);
        if (locked != 0)
            io::Error("无法锁定宿主字体配置");
        // cache属于已验证宿主私有目录，生成XML时嵌入真实绝对路径；Fontconfig不会
        // 把relative前缀解释成配置所在目录。四个JDK和重启复用，不依赖cwd/HOME/XDG。
        // O_NOFOLLOW 目录打开拒绝将缓存指向沙箱之外；真实写入失败仍由调用者报告。
        auto cache = io::ChildDirectory(root.get(), "cache", true);
        if (faccessat(cache.get(), ".", W_OK | X_OK, 0) != 0)
            io::Error("宿主字体缓存目录不可写");
        io::Sync(root.get());
        io::Sync(files.get());
        const auto directory = filesDir + "/runtime-fonts";
        const auto expanded = ExpandFontsConf(directory + "/cache");
        const auto digest = io::Digest(expanded);
        fontsConf = Put(directory, root.get(), digest.c_str(), ".conf",
                        reinterpret_cast<const unsigned char *>(expanded.data()), expanded.size());
        jdk8Properties =
            Put(directory, root.get(), kJdk8PropertiesSha, ".properties", kJdk8Properties, sizeof(kJdk8Properties));
        return true;
    } catch (const std::exception &failure) {
        error = failure.what();
        return false;
    }
}
} // namespace amcl::jdk
