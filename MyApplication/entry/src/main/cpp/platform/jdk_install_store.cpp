/**
 * 单槽 writer → use.EX 下的持久安装事务。
 *
 * PREPARED 先落盘，才允许 old→backup / staging→target；两次 rename 均同步父目录。
 * 只有新目录已经落盘才发布 COMMITTED。恢复按记录里的精确目录 inode 和身份摘要判定，
 * 不看 mtime、不猜最新 backup；未知/损坏记录保留现场。COMMITTED 允许中断后继续清旧树。
 */
#include "jdk_install_store.h"
#include "jdk_install_io.h"
#include <cstdlib>
#include <elf.h>
#include <exception>
#include <optional>
#include <set>
#include <sstream>

#ifdef AMCL_JDK_INSTALL_TEST
extern "C" void amclJdkInstallTestCheckpoint(const char *name);
#endif

namespace amcl::jdk {
namespace {
using namespace io;
void Point(const char *name) {
#ifdef AMCL_JDK_INSTALL_TEST
    amclJdkInstallTestCheckpoint(name);
#else
    (void)name;
#endif
}
struct Slot {
    std::string files, major;
    Fd root, locks;
    Slot(const std::string &filesDir, const std::string &version) : files(filesDir), major(version) {
        Major(major);
        Require(!files.empty() && files.front() == '/' && files.back() != '/' && files.find('\0') == std::string::npos,
                "JDK 根路径无效");
        auto base = Directory(files);
        root = ChildDirectory(base.get(), "jdk", true);
        locks = ChildDirectory(root.get(), ".locks", true);
        // 首次安装时父目录本身也必须持久：只 fsync journal 所在目录不能保证 jdk/.locks
        // 这两个新目录项在断电后存在。已有目录走相同简短路径，不依赖创建结果猜耐久性。
        Sync(base.get());
        Sync(root.get());
    }
    void lease(int fd, const std::string &kind) {
        struct stat actual {
        }, path{};
        if (fd < 0 || fstat(fd, &actual) ||
            fstatat(locks.get(), (major + "." + kind).c_str(), &path, AT_SYMLINK_NOFOLLOW))
            Error("安装租约 fd 无效");
        Require(S_ISREG(actual.st_mode) && actual.st_nlink == 1 && actual.st_dev == path.st_dev &&
                    actual.st_ino == path.st_ino,
                "安装租约不是稳定锁 inode");
        // fd 来自本次 ArkTS 租约对象，flock 同一 OFD 不释放已有排他权；不能借别槽 fd 绕过协议。
        if (flock(fd, LOCK_EX | LOCK_NB))
            Error("无法确认 JDK 排他租约");
    }
    std::string relative(const std::string &stage) const {
        const std::string prefix = files + "/jdk/";
        Require(stage.rfind(prefix, 0) == 0, "staging 不在本 JDK 根内");
        const std::string relative = stage.substr(prefix.size());
        auto parts = Parts(relative);
        Require(parts.size() <= 2 && parts.front().rfind(".staging-" + major + "-", 0) == 0, "staging 不属于当前槽");
        return relative;
    }
};
std::string Inode(int fd) {
    struct stat st {};
    if (fstat(fd, &st))
        Error("无法读取目录身份");
    return std::to_string(uint64_t(st.st_dev)) + ":" + std::to_string(uint64_t(st.st_ino));
}
struct StageOwner {
    std::string directory, inode;
};
/** staging归属与payload分开存于稳定锁目录，用户导入备份不会把旧owner带进新任务。
 * writer保证同槽只有一个owner；COMMITTING另用journal，不因下载中存在owner阻塞旧JDK读者。 */
std::optional<StageOwner> ReadStageOwner(Slot &slot) {
    const auto name = slot.major + ".stage";
    if (!Exists(slot.locks.get(), name))
        return std::nullopt;
    const auto text = SmallFile(slot.locks.get(), name, 1024);
    std::vector<std::string> lines;
    std::istringstream stream(text);
    std::string line;
    while (std::getline(stream, line))
        lines.push_back(line);
    Require(lines.size() == 4 && lines[0] == "AMCL-JDK-STAGE-1" && text.back() == '\n', "JDK staging归属记录无效");
    const auto payload = lines[0] + "\n" + lines[1] + "\n" + lines[2] + "\n";
    Require(Hash(lines[3]) && Digest(payload) == lines[3], "JDK staging归属记录损坏");
    Require(Parts(lines[1]).size() == 1 && lines[1].rfind(".staging-" + slot.major + "-", 0) == 0,
            "JDK staging归属越过槽位");
    const auto colon = lines[2].find(':');
    Require(colon != std::string::npos && colon > 0 && colon + 1 < lines[2].size() &&
                lines[2].find(':', colon + 1) == std::string::npos &&
                lines[2].find_first_not_of("0123456789:") == std::string::npos,
            "JDK staging inode记录无效");
    return StageOwner{lines[1], lines[2]};
}
void SaveStageOwner(Slot &slot, const std::string &directory, int fd) {
    const auto name = slot.major + ".stage", temporary = name + ".tmp";
    // 临时记录只能是本协议的普通单链接文件；未知类型留在原处，不能跟随链接写入。
    if (Exists(slot.locks.get(), temporary)) {
        SmallFile(slot.locks.get(), temporary, 1024);
        if (unlinkat(slot.locks.get(), temporary.c_str(), 0))
            Error("无法移除staging归属暂存");
    }
    Fd file(openat(slot.locks.get(), temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600));
    if (file.get() < 0)
        Error("无法建立staging归属记录");
    const auto payload = "AMCL-JDK-STAGE-1\n" + directory + "\n" + Inode(fd) + "\n";
    const auto bytes = payload + Digest(payload) + '\n';
    Write(file.get(), bytes.data(), bytes.size());
    Point("stage-owner-write");
    Sync(file.get());
    if (renameat(slot.locks.get(), temporary.c_str(), slot.locks.get(), name.c_str()))
        Error("无法发布staging归属记录");
    Point("stage-owner-rename");
    Sync(slot.locks.get());
}
/** 不看目录时间或模式猜所有者；只有归属记录中的精确inode有删除资格。
 * journal先于任何清理，哪怕记录损坏也必须保留唯一新/旧副本。空的无owner目录保守保留。 */
void CollectStage(Slot &slot, const std::string &expected = "") {
    Require(!Exists(slot.locks.get(), slot.major + ".journal"), "存在JDK恢复记录，暂不回收staging");
    const auto owner = ReadStageOwner(slot);
    if (!owner) {
        Require(expected.empty() || !Exists(slot.root.get(), expected), "没有归属记录，拒绝清理未知staging");
        return;
    }
    Require(expected.empty() || expected == owner->directory, "staging路径不属于当前owner");
    if (Exists(slot.root.get(), owner->directory)) {
        auto dir = ChildDirectory(slot.root.get(), owner->directory);
        Require(Inode(dir.get()) == owner->inode, "staging inode已改变，保留现场");
        size_t count = 0;
        Remove(slot.root.get(), owner->directory, count);
        Point("stage-cleaned");
        Sync(slot.root.get());
    }
    if (unlinkat(slot.locks.get(), (slot.major + ".stage").c_str(), 0))
        Error("无法完成staging归属记录");
    Point("stage-owner-unlink");
    Sync(slot.locks.get());
}
void VerifyStage(Slot &slot, const std::string &relative) {
    const auto owner = ReadStageOwner(slot);
    const auto top = Parts(relative).front();
    Require(owner && owner->directory == top, "发布候选不属于已登记staging");
    auto dir = ChildDirectory(slot.root.get(), top);
    Require(Inode(dir.get()) == owner->inode, "发布候选staging inode已改变");
}
/** 收据/来源戳/封存摘要与目录 inode 同时绑定；合法 keytool 等数据修改不伪装成换安装。 */
std::string Identity(int fd) {
    std::string markers;
    for (const std::string name : {".amcl-runtime-receipt.json", ".amcl_release_tag", ".amcl-install-seal"}) {
        markers += name + "\n";
        markers += Exists(fd, name) ? Digest(SmallFile(fd, name, 4 * 1024 * 1024)) : "absent";
        markers += '\n';
    }
    return Inode(fd) + ":" + Digest(markers);
}
Fd RelativeDirectory(int root, const std::string &path) {
    auto parent = Parent(root, path);
    return ChildDirectory(parent.get(), Leaf(path));
}
bool Matches(Slot &slot, const std::string &name, const std::string &identity, bool inodeOnly = false) {
    if (!Exists(slot.root.get(), name))
        return false;
    auto dir = RelativeDirectory(slot.root.get(), name);
    return inodeOnly ? identity.rfind(Inode(dir.get()) + ":", 0) == 0 : Identity(dir.get()) == identity;
}
struct Journal {
    std::string phase, operation, stage, backup, previous, next;
};
Journal Decode(const std::string &text, const std::string &major) {
    Require(text.size() <= 4096 && !text.empty() && text.back() == '\n', "JDK journal 长度或终止符无效");
    std::vector<std::string> lines;
    std::istringstream stream(text);
    std::string line;
    while (std::getline(stream, line))
        lines.push_back(line);
    Require(lines.size() == 9 && lines[0] == "AMCL-JDK-1" && (lines[1] == "PREPARED" || lines[1] == "COMMITTED") &&
                (lines[2] == "install" || lines[2] == "delete"),
            "JDK journal 版本/状态无效");
    const auto payload = text.substr(0, text.size() - lines.back().size() - 1);
    Require(Hash(lines.back()) && Digest(payload) == lines.back(), "JDK journal 完整性校验失败");
    Journal j{lines[1], lines[2], lines[3], lines[4], lines[5], lines[6]};
    // 第 7 行是 next，索引保持显式；结构里每个路径都再做约束，记录不能授权任意删除。
    Require(lines[7].empty(), "JDK journal 保留字段无效");
    Require(j.backup.rfind(major + ".backup-", 0) == 0 && Parts(j.backup).size() == 1,
            "JDK journal backup 不属于当前槽");
    if (j.operation == "install")
        Require(Parts(j.stage).size() <= 2 && j.stage.rfind(".staging-" + major + "-", 0) == 0,
                "JDK journal staging 不属于当前槽");
    else
        Require(j.stage.empty() && j.next.empty(), "删除 journal 不能指定新安装");
    return j;
}
void Save(Slot &slot, const Journal &journal) {
    const auto name = slot.major + ".journal", temp = name + ".tmp";
    if (Exists(slot.locks.get(), temp)) {
        struct stat st {};
        if (fstatat(slot.locks.get(), temp.c_str(), &st, AT_SYMLINK_NOFOLLOW))
            Error("无法检查 journal 暂存");
        Require(S_ISREG(st.st_mode) && st.st_nlink == 1, "journal 暂存不是普通文件");
        if (unlinkat(slot.locks.get(), temp.c_str(), 0))
            Error("无法清理 journal 暂存");
    }
    Fd fd(openat(slot.locks.get(), temp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
    if (fd.get() < 0)
        Error("无法建立 journal");
    // 空保留字段令将来协议扩展显式失败，不接受尾随未解释数据。
    const std::string payload = "AMCL-JDK-1\n" + journal.phase + "\n" + journal.operation + "\n" + journal.stage +
                                "\n" + journal.backup + "\n" + journal.previous + "\n" + journal.next + "\n\n";
    const auto bytes = payload + Digest(payload) + '\n';
    Write(fd.get(), bytes.data(), bytes.size());
    Point("journal-write");
    Sync(fd.get());
    Point("journal-file-fsync");
    if (renameat(slot.locks.get(), temp.c_str(), slot.locks.get(), name.c_str()))
        Error("无法发布 journal");
    Point("journal-rename");
    Sync(slot.locks.get());
    Point("journal-dir-fsync");
}
void RemoveJournal(Slot &slot) {
    if (unlinkat(slot.locks.get(), (slot.major + ".journal").c_str(), 0))
        Error("无法完成 journal");
    Point("journal-unlink");
    Sync(slot.locks.get());
    Point("journal-remove-fsync");
}
void Rename(Slot &slot, const std::string &from, const std::string &to, const char *checkpoint) {
    auto parent = Parent(slot.root.get(), from);
    if (renameat(parent.get(), Leaf(from).c_str(), slot.root.get(), to.c_str()))
        Error("JDK 目录切换失败");
    Point(checkpoint);
    Sync(parent.get());
    Sync(slot.root.get());
    Point("rename-dir-fsync");
}
/** COMMITTED 的目标始终先验身份，清理可以重入；仅 inode 身份授权清理部分删除的 backup。 */
void Finish(Slot &slot, const Journal &journal) {
    if (journal.operation == "install")
        Require(Matches(slot, slot.major, journal.next), "已提交 JDK 目标身份不匹配，保留现场");
    else
        Require(!Exists(slot.root.get(), slot.major), "已提交删除却发现其他 JDK，保留现场");
    if (Exists(slot.root.get(), journal.backup)) {
        Require(!journal.previous.empty() && Matches(slot, journal.backup, journal.previous, true),
                "JDK backup inode 改变，保留现场");
        size_t count = 0;
        Remove(slot.root.get(), journal.backup, count);
        Point("backup-cleaned");
        Sync(slot.root.get());
    }
    RemoveJournal(slot);
    CollectStage(slot);
}
void Recover(Slot &slot) {
    const auto name = slot.major + ".journal";
    if (!Exists(slot.locks.get(), name))
        return;
    auto journal = Decode(SmallFile(slot.locks.get(), name, 4096), slot.major);
    if (journal.phase == "COMMITTED") {
        Finish(slot, journal);
        return;
    }
    if (journal.operation == "delete") {
        if (Exists(slot.root.get(), slot.major)) {
            Require(Matches(slot, slot.major, journal.previous) && !Exists(slot.root.get(), journal.backup),
                    "删除恢复发现未知目录组合");
            Rename(slot, slot.major, journal.backup, "delete-rename");
        }
        Require(Matches(slot, journal.backup, journal.previous), "删除恢复缺少原目录");
        journal.phase = "COMMITTED";
        Save(slot, journal);
        Finish(slot, journal);
        return;
    }
    if (Matches(slot, slot.major, journal.next)) {
        Sync(slot.root.get());
        journal.phase = "COMMITTED";
        Save(slot, journal);
        Finish(slot, journal);
        return;
    }
    // 新目录未发布时恢复旧目录；旧目录本来不存在，则维持未安装状态。staging 不凭名称删除。
    if (journal.previous.empty())
        Require(!Exists(slot.root.get(), slot.major) && !Exists(slot.root.get(), journal.backup),
                "首次安装恢复发现未知目标");
    else if (Exists(slot.root.get(), slot.major))
        Require(Matches(slot, slot.major, journal.previous) && !Exists(slot.root.get(), journal.backup),
                "恢复目标不是 journal 中的旧安装");
    else {
        Require(Matches(slot, journal.backup, journal.previous), "恢复缺少已认领的旧安装");
        Rename(slot, journal.backup, slot.major, "rollback-rename");
    }
    RemoveJournal(slot);
    CollectStage(slot);
}
/** 校验真实系统执行文件的 ELF 头、完整程序头、入口、解释器和动态依赖字符串。 */
void Executable(int fd, uint64_t size, const std::string &relative, const std::set<std::string> &libraries) {
    if (relative == "bin/java-rmi.cgi" || relative == "jre/bin/java-rmi.cgi") {
        Require(size >= 10 && size <= 1024 * 1024, "JDK8 CGI 工具大小无效");
        std::string script(size, '\0');
        Read(fd, script.data(), script.size(), 0);
        Require(script.rfind("#!/bin/sh\n", 0) == 0 && script.find('\0') == std::string::npos, "JDK8 CGI 工具格式无效");
        return;
    }
    Require(size >= sizeof(Elf64_Ehdr), "JDK 可执行文件已截断：" + relative);
    Elf64_Ehdr h{};
    Read(fd, &h, sizeof(h), 0);
    Require(memcmp(h.e_ident, "\177ELF\2\1\1", 7) == 0 && h.e_machine == EM_AARCH64 && h.e_version == EV_CURRENT &&
                (h.e_type == ET_DYN || h.e_type == ET_EXEC) && h.e_ehsize == sizeof(h) &&
                h.e_phentsize == sizeof(Elf64_Phdr) && h.e_phnum > 0 && h.e_phnum <= 1024 && h.e_phoff >= sizeof(h) &&
                h.e_phoff <= size && uint64_t(h.e_phnum) * sizeof(Elf64_Phdr) <= size - h.e_phoff && h.e_entry % 4 == 0,
            "JDK 工具不是有效 AArch64 ELF：" + relative);
    std::vector<Elf64_Phdr> ph(h.e_phnum);
    Read(fd, ph.data(), ph.size() * sizeof(Elf64_Phdr), h.e_phoff);
    bool entry = false;
    unsigned interpreters = 0, dynamics = 0;
    Elf64_Phdr dynamic{};
    for (const auto &p : ph) {
        Require(p.p_offset <= size && p.p_filesz <= size - p.p_offset, "JDK 工具程序段越界");
        if (p.p_type == PT_LOAD) {
            Require(
                p.p_filesz <= p.p_memsz && p.p_memsz <= UINT64_MAX - p.p_vaddr &&
                    (p.p_align <= 1 || (!(p.p_align & (p.p_align - 1)) && (p.p_vaddr - p.p_offset) % p.p_align == 0)),
                "JDK 工具 LOAD 无效");
            entry |= (p.p_flags & PF_X) && h.e_entry >= p.p_vaddr && h.e_entry - p.p_vaddr < p.p_filesz;
        }
        if (p.p_type == PT_INTERP) {
            ++interpreters;
            Require(p.p_filesz == sizeof("/lib/ld-musl-aarch64.so.1"), "JDK 工具解释器长度错误");
            std::string interp(p.p_filesz, '\0');
            Read(fd, interp.data(), interp.size(), p.p_offset);
            Require(interp == std::string("/lib/ld-musl-aarch64.so.1\0", p.p_filesz), "JDK 工具解释器不匹配 OHOS");
        }
        if (p.p_type == PT_DYNAMIC) {
            ++dynamics;
            dynamic = p;
        }
    }
    Require(entry && interpreters == 1 && dynamics == 1 && dynamic.p_filesz <= 1024 * 1024 &&
                dynamic.p_filesz % sizeof(Elf64_Dyn) == 0,
            "JDK 工具缺少入口/唯一动态表/解释器");
    std::vector<Elf64_Dyn> dyn(dynamic.p_filesz / sizeof(Elf64_Dyn));
    Read(fd, dyn.data(), dynamic.p_filesz, dynamic.p_offset);
    uint64_t strtab = 0, strsize = 0;
    bool terminated = false;
    std::vector<uint64_t> needed;
    for (const auto &d : dyn) {
        if (d.d_tag == DT_NULL) {
            terminated = true;
            break;
        }
        if (d.d_tag == DT_STRTAB)
            strtab = d.d_un.d_ptr;
        if (d.d_tag == DT_STRSZ)
            strsize = d.d_un.d_val;
        if (d.d_tag == DT_NEEDED)
            needed.push_back(d.d_un.d_val);
    }
    Require(terminated && strsize > 0 && strsize <= 1024 * 1024, "JDK 工具动态字符串无效");
    bool mapped = false;
    uint64_t offset = 0;
    for (const auto &p : ph)
        if (p.p_type == PT_LOAD && strtab >= p.p_vaddr && strtab - p.p_vaddr <= p.p_filesz &&
            strsize <= p.p_filesz - (strtab - p.p_vaddr)) {
            mapped = true;
            offset = p.p_offset + strtab - p.p_vaddr;
            break;
        }
    Require(mapped, "JDK 工具动态字符串未由 LOAD 覆盖");
    std::string strings(strsize, '\0');
    Read(fd, strings.data(), strings.size(), offset);
    const std::set<std::string> system{
        "libc.so", "libm.so", "libdl.so", "libpthread.so", "librt.so", "libz.so", "ld-musl-aarch64.so.1"};
    for (const auto n : needed) {
        Require(n < strings.size(), "JDK 工具依赖字符串越界");
        const auto end = strings.find('\0', n);
        Require(end != std::string::npos, "JDK 工具依赖无终止符");
        const auto name = strings.substr(n, end - n);
        Require(Parts(name).size() == 1 && (libraries.count(name) || system.count(name)), "JDK 工具缺少依赖：" + name);
    }
}
/**
 * 精准保留稳定JDK17 v5/JDK21 v7原件中的旧helper。这些公开包只有JVM运行层，其jspawnhelper仍是
 * ld-linux解释器字段的历史版本；不能把已发布payload误授予“已验证OHOS工具”的资格，也不能因
 * 新增完整JDK工具检查拒绝整包安装。例外同时绑定槽、整个已验ZIP、唯一路径、大小和
 * helper完整SHA；未知导入/新R12/任意篡改仍进入原严格musl验证，绝不扩充解释器白名单。
 * 此函数只识别既有字节，不改文件、执行目标或绕过外层无链接/单inode/权限/封存检查。
 */
bool RetainedLegacyHelper(int fd, uint64_t size, const std::string &relative,
                          const std::string &major, const std::string &archiveSha) {
    if (relative != "lib/jspawnhelper") return false;
    // JDK17 v5与已处理的JDK21 v7同属历史发行原件：保留其精确字节以维持普通通道切换，
    // 不给Linux解释器授予OHOS执行资格。任何一个绑定字段变化都退回严格工具校验。
    uint64_t expectedSize = 0;
    const char *expectedSha = nullptr;
    if (major == "21" && archiveSha == "21556d0d4fc5eea09ba27068cf8a96803bb1667b35adbc8495fdc5f831316275") {
        expectedSize = 23200;
        expectedSha = "b2d14931d6ada5aafc3367d810013144c4d52cf125e3614d53e0907c0056fb9a";
    } else if (major == "17" && archiveSha == "0e26b0dece38156838456cfb12058d863aa9856cdd8fd648f06f9bc5e91f8ecd") {
        expectedSize = 18624;
        expectedSha = "8c1507458c7de60c16acae78a131f779941d2ab1c4a4f83466d05ac295c6ef96";
    } else return false;
    Require(size == expectedSize, "历史JDK helper大小不匹配");
    std::vector<unsigned char> bytes(static_cast<size_t>(size));
    Read(fd, bytes.data(), bytes.size(), 0);
    download::Sha256 hash;
    hash.update(bytes.data(), bytes.size());
    Require(hash.finalizeHex() == expectedSha, "历史JDK helper内容不匹配");
    return true;
}
/** 安装期遍历有界；所有文件重新读取实际字节并哈希，目录最后 fsync，绝不把 ZIP CRC 当 SHA。 */
void SealTree(int fd, const std::string &prefix, download::Sha256 &sha, size_t &count, uint64_t &bytes,
              const std::set<std::string> &libraries, const std::string &major, const std::string &archiveSha,
              size_t depth = 0) {
    Require(depth <= MaxDepth, "JDK 封存深度超限");
    for (const auto &name : Names(fd)) {
        if (prefix.empty() && name == ".amcl-install-seal")
            continue;
        Require(++count <= MaxEntries, "JDK 封存条目超限");
        const auto path = prefix.empty() ? name : prefix + "/" + name;
        struct stat st {};
        if (fstatat(fd, name.c_str(), &st, AT_SYMLINK_NOFOLLOW))
            Error("无法读取 JDK 文件属性");
        if (S_ISDIR(st.st_mode)) {
            auto child = ChildDirectory(fd, name);
            if (fchmod(child.get(), 0755))
                Error("无法恢复 JDK 目录权限");
            struct stat mode {};
            if (fstat(child.get(), &mode))
                Error("无法回读 JDK 目录权限");
            Require((mode.st_mode & 07777) == 0755, "JDK 目录权限未生效");
            const auto description = "D " + path + " 0755\n";
            sha.update(description.data(), description.size());
            SealTree(child.get(), path, sha, count, bytes, libraries, major, archiveSha, depth + 1);
            continue;
        }
        Require(S_ISREG(st.st_mode) && st.st_nlink == 1 && st.st_size >= 0 && uint64_t(st.st_size) <= MaxBytes - bytes,
                "JDK 含链接/特殊文件或超限内容");
        bytes += st.st_size;
        Fd file(openat(fd, name.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
        if (file.get() < 0)
            Error("无法封存 JDK 文件");
        const bool executable = path.rfind("bin/", 0) == 0 || path.rfind("jre/bin/", 0) == 0 ||
                                path == "lib/jspawnhelper" || path == "jre/lib/aarch64/jspawnhelper";
        if (executable) {
            // 精准旧payload继续保留原0755及真实权限回读；它不被改写或当作musl工具。
            if (!RetainedLegacyHelper(file.get(), st.st_size, path, major, archiveSha))
                Executable(file.get(), st.st_size, path, libraries);
            if (fchmod(file.get(), 0755))
                Error("JDK 工具执行权限设置失败");
        }
        struct stat before {};
        if (fstat(file.get(), &before))
            Error("无法回读 JDK 工具权限");
        Require(st.st_dev == before.st_dev && st.st_ino == before.st_ino && before.st_nlink == 1 &&
                    (!executable || (before.st_mode & 07777) == 0755),
                "JDK 文件身份或执行权限未生效");
        // 深度可达64，缓冲区在堆上且仅处理普通文件时存在，不能每层递归占256KiB线程栈。
        download::Sha256 fileHash;
        std::vector<unsigned char> buffer(Chunk);
        for (uint64_t at = 0; at < uint64_t(before.st_size);) {
            const size_t n = std::min<uint64_t>(buffer.size(), before.st_size - at);
            Read(file.get(), buffer.data(), n, at);
            fileHash.update(buffer.data(), n);
            at += n;
        }
        Sync(file.get());
        struct stat after {};
        if (fstat(file.get(), &after))
            Error("无法复核 JDK 文件");
        Require(before.st_size == after.st_size && before.st_mtim.tv_sec == after.st_mtim.tv_sec &&
                    before.st_mtim.tv_nsec == after.st_mtim.tv_nsec,
                "JDK 封存时文件被修改");
        const auto description = "F " + path + " " + std::to_string(before.st_mode & 07777) + " " +
                                 std::to_string(before.st_size) + " " + fileHash.finalizeHex() + "\n";
        sha.update(description.data(), description.size());
    }
    Sync(fd);
    Point("payload-dir-fsync");
}
void LibraryNames(int fd, std::set<std::string> &names, size_t &count, size_t depth = 0) {
    Require(depth <= MaxDepth, "JDK 目录深度超限");
    for (const auto &name : Names(fd)) {
        Require(++count <= MaxEntries, "JDK 条目数量超限");
        struct stat st {};
        if (fstatat(fd, name.c_str(), &st, AT_SYMLINK_NOFOLLOW))
            Error("无法枚举 JDK 库");
        if (S_ISDIR(st.st_mode)) {
            auto dir = ChildDirectory(fd, name);
            LibraryNames(dir.get(), names, count, depth + 1);
        } else {
            Require(S_ISREG(st.st_mode) && st.st_nlink == 1, "JDK 含链接或特殊文件");
            names.insert(name);
        }
    }
}
} // namespace

std::string CreateInstallStage(const std::string &filesDir, const std::string &major, int writerFd) {
    Slot slot(filesDir, major);
    slot.lease(writerFd, "writer");
    Require(!Exists(slot.locks.get(), major + ".journal"), "创建 staging 前必须恢复前次事务");
    CollectStage(slot);
    std::string path = filesDir + "/jdk/.staging-" + major + "-XXXXXX";
    Require(mkdtemp(path.data()) != nullptr, "无法创建唯一 JDK staging");
    Sync(slot.root.get());
    auto dir = ChildDirectory(slot.root.get(), Leaf(path));
    SaveStageOwner(slot, Leaf(path), dir.get());
    return path;
}
void DiscardInstallStage(const std::string &filesDir, const std::string &major, const std::string &stage,
                         int writerFd) {
    if (stage.empty())
        return;
    Slot slot(filesDir, major);
    slot.lease(writerFd, "writer");
    const auto relative = slot.relative(stage);
    // 记录损坏也不能删除潜在唯一好副本；恢复不成功就保留全部关联 staging。
    if (Exists(slot.locks.get(), major + ".journal"))
        return;
    CollectStage(slot, Parts(relative).front());
}
bool InstallRecoveryRequired(const std::string &filesDir, const std::string &major) {
    Major(major);
    struct stat st {};
    const auto path = filesDir + "/jdk/.locks/" + major + ".journal";
    if (lstat(path.c_str(), &st) == 0)
        return true;
    if (errno == ENOENT)
        return false;
    Error("无法检查 JDK 恢复状态");
}
void RecoverInstallSlot(const std::string &filesDir, const std::string &major, int writerFd, int useFd) {
    Slot slot(filesDir, major);
    slot.lease(writerFd, "writer");
    slot.lease(useFd, "use");
    Recover(slot);
    CollectStage(slot);
}
void CollectAbandonedInstallStage(const std::string &filesDir, const std::string &major, int writerFd) {
    Slot slot(filesDir, major);
    slot.lease(writerFd, "writer");
    CollectStage(slot);
}
void SealInstallStage(const std::string &path, const std::string &major, const std::string &archiveSha) {
    Major(major);
    Require(Hash(archiveSha), "JDK 封存缺少归档身份");
    auto root = Directory(path);
    if (Exists(root.get(), ".amcl-install-seal")) {
        SmallFile(root.get(), ".amcl-install-seal");
        if (unlinkat(root.get(), ".amcl-install-seal", 0))
            Error("无法移除包内非可信封存记录");
    }
    // 现代完整 JDK 必须带真实 helper，JDK8 经典 fork/exec 不强加该文件。
    if (major != "8") {
        auto lib = ChildDirectory(root.get(), "lib");
        Require(Exists(lib.get(), "jspawnhelper"), "现代 JDK 缺少 jspawnhelper");
    }
    std::set<std::string> names;
    size_t count = 0;
    LibraryNames(root.get(), names, count);
    count = 0;
    uint64_t bytes = 0;
    download::Sha256 sha;
    SealTree(root.get(), "", sha, count, bytes, names, major, archiveSha);
    const auto seal = "AMCL-JDK-SEAL-1\n" + major + "\n" + archiveSha + "\n" + sha.finalizeHex() + "\n";
    Fd file(openat(root.get(), ".amcl-install-seal", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600));
    if (file.get() < 0)
        Error("无法写入 JDK 封存记录");
    Write(file.get(), seal.data(), seal.size());
    Sync(file.get());
    Point("seal-file-fsync");
    Sync(root.get());
    Point("seal-dir-fsync");
}
void PublishInstallStage(const std::string &filesDir, const std::string &major, const std::string &stage, int writerFd,
                         int useFd) {
    Slot slot(filesDir, major);
    slot.lease(writerFd, "writer");
    slot.lease(useFd, "use");
    Recover(slot);
    const auto relative = slot.relative(stage);
    VerifyStage(slot, relative);
    auto fresh = RelativeDirectory(slot.root.get(), relative);
    const auto seal = SmallFile(fresh.get(), ".amcl-install-seal");
    Require(seal.rfind("AMCL-JDK-SEAL-1\n" + major + "\n", 0) == 0, "JDK staging 未完成当前槽的封存");
    Journal j{"PREPARED", "install",
              relative,   major + ".backup-" + Parts(relative).front().substr(10 + major.size()),
              "",         Identity(fresh.get())};
    Require(!Exists(slot.root.get(), j.backup), "JDK backup 已存在，拒绝覆盖");
    if (Exists(slot.root.get(), major)) {
        auto old = ChildDirectory(slot.root.get(), major);
        j.previous = Identity(old.get());
        Sync(old.get());
    }
    Save(slot, j);
    try {
        if (!j.previous.empty())
            Rename(slot, major, j.backup, "old-rename");
        Rename(slot, relative, major, "new-rename");
        j.phase = "COMMITTED";
        Save(slot, j);
        Finish(slot, j);
    } catch (...) {
        // 真正崩溃没有 catch；正常 I/O 失败也通过相同恢复算法，避免两套回滚语义分叉。
        auto failure = std::current_exception();
        try {
            Recover(slot);
            if (Matches(slot, major, j.next))
                return;
        } catch (...) { /* 保留 journal 和全部关联目录。 */
        }
        std::rethrow_exception(failure);
    }
}
void DeleteInstallSlot(const std::string &filesDir, const std::string &major, int writerFd, int useFd) {
    Slot slot(filesDir, major);
    slot.lease(writerFd, "writer");
    slot.lease(useFd, "use");
    Recover(slot);
    if (!Exists(slot.root.get(), major))
        return;
    auto old = ChildDirectory(slot.root.get(), major);
    // 删除使用新建临时目录产生唯一名字，再移除空壳；不覆盖任何已有 backup。
    const auto temporary = CreateInstallStage(filesDir, major, writerFd);
    const auto leaf = Leaf(temporary);
    if (unlinkat(slot.root.get(), leaf.c_str(), AT_REMOVEDIR))
        Error("无法准备删除备份名");
    Journal j{"PREPARED", "delete", "", major + ".backup-" + leaf.substr(10 + major.size()), Identity(old.get()), ""};
    Save(slot, j);
    Recover(slot);
}
} // namespace amcl::jdk
