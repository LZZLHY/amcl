// mg_config_migration.h - Pure MobileGlues 2.0 config migration policy.
#ifndef AMCL_MG_CONFIG_MIGRATION_H
#define AMCL_MG_CONFIG_MIGRATION_H

#include <string>
#include <string_view>

namespace amcl::mgconfig {

// Bump this id whenever serialized preset content changes; device config survives app upgrades.
// v3 adds shipping-off `bufferUploadMode`; `bufferCoherentAsFlush` remains explicit 0.
// See docs/guides/mobileglues-2.0-ohos-governance.md for migration history.
inline constexpr char kPresetId[] =
    "mobileglues-2.0-android-parity-ohos-v3";

enum class ConfigAction {
    KeepCurrent,
    Create,
    Migrate,
    ReplaceMalformed,
};

struct ConfigPlan {
    ConfigAction action = ConfigAction::ReplaceMalformed;
    bool ok = false;
    int preservedOverrides = 0;
    std::string json;
    std::string reason;
    std::string error;
};

// existingJson is ignored when exists is false. A successful KeepCurrent plan
// intentionally has an empty json payload; every other successful action
// returns a complete, newline-terminated config document.
ConfigPlan PlanMobileGluesConfig(bool exists, std::string_view existingJson);

constexpr bool ConfigActionNeedsBackup(ConfigAction action) {
    return action == ConfigAction::Migrate ||
           action == ConfigAction::ReplaceMalformed;
}

} // namespace amcl::mgconfig

#endif // AMCL_MG_CONFIG_MIGRATION_H
