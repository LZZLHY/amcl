/** TestHooks 独占 profile：在 fresh NCP、jvmInit 前验证安装槽 provider 的默认字体缓存。
 * 不设置全局 FcConfig，不调用 FcFini，不读取任意 Want 路径；预期哈希来自宿主审核侧车。
 * 本头仅提供调用接口，NativeJava/Want/JAR 接线由父任务负责。 */
#pragma once
#ifdef MC_OHOS_BUILD_TESTS
#include "jdk_font_context_qualification.h"
#include "../jvm/elf_loader.h"
#include <chrono>
#include <memory>
#include <sstream>
#include <type_traits>
#ifdef AMCL_FONTCONFIG_USE_PUBLIC_HEADER
#include <fontconfig/fontconfig.h>
#endif

namespace amcl::jdkqualification::fontdefaults {
namespace io = amcl::jdk::io;
namespace fc {
/* 对照锁定 Fontconfig 2.17.1 fontconfig/fontconfig.h.in；不解引用不透明对象。
 * ABI 宿主/SDK编译验证启用 PUBLIC_HEADER，逐个静态核函数签名；产品探针无需链接 FC。 */
#ifdef AMCL_FONTCONFIG_USE_PUBLIC_HEADER
using Config = ::FcConfig; using Pattern = ::FcPattern; using CharSet = ::FcCharSet;
using StrList = ::FcStrList; using Cache = ::FcCache; using Result = ::FcResult; using MatchKind = ::FcMatchKind;
#else
struct Config; struct Pattern; struct CharSet; struct StrList; struct Cache;
enum Result { Match = 0, NoMatch, TypeMismatch, NoId, OutOfMemory };
enum MatchKind { MatchPattern = 0, MatchFont, MatchScan };
#endif
using Char8 = unsigned char; using Char32 = unsigned int; using Bool = int;
using Init = Config* (*)(); using Destroy = void (*)(Config*); using BuildFonts = Bool (*)(Config*);
using Directories = StrList* (*)(Config*); using Next = Char8* (*)(StrList*); using Done = void (*)(StrList*);
using ReadCache = Cache* (*)(const Char8*, Bool, Config*);
using LoadCache = Cache* (*)(const Char8*, Config*, Char8**);
using UnloadCache = void (*)(Cache*); using Count = int (*)(const Cache*); using FreeString = void (*)(Char8*);
using Parse = Pattern* (*)(const Char8*); using DestroyPattern = void (*)(Pattern*);
using Substitute = Bool (*)(Config*, Pattern*, MatchKind); using Defaults = void (*)(Pattern*);
using FontMatch = Pattern* (*)(Config*, Pattern*, Result*);
using GetString = Result (*)(const Pattern*, const char*, int, Char8**);
using GetCharset = Result (*)(const Pattern*, const char*, int, CharSet**);
using HasChar = Bool (*)(const CharSet*, Char32);
#ifdef AMCL_FONTCONFIG_USE_PUBLIC_HEADER
#define AMCL_FC_SIGNATURE(type, function) static_assert(std::is_same<type, decltype(&::function)>::value, #function " ABI differs")
AMCL_FC_SIGNATURE(Init, FcInitLoadConfig); AMCL_FC_SIGNATURE(Destroy, FcConfigDestroy);
AMCL_FC_SIGNATURE(BuildFonts, FcConfigBuildFonts); AMCL_FC_SIGNATURE(Directories, FcConfigGetCacheDirs);
AMCL_FC_SIGNATURE(Directories, FcConfigGetFontDirs); AMCL_FC_SIGNATURE(Next, FcStrListNext);
AMCL_FC_SIGNATURE(Done, FcStrListDone); AMCL_FC_SIGNATURE(ReadCache, FcDirCacheRead);
AMCL_FC_SIGNATURE(LoadCache, FcDirCacheLoad); AMCL_FC_SIGNATURE(UnloadCache, FcDirCacheUnload);
AMCL_FC_SIGNATURE(Count, FcCacheNumFont); AMCL_FC_SIGNATURE(FreeString, FcStrFree);
AMCL_FC_SIGNATURE(Parse, FcNameParse); AMCL_FC_SIGNATURE(DestroyPattern, FcPatternDestroy);
AMCL_FC_SIGNATURE(Substitute, FcConfigSubstitute); AMCL_FC_SIGNATURE(Defaults, FcDefaultSubstitute);
AMCL_FC_SIGNATURE(FontMatch, FcFontMatch); AMCL_FC_SIGNATURE(GetString, FcPatternGetString);
AMCL_FC_SIGNATURE(GetCharset, FcPatternGetCharSet); AMCL_FC_SIGNATURE(HasChar, FcCharSetHasChar);
#undef AMCL_FC_SIGNATURE
#endif
} // namespace fc

inline std::string Quote(const std::string& text) { return fontcontext::Quote(text); }
inline void Field(std::string& fields, const std::string& name, const std::string& value) {
    if (!fields.empty()) fields += ',';
    fields += Quote(name) + ':' + value;
}
inline std::string Canonical(const std::string& path) {
    char real[PATH_MAX]{};
    io::Require(!path.empty() && path[0] == '/' && realpath(path.c_str(), real), "字体资格路径不是已存在绝对路径");
    return real;
}

struct FileState {
    std::string sha;
    uint64_t bytes = 0, inode = 0, device = 0;
    uint32_t mode = 0, uid = 0;
    int64_t modifiedSeconds = 0, modifiedNanoseconds = 0;
    std::string Json() const {
        return "{\"sha256\":" + Quote(sha) + ",\"bytes\":" + std::to_string(bytes) +
            ",\"mode\":" + std::to_string(mode) + ",\"uid\":" + std::to_string(uid) + ",\"inode\":" + std::to_string(inode) +
            ",\"device\":" + std::to_string(device) + ",\"mtimeSeconds\":" + std::to_string(modifiedSeconds) +
            ",\"mtimeNanoseconds\":" + std::to_string(modifiedNanoseconds) + '}';
    }
};
inline FileState ReadFile(int directory, const std::string& name) {
    io::Fd file(openat(directory, name.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
    if (file.get() < 0) io::Error("无法读取字体资格实物 " + name);
    struct stat before{}, after{};
    io::Require(fstat(file.get(), &before) == 0 && S_ISREG(before.st_mode) && before.st_nlink == 1 &&
        before.st_size >= 0 && uint64_t(before.st_size) <= io::MaxBytes, "字体资格实物不是有界普通文件");
    download::Sha256 hash;
    std::vector<unsigned char> buffer(io::Chunk);
    for (uint64_t at = 0; at < uint64_t(before.st_size);) {
        const size_t count = std::min<uint64_t>(buffer.size(), uint64_t(before.st_size) - at);
        io::Read(file.get(), buffer.data(), count, at); hash.update(buffer.data(), count); at += count;
    }
    io::Require(fstat(file.get(), &after) == 0 && before.st_dev == after.st_dev && before.st_ino == after.st_ino &&
        before.st_size == after.st_size && before.st_mode == after.st_mode &&
        before.st_mtim.tv_sec == after.st_mtim.tv_sec && before.st_mtim.tv_nsec == after.st_mtim.tv_nsec,
        "字体资格实物在读取时改变");
    return {hash.finalizeHex(), uint64_t(before.st_size), uint64_t(before.st_ino), uint64_t(before.st_dev),
        uint32_t(before.st_mode & 07777), uint32_t(before.st_uid), int64_t(before.st_mtim.tv_sec), int64_t(before.st_mtim.tv_nsec)};
}
inline FileState ReadAbsolute(const std::string& path) {
    io::Require(Canonical(path) == path, "字体资格实物不能是路径别名");
    const auto slash = path.rfind('/'); auto parent = io::Directory(path.substr(0, slash));
    return ReadFile(parent.get(), path.substr(slash + 1));
}

struct TreeState { std::string sha; uint64_t bytes = 0; size_t files = 0, directories = 0; };
inline void HashTree(int directory, const std::string& prefix, download::Sha256& hash, TreeState& result, size_t depth) {
    io::Require(depth <= io::MaxDepth, "JDK资格目录深度超限");
    for (const auto& name : io::Names(directory)) {
        io::Require(result.files + result.directories < io::MaxEntries, "JDK资格条目超限");
        struct stat status{};
        io::Require(fstatat(directory, name.c_str(), &status, AT_SYMLINK_NOFOLLOW) == 0, "JDK资格属性读取失败");
        const std::string relative = prefix + name;
        std::string record;
        if (S_ISDIR(status.st_mode)) {
            ++result.directories; auto child = io::ChildDirectory(directory, name);
            record = "D " + relative + " " + std::to_string(status.st_mode & 07777) + '\n';
            hash.update(record.data(), record.size()); HashTree(child.get(), relative + '/', hash, result, depth + 1);
        } else {
            const auto file = ReadFile(directory, name); ++result.files;
            io::Require(file.bytes <= io::MaxBytes - result.bytes, "JDK资格字节数超限"); result.bytes += file.bytes;
            record = "F " + relative + " " + std::to_string(file.mode) + " " + std::to_string(file.bytes) + " " + file.sha + '\n';
            hash.update(record.data(), record.size());
        }
    }
}
inline TreeState Snapshot(const std::string& root) {
    auto directory = io::Directory(root); TreeState result; download::Sha256 hash;
    struct stat status{};
    io::Require(fstat(directory.get(), &status) == 0, "JDK根权限读取失败");
    const std::string rootMode = "D . " + std::to_string(status.st_mode & 07777) + '\n';
    hash.update(rootMode.data(), rootMode.size());
    HashTree(directory.get(), "", hash, result, 0); result.sha = hash.finalizeHex(); return result;
}

class SearchPath final {
    std::string restore_; bool changed_ = false; bool& restored_;
public:
    SearchPath(const std::string& restore, bool& restored) : restore_(restore), restored_(restored) {}
    void Select(const std::string& path) { changed_ = true; elf_set_search_path(path.c_str()); }
    ~SearchPath() { if (changed_) { try { elf_set_search_path(restore_.c_str()); } catch (...) { restored_ = false; } } }
};
class Module final {
    void* handle_ = nullptr; bool& closed_;
public:
    Module(const std::string& path, bool& closed) : handle_(elf_dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL)), closed_(closed) {
        io::Require(handle_ != nullptr, "无法加载安装槽字体provider: " + std::string(elf_error() ? elf_error() : "unknown"));
    }
    ~Module() { if (handle_ && elf_dlclose(handle_) != 0) closed_ = false; }
    void* get() const { return handle_; }
};
inline std::string Origin(const void* symbol) {
    Dl_info info{};
    io::Require(symbol && elf_dladdr(symbol, &info) && info.dli_fname && info.dli_fbase, "字体符号没有可核验provider");
    return Canonical(info.dli_fname);
}
template<class Function> inline Function Symbol(void* library, const char* name, const std::string& expected) {
    void* symbol = elf_dlsym(library, name);
    io::Require(symbol && Origin(symbol) == expected, "字体API提供者不属于安装槽: " + std::string(name));
    return reinterpret_cast<Function>(symbol);
}

struct Api {
    fc::Init init; fc::Destroy destroy; fc::BuildFonts build;
    fc::Directories caches, fonts; fc::Next next; fc::Done done;
    fc::ReadCache read; fc::LoadCache load; fc::UnloadCache unload; fc::Count count; fc::FreeString freeString;
    fc::Parse parse; fc::DestroyPattern destroyPattern; fc::Substitute substitute; fc::Defaults defaults;
    fc::FontMatch match; fc::GetString string; fc::GetCharset charset; fc::HasChar has;
    Api(void* handle, const std::string& origin)
      : init(Symbol<fc::Init>(handle,"FcInitLoadConfig",origin)), destroy(Symbol<fc::Destroy>(handle,"FcConfigDestroy",origin)),
        build(Symbol<fc::BuildFonts>(handle,"FcConfigBuildFonts",origin)), caches(Symbol<fc::Directories>(handle,"FcConfigGetCacheDirs",origin)),
        fonts(Symbol<fc::Directories>(handle,"FcConfigGetFontDirs",origin)), next(Symbol<fc::Next>(handle,"FcStrListNext",origin)),
        done(Symbol<fc::Done>(handle,"FcStrListDone",origin)), read(Symbol<fc::ReadCache>(handle,"FcDirCacheRead",origin)),
        load(Symbol<fc::LoadCache>(handle,"FcDirCacheLoad",origin)), unload(Symbol<fc::UnloadCache>(handle,"FcDirCacheUnload",origin)),
        count(Symbol<fc::Count>(handle,"FcCacheNumFont",origin)), freeString(Symbol<fc::FreeString>(handle,"FcStrFree",origin)),
        parse(Symbol<fc::Parse>(handle,"FcNameParse",origin)), destroyPattern(Symbol<fc::DestroyPattern>(handle,"FcPatternDestroy",origin)),
        substitute(Symbol<fc::Substitute>(handle,"FcConfigSubstitute",origin)), defaults(Symbol<fc::Defaults>(handle,"FcDefaultSubstitute",origin)),
        match(Symbol<fc::FontMatch>(handle,"FcFontMatch",origin)), string(Symbol<fc::GetString>(handle,"FcPatternGetString",origin)),
        charset(Symbol<fc::GetCharset>(handle,"FcPatternGetCharSet",origin)), has(Symbol<fc::HasChar>(handle,"FcCharSetHasChar",origin)) {}
    std::vector<std::string> List(fc::Config* config, fc::Directories function) const {
        std::unique_ptr<fc::StrList, fc::Done> list(function(config), done);
        io::Require(bool(list), "默认字体目录列表不存在"); std::vector<std::string> result;
        for (fc::Char8* value; (value = next(list.get())) != nullptr;) {
            io::Require(result.size() < 32, "默认字体目录数量超限"); result.emplace_back(reinterpret_cast<char*>(value));
        }
        return result;
    }
};
inline std::string StringList(const std::vector<std::string>& values) {
    std::string result = "["; for (const auto& value : values) { if (result.size() > 1) result += ','; result += Quote(value); }
    return result + ']';
}
inline int64_t Micros(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - start).count();
}
inline std::string MatchFont(const Api& api, fc::Config* config, const char* query, fc::Char32 character) {
    std::unique_ptr<fc::Pattern, fc::DestroyPattern> pattern(api.parse(reinterpret_cast<const fc::Char8*>(query)), api.destroyPattern);
    io::Require(pattern && api.substitute(config, pattern.get(), static_cast<fc::MatchKind>(0)), "默认字体请求建立失败");
    api.defaults(pattern.get()); fc::Result result = static_cast<fc::Result>(1);
    std::unique_ptr<fc::Pattern, fc::DestroyPattern> selected(api.match(config, pattern.get(), &result), api.destroyPattern);
    fc::Char8 *file = nullptr, *family = nullptr; fc::CharSet* characters = nullptr;
    io::Require(selected && int(result) == 0 && int(api.string(selected.get(), "file", 0, &file)) == 0 && file &&
        int(api.string(selected.get(), "family", 0, &family)) == 0 && family &&
        int(api.charset(selected.get(), "charset", 0, &characters)) == 0 && characters && api.has(characters, character),
        "默认字体真实字符覆盖失败");
    const std::string path(reinterpret_cast<char*>(file));
    io::Require(path.rfind("/system/fonts/", 0) == 0 && access(path.c_str(), R_OK) == 0, "默认字体文件不是可读系统字体");
    return "{\"query\":" + Quote(query) + ",\"family\":" + Quote(reinterpret_cast<char*>(family)) +
        ",\"file\":" + Quote(path) + ",\"character\":" + std::to_string(character) + ",\"covered\":true}";
}
} // namespace amcl::jdkqualification::fontdefaults

