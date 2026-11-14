/*
 * 历史异常/展开伪实现已经退役；保留入口让旧手工构建命令明确失败。
 * 真实实现由 prepare_jdk_abi.sh 链接同 SDK 的 libc++_shared.so。
 */
#error "Retired fake EH provider: use prepare_jdk_abi.sh and the real SDK C++ runtime"
