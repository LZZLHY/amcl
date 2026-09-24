#include <sys/mman.h>
#include <sys/syscall.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <dlfcn.h>
#include <sstream>
#include <string>
#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "JIT_TEST"

static std::string g_results;

static void appendResult(const char* testName, bool success, const char* detail) {
    g_results += testName;
    g_results += ": ";
    g_results += success ? "✅ 允许" : "❌ 被禁止";
    g_results += " (";
    g_results += detail;
    g_results += ")\n";
    OH_LOG_INFO(LOG_APP, "[%{public}s] %{public}s - %{public}s",
                testName, success ? "ALLOWED" : "BLOCKED", detail);
}

// 测试1：匿名内存 + PROT_READ|PROT_WRITE|PROT_EXEC
static void test1_anon_rwx() {
    void* p = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        char buf[128];
        snprintf(buf, sizeof(buf), "mmap失败, errno=%d (%s)", errno, strerror(errno));
        appendResult("测试1 [匿名RWX]", false, buf);
    } else {
        char buf[128];
        snprintf(buf, sizeof(buf), "mmap成功, addr=%p", p);
        appendResult("测试1 [匿名RWX]", true, buf);
        munmap(p, 4096);
    }
}

// 测试2：匿名内存先 RW，再 mprotect 加 EXEC
static void test2_anon_rw_then_exec() {
    void* p = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        appendResult("测试2 [匿名RW→EXEC]", false, "mmap RW 失败");
        return;
    }

    // 写入 ARM64 ret 指令: 0xd65f03c0
    uint32_t ret_insn = 0xd65f03c0;
    memcpy(p, &ret_insn, sizeof(ret_insn));

    int rc = mprotect(p, 4096, PROT_READ | PROT_EXEC);
    if (rc == -1) {
        char buf[128];
        snprintf(buf, sizeof(buf), "mprotect失败, errno=%d (%s)", errno, strerror(errno));
        appendResult("测试2 [匿名RW→EXEC]", false, buf);
    } else {
        // 尝试执行 ret 指令
        typedef void (*func_t)(void);
        ((func_t)p)();
        appendResult("测试2 [匿名RW→EXEC]", true, "mprotect成功且执行成功");
    }
    munmap(p, 4096);
}

// 测试3：文件映射 + PROT_EXEC
static void test3_file_exec(const char* sandboxPath) {
    char filepath[512];
    snprintf(filepath, sizeof(filepath), "%s/test_code.bin", sandboxPath);

    // 创建包含 ARM64 ret 指令的文件
    int fd = open(filepath, O_RDWR | O_CREAT | O_TRUNC, 0755);
    if (fd < 0) {
        char buf[256];
        snprintf(buf, sizeof(buf), "创建文件失败: %s, errno=%d", filepath, errno);
        appendResult("测试3 [文件映射EXEC]", false, buf);
        return;
    }
    uint32_t ret_insn = 0xd65f03c0;
    write(fd, &ret_insn, sizeof(ret_insn));
    // 填充到4096字节（一个页）
    char zeros[4092] = {0};
    write(fd, zeros, sizeof(zeros));
    close(fd);

    // 以只读方式重新打开并映射为可执行
    fd = open(filepath, O_RDONLY);
    if (fd < 0) {
        appendResult("测试3 [文件映射EXEC]", false, "重新打开文件失败");
        return;
    }
    void* p = mmap(NULL, 4096, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, 0);
    close(fd);

    if (p == MAP_FAILED) {
        char buf[128];
        snprintf(buf, sizeof(buf), "mmap失败, errno=%d (%s)", errno, strerror(errno));
        appendResult("测试3 [文件映射EXEC]", false, buf);
    } else {
        // 尝试执行
        typedef void (*func_t)(void);
        ((func_t)p)();
        appendResult("测试3 [文件映射EXEC]", true, "文件映射可执行且执行成功");
        munmap(p, 4096);
    }

    unlink(filepath);
}

