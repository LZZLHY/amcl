#include "../../../utils/amcl_log.h"

// 策略测试只验证决策，不启动文件系统 writer；日志持久性另由真实 writer 探针验证。
extern "C" void amclLogWrite(AmclLogLevel, const char*, const char*, ...) {}
extern "C" void amclLogPrint(AmclLogLevel, unsigned int, const char*, const char*, ...) {}
