// mg_config.cpp - MobileGlues 2.0 OHOS runtime preset and migration.

#include "mg_config.h"
#include "mg_config_migration.h"

#include <hilog/log.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

#undef LOG_TAG
#define LOG_TAG "MG_CONFIG"

namespace {

constexpr size_t kMaximumConfigBytes = 1024U * 1024U;
constexpr char kConfigName[] = "config.json";
constexpr char kBackupName[] = "config.json.amcl-pre-2.0-v1.bak";

bool EnvDisabled(const char *name) {
    const char *value = std::getenv(name);
    if (value == nullptr || value[0] == '\0') return false;
    return std::strcmp(value, "0") == 0 || strcasecmp(value, "off") == 0 ||
           strcasecmp(value, "false") == 0 || strcasecmp(value, "no") == 0 ||
           strcasecmp(value, "disabled") == 0;
}

bool ReadConfig(const std::string &path, bool *exists, std::string *content,
                std::string *error) {
    *exists = false;
    content->clear();
    struct stat info {};
    if (stat(path.c_str(), &info) != 0) {
        if (errno == ENOENT) return true;
        *error = std::string("stat failed: ") + std::strerror(errno);
        return false;
    }
    *exists = true;
    if (!S_ISREG(info.st_mode) || info.st_size < 0 ||
        static_cast<unsigned long long>(info.st_size) > kMaximumConfigBytes) {
        *error = "config is not a regular file within the 1 MiB safety limit";
        return false;
    }
    FILE *input = std::fopen(path.c_str(), "rb");
    if (input == nullptr) {
        *error = std::string("open failed: ") + std::strerror(errno);
        return false;
    }
    content->resize(static_cast<size_t>(info.st_size));
    const size_t read = content->empty()
                            ? 0
                            : std::fread(content->data(), 1, content->size(), input);
    const bool readOk = read == content->size() && std::ferror(input) == 0;
    const int closeResult = std::fclose(input);
    if (!readOk || closeResult != 0) {
        // A short fread does not set errno, so strerror would report whatever
        // stale value a previous call left behind. Only quote errno for the
        // close failure, which does set it.
        *error = !readOk ? "read failed: short read"
                         : std::string("close failed: ") + std::strerror(errno);
        return false;
    }
    return true;
}

bool SyncDirectory(const std::string &directory) {
    const int descriptor = open(directory.c_str(), O_RDONLY | O_DIRECTORY);
    if (descriptor < 0) return false;
    int failure = fsync(descriptor) == 0 ? 0 : errno;
    if (close(descriptor) != 0 && failure == 0) failure = errno;
    if (failure == 0) return true;
    errno = failure;
    return false;
}

bool AtomicWrite(const std::string &directory, const std::string &path,
                 const std::string &content, std::string *error) {
    error->clear();
    const std::string temporary =
        path + ".tmp." + std::to_string(static_cast<long long>(getpid()));
    const int descriptor = open(temporary.c_str(),
                                O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (descriptor < 0) {
        *error = std::string("create temp failed: ") + std::strerror(errno);
        return false;
    }

    size_t offset = 0;
    int failure = 0;
    while (offset < content.size()) {
        const ssize_t written =
            write(descriptor, content.data() + offset, content.size() - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            failure = written < 0 ? errno : EIO;
            break;
        }
        offset += static_cast<size_t>(written);
    }
    if (failure == 0 && fsync(descriptor) != 0) failure = errno;
    if (close(descriptor) != 0 && failure == 0) failure = errno;
    if (failure != 0) {
        unlink(temporary.c_str());
        *error = std::string("write temp failed: ") + std::strerror(failure);
        return false;
    }
    if (rename(temporary.c_str(), path.c_str()) != 0) {
        const int saved = errno;
        unlink(temporary.c_str());
        *error = std::string("rename temp failed: ") + std::strerror(saved);
        return false;
    }
    chmod(path.c_str(), 0600);
    if (!SyncDirectory(directory))
        *error = std::string("directory sync warning: ") + std::strerror(errno);
    return true;
}

bool EnsureBackup(const std::string &directory, const std::string &backupPath,
                  const std::string &content, std::string *error) {
    error->clear();
    struct stat ignored {};
    if (stat(backupPath.c_str(), &ignored) == 0) return true;
    if (errno != ENOENT) {
        *error = std::string("backup stat failed: ") + std::strerror(errno);
        return false;
    }
    return AtomicWrite(directory, backupPath, content, error);
}

const char *ActionName(amcl::mgconfig::ConfigAction action) {
    using amcl::mgconfig::ConfigAction;
    switch (action) {
    case ConfigAction::KeepCurrent:
        return "keep-current";
    case ConfigAction::Create:
        return "create";
    case ConfigAction::Migrate:
        return "migrate";
    case ConfigAction::ReplaceMalformed:
        return "replace-malformed";
    }
    return "unknown";
}

} // namespace

extern "C" void prepareMobileGluesRuntime() {
    const std::string mgDir = "/data/storage/el2/base/files/MG";
    if (mkdir(mgDir.c_str(), 0755) != 0 && errno != EEXIST) {
        OH_LOG_ERROR(LOG_APP, "mkdir(%{public}s) failed: %{public}s",
                     mgDir.c_str(), std::strerror(errno));
        return;
    }
    if (setenv("MG_DIR_PATH", mgDir.c_str(), /*overwrite=*/1) != 0) {
        OH_LOG_ERROR(LOG_APP, "setenv(MG_DIR_PATH) failed: %{public}s",
                     std::strerror(errno));
        return;
    }

    // Android may probe ANGLE by default. AMCL ships no ANGLE libraries, so
    // force-disable that backend as the single documented platform difference.
    if (setenv("MG_ANGLE_DIR", "", /*overwrite=*/1) != 0) {
        OH_LOG_ERROR(LOG_APP, "setenv(MG_ANGLE_DIR) failed: %{public}s",
                     std::strerror(errno));
        return;
    }

    const std::string configPath = mgDir + "/" + kConfigName;
    const std::string backupPath = mgDir + "/" + kBackupName;
    bool exists = false;
    std::string existing;
    std::string error;
    if (!ReadConfig(configPath, &exists, &existing, &error)) {
        OH_LOG_ERROR(LOG_APP, "MG config inspection failed: %{public}s",
                     error.c_str());
        return;
    }

    // Emergency rollback: preserve an existing file byte-for-byte. Missing
    // files still receive the safe 2.0 preset so first installs remain defined.
    if (exists && EnvDisabled("AMCL_MG_CONFIG_MIGRATION")) {
        OH_LOG_WARN(LOG_APP,
                    "MG config migration disabled by environment; preserving %{public}s",
                    configPath.c_str());
        return;
    }

    const amcl::mgconfig::ConfigPlan plan =
        amcl::mgconfig::PlanMobileGluesConfig(exists, existing);
    if (!plan.ok) {
        OH_LOG_ERROR(LOG_APP, "MG config planning failed: %{public}s",
                     plan.error.c_str());
        return;
    }
    if (plan.action == amcl::mgconfig::ConfigAction::KeepCurrent) {
        OH_LOG_INFO(LOG_APP, "MG 2.0 preset current: %{public}s",
                    configPath.c_str());
        return;
    }

    if (amcl::mgconfig::ConfigActionNeedsBackup(plan.action)) {
        if (!EnsureBackup(mgDir, backupPath, existing, &error)) {
            OH_LOG_ERROR(LOG_APP,
                         "MG config backup failed; original preserved: %{public}s",
                         error.c_str());
            return;
        }
        if (!error.empty()) {
            OH_LOG_WARN(LOG_APP, "MG config backup %{public}s", error.c_str());
        }
    }
    if (!AtomicWrite(mgDir, configPath, plan.json, &error)) {
        OH_LOG_ERROR(LOG_APP,
                     "MG config atomic update failed; original preserved: %{public}s",
                     error.c_str());
        return;
    }
    if (!error.empty()) {
        OH_LOG_WARN(LOG_APP, "MG config update %{public}s", error.c_str());
    }

    OH_LOG_INFO(LOG_APP,
                "MG 2.0 config action=%{public}s reason=%{public}s "
                "preservedOverrides=%{public}d backup=%{public}s",
                ActionName(plan.action), plan.reason.c_str(),
                plan.preservedOverrides,
                amcl::mgconfig::ConfigActionNeedsBackup(plan.action)
                    ? backupPath.c_str()
                    : "none");
}
