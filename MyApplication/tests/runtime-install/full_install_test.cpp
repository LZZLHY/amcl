/** 四份真实候选的完整Native安装/导入管线。原ZIP只读，目标ELF从不执行。
 * 每版先发布受管安装，再按用户导入覆盖；读取最终每个文件的真实SHA/mode供独立Python对照。
 * 大树只占显式2GiB tmpfs，核对/输出清单后用生产删除事务逐版回收。 */
#include "../../entry/src/main/cpp/platform/jdk_install_io.h"
#include "../../entry/src/main/cpp/platform/jdk_install_store.h"
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>

namespace fs = std::filesystem;
using namespace amcl::jdk;
using namespace amcl::jdk::io;
using Clock = std::chrono::steady_clock;
long long Elapsed(Clock::time_point start) {
    return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start).count();
}
struct Locks {
    Fd writer, use;
    fs::path files;
    std::string major;
    Locks(const fs::path &root, const std::string &version) : files(root), major(version) {
        fs::create_directories(files / "jdk/.locks");
        writer = Fd(open((files / ("jdk/.locks/" + major + ".writer")).c_str(), O_CREAT | O_RDWR | O_CLOEXEC, 0600));
        if (writer.get() < 0 || flock(writer.get(), LOCK_EX | LOCK_NB))
            Error("完整测试writer失败");
    }
    void readUse() {
        use = Fd(open((files / ("jdk/.locks/" + major + ".use")).c_str(), O_CREAT | O_RDWR | O_CLOEXEC, 0600));
        if (use.get() < 0 || flock(use.get(), LOCK_SH | LOCK_NB))
            Error("完整测试读租约失败");
    }
    void publishUse() {
        // 明确退出本次未激活读侧，重新打开独立OFD取得EX；不在SH上升级。
        use = Fd();
        use = Fd(open((files / ("jdk/.locks/" + major + ".use")).c_str(), O_RDWR | O_CLOEXEC));
        if (use.get() < 0 || flock(use.get(), LOCK_EX | LOCK_NB))
            Error("完整测试发布租约失败");
    }
};
void WriteMetadata(const fs::path &path, const std::string &value) {
    Fd file(open(path.c_str(), O_CREAT | O_TRUNC | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0600));
    if (file.get() < 0)
        Error("无法建立测试来源戳");
    Write(file.get(), value.data(), value.size());
    Sync(file.get());
}
void Readback(int root, const std::string &prefix, std::ofstream &report, uint64_t &total, size_t &count) {
    for (const auto &name : Names(root)) {
        const auto relative = prefix.empty() ? name : prefix + "/" + name;
        struct stat st {};
        if (fstatat(root, name.c_str(), &st, AT_SYMLINK_NOFOLLOW))
            Error("完整安装回读属性失败");
        if (S_ISDIR(st.st_mode)) {
            auto dir = ChildDirectory(root, name);
            Readback(dir.get(), relative, report, total, count);
            continue;
        }
        Require(S_ISREG(st.st_mode) && st.st_nlink == 1, "完整安装回读遇到链接或特殊项");
        Fd file(openat(root, name.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
        if (file.get() < 0)
            Error("完整安装回读失败");
        download::Sha256 sha;
        std::vector<unsigned char> bytes(Chunk);
        for (uint64_t at = 0; at < uint64_t(st.st_size);) {
            const auto n = std::min<uint64_t>(bytes.size(), st.st_size - at);
            Read(file.get(), bytes.data(), n, at);
            sha.update(bytes.data(), n);
            at += n;
        }
        report << relative << '\t' << st.st_size << '\t' << std::oct << (st.st_mode & 07777) << std::dec << '\t'
               << sha.finalizeHex() << '\n';
        total += st.st_size;
        ++count;
    }
}
int main(int argc, char **argv) {
    try {
        Require(argc == 4, "参数：input.tsv scratch output");
        std::cout.setf(std::ios::unitbuf);
        const fs::path scratch = argv[2], output = argv[3];
        fs::create_directories(scratch);
        std::ifstream manifest(argv[1]);
        Require(bool(manifest), "无法读取四ZIP固定清单");
        std::string line;
        size_t versions = 0;
        while (std::getline(manifest, line)) {
            std::istringstream row(line);
            std::string major, archive, sha, size;
            Require(bool(std::getline(row, major, '\t')) && bool(std::getline(row, archive, '\t')) &&
                        bool(std::getline(row, sha, '\t')) && bool(std::getline(row, size)),
                    "四ZIP清单格式错误");
            const auto files = scratch / major;
            fs::create_directory(files);
            Locks locks(files, major);
            for (bool imported : {false, true}) {
                const auto started = Clock::now();
                locks.readUse();
                const auto stage = CreateInstallStage(files, major, locks.writer.get());
                ExtractInstallArchive(archive, stage, sha, 300000);
                const auto extractedMs = Elapsed(started);
                const fs::path root = stage;
                // 只替代上层来源I/O，不重写production ZIP/seal/journal/rename状态机。
                if (imported) {
                    if (fs::exists(root / ".amcl-runtime-receipt.json"))
                        fs::remove(root / ".amcl-runtime-receipt.json");
                    WriteMetadata(root / ".amcl_release_tag", "imported:" + sha.substr(0, 12));
                } else {
                    WriteMetadata(root / ".amcl-runtime-receipt.json", "{\"origin\":\"catalog\",\"archiveSha256\":\"" +
                                                                           sha + "\",\"javaMajor\":" + major + "}");
                    WriteMetadata(root / ".amcl_release_tag", "host-candidate-" + major);
                }
                SealInstallStage(stage, major, sha);
                const auto sealedMs = Elapsed(started);
                locks.publishUse();
                PublishInstallStage(files, major, stage, locks.writer.get(), locks.use.get());
                DiscardInstallStage(files, major, stage, locks.writer.get());
                const auto publishedMs = Elapsed(started);
                auto installed = Directory(files / "jdk" / major);
                Require(!InstallRecoveryRequired(files, major), "完整安装仍有未恢复journal");
                Require(Exists(installed.get(), ".amcl-runtime-receipt.json") != imported, "受管收据与导入来源不一致");
                const auto tag = SmallFile(installed.get(), ".amcl_release_tag");
                Require(tag == (imported ? "imported:" + sha.substr(0, 12) : "host-candidate-" + major),
                        "来源戳未随目录发布");
                const std::string kind = imported ? "import" : "catalog";
                std::ofstream report(output / ("installed-" + major + "-" + kind + ".tsv"));
                uint64_t bytes = 0;
                size_t count = 0;
                Readback(installed.get(), "", report, bytes, count);
                report.close();
                Require(bool(report), "无法保存逐文件回读证据");
                std::cout << "FULL-INSTALL major=" << major << " kind=" << kind << " archiveSha=" << sha
                          << " archiveSize=" << size << " extractMs=" << extractedMs
                          << " sealMs=" << (sealedMs - extractedMs) << " publishMs=" << (publishedMs - sealedMs)
                          << " readbackMs=" << (Elapsed(started) - publishedMs) << " files=" << count
                          << " bytes=" << bytes << '\n';
            }
            DeleteInstallSlot(files, major, locks.writer.get(), locks.use.get());
            Require(!fs::exists(files / "jdk" / major), "完整测试删除事务未清理目标");
            ++versions;
        }
        Require(versions == 4, "完整测试必须覆盖四版本");
        std::cout << "Four real archives: catalog + imported publication/readback complete; no target ELF executed\n";
    } catch (const std::exception &error) {
        std::cerr << "FULL-INSTALL-FAIL " << error.what() << '\n';
        return 1;
    }
}
