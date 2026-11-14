/** 仅宿主政策测试使用的系统权限声明；实现由夹具显式控制，不编入应用。 */
#pragma once
extern "C" bool OH_AT_CheckSelfPermission(const char* permission);
