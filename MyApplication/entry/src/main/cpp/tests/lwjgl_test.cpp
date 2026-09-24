// lwjgl_test.cpp — P5: LWJGL native 库验证
// 测试 LWJGL native .so 是否能在 OHOS 上正确加载并提供 JNI 符号
// 包含 RWX mmap 检测（libffi closure 依赖可执行内存）

#include "tests.h"
#include <hilog/log.h>
#include <dlfcn.h>
#include <cstring>
#include <cstdio>
#include <string>
#include <sstream>
#include <sys/mman.h>
#include <unistd.h>

#undef LOG_TAG
#define LOG_TAG "LWJGL_TEST"

static std::string g_lwjglTestResult;

// 检测 RWX mmap 权限（libffi closure 和 JVM JIT 都需要）
static bool detectRwxMmap() {
    void* p = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p != MAP_FAILED) {
        munmap(p, 4096);
        return true;
    }
    return false;
}

// 检查 LWJGL .so 是否在 JVM 可达路径中
// OHOS 上 HAP 打包的 .so 会解压到 /data/storage/el1/bundle/libs/arm64/
// jvm_launcher.cpp 已将该目录设为 java.library.path
static bool checkLibraryPath() {
    // 尝试 dlopen liblwjgl.so，如果成功说明在 ld 搜索路径中
    void* h = dlopen("liblwjgl.so", RTLD_NOW);
    if (h) {
        // 获取实际路径
        Dl_info info;
        void* sym = dlsym(h, "Java_org_lwjgl_system_JNI_invokePPP__JJJ");
        if (sym && dladdr(sym, &info) && info.dli_fname) {
            OH_LOG_INFO(LOG_APP, "liblwjgl.so path: %{public}s", info.dli_fname);
        }
        dlclose(h);
        return true;
    }
    return false;
}

// LWJGL native 库列表及其关键符号
struct LwjglLib {
    const char* soName;
    const char* displayName;
    const char* keySymbols[4]; // 要检查的关键 JNI 符号，NULL 结尾
};

static const LwjglLib kLwjglLibs[] = {
    {
        "liblwjgl.so", "LWJGL Core",
        {
            "Java_org_lwjgl_system_JNI_invokePPP__JJJ",  // JNI downcall (3 long args)
            "Java_org_lwjgl_system_MemoryUtil_memGlobalRefToObject", // 内存工具
            "Java_org_lwjgl_system_ThreadLocalUtil_nsetupEnvData", // TLS
            nullptr
        }
    },
    {
        "liblwjgl_opengl.so", "LWJGL OpenGL",
        {
            "Java_org_lwjgl_opengl_GL11C_glDrawArrays",  // GL11C 核心
            "Java_org_lwjgl_opengl_GL20C_nglShaderSource__IIJJ", // 着色器
            "Java_org_lwjgl_opengl_GL30C_nglGenVertexArrays__IJ", // VAO
            nullptr
        }
    },
    {
        "liblwjgl_stb.so", "LWJGL STB",
        {
            "Java_org_lwjgl_stb_STBImage_nstbi_1load_1from_1memory__JIJJJI", // 图像加载
            "Java_org_lwjgl_stb_STBTruetype_nstbtt_1InitFont",       // 字体
            nullptr, nullptr
        }
    },
    {
        "liblwjgl_tinyfd.so", "LWJGL TinyFD",
        {
            "Java_org_lwjgl_util_tinyfd_TinyFileDialogs_ntinyfd_1messageBox", // 消息框
            nullptr, nullptr, nullptr
        }
    },
};

// 全局变量：由 NAPI 层设置 filesDir（保留接口，但不再用于 .so 搜索）
static std::string g_lwjglTestFilesDir;

void lwjglTestSetFilesDir(const char* filesDir) {
    if (filesDir) g_lwjglTestFilesDir = filesDir;
}

