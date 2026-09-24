// mg_config_migration.cpp - Schema-aware MobileGlues 2.0 preset migration.

#include "mg_config_migration.h"

#include "cJSON.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <limits>
#include <memory>
#include <string>
#include <utility>

namespace amcl::mgconfig {
namespace {

using JsonPtr = std::unique_ptr<cJSON, decltype(&cJSON_Delete)>;

struct IntField {
    const char *name;
    int defaultValue;
    int minimum;
    int maximum;
    bool allowZeroGap;
};

constexpr std::array<IntField, 11> kPreservedIntFields = {{
    {"enableNoError", 0, 0, 3, false},
    {"enableExtComputeShader", 0, 0, 1, false},
    {"enableExtTimerQuery", 1, 0, 1, false},
    {"enableExtDirectStateAccess", 0, 0, 1, false},
    // <=2047: MG 2.0 multiplies this by 1024*1024 in *int* (settings.cpp) — 2048+ is signed-overflow UB.
    {"maxGlslCacheSize", 32, 0, 2047, false},
    {"angleDepthClearFixMode", 0, 0, 2, false},
    {"customGLVersion", 0, 32, 46, true},
    {"fsr1Setting", 0, 0, 4, false},
    {"hideMGEnvLevel", 0, 0, 1, false},
    // Shipping keeps coherent substitution off; MG still preserves exact dynamic-storage contracts.
    {"bufferCoherentAsFlush", 0, 0, 1, false},
    // Hidden MG upload-scheduler mode stays off except during controlled diagnostics.
    {"bufferUploadMode", 0, 0, 2, false},
}};

constexpr std::array<const char *, 8> kGlobalBackends = {{
    "native", "multiindirect", "multibasevertex", "multiarrays",
    "indirect", "basevertex", "unroll", "compute",
}};
constexpr std::array<const char *, 3> kArraysBackends = {{
    "unroll", "multiarrays", "multiindirect",
}};
constexpr std::array<const char *, 5> kElementsBackends = {{
    "unroll", "indirect", "multiindirect", "multibasevertex", "multiarrays",
}};
constexpr std::array<const char *, 6> kElementsBaseVertexBackends = {{
    "unroll", "basevertex", "indirect", "multiindirect",
    "multibasevertex", "compute",
}};
constexpr std::array<const char *, 2> kIndirectBackends = {{
    "indirect", "multiindirect",
}};

struct StringField {
    const char *name;
    const char *defaultValue;
    const char *const *allowed;
    size_t allowedCount;
    bool required;
};

constexpr std::array<StringField, 6> kOrderFields = {{
    {"multidrawOrder",
     "native,multiindirect,multibasevertex,multiarrays,indirect,basevertex,unroll,compute",
     kGlobalBackends.data(), kGlobalBackends.size(), true},
    {"multidrawOrderArrays", nullptr, kArraysBackends.data(),
     kArraysBackends.size(), false},
    {"multidrawOrderElements", nullptr, kElementsBackends.data(),
     kElementsBackends.size(), false},
    {"multidrawOrderElementsBaseVertex", nullptr,
     kElementsBaseVertexBackends.data(), kElementsBaseVertexBackends.size(), false},
    {"multidrawOrderArraysIndirect", nullptr, kIndirectBackends.data(),
     kIndirectBackends.size(), false},
    {"multidrawOrderElementsIndirect", nullptr, kIndirectBackends.data(),
     kIndirectBackends.size(), false},
}};

constexpr std::array<const char *, 7> kLegacyKeys = {{
    "multidrawMode",
    "multidrawDisableBackends",
    "multidrawModeArrays",
    "multidrawModeElements",
    "multidrawModeElementsBaseVertex",
    "multidrawModeArraysIndirect",
    "multidrawModeElementsIndirect",
}};

bool TryGetInt(const cJSON *root, const IntField &field, int *value) {
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(root, field.name);
    if (!cJSON_IsNumber(item) || !std::isfinite(item->valuedouble) ||
        std::floor(item->valuedouble) != item->valuedouble ||
        item->valuedouble < std::numeric_limits<int>::min() ||
        item->valuedouble > std::numeric_limits<int>::max()) {
        return false;
    }
    const int candidate = static_cast<int>(item->valuedouble);
    if (field.allowZeroGap && candidate == 0) {
        *value = candidate;
        return true;
    }
    if (candidate < field.minimum || candidate > field.maximum) return false;
    *value = candidate;
    return true;
}

bool IsExactInteger(const cJSON *root, const char *name, int expected) {
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(root, name);
    return cJSON_IsNumber(item) && std::isfinite(item->valuedouble) &&
           item->valuedouble == expected;
}

std::string NormalizeBackendToken(std::string token) {
    token.erase(std::remove_if(token.begin(), token.end(), [](char value) {
                    return value == ' ' || value == '\t' || value == '_' ||
                           value == '-';
                }),
                token.end());
    std::transform(token.begin(), token.end(), token.begin(), [](char value) {
        return value >= 'A' && value <= 'Z'
                   ? static_cast<char>(value - 'A' + 'a')
                   : value;
    });
    return token;
}

bool IsValidOrder(const char *value, const StringField &field) {
    if (value == nullptr || value[0] == '\0') return false;
    std::string token;
    size_t accepted = 0;
    const std::string raw(value);
    for (size_t index = 0; index <= raw.size(); ++index) {
        const char current = index < raw.size() ? raw[index] : ',';
        if (current != ',' && current != ';') {
            token.push_back(current);
            continue;
        }
        token = NormalizeBackendToken(std::move(token));
        if (token.empty()) continue;
        bool known = false;
        for (size_t allowed = 0; allowed < field.allowedCount; ++allowed) {
            if (token == field.allowed[allowed]) {
                known = true;
                break;
            }
        }
        if (!known) return false;
        ++accepted;
        token.clear();
    }
    return accepted > 0 && accepted <= field.allowedCount;
}

const char *GetValidOrder(const cJSON *root, const StringField &field) {
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(root, field.name);
    if (!cJSON_IsString(item) || !IsValidOrder(item->valuestring, field)) {
        return nullptr;
    }
    return item->valuestring;
}

bool HasCurrentMarker(const cJSON *root) {
    const cJSON *marker = cJSON_GetObjectItemCaseSensitive(root, "_amclPreset");
    return cJSON_IsString(marker) && marker->valuestring != nullptr &&
           std::string(marker->valuestring) == kPresetId;
}

bool IsValidCurrent(const cJSON *root) {
    if (!HasCurrentMarker(root) || !IsExactInteger(root, "enableANGLE", 2)) {
        return false;
    }
    for (const IntField &field : kPreservedIntFields) {
        int ignored = 0;
        if (!TryGetInt(root, field, &ignored)) return false;
    }
    for (const StringField &field : kOrderFields) {
        const cJSON *item = cJSON_GetObjectItemCaseSensitive(root, field.name);
        if (item == nullptr) {
            if (field.required) return false;
            continue;
        }
        if (GetValidOrder(root, field) == nullptr) return false;
    }
    for (const char *legacy : kLegacyKeys) {
        if (cJSON_GetObjectItemCaseSensitive(root, legacy) != nullptr) return false;
    }
    return true;
}

bool AddNumber(cJSON *root, const char *name, int value) {
    return cJSON_AddNumberToObject(root, name, value) != nullptr;
}

bool AddString(cJSON *root, const char *name, const char *value) {
    return value != nullptr && cJSON_AddStringToObject(root, name, value) != nullptr;
}

JsonPtr BuildNormalized(const cJSON *existing, int *preservedOverrides,
                        std::string *error) {
    JsonPtr result(cJSON_CreateObject(), cJSON_Delete);
    if (!result) {
        *error = "cannot allocate config root";
        return result;
    }
    if (!AddString(result.get(), "_amclPreset", kPresetId) ||
        !AddNumber(result.get(), "enableANGLE", 2)) {
        *error = "cannot allocate required platform fields";
        return JsonPtr(nullptr, cJSON_Delete);
    }

    for (const IntField &field : kPreservedIntFields) {
        int value = field.defaultValue;
        int existingValue = 0;
        if (existing != nullptr && TryGetInt(existing, field, &existingValue)) {
            value = existingValue;
            if (value != field.defaultValue) ++*preservedOverrides;
        }
        if (!AddNumber(result.get(), field.name, value)) {
            *error = std::string("cannot allocate field: ") + field.name;
            return JsonPtr(nullptr, cJSON_Delete);
        }
    }

    for (const StringField &field : kOrderFields) {
        const char *value = existing != nullptr ? GetValidOrder(existing, field) : nullptr;
        if (value != nullptr) {
            if (field.defaultValue == nullptr || std::string(value) != field.defaultValue) {
                ++*preservedOverrides;
            }
        } else {
            value = field.defaultValue;
        }
        if (value != nullptr && !AddString(result.get(), field.name, value)) {
            *error = std::string("cannot allocate field: ") + field.name;
            return JsonPtr(nullptr, cJSON_Delete);
        }
    }
    return result;
}

} // namespace

ConfigPlan PlanMobileGluesConfig(bool exists, std::string_view existingJson) {
    ConfigPlan plan;
    plan.ok = false;

    JsonPtr existing(nullptr, cJSON_Delete);
    if (exists) {
        std::string payload(existingJson);
        const char *parseEnd = nullptr;
        existing.reset(cJSON_ParseWithLengthOpts(
            payload.c_str(), payload.size() + 1, &parseEnd,
            /*require_null_terminated=*/1));
        if (!existing || !cJSON_IsObject(existing.get())) {
            plan.action = ConfigAction::ReplaceMalformed;
            plan.reason = "malformed-or-non-object";
            existing.reset();
        } else if (IsValidCurrent(existing.get())) {
            plan.action = ConfigAction::KeepCurrent;
            plan.reason = "current-valid";
            plan.ok = true;
            return plan;
        } else {
            plan.action = ConfigAction::Migrate;
            plan.reason = HasCurrentMarker(existing.get()) ? "current-invalid"
                                                           : "legacy-or-unmarked";
        }
    } else {
        plan.action = ConfigAction::Create;
        plan.reason = "absent";
    }

    JsonPtr normalized = BuildNormalized(existing.get(), &plan.preservedOverrides,
                                         &plan.error);
    if (!normalized) return plan;
    char *printed = cJSON_Print(normalized.get());
    if (printed == nullptr) {
        plan.error = "cannot serialize normalized config";
        return plan;
    }
    plan.json.assign(printed);
    cJSON_free(printed);
    plan.json.push_back('\n');
    plan.ok = true;
    return plan;
}

} // namespace amcl::mgconfig
