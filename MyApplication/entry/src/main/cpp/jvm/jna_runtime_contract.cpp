#include "jna_runtime_contract.h"

#include <algorithm>
#include <fstream>
#include <limits>
#include <sys/stat.h>
#include <zlib.h>

namespace amcl::jvm {
namespace {
constexpr size_t kMaxJar = 64 * 1024 * 1024;
constexpr size_t kMaxClass = 4096;
constexpr const char* kVersionEntry = "com/sun/jna/Version.class";

/** 所有边界使用减法判定，禁止畸形 ZIP/class 长度加法溢出后绕过检查。 */
bool Range(size_t offset, size_t size, size_t limit) { return offset <= limit && size <= limit - offset; }
uint16_t Le16(const std::vector<uint8_t>& b, size_t p) { return b[p] | uint16_t(b[p + 1]) << 8; }
uint32_t Le32(const std::vector<uint8_t>& b, size_t p) { return Le16(b, p) | uint32_t(Le16(b, p + 2)) << 16; }
std::string Text(const std::vector<uint8_t>& b, size_t p, size_t n) {
    return std::string(reinterpret_cast<const char*>(b.data() + p), n);
}
bool Fail(std::string& reason, const char* value) { reason = value; return false; }

/** class 游标在每次推进前验证，读取失败后不可继续把默认 0 当合法索引。 */
struct ClassReader {
    const std::vector<uint8_t>& bytes;
    size_t offset = 0;
    bool valid = true;
    uint32_t read(size_t n) {
        if (!Range(offset, n, bytes.size())) { valid = false; return 0; }
        uint32_t value = 0;
        for (size_t i = 0; i < n; ++i) value = (value << 8) | bytes[offset++];
        return value;
    }
    bool skip(size_t n) {
        if (!Range(offset, n, bytes.size())) { valid = false; return false; }
        offset += n; return true;
    }
};
struct Constant { uint8_t tag = 0; uint16_t index = 0; std::string text; };

bool ProtocolParts(const std::string& text, unsigned& major, unsigned& minor) {
    unsigned values[3] = {};
    size_t part = 0, digits = 0;
    for (char c : text) {
        if (c == '.' && digits && part < 2) { ++part; digits = 0; continue; }
        if (c < '0' || c > '9' || values[part] > 10000) return false;
        values[part] = values[part] * 10 + static_cast<unsigned>(c - '0'); ++digits;
    }
    if (part != 2 || !digits) return false;
    major = values[0]; minor = values[1]; return true;
}
bool RegularFile(const std::string& path) {
    struct stat value {};
    return stat(path.c_str(), &value) == 0 && (value.st_mode & S_IFMT) == S_IFREG && value.st_size > 0;
}
/**
 * MR-JAR 的版本层可以同时改变协议声明和 Native 内联期望。宿主没有重建各加载器/
 * JDK 的 MR 选择规则，因此只要存在这两类的版本覆盖，就不能证明 base 协议会生效。
 * 其他类的 MR 条目不影响本声明，不能把普通第三方 MR-JAR 一概误判为不支持。
 */
bool IsMultiReleaseJnaCore(const std::string& name) {
    const std::string prefix = "META-INF/versions/";
    if (name.compare(0, prefix.size(), prefix) != 0) return false;
    const auto slash = name.find('/', prefix.size());
    if (slash == std::string::npos || slash == prefix.size()) return false;
    for (size_t i = prefix.size(); i < slash; ++i) if (name[i] < '0' || name[i] > '9') return false;
    const auto core = name.substr(slash + 1);
    return core == "com/sun/jna/Version.class" || core == "com/sun/jna/Native.class";
}
}

bool ReadJnaNativeVersion(const std::vector<uint8_t>& bytes, std::string& version, std::string& reason) {
    version.clear();
    if (bytes.size() > kMaxClass) return Fail(reason, "jna_class_too_large");
    ClassReader r{bytes};
    if (r.read(4) != 0xcafebabe) return Fail(reason, "jna_class_invalid_magic");
    r.read(2); r.read(2);
    const auto count = r.read(2);
    if (!r.valid || count < 2 || count > 512) return Fail(reason, "jna_class_invalid_pool");
    std::vector<Constant> pool(count);
    for (size_t i = 1; i < count && r.valid; ++i) {
        auto& value = pool[i]; value.tag = static_cast<uint8_t>(r.read(1));
        switch (value.tag) {
            case 1: {
                const auto length = r.read(2);
                if (!r.valid || !Range(r.offset, length, bytes.size())) return Fail(reason, "jna_class_truncated");
                value.text = Text(bytes, r.offset, length); r.skip(length); break;
            }
            case 7: case 8: case 16: case 19: case 20: value.index = static_cast<uint16_t>(r.read(2)); break;
            case 3: case 4: case 9: case 10: case 11: case 12: case 17: case 18: r.skip(4); break;
            case 5: case 6: r.skip(8); if (++i >= count) return Fail(reason, "jna_class_invalid_pool"); break;
            case 15: r.skip(3); break;
            default: return Fail(reason, "jna_class_unknown_constant");
        }
    }
    const auto textAt = [&](uint32_t index) -> std::string {
        return index < count && pool[index].tag == 1 ? pool[index].text : std::string{};
    };
    r.read(2);
    const auto thisClass = r.read(2); r.read(2);
    if (!r.valid || thisClass >= count || pool[thisClass].tag != 7 ||
        textAt(pool[thisClass].index) != "com/sun/jna/Version") return Fail(reason, "jna_class_identity_mismatch");
    const auto interfaces = r.read(2);
    if (!r.skip(size_t(interfaces) * 2)) return Fail(reason, "jna_class_truncated");
    const auto fields = r.read(2);
    bool found = false;
    for (uint32_t i = 0; i < fields && r.valid; ++i) {
        const auto flags = r.read(2); const auto name = r.read(2); const auto descriptor = r.read(2);
        const auto attributes = r.read(2);
        const bool wanted = textAt(name) == "VERSION_NATIVE";
        if (wanted && (found || textAt(descriptor) != "Ljava/lang/String;" || (flags & 0x18) != 0x18))
            return Fail(reason, "jna_class_invalid_version_field");
        for (uint32_t j = 0; j < attributes && r.valid; ++j) {
            const auto attribute = r.read(2); const auto size = r.read(4);
            if (wanted && textAt(attribute) == "ConstantValue") {
                if (found || size != 2) return Fail(reason, "jna_class_invalid_version_field");
                const auto index = r.read(2);
                if (!r.valid || index >= count || pool[index].tag != 8) return Fail(reason, "jna_class_invalid_version_field");
                version = textAt(pool[index].index); found = true;
            } else r.skip(size);
        }
        if (wanted && !found) return Fail(reason, "jna_class_missing_constant_value");
    }
    // Version 是声明常量的接口；仍遍历后续方法/类属性，拒绝尾部截断和拼接垃圾。
    const auto methods = r.read(2);
    for (uint32_t i = 0; i < methods && r.valid; ++i) {
        r.skip(6); const auto attributes = r.read(2);
        for (uint32_t j = 0; j < attributes && r.valid; ++j) { r.read(2); const auto n = r.read(4); r.skip(n); }
    }
    const auto attributes = r.read(2);
    for (uint32_t i = 0; i < attributes && r.valid; ++i) { r.read(2); const auto n = r.read(4); r.skip(n); }
    unsigned major = 0, minor = 0;
    if (!r.valid || r.offset != bytes.size()) return Fail(reason, "jna_class_truncated_or_trailing");
    if (!found || !ProtocolParts(version, major, minor)) return Fail(reason, "jna_class_unknown_protocol");
    reason = "jna_protocol_read"; return true;
}

bool ReadJnaVersionFromJar(const std::string& path, std::string& version, std::string& reason) {
    std::ifstream stream(path, std::ios::binary | std::ios::ate);
    if (!stream) return Fail(reason, "jna_jar_unreadable");
    const auto length = stream.tellg();
    if (length < 22 || length > static_cast<std::streamoff>(kMaxJar)) return Fail(reason, "jna_jar_size_unsupported");
    std::vector<uint8_t> data(static_cast<size_t>(length));
    stream.seekg(0); stream.read(reinterpret_cast<char*>(data.data()), length);
    if (!stream) return Fail(reason, "jna_jar_unreadable");
    size_t eocd = data.size();
    const size_t begin = data.size() > 65557 ? data.size() - 65557 : 0;
    for (size_t p = data.size() - 22;; --p) {
        if (Le32(data, p) == 0x06054b50 && Range(p + 22, Le16(data, p + 20), data.size()) &&
            p + 22 + Le16(data, p + 20) == data.size()) { eocd = p; break; }
        if (p == begin) break;
    }
    if (eocd == data.size()) return Fail(reason, "jna_zip_eocd_missing");
    const size_t count = Le16(data, eocd + 10), size = Le32(data, eocd + 12), offset = Le32(data, eocd + 16);
    if (count == 0xffff || size == 0xffffffff || offset == 0xffffffff) return Fail(reason, "jna_zip64_deferred");
    if (Le16(data, eocd + 4) || Le16(data, eocd + 6) || Le16(data, eocd + 8) != count)
        return Fail(reason, "jna_zip_multidisk_deferred");
    if (!Range(offset, size, eocd) || count > 8192) return Fail(reason, "jna_zip_central_invalid");
    size_t p = offset, target = 0, matches = 0;
    bool multiReleaseCore = false;
    for (size_t i = 0; i < count; ++i) {
        if (!Range(p, 46, offset + size) || Le32(data, p) != 0x02014b50) return Fail(reason, "jna_zip_central_invalid");
        const size_t name = Le16(data, p + 28), extra = Le16(data, p + 30), comment = Le16(data, p + 32);
        if (!Range(p + 46, name + extra + comment, offset + size)) return Fail(reason, "jna_zip_central_invalid");
        const auto entryName = Text(data, p + 46, name);
        if (entryName == kVersionEntry) { target = p; ++matches; }
        if (IsMultiReleaseJnaCore(entryName)) multiReleaseCore = true;
        p += 46 + name + extra + comment;
    }
    if (p != offset + size) return Fail(reason, "jna_zip_central_invalid");
    if (multiReleaseCore) return Fail(reason, "jna_multi_release_core_deferred");
    if (matches != 1) return Fail(reason, matches ? "jna_zip_duplicate_version" : "jna_zip_version_missing");
    const auto flags = Le16(data, target + 8), method = Le16(data, target + 10);
    const size_t compressed = Le32(data, target + 20), uncompressed = Le32(data, target + 24), local = Le32(data, target + 42);
    if (compressed == 0xffffffff || uncompressed == 0xffffffff || local == 0xffffffff)
        return Fail(reason, "jna_zip64_deferred");
    if (flags & (1 | 0x40)) return Fail(reason, "jna_zip_encrypted_deferred");
    if (method != 0 && method != 8) return Fail(reason, "jna_zip_compression_deferred");
    if (!uncompressed || uncompressed > kMaxClass || compressed > kMaxClass * 2) return Fail(reason, "jna_class_too_large");
    if (!Range(local, 30, offset) || Le32(data, local) != 0x04034b50 || Le16(data, local + 6) != flags ||
        Le16(data, local + 8) != method) return Fail(reason, "jna_zip_local_mismatch");
    const size_t localName = Le16(data, local + 26), localExtra = Le16(data, local + 28);
    if (!Range(local + 30, localName + localExtra, offset) || Text(data, local + 30, localName) != kVersionEntry)
        return Fail(reason, "jna_zip_local_mismatch");
    const size_t start = local + 30 + localName + localExtra;
    if (!Range(start, compressed, offset)) return Fail(reason, "jna_zip_payload_invalid");
    if (!(flags & 8) && (Le32(data, local + 14) != Le32(data, target + 16) ||
        Le32(data, local + 18) != compressed || Le32(data, local + 22) != uncompressed))
        return Fail(reason, "jna_zip_local_mismatch");
    std::vector<uint8_t> bytes(uncompressed);
    if (method == 0) {
        if (compressed != uncompressed) return Fail(reason, "jna_zip_payload_invalid");
        std::copy_n(data.begin() + start, compressed, bytes.begin());
    } else {
        z_stream state{};
        state.next_in = data.data() + start; state.avail_in = static_cast<uInt>(compressed);
        state.next_out = bytes.data(); state.avail_out = static_cast<uInt>(uncompressed);
        if (inflateInit2(&state, -MAX_WBITS) != Z_OK) return Fail(reason, "jna_zip_inflate_failed");
        const int result = inflate(&state, Z_FINISH);
        const bool valid = result == Z_STREAM_END && state.total_in == compressed && state.total_out == uncompressed;
        inflateEnd(&state);
        if (!valid) return Fail(reason, "jna_zip_inflate_failed");
    }
    if (crc32(0, bytes.data(), static_cast<uInt>(bytes.size())) != Le32(data, target + 16))
        return Fail(reason, "jna_zip_crc_mismatch");
    return ReadJnaNativeVersion(bytes, version, reason);
}

JnaBootstrap SelectJnaBootstrap(const std::string& protocol, const std::string& nativeDir) {
    JnaBootstrap result; result.protocol = protocol; result.reason = "jna_protocol_unbundled";
    unsigned major = 0, minor = 0;
    if (!ProtocolParts(protocol, major, minor)) { result.reason = "jna_protocol_invalid"; return result; }
    // 本体来自三个已锁定上游协议；补丁号按 JNA 自身比较函数语义不参与兼容性选择。
    if (major == 5 && minor <= 1) result.bootLibraryName = "jnidispatch_v5";
    else if (major == 6 && minor <= 1) result.bootLibraryName = "jnidispatch_v6";
    else if (major == 7 && minor == 0) result.bootLibraryName = "jnidispatch";
    else return result;
    result.mode = "selected"; result.bootLibraryPath = nativeDir;
    result.requiredArtifact = nativeDir + "/lib" + result.bootLibraryName + ".so";
    result.ok = RegularFile(result.requiredArtifact);
    result.reason = result.ok ? "jna_protocol_selected" : "jna_runtime_artifact_missing";
    return result;
}

JnaBootstrap ResolveJnaBootstrap(const std::string& classpath, const std::string& nativeDir) {
    std::vector<std::string> candidates;
    size_t start = 0;
    while (start <= classpath.size()) {
        const size_t end = classpath.find(':', start);
        const auto path = classpath.substr(start, end == std::string::npos ? end : end - start);
        const auto slash = path.find_last_of("/\\");
        const auto name = path.substr(slash == std::string::npos ? 0 : slash + 1);
        if ((name == "jna.jar" || (name.compare(0, 4, "jna-") == 0 && name != "jna-platform.jar" &&
            name.compare(0, 13, "jna-platform-") != 0)) &&
            name.size() >= 4 && name.substr(name.size() - 4) == ".jar") candidates.push_back(path);
        if (end == std::string::npos) break;
        start = end + 1;
    }
    JnaBootstrap result;
    if (candidates.empty()) return result;
    if (candidates.size() != 1) { result.reason = "jna_multiple_candidates_deferred"; return result; }
    std::string protocol, reason;
    if (!ReadJnaVersionFromJar(candidates[0], protocol, reason)) {
        result.reason = reason; result.sourceJar = candidates[0]; return result;
    }
    result = SelectJnaBootstrap(protocol, nativeDir); result.sourceJar = candidates[0]; return result;
}
}
