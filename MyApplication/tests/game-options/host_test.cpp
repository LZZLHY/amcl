#include "../../entry/src/main/cpp/jvm/game_options.h"

#include <algorithm>
#include <cassert>
#include <cerrno>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <unistd.h>

namespace {
enum class Fault { none, openDenied, readError, earlyEnd, writeError, zeroWrite, shortWrite, syncError, closeError, replaceTarget };
Fault fault = Fault::none;
std::string target;
bool readStarted = false;
int outputFd = -1;
void save(const std::string &value) {
    std::ofstream f(target, std::ios::binary);
    f << value;
    f.close();
    assert(f.good());
}
std::string contents() {
    std::ifstream f(target, std::ios::binary);
    return {std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>()};
}
}

// 链接器仅替换系统边界。仍由生产函数在真实目录读取、落盘、改名或保全原文件。
extern "C" int __real_open(const char *, int, ...);
extern "C" int __wrap_open(const char *path, int flags) {
    if (fault == Fault::openDenied && target == path) { errno = EACCES; return -1; }
    return __real_open(path, flags);
}
extern "C" ssize_t __real_read(int, void *, size_t);
extern "C" ssize_t __wrap_read(int fd, void *p, size_t n) {
    if (fault == Fault::readError) { errno = EIO; return -1; }
    if (fault == Fault::earlyEnd) {
        if (readStarted) return 0;
        readStarted = true;
        return __real_read(fd, p, 3);
    }
    return __real_read(fd, p, n);
}
extern "C" ssize_t __real_write(int, const void *, size_t);
extern "C" ssize_t __wrap_write(int fd, const void *p, size_t n) {
    outputFd = fd;
    if (fault == Fault::writeError) { errno = ENOSPC; return -1; }
    if (fault == Fault::zeroWrite) return 0;
    return __real_write(fd, p, fault == Fault::shortWrite ? std::min(n, size_t(3)) : n);
}
extern "C" int __real_fsync(int);
extern "C" int __wrap_fsync(int fd) {
    if (fault == Fault::syncError) { errno = EIO; return -1; }
    if (fault == Fault::replaceTarget) {
        std::ofstream fresh(target + ".new"); fresh << "external:keep\n"; fresh.close();
        std::filesystem::rename(target + ".new", target);
    }
    return __real_fsync(fd);
}
extern "C" int __real_close(int);
extern "C" int __wrap_close(int fd) {
    int result = __real_close(fd);
    if (fd == outputFd && fault == Fault::closeError) { errno = EIO; return -1; }
    return result;
}

int main(int argc, char **argv) {
    assert(argc == 2);
    const std::string dir = argv[1];
    target = dir + "/options.txt";
    const std::string old = "key_key.jump:key.keyboard.x\r\nfullscreen:true\r\nlang:zh_cn\r\ngamma:0.75";
    const std::string desired = "key_key.jump:key.keyboard.x\r\nfullscreen:false\r\nlang:en_us\r\ngamma:0.75";
    save(old);
    for (Fault mode : {Fault::openDenied, Fault::readError, Fault::earlyEnd, Fault::writeError,
                       Fault::zeroWrite, Fault::syncError, Fault::closeError}) {
        fault = mode;
        outputFd = -1;
        assert(!amcl::updateGameOptions(dir, "en_us", true));
        fault = Fault::none;
        assert(contents() == old);
        assert(std::distance(std::filesystem::directory_iterator(dir),
                             std::filesystem::directory_iterator{}) == 1);
    }
    fault = Fault::shortWrite;
    assert(amcl::updateGameOptions(dir, "en_us", true) && contents() == desired);
    fault = Fault::writeError; // 未发生变更时不再打开输出。
    assert(amcl::updateGameOptions(dir, "en_us", true) && contents() == desired);
    fault = Fault::none;
    save("fullscreen:true\nkey_key.jump:key.keyboard.x");
    assert(amcl::updateGameOptions(dir, "ja_jp", false));
    assert(contents() == "fullscreen:true\nkey_key.jump:key.keyboard.x\nlang:ja_jp\n");

    for (bool existing : {true, false}) {
        if (!existing) std::filesystem::remove(target);
        fault = Fault::replaceTarget;
        assert(!amcl::updateGameOptions(dir, "zh_tw", false));
        fault = Fault::none;
        assert(contents() == "external:keep\n");
    }
    std::filesystem::remove(target);
    assert(amcl::updateGameOptions(dir, "unsupported", false) && !std::filesystem::exists(target));
    assert(amcl::updateGameOptions(dir, "zh_cn", true) && contents() == "lang:zh_cn\n");
}
