/**
 * JDK 单槽安装的 POSIX 存储边界。复用 jdk/.locks/<major>.writer/use，
 * 不引入活动指针或第二套运行时代际；所有修改只发生在独占 staging 或 use.EX 内。
 * API 失败抛出 std::runtime_error，NAPI 统一转换为拒绝/异常；不吞掉权限和 fsync 失败。
 */
#pragma once
#include <cstdint>
#include <string>

namespace amcl::jdk {
/** 创建同文件系统唯一 staging；writerFd 必须仍持有对应槽的排他 writer 锁。 */
std::string CreateInstallStage(const std::string &filesDir, const std::string &major, int writerFd);
/** 只移除本槽、未被持久 journal 引用的 staging；调用时底层解压必须已经结束。 */
void DiscardInstallStage(const std::string &filesDir, const std::string &major, const std::string &stage, int writerFd);
/** 有界预检全部目录项后流式写入：安全相对路径、无链接、数量/深度/实际输出预算。
 * archiveSha 是调用方已经计算/验证的完整 ZIP SHA256；同一打开 fd 再验，防止校验后换包。
 * timeoutMs 只终止本同步 owner；函数退出并关闭全部 fd 后，异步调用方才可清理 staging。 */
void ExtractInstallArchive(const std::string &archive, const std::string &stage, const std::string &archiveSha,
                           uint64_t timeoutMs);
/** 下载和导入共用：验证 ELF 工具/helper、真实 fchmod+回读、逐文件摘要与 fsync，最后封存安装身份。
 * 精确已发布JDK21 v7归档内的固定旧helper只按其完整SHA保留原字节，不授予OHOS工具资格。 */
void SealInstallStage(const std::string &root, const std::string &major, const std::string &archiveSha);
/** 发布/恢复须同时给出 writer 和 use.EX。已持久提交后清理失败保留可读目标，供下次重试。 */
void PublishInstallStage(const std::string &filesDir, const std::string &major, const std::string &stage, int writerFd,
                         int useFd);
void RecoverInstallSlot(const std::string &filesDir, const std::string &major, int writerFd, int useFd);
/** 只读存在性查询；任何记录（包括损坏记录）都表示读者必须先退出 SH 再进入恢复。 */
bool InstallRecoveryRequired(const std::string &filesDir, const std::string &major);
/** 仅在writer下认领已登记且inode匹配的遗留staging；活动下载或未知目录不按名称清理。 */
void CollectAbandonedInstallStage(const std::string &filesDir, const std::string &major, int writerFd);
/** 删除也经过同一 journal，崩溃后明确完成删除或保留旧目录，不产生半棵安装。 */
void DeleteInstallSlot(const std::string &filesDir, const std::string &major, int writerFd, int useFd);
} // namespace amcl::jdk
