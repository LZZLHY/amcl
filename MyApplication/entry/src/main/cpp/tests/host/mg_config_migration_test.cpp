#include "mg_config_migration.h"

#include <cctype>
#include <iostream>
#include <string>

namespace {

bool Require(bool condition, const char *message) {
    if (condition) return true;
    std::cerr << message << '\n';
    return false;
}

bool FindJsonNumber(const std::string &json, const std::string &key,
                    size_t *begin, size_t *end) {
    const size_t keyPosition = json.find('"' + key + '"');
    if (keyPosition == std::string::npos) return false;
    const size_t colon = json.find(':', keyPosition + key.size() + 2);
    if (colon == std::string::npos) return false;
    size_t cursor = colon + 1;
    while (cursor < json.size() &&
           std::isspace(static_cast<unsigned char>(json[cursor]))) {
        ++cursor;
    }
    *begin = cursor;
    if (cursor < json.size() && json[cursor] == '-') ++cursor;
    while (cursor < json.size() &&
           std::isdigit(static_cast<unsigned char>(json[cursor]))) {
        ++cursor;
    }
    *end = cursor;
    return *end > *begin;
}

bool JsonHasNumber(const std::string &json, const std::string &key,
                   int expected) {
    size_t begin = 0;
    size_t end = 0;
    return FindJsonNumber(json, key, &begin, &end) &&
           json.substr(begin, end - begin) == std::to_string(expected);
}

bool ReplaceJsonNumber(std::string *json, const std::string &key, int value) {
    size_t begin = 0;
    size_t end = 0;
    if (!FindJsonNumber(*json, key, &begin, &end)) return false;
    json->replace(begin, end - begin, std::to_string(value));
    return true;
}

} // namespace

int main() {
    using amcl::mgconfig::ConfigAction;
    using amcl::mgconfig::PlanMobileGluesConfig;

    const auto absent = PlanMobileGluesConfig(false, {});
    if (!Require(absent.ok && absent.action == ConfigAction::Create,
                 "absent config did not create the preset") ||
        !Require(absent.json.find(amcl::mgconfig::kPresetId) != std::string::npos,
                 "created config omitted the preset marker") ||
        // Explicitly override the provider's historical coherent default and keep scheduling off.
        !Require(JsonHasNumber(absent.json, "bufferCoherentAsFlush", 0),
                 "preset did not force bufferCoherentAsFlush off") ||
        !Require(JsonHasNumber(absent.json, "bufferUploadMode", 0),
                 "preset did not keep the upload scheduler disabled") ||
        !Require(PlanMobileGluesConfig(true, absent.json).action ==
                     ConfigAction::KeepCurrent,
                 "created config is not self-validating")) {
        return 1;
    }

    const std::string legacy = R"json({
  "enableANGLE": 3,
  "enableNoError": 3,
  "customGLVersion": 46,
  "multidrawOrder": "unroll,basevertex",
  "multidrawOrderElements": "unroll,multiindirect",
  "multidrawMode": 2,
  "bufferCoherentAsFlush": 1,
  "bufferUploadMode": 2,
  "userMetadata": "must remain in backup only"
})json";
    const auto migrated = PlanMobileGluesConfig(true, legacy);
    if (!Require(migrated.ok && migrated.action == ConfigAction::Migrate,
                 "legacy config did not migrate") ||
        !Require(migrated.preservedOverrides >= 4,
                 "supported legacy user overrides were not preserved") ||
        !Require(JsonHasNumber(migrated.json, "enableANGLE", 2),
                 "OHOS ANGLE force-disable was not restored") ||
        !Require(JsonHasNumber(migrated.json, "enableNoError", 3),
                 "valid numeric override was not preserved") ||
        // Preserve supported non-default values so migration remains a controlled fallback path.
        !Require(JsonHasNumber(migrated.json, "bufferCoherentAsFlush", 1),
                 "supported bufferCoherentAsFlush override was not preserved") ||
        !Require(JsonHasNumber(migrated.json, "bufferUploadMode", 2),
                 "supported bufferUploadMode override was not preserved") ||
        !Require(migrated.json.find("multidrawMode") == std::string::npos &&
                     migrated.json.find("userMetadata") == std::string::npos,
                 "legacy or unknown keys escaped normalization") ||
        !Require(PlanMobileGluesConfig(true, migrated.json).action ==
                     ConfigAction::KeepCurrent,
                 "migrated config is not self-validating")) {
        return 1;
    }

    const auto malformed = PlanMobileGluesConfig(true, "{not-json");
    if (!Require(malformed.ok &&
                     malformed.action == ConfigAction::ReplaceMalformed,
                 "malformed config did not fail into a safe replacement") ||
        !Require(PlanMobileGluesConfig(true, malformed.json).action ==
                     ConfigAction::KeepCurrent,
                 "malformed replacement is not self-validating")) {
        return 1;
    }

    std::string invalidCurrent = absent.json;
    if (!Require(ReplaceJsonNumber(&invalidCurrent, "enableExtTimerQuery", 9),
                 "fixture could not corrupt current field")) {
        return 1;
    }
    const auto repaired = PlanMobileGluesConfig(true, invalidCurrent);
    if (!Require(repaired.ok && repaired.action == ConfigAction::Migrate &&
                     repaired.reason == "current-invalid",
                 "invalid current config was not repaired") ||
        !Require(JsonHasNumber(repaired.json, "enableExtTimerQuery", 1),
                 "invalid override did not fall back to the baseline")) {
        return 1;
    }

    std::string validOverride = absent.json;
    if (!Require(ReplaceJsonNumber(&validOverride, "enableNoError", 3),
                 "fixture could not add a valid current override") ||
        !Require(PlanMobileGluesConfig(true, validOverride).action ==
                     ConfigAction::KeepCurrent,
                 "valid current user override should be preserved byte-for-byte")) {
        return 1;
    }

    // maxGlslCacheSize*1024*1024 is int arithmetic in MG (settings.cpp): 2047 is the last legal override, 2048 overflows.
    std::string cacheEdge = absent.json;
    if (!Require(ReplaceJsonNumber(&cacheEdge, "maxGlslCacheSize", 2047),
                 "fixture could not set the cache-size edge value") ||
        !Require(PlanMobileGluesConfig(true, cacheEdge).action ==
                     ConfigAction::KeepCurrent,
                 "maxGlslCacheSize=2047 must remain a legal user override")) {
        return 1;
    }
    std::string cacheOverflow = absent.json;
    if (!Require(ReplaceJsonNumber(&cacheOverflow, "maxGlslCacheSize", 2048),
                 "fixture could not set the cache-size overflow value")) {
        return 1;
    }
    const auto cacheRepaired = PlanMobileGluesConfig(true, cacheOverflow);
    if (!Require(cacheRepaired.ok && cacheRepaired.action == ConfigAction::Migrate,
                 "maxGlslCacheSize=2048 must be rejected as invalid") ||
        !Require(JsonHasNumber(cacheRepaired.json, "maxGlslCacheSize", 32),
                 "overflowing maxGlslCacheSize did not fall back to the baseline")) {
        return 1;
    }

    std::cout << "mg_config_migration_test: PASS\n";
    return 0;
}
