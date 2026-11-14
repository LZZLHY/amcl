/**
 * 读取已发布v7和源码构建musl helper的真实ELF，执行生产解压/封存/发布但不执行目标代码。
 * 完整ZIP只读；所有写入仅限显式scratch。未知归档、槽、路径、篡改和链接必须继续拒绝。
 * 最终逐文件回读供独立Python ZIP实现核对，不用被测解析器生成期望值。
 */
#include "../../entry/src/main/cpp/platform/jdk_install_io.h"
#include "../../entry/src/main/cpp/platform/jdk_install_store.h"
#include <cassert>
#include <elf.h>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <iterator>

namespace fs = std::filesystem;
using namespace amcl::jdk;
using namespace amcl::jdk::io;
const std::string ArchiveSha = "21556d0d4fc5eea09ba27068cf8a96803bb1667b35adbc8495fdc5f831316275";
const std::string HelperSha = "b2d14931d6ada5aafc3367d810013144c4d52cf125e3614d53e0907c0056fb9a";

std::string Bytes(const fs::path &path) {
    std::ifstream file(path, std::ios::binary); Require(bool(file), "fixture unreadable");
    return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}
std::string Sha(const std::string &bytes) { download::Sha256 hash; hash.update(bytes.data(), bytes.size()); return hash.finalizeHex(); }
void WriteFixture(const fs::path &path, const std::string &bytes) {
    fs::create_directories(path.parent_path());
    Fd file(open(path.c_str(), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0600));
    Require(file.get() >= 0, "fixture create failed"); Write(file.get(), bytes.data(), bytes.size()); Sync(file.get());
}
void Rejected(const std::string &name, const std::function<void()> &action) {
    bool rejected = false;
    try { action(); } catch (const std::exception &error) { rejected = true; std::cout << "REJECT " << name << ": " << error.what() << '\n'; }
    Require(rejected, "unexpected acceptance: " + name);
}
/** 以实际ELF程序头证明两种解释器确为原字节，不以构造头或修改字符串冒充正例。 */
std::string Interpreter(const std::string &bytes) {
    Require(bytes.size() >= sizeof(Elf64_Ehdr), "helper truncated"); Elf64_Ehdr head{}; memcpy(&head, bytes.data(), sizeof(head));
    Require(!memcmp(head.e_ident, "\177ELF\2\1\1", 7) && head.e_machine == EM_AARCH64, "helper not AArch64");
    Require(head.e_phentsize == sizeof(Elf64_Phdr) && head.e_phoff <= bytes.size() &&
        head.e_phnum <= (bytes.size() - head.e_phoff) / sizeof(Elf64_Phdr), "helper phdr bounds");
    std::string result; unsigned count = 0;
    for (unsigned i = 0; i < head.e_phnum; ++i) {
        Elf64_Phdr p{}; memcpy(&p, bytes.data() + head.e_phoff + i * sizeof(p), sizeof(p));
        if (p.p_type != PT_INTERP) continue; ++count;
        Require(p.p_offset <= bytes.size() && p.p_filesz <= bytes.size() - p.p_offset, "helper interpreter bounds");
        result.assign(bytes.data() + p.p_offset, p.p_filesz);
    }
    Require(count == 1, "helper interpreter count"); return result;
}
/** 回读真实已发布目录中的完整payload及mode；不复用Native seal计算得到的摘要。 */
void Readback(int root, const std::string &prefix, std::ofstream &out, size_t &files) {
    for (const auto &name : Names(root)) {
        const auto relative = prefix.empty() ? name : prefix + "/" + name;
        struct stat st{}; Require(!fstatat(root, name.c_str(), &st, AT_SYMLINK_NOFOLLOW), "readback stat failed");
        if (S_ISDIR(st.st_mode)) { auto child = ChildDirectory(root, name); Readback(child.get(), relative, out, files); continue; }
        Require(S_ISREG(st.st_mode) && st.st_nlink == 1, "readback linked/special file");
        Fd file(openat(root, name.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)); Require(file.get() >= 0, "readback open failed");
        download::Sha256 hash; std::vector<unsigned char> bytes(Chunk);
        for (uint64_t at = 0; at < uint64_t(st.st_size);) {
            const auto size = std::min<uint64_t>(bytes.size(), st.st_size - at); Read(file.get(), bytes.data(), size, at);
            hash.update(bytes.data(), size); at += size;
        }
        out << relative << '\t' << st.st_size << '\t' << std::oct << (st.st_mode & 07777) << std::dec << '\t' << hash.finalizeHex() << '\n'; ++files;
    }
}
int main(int argc, char **argv) {
    try {
        Require(argc == 5, "args: legacy.zip fixtures scratch report-dir");
        const fs::path archive = argv[1], fixtures = argv[2], scratch = argv[3], reports = argv[4];
        Require(scratch.string().rfind("/dev/shm/amcl-jdk-legacy-", 0) == 0, "scratch must be own tmpfs fixture");
        fs::create_directories(scratch); fs::create_directories(reports);
        const auto legacy = Bytes(fixtures / "legacy.bin"), musl = Bytes(fixtures / "musl.bin");
        Require(Sha(legacy) == HelperSha && legacy.size() == 23200, "legacy fixture identity");
        Require(Interpreter(legacy) == std::string("/lib/ld-linux-aarch64.so.1\0", 27), "legacy actual interpreter");
        Require(Interpreter(musl) == std::string("/lib/ld-musl-aarch64.so.1\0", 26), "musl actual interpreter");
        // 完整v7经过同fd归档SHA/安全解压、实际封存和journal发布；旧内容直到成功发布前保留。
        const auto files = scratch / "full"; fs::create_directories(files / "jdk/21"); fs::create_directories(files / "jdk/.locks");
        WriteFixture(files / "jdk/21/old-sentinel", "old-valid-runtime");
        WriteFixture(files / "jdk/21/.amcl_release_tag", "old");
        Fd writer(open((files / "jdk/.locks/21.writer").c_str(), O_CREAT | O_RDWR | O_CLOEXEC, 0600));
        Fd use(open((files / "jdk/.locks/21.use").c_str(), O_CREAT | O_RDWR | O_CLOEXEC, 0600));
        Require(writer.get() >= 0 && use.get() >= 0 && !flock(writer.get(), LOCK_EX | LOCK_NB) && !flock(use.get(), LOCK_EX | LOCK_NB), "fixture lock failed");
        const auto stage = CreateInstallStage(files, "21", writer.get());
        ExtractInstallArchive(archive, stage, ArchiveSha, 300000);
        WriteFixture(fs::path(stage) / ".amcl_release_tag", "v21.0.5-ohos-7");
        SealInstallStage(stage, "21", ArchiveSha);
        Require(Bytes(files / "jdk/21/old-sentinel") == "old-valid-runtime", "old slot modified before publish");
        PublishInstallStage(files, "21", stage, writer.get(), use.get());
        Require(Sha(Bytes(files / "jdk/21/lib/jspawnhelper")) == HelperSha, "published helper changed");
        struct stat mode{}; Require(!stat((files / "jdk/21/lib/jspawnhelper").c_str(), &mode) && (mode.st_mode & 07777) == 0755, "legacy mode changed");
        auto installed = Directory(files / "jdk/21"); std::ofstream report(reports / "installed-v7.tsv"); size_t count = 0;
        Readback(installed.get(), "", report, count); report.close(); Require(bool(report), "readback report failed");
        std::cout << "PASS actual full v7 SHA/extract/seal/publication/readback files=" << count << '\n';

        const auto leaf = [&](const std::string &name, const std::string &data) {
            const auto root = scratch / name; WriteFixture(root / "lib/jspawnhelper", data); return root;
        };
        const auto modern = leaf("modern-musl", musl);
        // 真实musl工具还依赖同一发布包内的shim，正例提供实际库原件；不能用缺少
        // 依赖的残缺树误称生产校验回归，也不能删除依赖检查让正例强行通过。
        fs::copy_file(fixtures / "musl-shim.so", modern / "lib/libcxxabi_shim.so");
        SealInstallStage(modern, "21", std::string(64, 'a'));
        Require(!stat((modern / "lib/jspawnhelper").c_str(), &mode) && (mode.st_mode & 07777) == 0755, "musl mode failed");
        std::cout << "PASS actual musl helper remains strictly validated and chmod read back\n";
        Rejected("wrong archive", [&] { SealInstallStage(leaf("wrong-archive", legacy), "21", std::string(64, 'b')); });
        Rejected("wrong slot", [&] { SealInstallStage(leaf("wrong-slot", legacy), "17", ArchiveSha); });
        auto tampered = legacy; tampered.back() ^= 1;
        Rejected("tampered real ELF", [&] { SealInstallStage(leaf("tampered", tampered), "21", ArchiveSha); });
        Rejected("truncated real ELF", [&] { SealInstallStage(leaf("truncated", legacy.substr(0, 100)), "21", ArchiveSha); });
        const auto wrongPath = leaf("wrong-path", legacy); WriteFixture(wrongPath / "bin/java", legacy);
        Rejected("same bytes in bin/java", [&] { SealInstallStage(wrongPath, "21", ArchiveSha); });
        const auto linked = scratch / "symlink"; fs::create_directories(linked / "lib"); fs::create_symlink(fixtures / "legacy.bin", linked / "lib/jspawnhelper");
        Rejected("symlink", [&] { SealInstallStage(linked, "21", ArchiveSha); });
        const auto hard = leaf("hardlink", legacy); fs::create_hard_link(hard / "lib/jspawnhelper", hard / "lib/another");
        Rejected("hardlink", [&] { SealInstallStage(hard, "21", ArchiveSha); });
        Require(Bytes(files / "jdk/21/.amcl_release_tag") == "v21.0.5-ohos-7" && Sha(Bytes(files / "jdk/21/lib/jspawnhelper")) == HelperSha, "negative cases affected valid installed slot");
        std::cout << "PASS seven strict negative cases; no target ELF executed\n";
    } catch (const std::exception &error) { std::cerr << "LEGACY-HELPER-FAIL " << error.what() << '\n'; return 1; }
    return 0;
}
