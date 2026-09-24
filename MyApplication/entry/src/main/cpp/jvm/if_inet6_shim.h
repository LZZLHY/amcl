/**
 * if_inet6_shim.h — 为 ELF-loaded 的 JDK 合成 /proc/net/if_inet6
 *
 * 方案：docs/adaptation/JDK_IPV6_ADAPTATION_PLAN.md §四·五 R1
 * 施工记录：docs/refactor/JDK-IPv6施工记录.md §S06
 *
 * ============================================================================
 * 它解决什么
 * ============================================================================
 * HarmonyOS 应用沙箱**拒绝读** /proc/net/if_inet6（真机实测 errno=13 EACCES；
 * 文件存在、目录能列、只是读被拒）。而上游 OpenJDK 的 Linux 分支用"能不能读到
 * 这个文件的第一行"来回答"本机有没有 IPv6"：
 *
 *   IPv6_supported()  = socket(AF_INET6) 成功
 *                     && [仅 JDK 17] fd 0 不是 AF_INET socket
 *                     && fopen("/proc/net/if_inet6") 且一次 fgets 非空   ← 这一条挂了
 *                     && dlsym(RTLD_DEFAULT, "inet_pton") 非空
 *
 * 真机实测四条里**只有第三条不成立** ⇒ Net.isIPv6Available() 恒为 false ⇒
 * NIO 建出 IPv4-only channel ⇒ 连 Inet6Address 抛 UnsupportedAddressTypeException
 * （message 为 null，Minecraft ConnectScreen 对它调 replaceAll 再炸一次 NPE）。
 *
 * ============================================================================
 * 为什么在这一层修（而不是改 JDK 的 C 代码重编）
 * ============================================================================
 * 1. 同一个文件在 JDK 里有**两个**独立消费者：`IPv6_supported()`（能力）与
 *    `NetworkInterface.c` 的 `enumIPv6Interfaces()`（枚举）。喂饱文件同时喂饱两者；
 *    只改 IPv6_supported() 会留下"能力 true 但 NetworkInterface 的 IPv6 恒为 0 条"
 *    的不自洽状态（真机已实测该状态的两侧数字：native getifaddrs 5 条 / Java 侧 0 条）。
 * 2. 走 HAP 更新通道，一次覆盖 JDK 8/17/21/25，用户**零 JDK 重下**
 *    （重发 JDK 要每版 108~117 MB，且无 `.amcl_release_tag` 戳的旧装根本收不到）。
 * 3. 平台哪天放开了这个文件，垫片按 R1.2 自动退化为透传，无需再改一次。
 *
 * ⚠️ 这**不是**"上游干净"的修法，只是平台适配垫片。上游语义的修法（给
 * net_util_md.c 打 patch 并重编 libnet.so）是方案 §四·五 R4，随下次 JDK 升版落地；
 * R4 落地后本垫片仍在喂消费者 2，不会变成死代码。
 *
 * ============================================================================
 * 边界
 * ============================================================================
 * - 只对**经 elf_loader 加载的库**生效（即 JDK 自己）。libentry.so 内部的 fopen
 *   在编译期直连 libc，不经过这里。
 * - 只拦精确路径、只服务只读打开；其余一律返回 NULL 让调用方回落真 fopen。
 * - 拿不到任何 IPv6 地址时**不造假**，回落真 fopen（维持今天的 false）。
 * - 四个版本的 libnet.so 都只导入 plain `fopen`（已逐个核对 .dynsym），
 *   所以插桩 `fopen` 一处即可；若将来某版本改用 `fopen64`，这里要补一条。
 */
#ifndef MC_OHOS_IF_INET6_SHIM_H
#define MC_OHOS_IF_INET6_SHIM_H

#include <stdio.h>

#ifdef __cplusplus
#include <cstddef>
#include <vector>

#include "../platform/if_inet6_synth.h"

namespace amcl {
namespace ifinet6 {

/**
 * 用 getifaddrs() 收集本机的 IPv6 地址，转成 if_inet6 的行记录。
 *
 * 公开出来是为了让 DevTools 的 IPv6 探针**复用同一份收集逻辑** ——
 * 探针里打印的"合成预演"因此就是垫片真正会产出的内容，而不是另写一遍的近似物。
 *
 * @return 收集到的条数（同 out.size()）；getifaddrs 失败返回 0 且 out 为空。
 */
std::size_t collectLocalEntries(std::vector<Entry> &out);

} // namespace ifinet6
} // namespace amcl

extern "C" {
#endif

/**
 * elf_loader 的 fopen 插桩入口。
 *
 * @return 非 NULL = 本垫片提供的可读流（调用方直接返回它）；
 *         NULL    = 本垫片不接管，**调用方必须回落真 fopen**。
 */
FILE *amclIfInet6ShimOpen(const char *path, const char *mode);

/** 供诊断使用：返回 [IPV6-SHIM] 观测行里 mode= 的当前开关取值（"on" / "off"）。 */
const char *amclIfInet6ShimModeName(void);

#ifdef __cplusplus
}
#endif

#endif // MC_OHOS_IF_INET6_SHIM_H
