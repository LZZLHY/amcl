/** ELF 符号版本表的有界只读解释。
 * 动态表由调用方冻结；所有相对指针仍必须落在 file-backed LOAD 内。解析只创建
 * 名称/索引数据，不执行 resolver，不写映像，失败时外层装载事务不能进入构造器。
 */
#pragma once
#include <elf.h>
#include <cstdint>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

namespace amcl::elfversions {
struct Version { std::string name; uint32_t hash = 0; };
/** relocation 允许上游通用的无版本定义抢占；显式 dlvsym 则要求精确版本。 */
struct Request { const char* name = nullptr; uint32_t hash = 0; bool relocation = false; };
struct Table {
    std::vector<Elf64_Half> symbols;
    std::unordered_map<uint16_t, Version> definitions;
    std::unordered_map<uint16_t, Version> requirements;

    /** 查询时默认跳过 @OLD 的 hidden 版本；不能因 hash 链中先遇到它就停止。 */
    bool accepts(size_t symbol, const Request* request) const noexcept {
        if (symbols.empty()) return !request || request->relocation;
        if (symbol >= symbols.size()) return false;
        const uint16_t value = symbols[symbol], index = value & 0x7fff;
        if (index == VER_NDX_LOCAL) return false;
        if (!request) return !(value & 0x8000);
        if (index == VER_NDX_GLOBAL) return request->relocation;
        const auto item = definitions.find(index);
        return item != definitions.end() && item->second.hash == request->hash &&
               item->second.name == request->name;
    }

