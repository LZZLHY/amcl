/**
 * 保留历史 libcxxabi_shim.so 依赖名的薄入口。
 *
 * guard、异常、RTTI、new/delete 和展开由 DT_NEEDED 指向的应用 NDK
 * libc++_shared.so 实现。这里不能重新定义这些符号或把失败伪装成成功。
 * JDK8 的 libc 名称兼容由独立 C 文件一起链接，不进入 C++ ABI 域。
 * 返回值只标识外壳协议，不代表设备的加载、异常和 TLS 已通过验证。
 */
extern "C" __attribute__((visibility("default")))
unsigned amcl_jdk_abi_facade_version() noexcept
{
    return 2;
}
