/**
 * 真实生产 loader 的 AArch64 集成负例：只替换平台日志与无关 IPv6 文件合成。
 * 验证强/弱导入、依赖失败、整批回滚、构造时序、重复失败和历史 JLI 精确兼容。
 */
#include "../../entry/src/main/cpp/jvm/elf_loader.cpp"
#include <cassert>
#include <fstream>
#include <iostream>
#include <thread>

static int marks = 0;
static std::string probePath;
static int concurrentProbes = 0;
/** 两种构造器都会等待独立查询线程；超时代表发生锁跨构造回调的死锁。 */
extern "C" void test_concurrent_probe(void) {
    std::thread probe{[] {
        assert(!elf_open(probePath.c_str()));
        assert(strstr(elf_error(), "initializing"));
        ++concurrentProbes;
    }};
    probe.join();
}
extern "C" void test_mark(int value) { marks += value; }
extern "C" void amclLogPrint(AmclLogLevel, unsigned int, const char*, const char*, ...) {}
extern "C" void amclLogWrite(AmclLogLevel, const char*, const char*, ...) {}
FILE* amclIfInet6ShimOpen(const char*, const char*) { return nullptr; }

/** 用已发布库原字节验证兼容分支；改动一个字节后必须拒绝，不依赖库内代码执行。 */
static void check_legacy(const std::string& path) {
    if (path.empty()) return;
    elf_handle_t h{};
    h.name = "libjli.so";
    h.path = path;
    auto fn = reinterpret_cast<unsigned char(*)()>(resolve_legacy_jli(&h, "JLI_IsStaticallyLinked"));
    assert(fn && fn() == 0);
    assert(!resolve_legacy_jli(&h, "unrelated_symbol"));
    elf_handle_t other{};
    other.name = "unrelated.so";
    other.path = path;
    assert(!resolve_legacy_jli(&other, "JLI_IsStaticallyLinked"));
}

int main(int argc, char** argv) {
    assert(argc >= 2);
    const std::string root = argv[1];
    elf_set_search_path(root.c_str());
    for (int n = 0; n < 2; ++n) {
        assert(!elf_open((root + "/libmissing.so").c_str()));
        assert(strstr(elf_error(), "missing_platform_function"));
        assert(marks == 0);
        assert(!elf_sym_global("bad_export"));
    }
    assert(!elf_open((root + "/libparent.so").c_str()));
    assert(marks == 0); // 依赖 good 已链接但构造尚未执行。
    assert(!elf_sym_global("good_value"));
    auto* good = elf_open((root + "/libgood.so").c_str());
    assert(good && marks == 1);
    assert(*static_cast<int*>(elf_sym(good, "good_value")) == 17);
    for (int kind : {1024, 1028, 1029, 1030, 1032, 4095}) {
        assert(!elf_open((root + "/libunsupported-" + std::to_string(kind) + ".so").c_str()));
        assert(strstr(elf_error(), "unsupported"));
        assert(marks == 1);
    }
    auto* weak = elf_open((root + "/libweak.so").c_str());
    assert(weak && reinterpret_cast<int(*)()>(elf_sym(weak, "weak_value"))() == 0);
    auto* cycle = elf_open((root + "/libcycle_a.so").c_str());
    assert(cycle && marks == 19);
    assert(reinterpret_cast<int(*)()>(elf_sym(cycle, "cycle_sum"))() == 18);
    probePath = root + "/libconcurrent.so";
    assert(elf_open(probePath.c_str()) && concurrentProbes == 1);
    probePath = root + "/libneeds_system.so";
    auto* system = elf_open(probePath.c_str());
    assert(system && concurrentProbes == 2);
    assert(reinterpret_cast<int(*)()>(elf_sym(system, "read_system_value"))() == 34);
    if (argc > 2) check_legacy(argv[2]);
    std::cout << "PASS real AArch64 ELF linking, rollback, weak imports and cyclic constructors\n";
}