// 测试4：memfd_create + PROT_EXEC
static void test4_memfd_exec() {
#ifdef __NR_memfd_create
    int fd = syscall(__NR_memfd_create, "jit_test", 0);
    if (fd < 0) {
        char buf[128];
        snprintf(buf, sizeof(buf), "memfd_create失败, errno=%d (%s) - 可能被seccomp拦截",
                 errno, strerror(errno));
        appendResult("测试4 [memfd EXEC]", false, buf);
        return;
    }

    uint32_t ret_insn = 0xd65f03c0;
    write(fd, &ret_insn, sizeof(ret_insn));
    char zeros[4092] = {0};
    write(fd, zeros, sizeof(zeros));

    void* p = mmap(NULL, 4096, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, 0);
    close(fd);

    if (p == MAP_FAILED) {
        char buf[128];
        snprintf(buf, sizeof(buf), "mmap失败, errno=%d (%s)", errno, strerror(errno));
        appendResult("测试4 [memfd EXEC]", false, buf);
    } else {
        appendResult("测试4 [memfd EXEC]", true, "memfd可执行映射成功");
        munmap(p, 4096);
    }
#else
    appendResult("测试4 [memfd EXEC]", false, "__NR_memfd_create 未定义");
#endif
}

// 测试5：dlopen 验证（验证 .so 文件加载是否正常）
static void test5_dlopen() {
    // 尝试 dlopen 系统库来验证 dlopen 机制本身可用
    void* handle = dlopen("libhilog_ndk.z.so", RTLD_NOW);
    if (!handle) {
        char buf[256];
        snprintf(buf, sizeof(buf), "dlopen失败: %s", dlerror());
        appendResult("测试5 [dlopen系统库]", false, buf);
    } else {
        appendResult("测试5 [dlopen系统库]", true, "dlopen系统库成功, 文件映射可执行路径可用");
        dlclose(handle);
    }
}

// 测试6：mmap 普通内存（不带 EXEC，验证 mmap 基础功能）
static void test6_anon_rw() {
    void* p = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        char buf[128];
        snprintf(buf, sizeof(buf), "mmap失败, errno=%d (%s)", errno, strerror(errno));
        appendResult("测试6 [匿名RW基础]", false, buf);
    } else {
        // 写入数据验证
        memset(p, 0xAB, 4096);
        uint8_t val = ((uint8_t*)p)[0];
        char buf[128];
        snprintf(buf, sizeof(buf), "mmap成功, 写入验证: 0x%02X", val);
        appendResult("测试6 [匿名RW基础]", val == 0xAB, buf);
        munmap(p, 4096);
    }
}

// 测试7：RWX 分配 → 写入代码 → mprotect 为 RX → 执行（模拟 HotSpot CodeCache）
static void test7_rwx_write_protect_exec() {
    void* p = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        appendResult("测试7 [RWX→写入→RX→执行]", false, "mmap RWX 失败");
        return;
    }
    // 写入 ARM64: mov x0, #42; ret
    uint32_t code[] = { 0xd2800540, 0xd65f03c0 }; // mov x0, #42; ret
    memcpy(p, code, sizeof(code));
    __builtin___clear_cache((char*)p, (char*)p + sizeof(code));

    // mprotect 为 RX（去掉写权限）
    int rc = mprotect(p, 4096, PROT_READ | PROT_EXEC);
    if (rc != 0) {
        char buf[128];
        snprintf(buf, sizeof(buf), "mprotect RWX→RX 失败, errno=%d (%s)", errno, strerror(errno));
        appendResult("测试7 [RWX→写入→RX→执行]", false, buf);
        munmap(p, 4096);
        return;
    }
    // 执行
    typedef long (*func_t)(void);
    long result = ((func_t)p)();
    char buf[128];
    snprintf(buf, sizeof(buf), "执行成功, 返回值=%ld (期望42)", result);
    appendResult("测试7 [RWX→写入→RX→执行]", result == 42, buf);
    munmap(p, 4096);
}

