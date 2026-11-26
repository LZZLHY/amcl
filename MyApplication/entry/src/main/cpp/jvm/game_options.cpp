#include "game_options.h"

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace amcl {
namespace {
// 与 ArkTS GameLanguages.ets 的语言集合一致，未知语言不改 lang。
static bool isSupportedGameLang(const std::string& lang) {
    static const char* kLangs[] = {
        "zh_cn", "zh_tw", "zh_hk", "en_us", "en_gb", "ja_jp", "ko_kr",
        "ru_ru", "de_de", "fr_fr", "es_es", "pt_br", "it_it", "vi_vn",
    };
    for (const char* l : kLangs) {
        if (lang == l) return true;
    }
    return false;
}
// 仅替换指定键的值，保留无关行、行尾以及已有文件的最后一个换行状态。
std::string updatedText(const std::string &original, const std::string &lang, bool forceWindowed) {
    std::string result;
    const bool setLanguage = isSupportedGameLang(lang);
    bool hadLanguage = false;
    for (size_t start = 0; start < original.size();) {
        const size_t newline = original.find('\n', start);
        const size_t next = newline == std::string::npos ? original.size() : newline + 1;
        size_t end = newline == std::string::npos ? next : newline;
        if (end > start && original[end - 1] == '\r') --end;
        if (setLanguage && end - start >= 5 && original.compare(start, 5, "lang:") == 0) {
            result += "lang:" + lang;
            hadLanguage = true;
        } else if (forceWindowed && original.compare(start, end - start, "fullscreen:true") == 0) {
            result += "fullscreen:false";
        } else {
            result.append(original, start, end - start);
        }
        result.append(original, end, next - end);
        start = next;
    }
    if (setLanguage && !hadLanguage) {
        const char *eol = original.find("\r\n") != std::string::npos ? "\r\n" : "\n";
        if (!result.empty() && result.back() != '\n') result += eol;
        result += "lang:" + lang + eol;
    }
    return result;
}

// 外部文件管理器也可能正在更换配置。只有读前和提交前仍是同一份记录才可替换。
bool sameVersion(const struct stat &a, const struct stat &b) {
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec;
}

bool readOriginal(int fd, struct stat &identity, std::string &text) {
    if (fstat(fd, &identity) != 0 || !S_ISREG(identity.st_mode)) return false;
    char buffer[8192];
    while (true) {
        const ssize_t n = read(fd, buffer, sizeof(buffer));
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) return false;
        if (n == 0) return static_cast<off_t>(text.size()) == identity.st_size;
        if (static_cast<off_t>(text.size()) + n > identity.st_size) return false;
        text.append(buffer, static_cast<size_t>(n));
    }
}

bool writeContents(int fd, const std::string &text) {
    for (size_t pos = 0; pos < text.size();) {
        const ssize_t n = write(fd, text.data() + pos, text.size() - pos);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        pos += static_cast<size_t>(n);
    }
    return fsync(fd) == 0;
}

} // namespace

bool updateGameOptions(const std::string &gameDir, const std::string &lang, bool forceWindowed) {
    const std::string path = gameDir + "/options.txt";
    const int source = open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    const bool existing = source >= 0;
    struct stat before{};
    std::string original;
    if (existing) {
        const bool complete = readOriginal(source, before, original);
        if (close(source) != 0 || !complete) return false;
    } else if (errno != ENOENT) {
        return false;
    }

    const std::string changed = updatedText(original, lang, forceWindowed);
    if (changed == original) return true;
    // 同目录改名不能绕开玩家给原文件设定的只读权限。
    if (existing && access(path.c_str(), W_OK) != 0) return false;

    // 临时文件和目标同目录，仅在写满、同步、关闭均成功后发布；故障不能截断原件。
    std::string tmp = gameDir + "/.amcl-options-XXXXXX";
    const int output = mkstemp(tmp.data());
    if (output < 0) return false;
    // 有些公共目录不支持 chmod，仍可用同目录临时文件完整替换。
    bool ok = !existing || fchmod(output, before.st_mode & 0777) == 0 ||
              errno == EOPNOTSUPP || errno == EPERM;
    if (ok) ok = writeContents(output, changed);
    if (close(output) != 0) ok = false;
    if (ok) {
        struct stat now{};
        const int status = lstat(path.c_str(), &now);
        const bool unchanged = existing ? status == 0 && sameVersion(before, now) : status < 0 && errno == ENOENT;
        ok = unchanged && rename(tmp.c_str(), path.c_str()) == 0;
    }
    if (!ok) unlink(tmp.c_str());
    return ok;
}
} // namespace amcl
