/**
 * 真实生产实现的宿主测试：故障注入只在 syscalls/持久化边界，不重写事务状态机。
 * 崩溃用 fork 子进程 _exit，父进程重新打开锁和目录恢复；不是 C++ catch 模拟死亡。
 */
#include "../../entry/src/main/cpp/platform/jdk_font_resources.h"
#include "../../entry/src/main/cpp/platform/jdk_install_io.h"
#include "../../entry/src/main/cpp/platform/jdk_install_store.h"
#include <cassert>
#include <filesystem>
#include <functional>
#include <iostream>
#include <sys/wait.h>

namespace fs = std::filesystem;
using namespace amcl::jdk;
using namespace amcl::jdk::io;
static int hit = 0, killAt = 0, failFsync = 0, failMode = 0, renameFailure = 0;
static std::string caseName;
extern "C" void amclJdkInstallTestCheckpoint(const char *name) {
    ++hit;
    if (killAt == hit) {
        dprintf(STDOUT_FILENO, "CRASH case=%s boundary=%d point=%s\n", caseName.c_str(), hit, name);
        _exit(73);
    }
}
extern "C" int __real_renameat(int, const char *, int, const char *);
extern "C" int __wrap_renameat(int a, const char *b, int c, const char *d) {
    if (renameFailure && std::string(d) == "8") {
        if (renameFailure == 1)
            renameFailure = 0;
        errno = EIO;
        return -1;
    }
    return __real_renameat(a, b, c, d);
}
extern "C" int __real_fsync(int);
extern "C" int __wrap_fsync(int fd) {
    if (failFsync > 0 && --failFsync == 0) {
        errno = ENOSPC;
        return -1;
    }
    const int result = __real_fsync(fd);
    // 覆盖生产新增的祖先/文件/目录fsync，而不依赖业务代码记得新增专用checkpoint。
    if (result == 0)
        amclJdkInstallTestCheckpoint("fsync-return");
    return result;
}
extern "C" int __real_fchmod(int, mode_t);
extern "C" int __wrap_fchmod(int fd, mode_t mode) {
    bool helper = false;
    if (failMode >= 2 && mode == 0755) {
        std::array<char, 4096> path{};
        const auto link = "/proc/self/fd/" + std::to_string(fd);
        const ssize_t n = readlink(link.c_str(), path.data(), path.size());
        helper = n > 0 && std::string(path.data(), n).find("/lib/jspawnhelper") != std::string::npos;
    }
    if (failMode == 1 || (failMode == 2 && helper)) {
        errno = EACCES;
        return -1;
    }
    if (failMode == 3 && helper)
        return 0; // 系统谎报成功但mode未改变，必须由回读抓到。
    return __real_fchmod(fd, mode);
}
void Text(const fs::path &path, const std::string &text) {
    Fd file(open(path.c_str(), O_CREAT | O_TRUNC | O_WRONLY | O_CLOEXEC, 0600));
    assert(file.get() >= 0);
    Write(file.get(), text.data(), text.size());
    Sync(file.get());
}
std::string Text(const fs::path &path) {
    auto dir = Directory(path.parent_path());
    return SmallFile(dir.get(), path.filename(), 1024 * 1024);
}
std::string HashFile(const fs::path &path) {
    auto dir = Directory(path.parent_path());
    Fd f(open(path.c_str(), O_RDONLY | O_CLOEXEC));
    struct stat st {};
    assert(fstat(f.get(), &st) == 0);
    download::Sha256 sha;
    std::array<unsigned char, Chunk> b{};
    for (uint64_t at = 0; at < uint64_t(st.st_size);) {
        const size_t n = std::min<uint64_t>(b.size(), st.st_size - at);
        Read(f.get(), b.data(), n, at);
        sha.update(b.data(), n);
        at += n;
    }
    return sha.finalizeHex();
}
void Throws(const std::function<void()> &call) {
    bool failed = false;
    try {
        call();
    } catch (const std::exception &error) {
        failed = true;
        std::cout << "EXPECTED " << error.what() << '\n';
    }
    assert(failed);
}
struct Leases {
    Fd writer, use;
    Leases(const fs::path &files, const std::string &major, bool useExclusive = true) {
        fs::create_directories(files / "jdk/.locks");
        writer = Fd(open((files / ("jdk/.locks/" + major + ".writer")).c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0600));
        use = Fd(open((files / ("jdk/.locks/" + major + ".use")).c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0600));
        assert(flock(writer.get(), LOCK_EX | LOCK_NB) == 0);
        assert(flock(use.get(), (useExclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0);
    }
};
void Setup(const fs::path &files, bool old) {
    fs::create_directories(files / "jdk");
    if (old) {
        fs::create_directory(files / "jdk/8");
        Text(files / "jdk/8/payload", "complete-old-payload");
        Text(files / "jdk/8/.amcl_release_tag", "old-source");
    }
}
std::string Stage(const fs::path &files, Leases &lease, bool wrapped = false) {
    auto path = CreateInstallStage(files, "8", lease.writer.get());
    if (wrapped) {
        fs::create_directory(path + "/jdk-custom");
        path += "/jdk-custom";
    }
    Text(fs::path(path) / "payload", "complete-new-payload");
    Text(fs::path(path) / ".amcl_release_tag", "imported:new-source");
    SealInstallStage(path, "8", Digest("new-archive"));
    return path;
}
void CheckComplete(const fs::path &files, bool oldExpected, bool deletion = false) {
    assert(!InstallRecoveryRequired(files, "8"));
    if (!fs::exists(files / "jdk/8")) {
        assert(deletion || !oldExpected);
        return;
    }
    const auto payload = Text(files / "jdk/8/payload"), tag = Text(files / "jdk/8/.amcl_release_tag");
    assert((payload == "complete-old-payload" && tag == "old-source") ||
           (payload == "complete-new-payload" && tag == "imported:new-source"));
    assert(!deletion);
    std::cout << "RECOVERED payload=" << payload << " tag=" << tag << '\n';
}
void CrashMatrix(const fs::path &base, bool old, bool deletion, bool wrapped) {
    const auto family =
        std::string(deletion ? "delete" : "install") + (old ? "-old" : "-first") + (wrapped ? "-wrapped" : "");
    const auto normal = base / (family + "-normal");
    Setup(normal, old);
    int boundaries = 0;
    {
        Leases lease(normal, "8");
        const auto stage = deletion ? std::string() : Stage(normal, lease, wrapped);
        hit = 0;
        if (deletion)
            DeleteInstallSlot(normal, "8", lease.writer.get(), lease.use.get());
        else
            PublishInstallStage(normal, "8", stage, lease.writer.get(), lease.use.get());
        boundaries = hit;
    }
    CheckComplete(normal, old, deletion);
    for (int point = 1; point <= boundaries; ++point) {
        const auto files = base / (family + "-crash-" + std::to_string(point));
        Setup(files, old);
        const pid_t child = fork();
        assert(child >= 0);
        if (child == 0) {
            Leases lease(files, "8");
            const auto stage = deletion ? std::string() : Stage(files, lease, wrapped);
            hit = 0;
            killAt = point;
            caseName = family;
            if (deletion)
                DeleteInstallSlot(files, "8", lease.writer.get(), lease.use.get());
            else
                PublishInstallStage(files, "8", stage, lease.writer.get(), lease.use.get());
            _exit(0);
        }
        int status = 0;
        assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 73);
        {
            Leases lease(files, "8");
            RecoverInstallSlot(files, "8", lease.writer.get(), lease.use.get());
        }
        // 删除 intent 在 journal 尚未可见前死亡可以保留旧安装；一旦提交删除就必须完整缺席。
        CheckComplete(files, old, deletion && !fs::exists(files / "jdk/8"));
    }
    std::cout << "MATRIX " << family << " boundaries=" << boundaries << '\n';
}
/** 从Create开始追踪每个实际fsync，覆盖payload/来源戳/seal进入journal前的真实死亡。
 * 有归属且已写payload的候选必须回收；创建归属前的空壳因不能证明所有者而保守保留。 */
void PreparationCrashMatrix(const fs::path &base) {
    const auto normal = base / "prepare-normal";
    Setup(normal, true);
    int boundaries = 0;
    {
        Leases lease(normal, "8");
        hit = 0;
        const auto stage = Stage(normal, lease);
        boundaries = hit;
        DiscardInstallStage(normal, "8", stage, lease.writer.get());
    }
    for (int point = 1; point <= boundaries; ++point) {
        const auto files = base / ("prepare-crash-" + std::to_string(point));
        Setup(files, true);
        const auto pid = fork();
        assert(pid >= 0);
        if (!pid) {
            Leases lease(files, "8");
            hit = 0;
            killAt = point;
            caseName = "prepare";
            Stage(files, lease);
            _exit(0);
        }
        int status;
        assert(waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 73);
        {
            Leases lease(files, "8", false); // 旧JDK使用者继续持SH，纯staging回收不能要求EX。
            CollectAbandonedInstallStage(files, "8", lease.writer.get());
            for (const auto &item : fs::directory_iterator(files / "jdk"))
                if (item.path().filename().string().rfind(".staging-", 0) == 0)
                    assert(fs::is_empty(item.path()));
            const auto next = Stage(files, lease);
            DiscardInstallStage(files, "8", next, lease.writer.get());
        }
        CheckComplete(files, true);
        assert(Text(files / "jdk/8/payload") == "complete-old-payload");
    }
    std::cout << "MATRIX prepare boundaries=" << boundaries << '\n';
}
int main(int argc, char **argv) {
    std::cout.setf(std::ios::unitbuf);
    assert(argc == 3);
    const fs::path fixtures = argv[1], base = argv[2];
    fs::create_directories(base);
    CrashMatrix(base, true, false, false);
    CrashMatrix(base, false, false, false);
    CrashMatrix(base, true, false, true);
    CrashMatrix(base, true, true, false);
    PreparationCrashMatrix(base);
    {
        const auto files = base / "changed-stage-owner";
        Setup(files, true);
        Leases lease(files, "8");
        const auto stage = Stage(files, lease);
        fs::rename(stage, stage + ".preserved");
        fs::create_directory(stage);
        Text(fs::path(stage) / "unknown", "do-not-delete");
        Throws([&] { CollectAbandonedInstallStage(files, "8", lease.writer.get()); });
        assert(Text(fs::path(stage) / "unknown") == "do-not-delete");
        assert(fs::exists(stage + ".preserved"));
        assert(Text(files / "jdk/8/payload") == "complete-old-payload");
    }
    {
        const auto files = base / "bad-stage-owner";
        Setup(files, true);
        Leases lease(files, "8");
        const auto stage = Stage(files, lease);
        Text(files / "jdk/.locks/8.stage", "invalid-owner");
        Throws([&] { DiscardInstallStage(files, "8", stage, lease.writer.get()); });
        assert(fs::exists(stage));
    }
    for (int failure = 1; failure <= 2; ++failure) {
        const auto files = base / ("rename-failure-" + std::to_string(failure));
        Setup(files, true);
        Leases lease(files, "8");
        const auto stage = Stage(files, lease);
        renameFailure = failure;
        Throws([&] { PublishInstallStage(files, "8", stage, lease.writer.get(), lease.use.get()); });
        renameFailure = 0;
        if (failure == 2) {
            assert(InstallRecoveryRequired(files, "8"));
            DiscardInstallStage(files, "8", stage, lease.writer.get());
            assert(fs::exists(stage));
        }
        RecoverInstallSlot(files, "8", lease.writer.get(), lease.use.get());
        assert(Text(files / "jdk/8/payload") == "complete-old-payload");
    }
    {
        const auto files = base / "journal-diskfull";
        Setup(files, true);
        Leases lease(files, "8");
        const auto stage = Stage(files, lease);
        failFsync = 2;
        Throws([&] { PublishInstallStage(files, "8", stage, lease.writer.get(), lease.use.get()); });
        failFsync = 0;
        assert(Text(files / "jdk/8/payload") == "complete-old-payload");
    }
    {
        const auto files = base / "bad-journal";
        Setup(files, true);
        Leases lease(files, "8");
        const auto stage = Stage(files, lease);
        Text(files / "jdk/.locks/8.journal", "bad-record");
        Throws([&] { RecoverInstallSlot(files, "8", lease.writer.get(), lease.use.get()); });
        DiscardInstallStage(files, "8", stage, lease.writer.get());
        assert(fs::exists(stage));
        assert(Text(files / "jdk/8/payload") == "complete-old-payload");
    }
    {
        const auto files = base / "busy";
        Setup(files, true);
        fs::create_directories(files / "jdk/.locks");
        Fd read(open((files / "jdk/.locks/8.use").c_str(), O_CREAT | O_RDWR | O_CLOEXEC, 0600));
        assert(flock(read.get(), LOCK_SH) == 0);
        const pid_t child = fork();
        assert(child >= 0);
        if (!child) {
            Fd exclusive(open((files / "jdk/.locks/8.use").c_str(), O_RDWR | O_CLOEXEC));
            assert(flock(exclusive.get(), LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK);
            _exit(0);
        }
        int status;
        assert(waitpid(child, &status, 0) == child && status == 0);
    }
    Text(base / "outside-sentinel", "unchanged");
    {
        // 真实v5 helper仍是Linux解释器；只允许保留精确已发布payload，不执行或改写它。
        // 错归档、错槽、错路径和同长度单字节变异均不能借用这一历史身份。
        const std::string archiveSha = "0e26b0dece38156838456cfb12058d863aa9856cdd8fd648f06f9bc5e91f8ecd";
        const std::string helperSha = "8c1507458c7de60c16acae78a131f779941d2ab1c4a4f83466d05ac295c6ef96";
        const auto helper = Text(fixtures / "legacy17-helper.bin");
        assert(helper.size() == 18624 && HashFile(fixtures / "legacy17-helper.bin") == helperSha);
        auto leaf = [&](const std::string &name, const std::string &relative, const std::string &bytes) {
            const auto root = base / name;
            fs::create_directories((root / relative).parent_path());
            Text(root / relative, bytes);
            return root;
        };
        const auto known = leaf("legacy17-known", "lib/jspawnhelper", helper);
        SealInstallStage(known, "17", archiveSha);
        struct stat mode {};
        assert(!stat((known / "lib/jspawnhelper").c_str(), &mode) && (mode.st_mode & 07777) == 0755);
        assert(HashFile(known / "lib/jspawnhelper") == helperSha);
        Throws([&] { SealInstallStage(leaf("legacy17-wrong-archive", "lib/jspawnhelper", helper), "17", std::string(64, 'b')); });
        Throws([&] { SealInstallStage(leaf("legacy17-wrong-major", "lib/jspawnhelper", helper), "21", archiveSha); });
        Throws([&] { SealInstallStage(leaf("legacy17-wrong-path", "bin/java", helper), "17", archiveSha); });
        auto changed = helper; changed.back() ^= 1;
        Throws([&] { SealInstallStage(leaf("legacy17-changed", "lib/jspawnhelper", changed), "17", archiveSha); });
        Throws([&] { SealInstallStage(leaf("legacy17-truncated", "lib/jspawnhelper", helper.substr(0, 100)), "17", archiveSha); });
        std::cout << "LEGACY17 exact retained helper and five identity negatives PASS\n";
    }
    for (const std::string name : {"good", "stored", "zip64", "directory", "descriptor", "wrapper"}) {
        const auto stage = base / ("zip-" + name);
        fs::create_directory(stage);
        const auto zip = fixtures / (name + ".zip");
        ExtractInstallArchive(zip, stage, HashFile(zip), 30000);
        if (name != "descriptor") {
            const auto root = name == "wrapper" ? stage / "jdk-custom" : stage;
            SealInstallStage(root, "17", HashFile(zip));
            struct stat st {};
            assert(stat((root / "lib/jspawnhelper").c_str(), &st) == 0 && (st.st_mode & 07777) == 0755);
            assert(HashFile(root / "lib/jspawnhelper") == HashFile(root / "bin/java"));
        }
        std::cout << "ZIP-PASS " << name << '\n';
    }
    for (const std::string name :
         {"traversal", "absolute", "backslash", "duplicate", "conflict", "component-order-conflict", "symlink", "fifo",
          "depth", "bad-crc", "local-mismatch", "declared-bomb", "actual-bomb"}) {
        const auto stage = base / ("zip-" + name);
        fs::create_directory(stage);
        const auto zip = fixtures / (name + ".zip");
        Throws([&] { ExtractInstallArchive(zip, stage, HashFile(zip), 30000); });
        assert(Text(base / "outside-sentinel") == "unchanged");
        std::cout << "ZIP-REJECT " << name << '\n';
    }
    for (const std::string name : {"missing-helper", "wrong-interpreter", "missing-dependency", "truncated-helper"}) {
        const auto stage = base / ("zip-" + name);
        fs::create_directory(stage);
        const auto zip = fixtures / (name + ".zip");
        ExtractInstallArchive(zip, stage, HashFile(zip), 30000);
        Throws([&] { SealInstallStage(stage, "17", HashFile(zip)); });
    }
    for (int mode : {1, 2, 3}) {
        const auto stage = base / ("chmod-failed-" + std::to_string(mode));
        fs::create_directory(stage);
        const auto zip = fixtures / "good.zip";
        ExtractInstallArchive(zip, stage, HashFile(zip), 30000);
        failMode = mode;
        Throws([&] { SealInstallStage(stage, "17", HashFile(zip)); });
        failMode = 0;
        assert(!fs::exists(stage / ".amcl-install-seal"));
    }
    {
        // Linux真实目录名包含中文及五种XML实体字符；不能把合法路径中的符号当XML语法。
        const auto files = base / u8"fonts-中文&<>\"'";
        fs::create_directory(files);
        std::string conf, properties, error;
        assert(PrepareFontResources(files, conf, properties, error));
        const auto original = Text(conf);
        // Fontconfig会将相对cachedir按cwd处理，必须发布转义后的绝对目录且按最终正文取SHA。
        const auto expected = "<cachedir>" + base.string() +
            u8"/fonts-中文&amp;&lt;&gt;&quot;&apos;/runtime-fonts/cache</cachedir>";
        assert(original.find(expected) != std::string::npos);
        assert(original.find("@AMCL_FONT_CACHE_DIR@") == std::string::npos);
        assert(fs::path(conf).filename() == Digest(original) + ".conf");
        // 下文会故意破坏正式配置；保留实际读回的原正文供独立XML解析器复核，不能用
        // 测试外重造的一份“预期XML”代替生产函数真正发布的特殊字符路径结果。
        Text(files / "validated-before-corruption.xml", original);
        assert(fs::is_directory(files / "runtime-fonts/cache"));
        assert(fs::status(files / "runtime-fonts/cache").permissions() == fs::perms::owner_all);
        assert(fs::status(conf).permissions() ==
               (fs::perms::owner_read | fs::perms::group_read | fs::perms::others_read));
        std::vector<pid_t> children;
        for (int i = 0; i < 8; ++i) {
            const auto pid = fork();
            assert(pid >= 0);
            if (!pid) {
                assert(PrepareFontResources(files, conf, properties, error));
                _exit(0);
            }
            children.push_back(pid);
        }
        for (const auto pid : children) {
            int status;
            assert(waitpid(pid, &status, 0) == pid && status == 0);
        }
        assert(Text(conf) == original);
        const auto held = conf + ".held";
        fs::rename(conf, held);
        fs::create_symlink(held, conf);
        assert(!PrepareFontResources(files, conf, properties, error));
        assert(fs::is_symlink(conf) && Text(held) == original);
        fs::remove(conf); fs::rename(held, conf);
        assert(chmod(conf.c_str(), 0644) == 0);
        Text(conf, "changed");
        assert(!PrepareFontResources(files, conf, properties, error));
        assert(Text(conf) == "changed");
    }
    {
        // 与上面的“已发布配置并发读取”区分：多个真实进程从空目录同时首次发布。
        // 两份不可变正文只出现完整版本，所有临时名称被各自收回，不需要 hardlink。
        const auto files = base / "fonts-first-publish";
        fs::create_directory(files);
        std::vector<pid_t> children;
        for (int i = 0; i < 8; ++i) {
            const auto pid = fork();
            assert(pid >= 0);
            if (!pid) {
                std::string conf, properties, error;
                assert(PrepareFontResources(files, conf, properties, error));
                _exit(0);
            }
            children.push_back(pid);
        }
        for (const auto pid : children) {
            int status;
            assert(waitpid(pid, &status, 0) == pid && status == 0);
        }
        size_t entries = 0;
        for (const auto &item : fs::directory_iterator(files / "runtime-fonts")) {
            assert(item.path().filename().string().find(".font-") != 0);
            ++entries;
        }
        assert(entries == 3); // cache 目录与两份 SHA 命名的配置。
        fs::remove(files / "runtime-fonts/cache");
        fs::create_directory_symlink(base, files / "runtime-fonts/cache");
        std::string conf, properties, error;
        assert(!PrepareFontResources(files, conf, properties, error));
        assert(!error.empty());
    }
    std::cout << "JDK installation native tests PASS: real process-death recovery, lock exclusion, I/O failures, ZIP "
                 "containment/budgets, helper mode, immutable fonts\n";
}