// 测试8：模拟 safepoint polling page — mprotect 切换 NONE ↔ RX
static void test8_safepoint_polling() {
    void* p = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        appendResult("测试8 [Safepoint模拟]", false, "mmap 失败");
        return;
    }
    // HotSpot safepoint: 先设为 PROT_NONE（触发 SIGSEGV），再恢复为 PROT_READ
    int rc1 = mprotect(p, 4096, PROT_NONE);
    int rc2 = mprotect(p, 4096, PROT_READ);
    int rc3 = mprotect(p, 4096, PROT_NONE);
    int rc4 = mprotect(p, 4096, PROT_READ | PROT_WRITE);
    char buf[256];
    snprintf(buf, sizeof(buf), "RW→NONE: %s, NONE→R: %s, R→NONE: %s, NONE→RW: %s",
             rc1 == 0 ? "OK" : strerror(errno),
             rc2 == 0 ? "OK" : strerror(errno),
             rc3 == 0 ? "OK" : strerror(errno),
             rc4 == 0 ? "OK" : strerror(errno));
    appendResult("测试8 [Safepoint模拟]", rc1 == 0 && rc2 == 0 && rc3 == 0 && rc4 == 0, buf);
    munmap(p, 4096);
}

// 测试9：大块 CodeCache 分配（模拟 HotSpot 默认 240MB CodeCache）
static void test9_large_codecache() {
    size_t sizes[] = { 1*1024*1024, 16*1024*1024, 64*1024*1024 };
    const char* labels[] = { "1MB", "16MB", "64MB" };
    for (int i = 0; i < 3; i++) {
        void* p = mmap(NULL, sizes[i], PROT_READ | PROT_WRITE | PROT_EXEC,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED) {
            char buf[128];
            snprintf(buf, sizeof(buf), "%s mmap RWX 失败, errno=%d", labels[i], errno);
            appendResult("测试9 [大块CodeCache]", false, buf);
        } else {
            // 在末尾写入 ret 并执行
            uint32_t ret_insn = 0xd65f03c0;
            char* end = (char*)p + sizes[i] - 4096;
            memcpy(end, &ret_insn, sizeof(ret_insn));
            __builtin___clear_cache(end, end + sizeof(ret_insn));
            typedef void (*func_t)(void);
            ((func_t)end)();
            char buf[128];
            snprintf(buf, sizeof(buf), "%s RWX 分配+执行成功", labels[i]);
            appendResult("测试9 [大块CodeCache]", true, buf);
            munmap(p, sizes[i]);
        }
    }
}

// 测试10：反复 mprotect RW↔RX 切换（模拟 JIT 编译+执行循环）
static void test10_repeated_mprotect() {
    void* p = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        appendResult("测试10 [反复mprotect]", false, "mmap 失败");
        return;
    }
    int fail_count = 0;
    int iterations = 100;
    for (int i = 0; i < iterations; i++) {
        // 写入代码（需要 W）
        uint32_t code[] = { (uint32_t)(0xd2800000 | ((i & 0xFFFF) << 5)), 0xd65f03c0 };
        int rc1 = mprotect(p, 4096, PROT_READ | PROT_WRITE);
        if (rc1 != 0) { fail_count++; continue; }
        memcpy(p, code, sizeof(code));
        __builtin___clear_cache((char*)p, (char*)p + sizeof(code));
        // 切换为可执行（去掉 W）
        int rc2 = mprotect(p, 4096, PROT_READ | PROT_EXEC);
        if (rc2 != 0) { fail_count++; continue; }
        // 执行
        typedef long (*func_t)(void);
        ((func_t)p)();
    }
    char buf[128];
    snprintf(buf, sizeof(buf), "%d/%d 次成功", iterations - fail_count, iterations);
    appendResult("测试10 [反复mprotect]", fail_count == 0, buf);
    munmap(p, 4096);
}

