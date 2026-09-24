#pragma once
#include <string>
#include <cstdint>
namespace amcl::runtime {
/** 一次维护的实际工作预算；包含扫描、尝试和文件操作，不能只限制成功删除数量。 */
struct MaintenanceLimits { unsigned entries = 128, attempts = 16, removals = 4, fileOperations = 256, milliseconds = 20; };
struct MaintenanceResult { unsigned scanned = 0, attempted = 0, removed = 0, fileOperations = 0; bool exhausted = false; };
MaintenanceResult CollectSlotGarbage(const std::string& activeDirectory, const MaintenanceLimits& limits = {});
// 只处理指定私有恢复目录的已识别票据/原子写暂存；墙钟回退或未来时间均保守保留。
MaintenanceResult CollectGraphicsTickets(const std::string& directory, const std::string& keepId, int64_t nowSeconds,
    const MaintenanceLimits& limits = {});
// 只接受 <mcDir>/.amcl-runtime/<64位内容身份>/<槽名>，不操作 Minecraft 世界或旧平铺槽。
std::string CreateSlotStage(const std::string& destination, std::string& error);
bool PublishSlotGeneration(const std::string& stage, const std::string& destination, std::string& error);
bool DiscardSlotStage(const std::string& stage, std::string& error);
std::string AcquireSlotGeneration(const std::string& directory, std::string& error);
bool ReleaseSlotGeneration(const std::string& handle);
bool RetireSlotGeneration(const std::string& directory, std::string& error);
}