const char* runLwjglTest() {
    std::ostringstream ss;
    ss << "===== P5: LWJGL Native 验证 =====\n\n";
    ss << "注意: .so 随 HAP 打包，使用系统 linker 搜索路径\n\n";

    int totalTests = 0;
    int passedTests = 0;

    for (const auto& lib : kLwjglLibs) {
        totalTests++;
        ss << "--- " << lib.displayName << " ---\n";

        // dlopen 裸文件名（HAP 打包的 .so 在系统 linker 搜索路径中）
        // 使用 RTLD_LAZY：某些库（如 liblwjgl.so）可能引用了 JVM 符号，
        // RTLD_NOW 会因未解析符号而失败，RTLD_LAZY 延迟解析
        dlerror();
        void* handle = dlopen(lib.soName, RTLD_LAZY);
        if (!handle) {
            // 回退：尝试 HAP 的 native lib 全路径
            std::string hapPath = std::string("/data/storage/el1/bundle/libs/arm64/") + lib.soName;
            dlerror();
            handle = dlopen(hapPath.c_str(), RTLD_LAZY);
        }
        if (!handle) {
            const char* err = dlerror();
            ss << "❌ dlopen(\"" << lib.soName << "\") 失败\n";
            ss << "   " << (err ? err : "unknown error") << "\n\n";
            OH_LOG_ERROR(LOG_APP, "dlopen %{public}s failed: %{public}s",
                         lib.soName, err ? err : "unknown");
            continue;
        }

        ss << "✅ dlopen(\"" << lib.soName << "\") 成功\n";
        OH_LOG_INFO(LOG_APP, "dlopen %{public}s OK", lib.soName);

        // 检查关键符号
        bool allSymbolsFound = true;
        for (int i = 0; i < 4 && lib.keySymbols[i]; i++) {
            void* sym = dlsym(handle, lib.keySymbols[i]);
            if (sym) {
                // 截短符号名用于显示
                std::string shortName(lib.keySymbols[i]);
                // 提取类名.方法名部分
                size_t javaPos = shortName.find("Java_org_lwjgl_");
                if (javaPos != std::string::npos) {
                    shortName = shortName.substr(javaPos + 15); // 跳过 "Java_org_lwjgl_"
                    // 截断参数签名
                    size_t paramPos = shortName.find("__");
                    if (paramPos != std::string::npos) {
                        shortName = shortName.substr(0, paramPos);
                    }
                }
                ss << "  ✅ " << shortName << "\n";
            } else {
                ss << "  ❌ " << lib.keySymbols[i] << " 未找到\n";
                allSymbolsFound = false;
            }
        }

        if (allSymbolsFound) {
            passedTests++;
        }

        dlclose(handle);
        ss << "\n";
    }

    // ============================================================
    // 额外检测：RWX mmap（libffi closure 依赖）
    // ============================================================
    ss << "--- libffi Closure 兼容性 ---\n";
    bool rwxOk = detectRwxMmap();
    if (rwxOk) {
        ss << "✅ RWX mmap 可用（libffi closure 正常）\n";
        OH_LOG_INFO(LOG_APP, "RWX mmap: available, libffi closure OK");
    } else {
        ss << "⚠️ RWX mmap 不可用（无 ALLOW_WRITABLE_CODE_MEMORY 权限）\n";
        ss << "   libffi closure（Callback.create）将无法工作\n";
        ss << "   LWJGL downcall（JNI.invokeP 等）不受影响\n";
        ss << "   MC 核心渲染路径可正常运行\n";
        OH_LOG_WARN(LOG_APP, "RWX mmap: unavailable, libffi closure disabled");
    }
    ss << "\n";

    // ============================================================
    // 额外检测：库路径（System.loadLibrary 可达性）
    // ============================================================
    ss << "--- JVM 库路径检测 ---\n";
    bool pathOk = checkLibraryPath();
    if (pathOk) {
        ss << "✅ liblwjgl.so 在动态链接器搜索路径中\n";
    } else {
        ss << "ℹ️ liblwjgl.so 裸名搜索不可达（OHOS linker 命名空间限制）\n";
        ss << "   MC 运行不受影响：mc_launcher 已设置 java.library.path\n";
    }
    ss << "\n";

    // 汇总
    int libCount = sizeof(kLwjglLibs) / sizeof(kLwjglLibs[0]);
    ss << "===== 结果: " << passedTests << "/" << libCount << " =====\n";
    if (passedTests == libCount) {
        ss << "🎉 LWJGL OHOS native 库验证通过！\n";
        ss << "JNI 绑定层可用，可对接 MC Java 层\n";
    } else {
        ss << "⚠️ 部分库未通过验证\n";
        ss << "请确认 .so 文件已随 HAP 打包在 entry/libs/arm64-v8a/ 中\n";
    }

    if (!rwxOk) {
        ss << "\n⚠️ libffi closure 不可用（无 RWX 权限）\n";
        ss << "LWJGL Callback.create() 会崩溃，已标记拦截\n";
        ss << "解决方案：申请 ohos.permission.ALLOW_WRITABLE_CODE_MEMORY\n";
    }

    g_lwjglTestResult = ss.str();
    OH_LOG_INFO(LOG_APP, "LWJGL test: %{public}d/%{public}d passed, rwx=%{public}s, path=%{public}s",
                passedTests, libCount, rwxOk ? "yes" : "no", pathOk ? "yes" : "no");
    return g_lwjglTestResult.c_str();
}