// 测试11：RWX 页面上直接执行（不做 mprotect，模拟 C1 直接在 RWX 上编译+执行）
static void test11_rwx_direct_exec() {
    void* p = mmap(NULL, 65536, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        appendResult("测试11 [RWX直接执行]", false, "mmap 失败");
        return;
    }
    // 写入多个函数并执行
    int success = 0;
    for (int i = 0; i < 16; i++) {
        char* slot = (char*)p + i * 4096;
        // mov x0, #(i*10); ret
        uint32_t code[] = { (uint32_t)(0xd2800000 | (((i * 10) & 0xFFFF) << 5)), 0xd65f03c0 };
        memcpy(slot, code, sizeof(code));
        __builtin___clear_cache(slot, slot + sizeof(code));
        typedef long (*func_t)(void);
        long r = ((func_t)slot)();
        if (r == i * 10) success++;
    }
    char buf[128];
    snprintf(buf, sizeof(buf), "%d/16 函数执行正确", success);
    appendResult("测试11 [RWX直接执行]", success == 16, buf);
    munmap(p, 65536);
}

// 测试12：检查 /proc/self/maps 中 RWX 页面是否真的有 x 权限
static void test12_check_proc_maps() {
    void* p = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        appendResult("测试12 [/proc/maps验证]", false, "mmap 失败");
        return;
    }
    // 读取 /proc/self/maps 查找这个地址
    FILE* f = fopen("/proc/self/maps", "r");
    char line[512];
    char perms[8] = "????";
    bool found = false;
    if (f) {
        while (fgets(line, sizeof(line), f)) {
            unsigned long start, end;
            char p_str[8];
            if (sscanf(line, "%lx-%lx %4s", &start, &end, p_str) == 3) {
                if ((unsigned long)p >= start && (unsigned long)p < end) {
                    strncpy(perms, p_str, 4);
                    perms[4] = '\0';
                    found = true;
                    break;
                }
            }
        }
        fclose(f);
    }
    char buf[256];
    if (found) {
        snprintf(buf, sizeof(buf), "addr=%p, 权限=%s, 期望=rwxp", p, perms);
        // 检查是否真的有 x
        bool has_x = (perms[2] == 'x');
        appendResult("测试12 [/proc/maps验证]", has_x, buf);
    } else {
        snprintf(buf, sizeof(buf), "addr=%p 未在 /proc/self/maps 中找到", p);
        appendResult("测试12 [/proc/maps验证]", false, buf);
    }
    munmap(p, 4096);
}

// 导出给 NAPI 调用的入口函数
extern "C" {

const char* runAllJitTests(const char* sandboxPath) {
    g_results.clear();
    g_results += "===== JIT/mmap 边界测试 =====\n";
    g_results += "沙箱路径: ";
    g_results += sandboxPath;
    g_results += "\n\n";

    OH_LOG_INFO(LOG_APP, "===== 开始 JIT/mmap 边界测试 =====");
    OH_LOG_INFO(LOG_APP, "沙箱路径: %{public}s", sandboxPath);

    g_results += "--- 基础测试 ---\n";
    test6_anon_rw();       // 先测基础 mmap
    test1_anon_rwx();      // 匿名 RWX
    test2_anon_rw_then_exec(); // 匿名 RW → EXEC
    test3_file_exec(sandboxPath); // 文件映射 EXEC
    test4_memfd_exec();    // memfd EXEC
    test5_dlopen();        // dlopen

    g_results += "\n--- HotSpot 模拟测试 ---\n";
    test7_rwx_write_protect_exec();  // CodeCache 流程
    test8_safepoint_polling();       // Safepoint polling page
    test9_large_codecache();         // 大块 CodeCache
    test10_repeated_mprotect();      // 反复 mprotect
    test11_rwx_direct_exec();        // RWX 直接执行
    test12_check_proc_maps();        // /proc/maps 验证

    g_results += "\n===== 测试完成 =====\n";
    g_results += "\n判断依据:\n";
    g_results += "• 测试1/2/7 成功 → 基础 JIT 可用\n";
    g_results += "• 测试8 成功 → Safepoint polling 可用\n";
    g_results += "• 测试10 成功 → 反复编译执行可用\n";
    g_results += "• 测试11 成功 → RWX 直接执行可用（C1 模式）\n";
    g_results += "• 测试12 显示 rwxp → 内核真正授予了 x 权限\n";
    g_results += "• 如果测试12 显示 rw-p → 内核静默剥离了 x 权限！\n";

    OH_LOG_INFO(LOG_APP, "===== 测试完成 =====");

    return g_results.c_str();
}

} // extern "C"
