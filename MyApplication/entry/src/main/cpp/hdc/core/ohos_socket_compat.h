/**
 * OHOS SDK 26 的 userspace sys/socket.h 与生成的 linux/socket.h 都声明了
 * sockaddr_storage。libusb 的 netlink 后端同时包含两者，导致重复定义。
 * 此探针先取 libc 的 ABI 定义，再屏蔽仅包含重复结构的 kernel socket 头；
 * netlink 所需的地址族 typedef 保持其原始 unsigned short 类型，不改 SDK 文件。
 */
#include <sys/socket.h>
#ifndef _UAPI_LINUX_SOCKET_H
#define _UAPI_LINUX_SOCKET_H
typedef unsigned short __kernel_sa_family_t;
#endif
_Static_assert(sizeof(struct sockaddr_storage) == 128, "OHOS sockaddr_storage ABI");
