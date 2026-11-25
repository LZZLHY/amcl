// 只用临时私有目录替代应用沙箱，覆盖生产文件的所有权、失败回滚和换名重试。
#include "../../platform/mobile_gamepad_publication.h"
#include <cstdlib>
#include <string>

#define REQUIRE(check) do { if (!(check)) { fprintf(stderr, "publication check failed at %d\n", __LINE__); exit(1); } } while (0)
static bool allowCapture = true;
static bool Capture(bool enabled) { return !enabled || allowCapture; }

int main() {
    char directory[] = "mobile-gamepad-XXXXXX";
    REQUIRE(mkdtemp(directory));
    const std::string path = std::string(directory) + "/reader";
    const std::string renamed = path + ".original";
    const AmclGamepadReaderDescriptor record{0, 1, sizeof(AmclDesktopGamepad), static_cast<uint32_t>(getpid()),
        reinterpret_cast<uintptr_t>(&Capture)};
    amcl::desktop::MobileGamepadPublication owner;
    auto configure = [&](bool enabled) { return owner.Configure(enabled, path.c_str(), record, Capture); };
    REQUIRE(configure(false) && access(path.c_str(), F_OK) < 0);
    allowCapture = false;
    REQUIRE(!configure(true) && access(path.c_str(), F_OK) < 0);
    allowCapture = true;
    REQUIRE(configure(true) && owner.OwnsFile());
    REQUIRE(configure(true) && configure(false) && !owner.OwnsFile() && access(path.c_str(), F_OK) < 0);
    // 预先存在的同名文件不接管。文件被替换，或同一 inode 已写入桌面前缀，也必须保留。
    int foreign = open(path.c_str(), O_CREAT | O_EXCL | O_WRONLY, 0600);
    REQUIRE(foreign >= 0);
    close(foreign);
    REQUIRE(!configure(true) && access(path.c_str(), F_OK) == 0);
    // 同 PID 合法旧移动记录（模拟强杀），才准许重建；其它 PID 或桌面发布必须保全。
    foreign = open(path.c_str(), O_RDWR);
    AmclGamepadReaderDescriptor old = record;
    old.reader = 0x10000;
    ++old.pid;
    REQUIRE(foreign >= 0 && pwrite(foreign, &old, sizeof(old), 0) == sizeof(old));
    REQUIRE(!configure(true));
    --old.pid;
    old.desktopGetter = 1;
    REQUIRE(pwrite(foreign, &old, sizeof(old), 0) == sizeof(old) && !configure(true));
    old.desktopGetter = 0;
    REQUIRE(pwrite(foreign, &old, sizeof(old), 0) == sizeof(old) && configure(true));
    struct stat previous{}, current{};
    REQUIRE(fstat(foreign, &previous) == 0 && stat(path.c_str(), &current) == 0 && previous.st_ino != current.st_ino);
    close(foreign);
    REQUIRE(rename(path.c_str(), renamed.c_str()) == 0);
    foreign = open(path.c_str(), O_CREAT | O_EXCL | O_WRONLY, 0600);
    REQUIRE(foreign >= 0);
    close(foreign);
    REQUIRE(configure(false) && access(path.c_str(), F_OK) == 0);
    REQUIRE(unlink(path.c_str()) == 0 && unlink(renamed.c_str()) == 0 && configure(true));
    const uintptr_t desktop = 100;
    foreign = open(path.c_str(), O_WRONLY);
    REQUIRE(foreign >= 0 && pwrite(foreign, &desktop, sizeof(desktop), 0) == sizeof(desktop));
    close(foreign);
    REQUIRE(configure(false) && access(path.c_str(), F_OK) == 0);
    REQUIRE(unlink(path.c_str()) == 0 && rmdir(directory) == 0);
    puts("mobile gamepad mapped / activation retry / own-file-only retirement PASS");
}