namespace amcl::jdkqualification {
/** 参数必须由固定侧车/安装记录提供。仅独立 font-defaults profile 调用，禁止混入CF性能。
 * search setter 无 getter；父任务保证本fresh NCP此前搜索域为空并显式传回空串。 */
inline bool RunInstalledFontDefaultsQualification(int runFd, const std::string& canonicalJdkRoot,
        const std::string& major, const std::string& expectedFcSha256, const std::string& expectedFtSha256,
        const std::string& restoreSearchPath) {
    using namespace fontdefaults;
    // 先取得固定报告名的排他创建权，再允许修改本次私有缓存；旧报告不会被覆盖或重跑。
    io::Fd file(openat(runFd,"font-defaults-report.json",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600));
    if (file.get() < 0) io::Error("无法独占创建默认字体资格报告");
    std::string fields, error; bool passed = false, captured = false;
    bool envRestored = true, cwdRestored = true, searchRestored = true, modulesClosed = true;
    TreeState before;
    try {
        io::Require((major == "8" || major == "17" || major == "21" || major == "25") &&
            io::Hash(expectedFcSha256) && io::Hash(expectedFtSha256), "默认字体资格身份参数无效");
        io::Require(canonicalJdkRoot != "/" && Canonical(canonicalJdkRoot) == canonicalJdkRoot, "JDK根不是规范绝对路径");
        const auto slash = canonicalJdkRoot.rfind('/');
        io::Require(slash > 0, "JDK父目录不能是文件系统根");
        const std::string native = canonicalJdkRoot + (major == "8" ? "/jre/lib/aarch64" : "/lib");
        const std::string fcPath = native + "/libfontconfig.so";
        const std::string ftPath = native + (major == "8" ? "/libfreetype.so.6" : "/libfreetype.so");
        const std::string cacheRoot = canonicalJdkRoot.substr(0, slash) + "/.amcl-fontconfig-cache/fontconfig";
        before = Snapshot(canonicalJdkRoot); captured = true;
        const auto fcFile = ReadAbsolute(fcPath), ftFile = ReadAbsolute(ftPath);
        io::Require(fcFile.sha == expectedFcSha256 && ftFile.sha == expectedFtSha256, "安装槽FC/FT正文与审核侧车不同");
        Field(fields,"fontconfigFile",fcFile.Json()); Field(fields,"freeTypeFile",ftFile.Json());
        Field(fields,"expectedCacheDirectory",Quote(cacheRoot));
        {
            fontcontext::Environment environment(envRestored); fontcontext::WorkingDirectory cwd(cwdRestored);
            SearchPath search(restoreSearchPath, searchRestored);
            Field(fields,"originalEnvironment",environment.Identity()); environment.Clear(); cwd.SelectRoot();
            errno = 0; const int cwdAccess = access("/", W_OK); const int cwdError = errno;
            Field(fields,"readOnlyCwd",cwdAccess != 0 ? "true" : "false"); Field(fields,"cwdAccessErrno",std::to_string(cwdError));
            io::Require(cwdAccess != 0, "当前NCP根目录可写，未验证只读CWD合同");
            search.Select(native + ':' + native + "/server");
            Module freeType(ftPath, modulesClosed), library(fcPath, modulesClosed);
            Api api(library.get(), fcPath);
            io::Require(Origin(elf_dlsym(library.get(), "FT_Get_BDF_Property")) == ftPath, "FC实际依赖的FT来自别处");
            Field(fields,"fontconfigOrigin",Quote(Origin(elf_dlsym(library.get(),"FcInitLoadConfig"))));
            Field(fields,"freeTypeOrigin",Quote(Origin(elf_dlsym(library.get(),"FT_Get_BDF_Property"))));
            std::unique_ptr<fc::Config, fc::Destroy> cold(api.init(), api.destroy);
            io::Require(bool(cold), "默认配置初始化失败");
            const auto cacheDirs = api.List(cold.get(), api.caches), fontDirs = api.List(cold.get(), api.fonts);
            Field(fields,"cacheDirectories",StringList(cacheDirs)); Field(fields,"fontDirectories",StringList(fontDirs));
            io::Require(cacheDirs.size() == 1 && cacheDirs[0] == cacheRoot, "默认缓存不是唯一槽外私有目录");
            io::Require(std::find(fontDirs.begin(),fontDirs.end(),"/system/fonts") != fontDirs.end(), "默认配置没有系统字体目录");
            const auto coldStarted = std::chrono::steady_clock::now();
            std::unique_ptr<fc::Cache, fc::UnloadCache> scanned(api.read(reinterpret_cast<const fc::Char8*>("/system/fonts"),1,cold.get()),api.unload);
            const auto coldUs = Micros(coldStarted);
            io::Require(scanned && api.count(scanned.get()) > 0, "真实系统字体冷扫描未生成缓存对象");
            const int fontCount = api.count(scanned.get());
            Field(fields,"forcedColdRescan","true"); Field(fields,"coldMicroseconds",std::to_string(coldUs));
            Field(fields,"cachedFontCount",std::to_string(fontCount));
            scanned.reset();
            fc::Char8* rawPath = nullptr;
            std::unique_ptr<fc::Cache, fc::UnloadCache> disk(api.load(reinterpret_cast<const fc::Char8*>("/system/fonts"),cold.get(),&rawPath),api.unload);
            std::unique_ptr<fc::Char8, fc::FreeString> ownedPath(rawPath,api.freeString);
            io::Require(disk && ownedPath, "冷扫描后没有可实际打开的磁盘缓存");
            const std::string cacheFile(reinterpret_cast<char*>(ownedPath.get()));
            io::Require(cacheFile.rfind(cacheRoot + '/',0) == 0 && cacheFile.find('/',cacheRoot.size()+1) == std::string::npos,
                "FcDirCacheLoad返回的文件不属于默认缓存根");
            const auto afterCold = ReadAbsolute(cacheFile);
            io::Require(afterCold.bytes > 0 && afterCold.uid == geteuid(), "磁盘字体缓存为空或不属于当前UID");
            auto privateCache = io::Directory(cacheRoot.substr(0,cacheRoot.rfind('/')));
            auto actualCache = io::Directory(cacheRoot); struct stat privateStat{}, cacheStat{};
            io::Require(fstat(privateCache.get(),&privateStat) == 0 && privateStat.st_uid == geteuid() &&
                (privateStat.st_mode & 0777) == 0700 && fstat(actualCache.get(),&cacheStat) == 0 &&
                cacheStat.st_uid == geteuid() && !(cacheStat.st_mode & (S_IWGRP|S_IWOTH)) && access(cacheRoot.c_str(),W_OK|X_OK) == 0,
                "默认缓存不是当前UID的私有可写目录");
            io::Fd synchronized(openat(actualCache.get(),io::Leaf(cacheFile).c_str(),O_RDONLY|O_NOFOLLOW|O_CLOEXEC));
            io::Require(synchronized.get() >= 0,"缓存实物同步打开失败");
            io::Sync(synchronized.get()); io::Sync(actualCache.get()); io::Sync(privateCache.get());
            Field(fields,"cacheDurabilitySync","true");
            Field(fields,"cacheFile",Quote(cacheFile)); Field(fields,"cacheAfterCold",afterCold.Json());
            disk.reset(); ownedPath.reset(); cold.reset();
            std::unique_ptr<fc::Config, fc::Destroy> warm(api.init(),api.destroy);
            io::Require(warm && api.List(warm.get(),api.caches) == cacheDirs, "重建配置后的默认缓存目录漂移");
            rawPath = nullptr; const auto warmStarted = std::chrono::steady_clock::now();
            std::unique_ptr<fc::Cache, fc::UnloadCache> loaded(api.load(reinterpret_cast<const fc::Char8*>("/system/fonts"),warm.get(),&rawPath),api.unload);
            const auto warmUs = Micros(warmStarted); ownedPath.reset(rawPath);
            io::Require(loaded && ownedPath && cacheFile == reinterpret_cast<char*>(ownedPath.get()) && api.count(loaded.get()) == fontCount,
                "只加载缓存的第二配置未复用实际文件");
            Field(fields,"warmLoadOnlyMicroseconds",std::to_string(warmUs));
            Field(fields,"warmUsedLoadOnlyApi","true"); loaded.reset(); ownedPath.reset();
            io::Require(api.build(warm.get()), "局部配置无法建立字体列表");
            Field(fields,"matches",'[' + MatchFont(api,warm.get(),"sans:lang=en",0x41) + ',' +
                MatchFont(api,warm.get(),"sans:lang=zh-cn",0x4e2d) + ']');
            const auto afterWarm = ReadAbsolute(cacheFile); Field(fields,"cacheAfterWarm",afterWarm.Json());
            io::Require(afterWarm.Json() == afterCold.Json(), "热配置/匹配改写了已有缓存");
            Field(fields,"cacheUnchangedOnWarm","true");
            warm.reset();
            envRestored = environment.Restore(); cwdRestored = cwd.Restore();
        }
        passed = true;
    } catch (const std::exception& failure) { error = failure.what(); }
    catch (...) { error = "默认字体资格发生未知异常"; }
    bool unchanged = false;
    if (captured) {
        try {
            const auto after = Snapshot(canonicalJdkRoot);
            unchanged = before.sha == after.sha && before.files == after.files && before.directories == after.directories && before.bytes == after.bytes;
            Field(fields,"runtimeBeforeSha256",Quote(before.sha)); Field(fields,"runtimeAfterSha256",Quote(after.sha));
            Field(fields,"runtimeFileCount",std::to_string(before.files)); Field(fields,"runtimeBytes",std::to_string(before.bytes));
        } catch (const std::exception& failure) { if (error.empty()) error = failure.what(); }
    }
    passed = passed && unchanged && envRestored && cwdRestored && searchRestored && modulesClosed;
    const std::string report = "{\"schema\":1,\"scope\":\"installed-provider isolated-NCP default cache only\",\"freshExecQualified\":false,\"pid\":" +
        std::to_string(getpid()) + ",\"major\":" + Quote(major) + ",\"jdkRoot\":" + Quote(canonicalJdkRoot) +
        ",\"passed\":" + (passed ? "true" : "false") + ",\"environmentRestored\":" + (envRestored ? "true" : "false") +
        ",\"cwdRestored\":" + (cwdRestored ? "true" : "false") + ",\"searchPathRestoredBySetter\":" + (searchRestored ? "true" : "false") +
        ",\"moduleReferencesClosed\":" + (modulesClosed ? "true" : "false") + ",\"runtimeContentAndModesUnchanged\":" + (unchanged ? "true" : "false") +
        ",\"observation\":{" + fields + "},\"error\":" + Quote(error) + "}\n";
    io::Write(file.get(),report.data(),report.size()); io::Sync(file.get()); io::Sync(runFd);
    return passed;
}
} // namespace amcl::jdkqualification
#endif
