/** 宿主测试只证明探针的提供者归属、失败分支、独占文件与环境/CWD恢复，不模拟真实Context。 */
#include "napi/jdk_font_context_qualification.h"
#include <cassert>
#include <iostream>
#include <stdexcept>
#include <sys/stat.h>

namespace io = amcl::jdk::io;
namespace fc = amcl::jdkqualification::fontcontext;

int main(int argc, char** argv) {
    assert(argc == 4);
    const std::string mode = argv[1], output = argv[2], fixture = argv[3];
    assert(chdir(output.c_str()) == 0);
    auto run = io::Directory(output);
    auto cache = io::ChildDirectory(run.get(), "缓存 cache", true);
    const std::string cachePath = output + "/缓存 cache";
    assert(setenv("HOME", "original-home-keep", 1) == 0);
    assert(setenv("FONTCONFIG_FILE", "original-file-keep", 1) == 0);
    assert(setenv("FONTCONFIG_PATH", "original-path-keep", 1) == 0);
    assert(setenv("XDG_CACHE_HOME", "original-xdg-keep", 1) == 0);
    assert(unsetenv("XDG_DATA_HOME") == 0);
    struct stat cwdBefore{}; assert(stat(".", &cwdBefore) == 0);
    void* library = nullptr;
    if (mode == "load-facade") assert(setenv("AMCL_FONT_CONTEXT_FIXTURE_CACHE", cachePath.c_str(), 1) == 0);
    if (mode != "missing-provider" && mode != "exception-restore" && mode != "load-facade") {
        library = dlopen(fixture.c_str(), RTLD_NOW | RTLD_LOCAL);
        assert(library);
        auto configure = reinterpret_cast<void (*)(const char*, int)>(dlsym(library, "AmclFontContextFixtureConfigure"));
        if (configure) configure((mode == "write-failure" ? output + "/missing/cache" : cachePath).c_str(),
                                 mode == "no-context" ? 1 : mode == "bad-path" ? 2 : mode == "bad-length" ? 3 : 0);
    }
    if (mode == "exception-restore") {
        bool restored = true;
        try {
            fc::Environment environment(restored);
            fc::WorkingDirectory directory(restored);
            environment.Clear(); directory.SelectRoot();
            throw std::runtime_error("injected failure after state change");
        } catch (const std::runtime_error&) {}
        assert(restored);
    } else {
        std::string collisionName;
        if (mode == "collision") {
            collisionName = "amcl-font-context-" + std::to_string(getpid()) + "-inherited.probe";
            io::Fd prior(openat(cache.get(), collisionName.c_str(), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600));
            assert(prior.get() >= 0);
            io::Write(prior.get(), "original evidence", 17); io::Sync(prior.get());
        }
        const auto report = amcl::jdkqualification::RunFontContextQualification(run.get());
        assert(report.find("\"freshExecQualified\":false") != std::string::npos);
        assert(io::SmallFile(run.get(), "font-context-report.json", 1024 * 64) == report);
        const char* expected = mode == "missing-provider" ? "PROVIDER-LOAD-FAILED" :
            mode == "missing-symbol" ? "SYMBOL-UNAVAILABLE" : mode == "wrong-provider" ? "PROVIDER-MISMATCH" :
            mode == "no-context" ? "API-FAILED" : (mode == "bad-path" || mode == "bad-length") ? "INVALID-RESULT" :
            (mode == "write-failure" || mode == "collision") ? "WRITE-FAILED" : "PASS";
        assert(report.find(expected) != std::string::npos);
        if (mode == "no-context") assert(report.find("\"returnCode\":16000011") != std::string::npos);
        if (mode == "good" || mode == "collision" || mode == "load-facade") assert(report.find("\"fsyncAndReadback\":true") != std::string::npos);
        if (mode == "load-facade") assert(report.find("\"loadedByProbe\":true") != std::string::npos &&
                                         report.find("\"noLoadSucceeded\":false") != std::string::npos);
        if (mode == "collision") assert(io::SmallFile(cache.get(), collisionName, 100) == "original evidence");
        // 第二次不得覆盖原报告；即使探针文件已存在，所有环境变更仍需恢复。
        bool rejected = false;
        try { (void)amcl::jdkqualification::RunFontContextQualification(run.get()); }
        catch (const std::exception&) { rejected = true; }
        assert(rejected && io::SmallFile(run.get(), "font-context-report.json", 1024 * 64) == report);
    }
    assert(std::string(getenv("HOME")) == "original-home-keep");
    assert(std::string(getenv("FONTCONFIG_FILE")) == "original-file-keep");
    assert(std::string(getenv("FONTCONFIG_PATH")) == "original-path-keep");
    assert(std::string(getenv("XDG_CACHE_HOME")) == "original-xdg-keep");
    assert(getenv("XDG_DATA_HOME") == nullptr);
    struct stat cwdAfter{}; assert(stat(".", &cwdAfter) == 0);
    assert(cwdBefore.st_dev == cwdAfter.st_dev && cwdBefore.st_ino == cwdAfter.st_ino);
    if (library) dlclose(library);
    std::cout << "PASS font context boundary: " << mode << "\n";
}