    /** 返回的 name 借用已冻结 Table，寿命覆盖整批重定位。 */
    Request required(size_t symbol, bool defined) const noexcept {
        if (symbols.empty() || symbol >= symbols.size()) return {};
        const uint16_t index = symbols[symbol] & 0x7fff;
        if (index <= VER_NDX_GLOBAL) return {};
        const auto& map = defined ? definitions : requirements;
        const auto item = map.find(index);
        return item == map.end() ? Request{} : Request{item->second.name.c_str(), item->second.hash, true};
    }
};

/** SysV hash 是 ELF verdef/vernaux 的规定版本名摘要，不依赖宿主 std::hash。 */
inline uint32_t hash(const char* name) noexcept {
    uint32_t value = 0;
    for (const unsigned char* p = reinterpret_cast<const unsigned char*>(name); *p; ++p) {
        value = (value << 4) + *p;
        const uint32_t high = value & 0xf0000000;
        if (high) value ^= high >> 24;
        value &= ~high;
    }
    return value;
}

/** view(addr,bytes) 只返回范围已核验的映像字节。链步长必须正向且可容纳结构，
 * 每层同时受明确条目数和文件范围限制；计数与链尾不一致也拒绝。
 */
template<class View>
bool parse(Table& table, const std::unordered_map<Elf64_Sxword, Elf64_Xword>& tags,
           const Elf64_Sym* symbols, size_t symbolCount, const char* strings, size_t stringBytes,
           View view, const char*& error) {
    auto fail = [&](const char* text) { error = text; return false; };
    auto value = [&](Elf64_Sxword key) -> uint64_t {
        const auto entry = tags.find(key); return entry == tags.end() ? 0 : entry->second;
    };
    auto read = [&](uint64_t address, auto& object) {
        const void* data = view(address, sizeof(object));
        if (!data) return false;
        std::memcpy(&object, data, sizeof(object)); return true;
    };
    auto advance = [](uint64_t& address, uint64_t delta, size_t minimum) {
        if (delta < minimum || delta > UINT64_MAX - address) return false;
        address += delta; return true;
    };
    auto name = [&](uint32_t offset) -> const char* {
        if (offset >= stringBytes || !strings[offset] ||
            !std::memchr(strings + offset, 0, stringBytes - offset)) return nullptr;
        return strings + offset;
    };
    if (value(DT_VERDEFNUM) > symbolCount || value(DT_VERNEEDNUM) > symbolCount)
        return fail("version table count exceeds symbol count");
    if (bool(value(DT_VERDEF)) != bool(value(DT_VERDEFNUM)) ||
        bool(value(DT_VERNEED)) != bool(value(DT_VERNEEDNUM)))
        return fail("incomplete version table address/count");
    uint64_t address = value(DT_VERDEF);
    for (uint64_t i = 0; i < value(DT_VERDEFNUM); ++i) {
        Elf64_Verdef definition{};
        if (!read(address, definition) || definition.vd_version != VER_DEF_CURRENT ||
            !definition.vd_cnt || definition.vd_cnt > symbolCount ||
            (definition.vd_ndx & 0x8000) || definition.vd_ndx == VER_NDX_LOCAL)
            return fail("invalid version definition");
        uint64_t auxiliary = address;
        if (!advance(auxiliary, definition.vd_aux, sizeof(definition))) return fail("invalid version auxiliary offset");
        const char* primary = nullptr;
        for (unsigned a = 0; a < definition.vd_cnt; ++a) {
            Elf64_Verdaux item{};
            if (!read(auxiliary, item) || !name(item.vda_name)) return fail("invalid version definition name");
            if (!a) primary = name(item.vda_name);
            if (a + 1 < definition.vd_cnt) {
                if (!advance(auxiliary, item.vda_next, sizeof(item))) return fail("invalid version parent chain");
            } else if (item.vda_next) return fail("version parent count mismatch");
        }
        if (hash(primary) != definition.vd_hash ||
            !table.definitions.emplace(definition.vd_ndx, Version{primary, definition.vd_hash}).second)
            return fail("duplicate version index or invalid definition hash");
        if (i + 1 < value(DT_VERDEFNUM)) {
            if (!advance(address, definition.vd_next, sizeof(definition))) return fail("invalid version definition chain");
        } else if (definition.vd_next) return fail("version definition count mismatch");
    }
    address = value(DT_VERNEED);
    for (uint64_t i = 0; i < value(DT_VERNEEDNUM); ++i) {
        Elf64_Verneed need{};
        if (!read(address, need) || need.vn_version != VER_NEED_CURRENT || !need.vn_cnt ||
            need.vn_cnt > symbolCount || !name(need.vn_file)) return fail("invalid version requirement");
        uint64_t auxiliary = address;
        if (!advance(auxiliary, need.vn_aux, sizeof(need))) return fail("invalid version requirement offset");
        for (unsigned a = 0; a < need.vn_cnt; ++a) {
            Elf64_Vernaux item{};
            if (!read(auxiliary, item) || !name(item.vna_name) ||
                (item.vna_other & 0x7fff) <= VER_NDX_GLOBAL || hash(name(item.vna_name)) != item.vna_hash)
                return fail("invalid required version name/index/hash");
            if (!table.requirements.emplace(item.vna_other & 0x7fff, Version{name(item.vna_name), item.vna_hash}).second)
                return fail("duplicate required version index");
            if (a + 1 < need.vn_cnt) {
                if (!advance(auxiliary, item.vna_next, sizeof(item))) return fail("invalid requirement chain");
            } else if (item.vna_next) return fail("version requirement count mismatch");
        }
        if (i + 1 < value(DT_VERNEEDNUM)) {
            if (!advance(address, need.vn_next, sizeof(need))) return fail("invalid version need chain");
        } else if (need.vn_next) return fail("version need count mismatch");
    }
    if (value(DT_VERSYM)) {
        if (symbolCount > SIZE_MAX / sizeof(Elf64_Half)) return fail("version symbols overflow");
        const void* data = view(value(DT_VERSYM), symbolCount * sizeof(Elf64_Half));
        if (!data) return fail("version symbols outside LOAD");
        table.symbols.resize(symbolCount);
        std::memcpy(table.symbols.data(), data, table.symbols.size() * sizeof(Elf64_Half));
        for (size_t i = 0; i < symbolCount; ++i) {
            const uint16_t index = table.symbols[i] & 0x7fff;
            const auto& map = symbols[i].st_shndx == SHN_UNDEF ? table.requirements : table.definitions;
            if (index > VER_NDX_GLOBAL && !map.count(index)) return fail("symbol references unknown version");
        }
    } else if (!table.definitions.empty() || !table.requirements.empty()) return fail("version records without VERSYM");
    return true;
}
} // namespace amcl::elfversions
